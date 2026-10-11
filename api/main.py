import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import boto3
from fastapi import FastAPI, HTTPException, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from prometheus_fastapi_instrumentator import Instrumentator
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker


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
log = logging.getLogger("api")


SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
S3_BUCKET = os.environ["S3_BUCKET"]
AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
MAX_BODY_BYTES = int(os.environ.get("MAX_BODY_BYTES", 10 * 1024 * 1024))

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
        pool_size=5,
        max_overflow=10,
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
        os.environ["DATABASE_URL"],
        pool_size=5,
        max_overflow=10,
        pool_pre_ping=True,
    )

SessionLocal = sessionmaker(bind=engine)


def init_db():
    with engine.begin() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS jobs (
                job_id      UUID PRIMARY KEY,
                status      TEXT NOT NULL DEFAULT 'pending',
                s3_key      TEXT NOT NULL,
                submitted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                completed_at TIMESTAMPTZ
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS results (
                job_id          UUID PRIMARY KEY REFERENCES jobs(job_id),
                total_sales     NUMERIC,
                rows_processed  INTEGER,
                rows_rejected   INTEGER,
                computed_at     TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """))


class SaleRecord(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)

    region: str | None = Field(default=None, max_length=64)
    amount: float | None = None
    sale_date: str | None = Field(default=None, max_length=32)
    order_id: str | None = Field(default=None, max_length=64)


class JobSubmission(BaseModel):
    records: list[SaleRecord] = Field(..., min_length=1, max_length=50_000)


class JobAccepted(BaseModel):
    job_id: uuid.UUID
    status: str


class JobStatus(BaseModel):
    job_id: uuid.UUID
    status: str
    submitted_at: datetime
    completed_at: datetime | None


class JobResult(BaseModel):
    job_id: uuid.UUID
    total_sales: float | None
    rows_processed: int | None
    rows_rejected: int | None


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    log.info("api started, tables ready")
    yield
    engine.dispose()
    log.info("api shutting down, db pool disposed")


app = FastAPI(title="sales-pipeline-api", lifespan=lifespan)

Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)


@app.middleware("http")
async def limit_body_size(request: Request, call_next):
    if request.method in ("POST", "PUT", "PATCH"):
        cl = request.headers.get("content-length")
        if cl is None:
            return Response(status_code=411)
        try:
            n = int(cl)
            if n < 0:
                return Response(status_code=400)
            if n > MAX_BODY_BYTES:
                return Response(status_code=413)
        except ValueError:
            return Response(status_code=400)
    return await call_next(request)


def _sanitize(obj):
    if isinstance(obj, float) and (obj != obj or obj in (float("inf"), float("-inf"))):
        return str(obj)
    if isinstance(obj, dict):
        return {k: _sanitize(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_sanitize(v) for v in obj]
    return obj


@app.exception_handler(RequestValidationError)
async def validation_handler(request: Request, exc: RequestValidationError):
    encoded = jsonable_encoder(exc.errors())
    return JSONResponse(status_code=422, content={"detail": _sanitize(encoded)})


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        sqs.get_queue_attributes(
            QueueUrl=SQS_QUEUE_URL, AttributeNames=["QueueArn"]
        )
        s3.head_bucket(Bucket=S3_BUCKET)
        return {"status": "ready"}
    except Exception as e:
        log.error(f"readiness check failed: {e}")
        raise HTTPException(status_code=503, detail="dependencies unavailable")


@app.post("/jobs", response_model=JobAccepted, status_code=202)
def submit_job(submission: JobSubmission):
    job_id = str(uuid.uuid4())
    s3_key = f"raw/{job_id}.json"

    body = submission.model_dump_json().encode("utf-8")
    try:
        s3.put_object(Bucket=S3_BUCKET, Key=s3_key, Body=body)
    except Exception as e:
        log.error(f"failed to store batch in s3: {e}", extra={"job_id": job_id})
        raise HTTPException(status_code=502, detail="could not store batch")

    db = SessionLocal()
    try:
        db.execute(
            text("INSERT INTO jobs (job_id, status, s3_key) "
                 "VALUES (:job_id, 'pending', :s3_key)"),
            {"job_id": job_id, "s3_key": s3_key},
        )
        db.commit()
    except Exception as e:
        db.rollback()
        log.error(f"failed to record job: {e}", extra={"job_id": job_id})
        raise HTTPException(status_code=500, detail="could not record job")
    finally:
        db.close()

    message = {
        "job_id": job_id,
        "s3_key": s3_key,
    }
    try:
        sqs.send_message(QueueUrl=SQS_QUEUE_URL, MessageBody=json.dumps(message))
    except Exception as e:
        log.error(f"failed to enqueue: {e}", extra={"job_id": job_id})
        _mark_failed(job_id)
        raise HTTPException(status_code=502, detail="could not enqueue job")

    log.info("job accepted", extra={"job_id": job_id})
    return JobAccepted(job_id=job_id, status="pending")


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


@app.get("/jobs/{job_id}", response_model=JobStatus)
def get_job(job_id: uuid.UUID):
    db = SessionLocal()
    try:
        row = db.execute(
            text("SELECT job_id, status, submitted_at, completed_at "
                 "FROM jobs WHERE job_id=:job_id"),
            {"job_id": str(job_id)},
        ).mappings().first()
        if not row:
            raise HTTPException(status_code=404, detail="job not found")
        return JobStatus(**row)
    finally:
        db.close()


@app.get("/jobs/{job_id}/result", response_model=JobResult)
def get_result(job_id: uuid.UUID):
    db = SessionLocal()
    try:
        row = db.execute(
            text("SELECT job_id, total_sales, rows_processed, "
                 "rows_rejected FROM results WHERE job_id=:job_id"),
            {"job_id": str(job_id)},
        ).mappings().first()
        if not row:
            raise HTTPException(status_code=404,
                                detail="no result yet (job pending or failed)")
        return JobResult(**row)
    finally:
        db.close()
