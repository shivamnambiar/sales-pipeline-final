import json
import os
from datetime import datetime
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

os.environ["DATABASE_URL"] = "sqlite:///./test.db"
os.environ["SQS_QUEUE_URL"] = queue_url
os.environ["S3_BUCKET"] = "sales-raw"

import main
from sqlalchemy import text

def sqlite_init_db():
    with main.engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                status TEXT NOT NULL DEFAULT 'pending',
                s3_key TEXT NOT NULL,
                submitted_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                completed_at TIMESTAMP
            )"""))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS results (
                job_id TEXT PRIMARY KEY,
                total_sales NUMERIC,
                rows_processed INTEGER,
                rows_rejected INTEGER,
                computed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )"""))
main.init_db = sqlite_init_db
sqlite_init_db()

from fastapi.testclient import TestClient

client = TestClient(main.app)
failures = []

def check(name, cond):
    print(("PASS" if cond else "FAIL"), "-", name)
    if not cond:
        failures.append(name)

r = client.get("/healthz")
check("healthz returns 200", r.status_code == 200)
check("healthz body ok", r.json() == {"status": "ok"})

r = client.get("/readyz")
check("readyz returns 200", r.status_code == 200)

batch = {"records": [
    {"region": "West", "amount": 100.0, "sale_date": "2026-01-01", "order_id": "a1"},
    {"region": "East", "amount": -5.0, "sale_date": "bad-date", "order_id": "a2"},
    {"region": None, "amount": None, "sale_date": None, "order_id": "a3"},
]}
r = client.post("/jobs", json=batch)
check("submit returns 202", r.status_code == 202)
job_id = r.json().get("job_id")
check("submit returns a job_id", bool(job_id))
check("submit status pending", r.json().get("status") == "pending")

objs = s3.list_objects_v2(Bucket="sales-raw").get("Contents", [])
check("batch stored in S3", len(objs) == 1)
check("S3 key matches job", objs and objs[0]["Key"] == f"raw/{job_id}.json")
stored = json.loads(s3.get_object(Bucket="sales-raw",
                    Key=f"raw/{job_id}.json")["Body"].read())
check("S3 object holds all 3 records", len(stored["records"]) == 3)

msgs = sqs.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10).get("Messages", [])
check("one message enqueued", len(msgs) == 1)
if msgs:
    body = json.loads(msgs[0]["Body"])
    check("message has job_id", body.get("job_id") == job_id)
    check("message has s3_key pointer", body.get("s3_key") == f"raw/{job_id}.json")
    check("message does NOT contain sales data", "records" not in body)
    check("pointer message is tiny (<500 bytes)", len(msgs[0]["Body"]) < 500)

r = client.get(f"/jobs/{job_id}")
check("status returns 200", r.status_code == 200)
check("status is pending", r.json().get("status") == "pending")

r = client.get(f"/jobs/{job_id}/result")
check("result 404s before processing", r.status_code == 404)

r = client.get("/jobs/00000000-0000-0000-0000-000000000000")
check("unknown job 404s", r.status_code == 404)

r = client.post("/jobs", json={"records": []})
check("empty batch rejected (422)", r.status_code == 422)

r = client.post("/jobs", json={"records": [
    {"region": "X" * 100, "amount": 1, "sale_date": "2026-01-01"}]})
check("oversized region string rejected (422)", r.status_code == 422)

r = client.post("/jobs", content='{"records": [{"region": "W", "amount": NaN, '
                                  '"sale_date": "2026-01-01"}]}',
                headers={"content-type": "application/json"})
check("NaN amount rejected by API (422)", r.status_code == 422)

r = client.get("/jobs/not-a-uuid")
check("invalid UUID path param rejected (422 not 500)", r.status_code == 422)

big_body = '{"records": [' + ",".join(
    ['{"region":"W","amount":1,"sale_date":"2026-01-01"}'] * 5) + ']}'
r = client.post("/jobs", content=big_body,
                headers={"content-type": "application/json",
                         "content-length": str(20 * 1024 * 1024)})
check("oversized Content-Length rejected (413)", r.status_code == 413)

import asyncio as _asyncio
from main import limit_body_size as _limit

async def _cn(_r):
    from starlette.responses import Response as _R
    return _R(status_code=200)

_no_cl = _asyncio.run(_limit(
    type("R", (), {"method": "POST", "headers": {}})(), _cn))
check("missing Content-Length on POST rejected (411)", _no_cl.status_code == 411)

from main import validation_handler as _vh
from fastapi.exceptions import RequestValidationError as _RVE
_exc = _RVE([{"type": "value_error", "loc": ("body", "x"), "msg": "bad",
             "input": "bad", "ctx": {"error": ValueError("raw object")}}])
_vr = _asyncio.run(_vh(None, _exc))
check("validation handler 422s on raw ctx object (not 500)",
      _vr.status_code == 422 and bool(_vr.body))

import uuid as _uuid
from main import JobStatus as _JS, JobResult as _JR, JobAccepted as _JA
_u = _uuid.uuid4()
try:
    _js = _JS(job_id=_u, status="done", submitted_at=datetime.now(), completed_at=None)
    _jr = _JR(job_id=_u, total_sales=1.0, rows_processed=1, rows_rejected=0)
    _ja = _JA(job_id=str(_u), status="pending")
    _uuid_ok = (f'"{_u}"' in _js.model_dump_json()
                and f'"{_u}"' in _jr.model_dump_json()
                and f'"{_u}"' in _ja.model_dump_json())
except Exception:
    _uuid_ok = False
check("response models accept UUID objects (real Postgres path)", _uuid_ok)

mock.stop()
print()
if failures:
    print(f"{len(failures)} FAILURE(S):", failures)
    raise SystemExit(1)
print("ALL CHECKS PASSED")
