import json
import os
import boto3
from moto import mock_aws

mock = mock_aws()
mock.start()

REGION = "us-east-1"
os.environ["AWS_DEFAULT_REGION"] = REGION
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"

s3 = boto3.client("s3", region_name=REGION)
s3.create_bucket(Bucket="sales-raw")
sqs = boto3.client("sqs", region_name=REGION)
queue_url = sqs.create_queue(QueueName="sales-jobs")["QueueUrl"]

os.environ["DATABASE_URL"] = "sqlite:///./worker_test.db"
os.environ["SQS_QUEUE_URL"] = queue_url
os.environ["S3_BUCKET"] = "sales-raw"

import worker
from sqlalchemy import text

with worker.engine.begin() as conn:
    conn.execute(text("""
        CREATE TABLE jobs (
            job_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'pending',
            s3_key TEXT NOT NULL, submitted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            completed_at TIMESTAMP)"""))
    conn.execute(text("""
        CREATE TABLE results (
            job_id TEXT PRIMARY KEY, total_sales NUMERIC,
            rows_processed INTEGER, rows_rejected INTEGER,
            computed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"""))

failures = []
def check(name, cond):
    print(("PASS" if cond else "FAIL"), "-", name)
    if not cond:
        failures.append(name)


JOB_ID = "11111111-1111-1111-1111-111111111111"
S3_KEY = f"raw/{JOB_ID}.json"

with worker.engine.begin() as conn:
    conn.execute(text("INSERT INTO jobs (job_id, status, s3_key) "
                      "VALUES (:j, 'pending', :k)"), {"j": JOB_ID, "k": S3_KEY})

batch = {"records": [
    {"region": "West", "amount": 100, "sale_date": "2026-01-01", "order_id": "1"},
    {"region": "West", "amount": 50, "sale_date": "2026-01-02", "order_id": "2"},
    {"region": "East", "amount": 200, "sale_date": "2026-01-03", "order_id": "3"},
    {"region": "East", "amount": -5, "sale_date": "2026-01-04", "order_id": "4"},
]}
s3.put_object(Bucket="sales-raw", Key=S3_KEY, Body=json.dumps(batch).encode())

sqs.send_message(QueueUrl=queue_url,
                 MessageBody=json.dumps({"job_id": JOB_ID, "s3_key": S3_KEY}))

import sqlalchemy
_real_execute = sqlalchemy.engine.Connection.execute
def _patched_execute(self, statement, *a, **k):
    try:
        s = str(statement)
        if "now()" in s:
            statement = text(s.replace("now()", "CURRENT_TIMESTAMP"))
    except Exception:
        pass
    return _real_execute(self, statement, *a, **k)
sqlalchemy.engine.Connection.execute = _patched_execute

resp = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
msg = resp["Messages"][0]
should_delete = worker.handle_message(msg)
check("first process returns delete=True", should_delete is True)

def get_result():
    with worker.engine.connect() as conn:
        return conn.execute(text("SELECT total_sales, rows_processed, rows_rejected "
                                 "FROM results WHERE job_id=:j"),
                            {"j": JOB_ID}).mappings().first()

r1 = get_result()
check("result row written", r1 is not None)
check("total_sales = 350 (100+50+200)", r1 and float(r1["total_sales"]) == 350)
check("rows_processed = 3", r1 and r1["rows_processed"] == 3)
check("rows_rejected = 1", r1 and r1["rows_rejected"] == 1)

def get_status():
    with worker.engine.connect() as conn:
        return conn.execute(text("SELECT status FROM jobs WHERE job_id=:j"),
                            {"j": JOB_ID}).scalar()
check("job marked done", get_status() == "done")

def count_results():
    with worker.engine.connect() as conn:
        return conn.execute(text("SELECT COUNT(*) FROM results WHERE job_id=:j"),
                            {"j": JOB_ID}).scalar()
check("exactly 1 result row after first process", count_results() == 1)

sqs.send_message(QueueUrl=queue_url,
                 MessageBody=json.dumps({"job_id": JOB_ID, "s3_key": S3_KEY}))
resp2 = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=1)
msg2 = resp2["Messages"][0]
should_delete2 = worker.handle_message(msg2)
check("redelivery returns delete=True", should_delete2 is True)

r2 = get_result()
check("total STILL 350 after redelivery (no double-count)",
      r2 and float(r2["total_sales"]) == 350)
check("STILL exactly 1 result row (idempotent)", count_results() == 1)

BIG_JOB = "22222222-2222-2222-2222-222222222222"
BIG_KEY = f"raw/{BIG_JOB}.json"
with worker.engine.begin() as conn:
    conn.execute(text("INSERT INTO jobs (job_id, status, s3_key) "
                      "VALUES (:j, 'pending', :k)"), {"j": BIG_JOB, "k": BIG_KEY})
big_body = json.dumps({"records": [{"region": "X", "amount": 1,
                       "sale_date": "2026-01-01", "order_id": str(i)}
                       for i in range(100)]}).encode()
s3.put_object(Bucket="sales-raw", Key=BIG_KEY, Body=big_body)
worker.MAX_S3_BYTES = 10
big_delete = worker.handle_message(
    {"Body": json.dumps({"job_id": BIG_JOB, "s3_key": BIG_KEY}),
     "ReceiptHandle": "y"})
check("oversized object returns delete=True (failed, not reprocessed)",
      big_delete is True)
with worker.engine.connect() as conn:
    big_status = conn.execute(text("SELECT status FROM jobs WHERE job_id=:j"),
                              {"j": BIG_JOB}).scalar()
check("oversized job marked failed", big_status == "failed")
with worker.engine.connect() as conn:
    big_results = conn.execute(text("SELECT COUNT(*) FROM results WHERE job_id=:j"),
                               {"j": BIG_JOB}).scalar()
check("oversized job wrote NO result row", big_results == 0)
worker.MAX_S3_BYTES = 50 * 1024 * 1024

should_delete3 = worker.handle_message({"Body": "not json", "ReceiptHandle": "x"})
check("malformed message returns delete=False (goes to DLQ)",
      should_delete3 is False)

forged = worker.handle_message({
    "Body": json.dumps({"job_id": "33333333-3333-3333-3333-333333333333",
                        "s3_key": "tfstate/secrets.json"}),
    "ReceiptHandle": "z"})
check("forged s3_key rejected (delete=False, never fetched)", forged is False)

bad_uuid = worker.handle_message({
    "Body": json.dumps({"job_id": "not-a-uuid", "s3_key": "raw/not-a-uuid.json"}),
    "ReceiptHandle": "z2"})
check("non-UUID job_id rejected", bad_uuid is False)

POISON_JOB = "44444444-4444-4444-4444-444444444444"
POISON_KEY = f"raw/{POISON_JOB}.json"
with worker.engine.begin() as conn:
    conn.execute(text("INSERT INTO jobs (job_id, status, s3_key) "
                      "VALUES (:j, 'pending', :k)"), {"j": POISON_JOB, "k": POISON_KEY})
s3.put_object(Bucket="sales-raw", Key=POISON_KEY,
              Body=json.dumps({"records": "abc"}).encode())
poison = worker.handle_message({
    "Body": json.dumps({"job_id": POISON_JOB, "s3_key": POISON_KEY}),
    "ReceiptHandle": "z3"})
check("non-list records returns delete=True (failed, not poison loop)",
      poison is True)
with worker.engine.connect() as conn:
    poison_status = conn.execute(text("SELECT status FROM jobs WHERE job_id=:j"),
                                 {"j": POISON_JOB}).scalar()
check("non-list records job marked failed", poison_status == "failed")

mock.stop()
print()
if failures:
    print(f"{len(failures)} FAILURE(S):", failures)
    raise SystemExit(1)
print("ALL INTEGRATION TESTS PASSED")
