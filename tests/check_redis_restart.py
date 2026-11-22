#!/usr/bin/env python3
"""Run the task's Redis entrypoint and interrupt native Kombu work mid-scan."""
import os
import re
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import time

from kombu import Connection
from redis import Redis
from redis.exceptions import AuthenticationError, ConnectionError, NoPermissionError

QUEUE = "gai_sampler_subcall_queue"
WORKER = "synthetic-worker-only"
EXPORTER = "synthetic-exporter-only"


def broker(port, cert_path):
    return Connection(
        f"rediss://scan-worker:{WORKER}@127.0.0.1:{port}/0",
        ssl={"ssl_ca_certs": cert_path, "ssl_cert_reqs": ssl.CERT_REQUIRED, "ssl_check_hostname": True},
        transport_options={"visibility_timeout": 1},
    )


def reserve(port, cert_path):
    with broker(port, cert_path) as connection:
        queue = connection.SimpleQueue(QUEUE)
        assert queue.get(timeout=5).payload == {"scan": "canary", "chunk": 1}
        print("reserved", flush=True)
        time.sleep(30)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_ready(process, client):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(process.stdout.read())
        try:
            if client.ping():
                return
        except ConnectionError:
            time.sleep(0.05)
    raise AssertionError("Redis did not become healthy")


def check():
    module = Path(__file__).resolve().parents[1]
    entrypoint = (module / "redis-entrypoint.sh").read_text()
    worker_access = re.search(r'redis_worker_access\s*=\s*"([^"]+)"', (module / "redis.tf").read_text()).group(1)
    with tempfile.TemporaryDirectory() as directory:
        base = Path(directory)
        cert = base / "test.pem"
        key = base / "test.key"
        subprocess.run(
            ["openssl", "req", "-x509", "-nodes", "-newkey", "rsa:2048", "-days", "1",
             "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
             "-keyout", str(key), "-out", str(cert)],
            check=True, capture_output=True,
        )
        (base / "data").mkdir()
        port = free_port()

        def start(runtime, service_port):
            (base / runtime).mkdir()
            return subprocess.Popen(
                ["sh", "-ec", entrypoint],
                env={**os.environ, "REDIS_BIND": "127.0.0.1", "REDIS_PORT": str(service_port),
                     "REDIS_DATA_DIR": str(base / "data"), "REDIS_RUNTIME_DIR": str(base / runtime),
                     "REDIS_WORKER_USER": "scan-worker", "REDIS_WORKER_PASSWORD": WORKER,
                     "REDIS_EXPORTER_USER": "queue-exporter", "REDIS_EXPORTER_PASSWORD": EXPORTER,
                     "REDIS_WORKER_ACCESS": worker_access,
                     "REDIS_EXPORTER_ACCESS": f"on ~{QUEUE} ~inhost-runtime:v1:canary:* -@all +ping +select +llen +mget",
                     "REDIS_TLS_CERTIFICATE": cert.read_text(), "REDIS_TLS_KEY": key.read_text(),
                     "REDIS_MAX_MEMORY": "32mb"},
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            )

        def client(user, password):
            return Redis(host="127.0.0.1", port=port, username=user, password=password,
                         ssl=True, ssl_ca_certs=str(cert), ssl_check_hostname=True, socket_timeout=1)

        first = start("first", port)
        worker = replacement = contender = None
        try:
            wait_ready(first, client("scan-worker", WORKER))
            subprocess.run(
                ["sh", "-ec", entrypoint, "redis-entrypoint", "health"],
                env={**os.environ, "SSL_CERT_FILE": str(cert), "REDIS_HOSTNAME": "127.0.0.1",
                     "REDIS_PORT": str(port), "REDIS_WORKER_USER": "scan-worker",
                     "REDIS_WORKER_PASSWORD": WORKER},
                check=True, timeout=5,
            )
            with broker(port, str(cert)) as connection:
                queue = connection.SimpleQueue(QUEUE)
                queue.put({"scan": "canary", "chunk": 1})
                queue.put({"scan": "canary", "chunk": 2})
                queue.close()

            worker = subprocess.Popen(
                [sys.executable, __file__, str(port), str(cert)],
                stdout=subprocess.PIPE, text=True,
            )
            assert worker.stdout in select.select([worker.stdout], [], [], 8)[0]
            assert worker.stdout.readline().strip() == "reserved"

            for probe in (client(None, None), client("default", WORKER)):
                try:
                    probe.ping()
                except AuthenticationError:
                    pass
                else:
                    raise AssertionError("The Redis default user accepted a connection")

            worker_probe = client("scan-worker", WORKER)
            assert worker_probe.hlen("unacked") == 1
            assert worker_probe.zcard("unacked_index") == 1
            exporter = client("queue-exporter", EXPORTER)
            assert exporter.llen(QUEUE) == 1
            try:
                exporter.lpush(QUEUE, "forbidden")
            except NoPermissionError:
                pass
            else:
                raise AssertionError("Read-only exporter was allowed to write to the broker")

            contender = start("contender", free_port())
            assert contender.wait(timeout=5) != 0, "Concurrent Redis acquired the persistent data directory"
            first.kill()
            first.wait(timeout=5)
            worker.kill()
            worker.wait(timeout=5)

            replacement = start("replacement", port)
            wait_ready(replacement, client("scan-worker", WORKER))
            assert exporter.llen(QUEUE) == 1, "Waiting work disappeared during server replacement"
            assert worker_probe.hlen("unacked") == 1, "AOF did not replay the broker reservation"
            assert worker_probe.zcard("unacked_index") == 1, "AOF did not replay the reservation index"
            with broker(port, str(cert)) as connection:
                queue = connection.SimpleQueue(QUEUE)
                deadline = time.monotonic() + 6
                while exporter.llen(QUEUE) < 2:
                    queue.channel.qos.restore_visible(interval=1)
                    assert time.monotonic() < deadline, "Unacknowledged work was not redelivered"
                    time.sleep(0.05)
                delivered = []
                for _ in range(2):
                    message = queue.get(timeout=4)
                    delivered.append(message.payload)
                    message.ack()
                assert sorted(item["chunk"] for item in delivered) == [1, 2], delivered
                assert all(item["scan"] == "canary" for item in delivered)
                assert exporter.llen(QUEUE) == 0
            print("PASS: Redis restart preserved waiting work and redelivered the interrupted scan chunk")
        finally:
            for process in (first, worker, contender, replacement):
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        reserve(int(sys.argv[1]), sys.argv[2])
    else:
        check()
