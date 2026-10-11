import json
import logging
import os
import signal
import sys
import time
import uuid
from datetime import datetime, timezone

import boto3
from prometheus_client import Counter, Histogram, start_http_server
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

from processing import process_batch


JOBS_PROCESSED = Counter(
    "worker_jobs_processed_total",
    "Jobs processed by outcome",
    ["outcome"],
)
RECORDS = Counter(
    "worker_records_total",
    "Sales records seen by outcome",
    ["outcome"],
)
RECORDS_REJECTED = Counter(
    "worker_records_rejected_total",
    "Rejected records by reason",
    ["reason"],
)
PROCESSING_SECONDS = Histogram(
    "worker_processing_seconds",
    "Time spent in process_batch per job",
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30),
)


class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "msg": record.getMessage(),
            "logger": record.name,
        }
        if hasattr(record, "job_id"):
            payload["job_id"] = record.job_id
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
log = logging.getLogger("worker")


SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
S3_BUCKET = os.environ["S3_BUCKET"]
AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
MAX_S3_BYTES = int(os.environ.get("MAX_S3_BYTES", 15 * 1024 * 1024))

_boto_kwargs = {"endpoint_url": AWS_ENDPOINT_URL} if AWS_ENDPOINT_URL else {}
s3 = boto3.client("s3", **_boto_kwargs)
sqs = boto3.client("sqs", **_boto_kwargs)

DB_IAM_AUTH = os.environ.get("DB_IAM_AUTH", "false").lower() == "true"

if DB_IAM_AUTH:
    from sqlalchemy import event

    DB_HOST = os.environ["DB_HOST"]
    DB_PORT = int(os.environ.get("DB_PORT", 5432))
    DB_NAME = os.environ["DB_NAME"]
    DB_USER = os.environ["DB_USER"]
    AWS_REGION = os.environ["AWS_DEFAULT_REGION"]
    _rds = boto3.client("rds", region_name=AWS_REGION)

    engine = create_engine(
        f"postgresql+psycopg2://{DB_USER}@{DB_HOST}:{DB_PORT}/{DB_NAME}",
        pool_size=2,
        max_overflow=5,
        pool_pre_ping=True,
        connect_args={"sslmode": "require"},
    )

    @event.listens_for(engine, "do_connect")
    def _provide_iam_token(dialect, conn_rec, cargs, cparams):
        cparams["password"] = _rds.generate_db_auth_token(
            DBHostname=DB_HOST, Port=DB_PORT, DBUsername=DB_USER, Region=AWS_REGION
        )
else:
    engine = create_engine(
        os.environ["DATABASE_URL"], pool_size=2, max_overflow=5, pool_pre_ping=True
    )

SessionLocal = sessionmaker(bind=engine)


_shutdown = False


def _handle_signal(signum, frame):
    global _shutdown
    log.info(f"received signal {signum}, will stop after current message")
    _shutdown = True


signal.signal(signal.SIGTERM, _handle_signal)
signal.signal(signal.SIGINT, _handle_signal)


def write_result_idempotent(job_id: str, summary: dict) -> bool:
    total_all = sum(summary["region_totals"].values())

    db = SessionLocal()
    try:
        res = db.execute(
            text("""
                INSERT INTO results
                    (job_id, total_sales, rows_processed, rows_rejected)
                VALUES
                    (:job_id, :total, :processed, :rejected)
                ON CONFLICT (job_id) DO NOTHING
            """),
            {
                "job_id": job_id,
                "total": total_all,
                "processed": summary["rows_processed"],
                "rejected": summary["rows_rejected"],
            },
        )
        first_time = res.rowcount > 0
        if first_time:
            db.execute(
                text("UPDATE jobs SET status='done', completed_at=now() "
                     "WHERE job_id=:job_id"),
                {"job_id": job_id},
            )
        db.commit()
        return first_time
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def handle_message(msg) -> bool:
    try:
        body = json.loads(msg["Body"])
        job_id = body["job_id"]
        s3_key = body["s3_key"]
    except (KeyError, json.JSONDecodeError, TypeError) as e:
        log.error(f"malformed message, leaving for DLQ redrive: {e}")
        return False

    if not isinstance(job_id, str) or not isinstance(s3_key, str):
        log.error("message fields not strings, leaving for DLQ redrive")
        return False

    try:
        uuid.UUID(job_id)
    except ValueError:
        log.error("job_id is not a valid UUID, leaving for DLQ redrive")
        return False

    if s3_key != f"raw/{job_id}.json":
        log.error(f"s3_key {s3_key} does not match expected raw/{{job_id}}.json; "
                  f"leaving for DLQ redrive", extra={"job_id": job_id})
        return False

    try:
        head = s3.head_object(Bucket=S3_BUCKET, Key=s3_key)
        size = head.get("ContentLength", 0)
        if size > MAX_S3_BYTES:
            log.error(
                f"object {s3_key} is {size} bytes, exceeds cap {MAX_S3_BYTES}; "
                f"marking job failed",
                extra={"job_id": job_id},
            )
            _mark_failed(job_id)
            return True

        obj = s3.get_object(Bucket=S3_BUCKET, Key=s3_key)
        batch = json.loads(obj["Body"].read())
        records = batch.get("records", []) if isinstance(batch, dict) else None
        if not isinstance(records, list):
            log.error("batch 'records' is not a list; marking job failed",
                      extra={"job_id": job_id})
            _mark_failed(job_id)
            return True

        with PROCESSING_SECONDS.time():
            summary = process_batch(records)

        first_time = write_result_idempotent(job_id, summary)
        if first_time:
            RECORDS.labels(outcome="processed").inc(summary["rows_processed"])
            RECORDS.labels(outcome="rejected").inc(summary["rows_rejected"])
            for reason, count in summary["rejection_breakdown"].items():
                RECORDS_REJECTED.labels(reason=reason).inc(count)
            JOBS_PROCESSED.labels(outcome="processed").inc()
            log.info(
                f"processed: {summary['rows_processed']} ok, "
                f"{summary['rows_rejected']} rejected "
                f"({summary['rejection_breakdown']})",
                extra={"job_id": job_id},
            )
        else:
            JOBS_PROCESSED.labels(outcome="redelivery_skipped").inc()
            log.info("already processed (redelivery), skipping",
                     extra={"job_id": job_id})
        return True
    except Exception as e:
        JOBS_PROCESSED.labels(outcome="failed").inc()
        log.error(f"processing failed: {e}", extra={"job_id": job_id})
        return False


def _mark_failed(job_id: str):
    db = SessionLocal()
    try:
        db.execute(
            text("UPDATE jobs SET status='failed' WHERE job_id=:job_id "
                 "AND status NOT IN ('done', 'failed')"),
            {"job_id": job_id},
        )
        db.commit()
    except Exception as e:
        log.error(f"could not mark job failed: {e}", extra={"job_id": job_id})
    finally:
        db.close()


def main():
    start_http_server(int(os.environ.get("METRICS_PORT", 9100)))
    log.info("worker started, polling for messages")
    backoff = 1
    while not _shutdown:
        try:
            resp = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,
            )
            backoff = 1
            messages = resp.get("Messages", [])
            if not messages:
                continue

            for msg in messages:
                should_delete = handle_message(msg)
                if should_delete:
                    sqs.delete_message(
                        QueueUrl=SQS_QUEUE_URL,
                        ReceiptHandle=msg["ReceiptHandle"],
                    )
        except Exception as e:
            log.error(f"receive loop error, backing off {backoff}s: {e}")
            for _ in range(backoff):
                if _shutdown:
                    break
                time.sleep(1)
            backoff = min(backoff * 2, 30)

    log.info("shutdown complete, exiting cleanly")
    sys.exit(0)


if __name__ == "__main__":
    main()
