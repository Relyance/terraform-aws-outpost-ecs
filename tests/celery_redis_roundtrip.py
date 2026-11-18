"""No-task Celery/Kombu roundtrips inside the disposable network-none fixture."""
from concurrent.futures import ThreadPoolExecutor
import time
import uuid

from celery import Celery
from kombu import Connection, Consumer, Exchange, Producer, Queue
import redis

base = "redis://worker:synthetic-local-only@127.0.0.1:6379/"
reader = Celery("acl-native-reader", backend=base + "1")
writer = Celery("acl-native-writer", backend=base + "1")
for app in (reader, writer):
    app.conf.update(result_serializer="json", accept_content=["json"], result_expires=30,
                    result_backend_always_retry=False, redis_socket_timeout=2,
                    redis_socket_connect_timeout=2)
probe = redis.Redis.from_url(base + "0", socket_timeout=2)
task_id = "acl-proof-" + uuid.uuid4().hex
result = reader.AsyncResult(task_id)
channel = reader.backend.get_key_for_task(task_id)
with ThreadPoolExecutor(max_workers=1) as pool:
    pending = pool.submit(result.get, timeout=8, disable_sync_subtasks=False)
    deadline = time.monotonic() + 5
    while probe.pubsub_numsub(channel)[0][1] != 1:
        assert time.monotonic() < deadline, "Celery AsyncResult did not subscribe"
        time.sleep(0.02)
    writer.backend.store_result(task_id, {"native": "redis-result"}, "SUCCESS")
    assert pending.result(timeout=10) == {"native": "redis-result"}
reader.backend.result_consumer.stop()

exchange = Exchange("celeryev", type="fanout")
queue = Queue("acl-event-" + uuid.uuid4().hex, exchange=exchange,
              routing_key="worker.*", auto_delete=True, exclusive=True)
received = []
with Connection(base + "0", transport_options={"fanout_patterns": True}) as receiver:
    with Consumer(receiver, queues=[queue], accept=["json"], no_ack=True,
                  callbacks=[lambda body, message: received.append(body)]):
        with ThreadPoolExecutor(max_workers=1) as pool:
            def drain_until_received():
                deadline = time.monotonic() + 8
                while not received:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, "Kombu callback did not receive fanout message"
                    receiver.drain_events(timeout=remaining)
            pending = pool.submit(drain_until_received)
            deadline = time.monotonic() + 5
            while probe.pubsub_numpat() < 1:
                assert time.monotonic() < deadline, "Kombu fanout did not subscribe"
                time.sleep(0.02)
            with Connection(base + "0") as sender:
                Producer(sender).publish({"native": "kombu-event"}, exchange=exchange,
                                         routing_key="worker.online", serializer="json",
                                         declare=[exchange])
            pending.result(timeout=10)
assert received == [{"native": "kombu-event"}], received
print("PASS: native Celery AsyncResult subscriber/result-publication and Kombu Redis fanout roundtrips; no tasks executed")
