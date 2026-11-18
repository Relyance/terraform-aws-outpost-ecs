#!/usr/bin/env python3
"""Exercise the module's literal worker ACL in an isolated disposable local Redis.

Requires Docker and a locally available Redis7 image. No published ports, volumes,
cloud credentials, network access or real queue/data access. The password is only
an ephemeral synthetic fixture inside this disposable container. Set CELERY_IMAGE
to a cached amd64 application image to also prove native Celery/Kombu roundtrips.
"""
from pathlib import Path
import os
import json
import select
import re
import subprocess
import time
import uuid
from urllib.parse import urlsplit

source = (Path(__file__).resolve().parents[1] / "redis.tf").read_text()
worker = source.split('resource "aws_elasticache_user" "worker" {', 1)[1].split('\nresource ', 1)[0]
acl = re.search(r'access_string\s*=\s*"([^"]+)"', worker).group(1)
name = "inhost-acl-test-" + uuid.uuid4().hex[:12]
image = os.environ.get("REDIS_IMAGE", "redis:7-alpine")


def local_docker():
    environment = dict(os.environ)
    endpoint = environment.get("DOCKER_HOST")
    if not endpoint:
        endpoint = subprocess.check_output(
            ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"],
            env=environment, text=True, timeout=20,
        ).strip()
    parsed = urlsplit(endpoint)
    if (parsed.scheme != "unix" or parsed.netloc or not parsed.path.startswith("/")
            or len(parsed.path) <= 1 or parsed.query or parsed.fragment or "\n" in endpoint):
        raise ValueError("Local Redis ACL proof requires a Unix Docker socket")
    for key in ("DOCKER_HOST", "DOCKER_CONTEXT", "BUILDX_BUILDER", "BUILDKIT_HOST"):
        environment.pop(key, None)
    return ["docker", "--host", endpoint], environment


docker_command, environment = local_docker()


def docker(*args):
    try:
        return subprocess.check_output(docker_command + list(args), env=environment,
                                       text=True, stderr=subprocess.STDOUT, timeout=20).strip()
    except subprocess.CalledProcessError as error:
        raise RuntimeError("Local Docker fixture failed: " + error.output) from None


def admin(*args):
    return docker("exec", name, "redis-cli", "--raw", *args)


def worker_command(*args):
    return docker("exec", name, "redis-cli", "--raw", "--no-auth-warning", "--user", "worker", "-a", "synthetic-local-only", *args)


image_id = docker("image", "inspect", image, "--format", "{{.Id}}")
assert re.fullmatch(r"sha256:[a-f0-9]{64}", image_id), "Cached local image identity unavailable"
docker("run", "--pull=never", "--rm", "-d", "--network", "none", "--name", name, image_id,
       "redis-server", "--save", "", "--appendonly", "no")
try:
    for attempt in range(30):
        if admin("PING") == "PONG":
            break
        time.sleep(0.1)
    else:
        raise AssertionError("Local Redis did not become ready")
    version = docker("exec", name, "redis-server", "--version")
    result = admin("ACL", "SETUSER", "worker", "reset", ">synthetic-local-only", *acl.split())
    assert result == "OK", "Worker ACL rejected by native Redis parser: " + result
    assert worker_command("SET", "acl:fixture", "value") == "OK"
    assert worker_command("GET", "acl:fixture") == "value"
    channel = "celery-task-meta-fixture"
    assert worker_command("PUBLISH", channel, "probe") == "0", "Celery result channel publication denied"
    subscriber = subprocess.Popen(
        docker_command + ["exec", name, "redis-cli", "--raw", "--no-auth-warning", "--user", "worker",
                          "-a", "synthetic-local-only", "SUBSCRIBE", channel],
        env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0,
    )
    def subscription_line():
        line = b""
        while not line.endswith(b"\n"):
            assert select.select([subscriber.stdout], [], [], 5)[0], "Pub/Sub fixture timed out"
            chunk = os.read(subscriber.stdout.fileno(), 1)
            assert chunk, "Pub/Sub subscriber exited unexpectedly"
            line += chunk
        return line.decode().strip()
    try:
        assert [subscription_line() for _ in range(3)] == ["subscribe", channel, "1"]
        assert worker_command("PUBLISH", channel, "native-result") == "1"
        assert [subscription_line() for _ in range(3)] == ["message", channel, "native-result"]
    finally:
        subscriber.terminate()
        subscriber.communicate(timeout=5)
    celery_image = os.environ.get("CELERY_IMAGE")
    if celery_image:
        celery_id = docker("image", "inspect", celery_image, "--format", "{{.Id}}")
        assert re.fullmatch(r"sha256:[a-f0-9]{64}", celery_id), "Cached Celery image unavailable"
        code = Path(__file__).with_name("celery_redis_roundtrip.py").read_text()
        print(docker("run", "--pull=never", "--rm", "--platform", "linux/amd64", "--read-only", "--network", "container:" + name,
                     "--entrypoint", "python", "-e", "PYTHONDONTWRITEBYTECODE=1", celery_id, "-c", code))
    script = "return redis.call('INCR', KEYS[1])"
    sha = worker_command("SCRIPT", "LOAD", script)
    assert re.fullmatch(r"[0-9a-f]{40}", sha), "SCRIPT LOAD denied: " + sha
    assert worker_command("EVALSHA", sha, "1", "acl:counter") == "1"
    assert worker_command("EVAL", "return redis.call('GET', KEYS[1])", "1", "acl:counter") == "1"
    denied = [("SCRIPT", "FLUSH"), ("SCRIPT", "KILL"), ("SCRIPT", "DEBUG", "YES"),
              ("SCRIPT", "EXISTS", sha), ("CONFIG", "GET", "loglevel"),
              ("ACL", "LIST"), ("FLUSHALL",)]
    for command in denied:
        reply = worker_command(*command)
        assert reply.startswith("NOPERM"), "Expected ACL denial for " + " ".join(command[:2]) + ": " + reply
    exporter_file = os.environ.get("REDIS_EXPORTER_ACL_FILE")
    if exporter_file:
        exporter_acl = Path(exporter_file).read_text().strip()
        result = admin("ACL", "SETUSER", "exporter", "reset", ">synthetic-local-only", *exporter_acl.split())
        assert result == "OK", "Exporter ACL rejected: " + result
        patterns = [part[1:] for part in exporter_acl.split() if part.startswith("~")]
        queue = next(pattern for pattern in patterns if "*" not in pattern)
        registry = next(pattern.replace("*", "sampler:test") for pattern in patterns if "inhost-runtime:v1:" in pattern)
        assert admin("LPUSH", queue, "fixture") == "1"
        assert admin("SET", registry, "metadata") == "OK"
        def metrics(*command):
            return docker("exec", name, "redis-cli", "--raw", "--no-auth-warning", "--user", "exporter", "-a", "synthetic-local-only", *command)
        assert metrics("PING") == "PONG" and metrics("SELECT", "0") == "OK"
        assert metrics("LLEN", queue) == "1" and metrics("MGET", registry) == "metadata"
        for command in [("SET", registry, "no"), ("RPOP", queue), ("GET", registry),
                        ("MGET", "foreign:registry"), ("LLEN", "foreign:queue"),
                        ("SCAN", "0"), ("EVAL", "return 1", "0"), ("ACL", "LIST"),
                        ("PUBLISH", channel, "forbidden"), ("SUBSCRIBE", channel)]:
            assert metrics(*command).startswith("NOPERM"), "Exporter grant too broad: " + command[0]
        parsed = json.loads(docker("exec", name, "redis-cli", "--json", "ACL", "GETUSER", "exporter"))
        if isinstance(parsed, list):
            parsed = dict(zip(parsed[::2], parsed[1::2]))
        assert parsed["channels"] == "", "Exporter acquired Redis channel rights"
        print("PASS: actual evaluated exporter ACL permits PING/SELECT/LLEN/MGET; writes, pull, GET, foreign keys, SCAN, EVAL, ACL and Pub/Sub denied; channel ACL empty")
    print(version)
    print("PASS: module worker ACL parses; SET/GET/SCRIPT LOAD/EVAL/EVALSHA and paired PUBLISH/SUBSCRIBE allowed; "
          "SCRIPT FLUSH/KILL/DEBUG/EXISTS, CONFIG, ACL and FLUSHALL denied")
finally:
    subprocess.run(docker_command + ["rm", "-f", name], env=environment, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=False, timeout=20)
