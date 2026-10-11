import argparse
import array
import asyncio
import json
import math
import multiprocessing as mp
import os
import resource
import signal
import socket
import sys
import time
from multiprocessing.connection import wait
from urllib.parse import urlsplit

CSV_COLUMNS = (
    "ts", "stage", "offered", "sent", "offered_dropped", "inflight",
    "h202", "h400", "h411", "h413", "h422", "h500", "h502", "hother",
    "e_conn_refused", "e_conn_timeout", "e_read_timeout", "e_reset",
    "lat_p50_ms", "lat_p95_ms", "lat_max_ms", "bytes_sent", "records_sent",
)

STATUS_ORDER = (202, 400, 411, 413, 422, 500, 502)
STATUS_INDEX = {code: i for i, code in enumerate(STATUS_ORDER)}
STATUS_OTHER = len(STATUS_ORDER)
NSTATUS = STATUS_OTHER + 1

ERR_CONN_REFUSED = 0
ERR_CONN_TIMEOUT = 1
ERR_READ_TIMEOUT = 2
ERR_RESET = 3
NERR = 4

REGION_TOKENS = ("West", "East", "Nrth", "Suth", "Cntl", "NrWt", "SoEa", "MdWt")

REJECT_KINDS = (
    "non_positive_amount",
    "missing_region",
    "missing_amount",
    "unparseable_date",
    "missing_date",
    "duplicate_order_id",
)

SLOT_TABLE = 1000
DEFAULTS = {
    "workers": 2,
    "tick_ms": 5,
    "max_inflight": 512,
    "connect_timeout_s": 5.0,
    "read_timeout_s": 30.0,
    "bodies_per_variant": 8,
    "ndjson_path": None,
    "ndjson_sample": 1,
    "resolve_once": True,
    "start_grace_s": 3.0,
    "report_grace_s": 1.2,
    "drain_s": 5.0,
    "on_complete": "exit",
    "cpu_limit_m": None,
    "deadline_s": None,
}


def read_cpu_limit_m(fallback):
    try:
        with open("/sys/fs/cgroup/cpu.max") as fh:
            quota, period = fh.read().split()
        if quota != "max":
            return int(int(quota) / int(period) * 1000)
    except OSError:
        pass
    try:
        with open("/sys/fs/cgroup/cpu/cpu.cfs_quota_us") as fh:
            quota = int(fh.read())
        with open("/sys/fs/cgroup/cpu/cpu.cfs_period_us") as fh:
            period = int(fh.read())
        if quota > 0:
            return int(quota / period * 1000)
    except OSError:
        pass
    return fallback


def read_throttling():
    for path, key in (("/sys/fs/cgroup/cpu.stat", "nr_throttled"),
                      ("/sys/fs/cgroup/cpu/cpu.stat", "nr_throttled")):
        try:
            with open(path) as fh:
                for line in fh:
                    if line.startswith(key):
                        return int(line.split()[1])
        except OSError:
            continue
    return None


def raise_nofile(needed):
    import resource as rlim
    try:
        soft, hard = rlim.getrlimit(rlim.RLIMIT_NOFILE)
        if soft < hard:
            rlim.setrlimit(rlim.RLIMIT_NOFILE, (hard, hard))
            soft = hard
    except (ValueError, OSError) as exc:
        soft, hard = rlim.getrlimit(rlim.RLIMIT_NOFILE)
        err(f"could not raise RLIMIT_NOFILE: {exc}")
    err(f"RLIMIT_NOFILE soft={soft} hard={hard} needed={needed}")
    if needed > soft:
        err(f"WARNING max_inflight needs {needed} fds but the soft limit is {soft}; "
            "reduce max_inflight or raise the limit or connections will fail")
    return soft


def err(msg):
    sys.stderr.write(f"{time.time():.3f} loadgen {msg}\n")
    sys.stderr.flush()


class ConfigError(Exception):
    pass


def load_config(path):
    with open(path, "rb") as fh:
        raw = json.load(fh)
    cfg = dict(DEFAULTS)
    known = set(DEFAULTS) | {"target", "stages"}
    for key in raw:
        if key not in known:
            raise ConfigError(f"unknown config key: {key}")
    cfg.update(raw)
    if "target" not in cfg:
        raise ConfigError("config needs a target url")
    stages = cfg.get("stages")
    if not isinstance(stages, list) or not stages:
        raise ConfigError("config needs a non-empty stages list")
    cfg["stages"] = [_normalise_stage(i, s) for i, s in enumerate(stages)]
    if cfg["workers"] < 1:
        raise ConfigError("workers must be >= 1")
    if cfg["ndjson_sample"] < 1:
        raise ConfigError("ndjson_sample must be >= 1")
    if cfg["on_complete"] not in ("exit", "idle"):
        raise ConfigError("on_complete must be exit or idle")
    return cfg


def _normalise_stage(index, raw):
    stage_keys = {
        "name", "kind", "path", "rate", "duration_s", "count", "mix",
        "expect_status", "stop_rule", "note",
    }
    for key in raw:
        if key not in stage_keys:
            raise ConfigError(f"stage {index}: unknown key {key}")
    kind = raw.get("kind")
    if kind not in ("get", "jobs", "idle"):
        raise ConfigError(f"stage {index}: kind must be get, jobs or idle")
    stage = {
        "name": raw.get("name", f"stage{index}"),
        "kind": kind,
        "duration_s": float(raw["duration_s"]),
        "note": raw.get("note", ""),
        "count": raw.get("count"),
        "stop_rule": _normalise_stop_rule(index, raw.get("stop_rule")),
    }
    if stage["duration_s"] <= 0:
        raise ConfigError(f"stage {index}: duration_s must be > 0")
    if stage["duration_s"] != int(stage["duration_s"]):
        raise ConfigError(f"stage {index}: duration_s must be a whole number of "
                          "seconds so stage boundaries land on gen.csv row boundaries")
    if kind == "idle":
        stage["rate"] = 0.0
        stage["path"] = None
        stage["mix"] = []
        stage["expect_status"] = None
        return stage
    stage["rate"] = float(raw["rate"])
    if stage["rate"] <= 0:
        raise ConfigError(f"stage {index}: rate must be > 0")
    if kind == "get":
        stage["path"] = raw.get("path", "/__loadgen_ping")
        stage["mix"] = []
        stage["expect_status"] = int(raw.get("expect_status", 404))
        return stage
    stage["path"] = raw.get("path", "/jobs")
    stage["expect_status"] = int(raw.get("expect_status", 202))
    mix = raw.get("mix")
    if not isinstance(mix, list) or not mix:
        raise ConfigError(f"stage {index}: jobs stage needs a mix list")
    stage["mix"] = [_normalise_mix(index, m) for m in mix]
    total = sum(m["weight"] for m in stage["mix"])
    if total <= 0:
        raise ConfigError(f"stage {index}: mix weights must sum > 0")
    for m in stage["mix"]:
        m["weight"] = m["weight"] / total
    return stage


def _normalise_mix(index, raw):
    for key in raw:
        if key not in ("n", "weight", "reject_frac"):
            raise ConfigError(f"stage {index}: unknown mix key {key}")
    n = int(raw["n"])
    if not 1 <= n <= 50000:
        raise ConfigError(f"stage {index}: n must be within 1..50000")
    reject_frac = float(raw.get("reject_frac", 0.02))
    if not 0.0 <= reject_frac < 1.0:
        raise ConfigError(f"stage {index}: reject_frac must be within [0,1)")
    weight = float(raw.get("weight", 1.0))
    if weight <= 0:
        raise ConfigError(f"stage {index}: mix weight must be > 0")
    return {"n": n, "weight": weight, "reject_frac": reject_frac}


def _normalise_stop_rule(index, raw):
    if raw is None:
        return None
    for key in raw:
        if key not in ("accept_ratio_min", "cpu_frac_max", "window_s", "on_trip"):
            raise ConfigError(f"stage {index}: unknown stop_rule key {key}")
    rule = {
        "accept_ratio_min": raw.get("accept_ratio_min"),
        "cpu_frac_max": raw.get("cpu_frac_max"),
        "window_s": float(raw.get("window_s", 30.0)),
        "on_trip": raw.get("on_trip", "record"),
    }
    if rule["on_trip"] not in ("record", "end_run"):
        raise ConfigError(f"stage {index}: stop_rule on_trip must be record or end_run")
    return rule


def reject_positions(n, k, phase):
    marks = {}
    if k <= 0:
        return marks
    span = n - 1
    for j in range(k):
        pos = 1 + ((j * span) // k + phase * 7) % span
        while pos in marks:
            pos = 1 + (pos % span)
        marks[pos] = REJECT_KINDS[(j + phase) % len(REJECT_KINDS)]
    return marks


def build_bodies(n, reject_frac, count):
    k = int(round(n * reject_frac))
    if k > n - 1:
        k = n - 1
    bodies = []
    for phase in range(count):
        base = (phase + 1) * 10_000_000
        region = REGION_TOKENS[phase % len(REGION_TOKENS)]
        donor = f"{base:012d}"
        marks = reject_positions(n, k, phase)
        records = []
        for i in range(n):
            record = {
                "region": region,
                "amount": 123.45,
                "sale_date": "2026-01-01",
                "order_id": f"{base + i:012d}",
            }
            kind = marks.get(i)
            if kind == "non_positive_amount":
                record["amount"] = -123.45
            elif kind == "missing_region":
                record["region"] = None
            elif kind == "missing_amount":
                record["amount"] = None
            elif kind == "unparseable_date":
                record["sale_date"] = "not-a-date"
            elif kind == "missing_date":
                record["sale_date"] = None
            elif kind == "duplicate_order_id":
                record["order_id"] = donor
            records.append(record)
        bodies.append(json.dumps({"records": records}, separators=(",", ":")).encode())
    return bodies, n - k, k


def get_request(host_header, path):
    return (
        f"GET {path} HTTP/1.1\r\n"
        f"host: {host_header}\r\n"
        "accept: */*\r\n"
        "connection: close\r\n\r\n"
    ).encode()


def post_request(host_header, path, body):
    head = (
        f"POST {path} HTTP/1.1\r\n"
        f"host: {host_header}\r\n"
        "content-type: application/json\r\n"
        f"content-length: {len(body)}\r\n"
        "connection: close\r\n\r\n"
    ).encode()
    return head + body


def build_slots(cfg, stage, host_header):
    if stage["kind"] == "idle":
        return []
    if stage["kind"] == "get":
        req = get_request(host_header, stage["path"])
        return [(req, len(req), 0, 0, 0)]
    per_variant = cfg["bodies_per_variant"]
    slots = []
    for entry in stage["mix"]:
        bodies, processed, rejected = build_bodies(
            entry["n"], entry["reject_frac"], per_variant
        )
        requests = [post_request(host_header, stage["path"], b) for b in bodies]
        share = max(1, int(round(entry["weight"] * SLOT_TABLE)))
        for i in range(share):
            req = requests[i % per_variant]
            slots.append((req, len(req), entry["n"], processed, rejected))
    return slots


def schedule(cfg):
    rows = []
    offset = 0.0
    for stage in cfg["stages"]:
        rows.append((offset, offset + stage["duration_s"], stage))
        offset += stage["duration_s"]
    return rows, offset


def first_load_offset(rows):
    for start, _, stage in rows:
        if stage["kind"] != "idle":
            return start
    return 0.0


def resolve_target(cfg):
    parts = urlsplit(cfg["target"])
    if parts.scheme != "http":
        raise ConfigError("target must be an http:// url; there is no TLS on this path")
    host = parts.hostname
    port = parts.port or 80
    host_header = f"{host}:{port}" if parts.port else host
    if cfg["resolve_once"]:
        infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
        addr = infos[0][4][0]
    else:
        addr = host
    return addr, port, host_header


class Response(asyncio.Protocol):
    __slots__ = ("fut", "req", "buf", "code", "need", "have", "t_done")

    def __init__(self, fut, req):
        self.fut = fut
        self.req = req
        self.buf = b""
        self.code = 0
        self.need = -1
        self.have = 0
        self.t_done = 0.0

    def connection_made(self, transport):
        transport.write(self.req)

    def data_received(self, data):
        if self.need < 0:
            self.buf += data
            cut = self.buf.find(b"\r\n\r\n")
            if cut < 0:
                return
            head = self.buf[:cut]
            self.code = int(head[9:12])
            self.need = 0
            for line in head.split(b"\r\n")[1:]:
                if line[:15].lower() == b"content-length:":
                    self.need = int(line[15:])
                    break
            self.buf = self.buf[cut + 4:]
            self.have = len(self.buf)
        else:
            self.buf += data
            self.have += len(data)
        if self.have >= self.need and not self.t_done:
            self.t_done = time.perf_counter()

    def connection_lost(self, exc):
        if self.fut.done():
            return
        if self.code:
            self.fut.set_result((self.code, self.buf, self.t_done or time.perf_counter()))
        else:
            self.fut.set_exception(exc or ConnectionResetError("closed before response"))


def find_job_id(body):
    cut = body.find(b'"job_id":"')
    if cut < 0:
        return ""
    return body[cut + 10:cut + 46].decode("ascii", "replace")


class Child:
    def __init__(self, index, conn, cfg, rows, addr, port, start_wall, deadline_at,
                 stop_evt, term_evt, slots_by_stage):
        self.index = index
        self.conn = conn
        self.cfg = cfg
        self.rows = rows
        self.addr = addr
        self.port = port
        self.start_wall = start_wall
        self.deadline_at = deadline_at
        self.stop_evt = stop_evt
        self.term_evt = term_evt
        self.slots_by_stage = slots_by_stage
        self.workers = cfg["workers"]
        self.tick = cfg["tick_ms"] / 1000.0
        self.cap = max(1, cfg["max_inflight"] // self.workers)
        self.connect_timeout = cfg["connect_timeout_s"]
        self.read_timeout = cfg["read_timeout_s"]
        self.ndjson_sample = cfg["ndjson_sample"]
        self.inflight = set()
        self.hs = [0] * NSTATUS
        self.errs = [0] * NERR
        self.lat = array.array("f")
        self.lat_max = 0.0
        self.offered = 0
        self.sent = 0
        self.dropped = 0
        self.bytes_sent = 0
        self.records_sent = 0
        self.stage_name = "-"
        self.seq = index
        self.done_seq = 0
        self.stage_hist = {}
        self.oserrors = {}
        self.finished = False
        self.nd_fd = -1
        self.nd_buf = bytearray()
        self.loop = None
        self.stage_sent = 0

    def open_ndjson(self):
        path = self.cfg["ndjson_path"]
        if not path:
            return
        self.nd_fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)

    def flush_ndjson(self):
        if self.nd_fd >= 0 and self.nd_buf:
            os.write(self.nd_fd, self.nd_buf)
            self.nd_buf.clear()

    def note_oserror(self, exc):
        key = getattr(exc, "errno", None) or type(exc).__name__
        self.oserrors[key] = self.oserrors.get(key, 0) + 1

    def record(self, code, body, lat_ms, n):
        self.hs[STATUS_INDEX.get(code, STATUS_OTHER)] += 1
        self.stage_hist[code] = self.stage_hist.get(code, 0) + 1
        self.lat.append(lat_ms)
        if lat_ms > self.lat_max:
            self.lat_max = lat_ms
        self.done_seq += 1
        if self.nd_fd >= 0 and self.done_seq % self.ndjson_sample == 0:
            job_id = find_job_id(body) if code == 202 else ""
            self.nd_buf += (
                f'{{"ts":{time.time():.3f},"job_id":"{job_id}",'
                f'"status":{code},"n":{n},"ms":{lat_ms:.3f}}}\n'
            ).encode()
            if len(self.nd_buf) >= 32768:
                self.flush_ndjson()

    async def fire(self, req, n):
        t0 = time.perf_counter()
        fut = self.loop.create_future()
        try:
            async with asyncio.timeout(self.connect_timeout):
                transport, _ = await self.loop.create_connection(
                    lambda: Response(fut, req), self.addr, self.port
                )
        except TimeoutError:
            self.errs[ERR_CONN_TIMEOUT] += 1
            return
        except ConnectionRefusedError:
            self.errs[ERR_CONN_REFUSED] += 1
            return
        except OSError as exc:
            self.note_oserror(exc)
            self.errs[ERR_RESET] += 1
            return
        try:
            async with asyncio.timeout(self.read_timeout):
                code, body, t_done = await fut
        except TimeoutError:
            transport.abort()
            self.errs[ERR_READ_TIMEOUT] += 1
            return
        except (ConnectionResetError, BrokenPipeError):
            self.errs[ERR_RESET] += 1
            return
        except OSError as exc:
            self.note_oserror(exc)
            self.errs[ERR_RESET] += 1
            return
        self.record(code, body, (t_done - t0) * 1000.0, n)

    def stopping(self):
        return self.term_evt.is_set() or time.time() >= self.deadline_at

    async def run_stage(self, start_at, end_at, stage, slots):
        self.stage_name = stage["name"]
        self.stage_hist = {}
        self.stage_sent = 0
        limit = stage["count"]
        if limit is not None:
            limit = limit // self.workers + (1 if self.index < limit % self.workers else 0)
        if stage["kind"] == "idle" or not slots:
            while time.time() < end_at and not self.stopping():
                await asyncio.sleep(min(self.tick * 20, max(0.0, end_at - time.time())))
            return
        interval = self.workers / stage["rate"]
        nslots = len(slots)
        next_at = start_at
        while True:
            now = time.time()
            if now >= end_at or self.stopping():
                return
            due = 0
            while next_at <= now:
                due += 1
                next_at += interval
            if due:
                room = self.cap - len(self.inflight)
                if limit is not None:
                    room = min(room, limit - self.stage_sent)
                    if limit - self.stage_sent <= 0:
                        due = 0
                launch = due if due < room else max(0, room)
                self.offered += due
                self.dropped += due - launch
                for _ in range(launch):
                    req, nbytes, n, _, _ = slots[self.seq % nslots]
                    self.seq += self.workers
                    task = self.loop.create_task(self.fire(req, n))
                    self.inflight.add(task)
                    task.add_done_callback(self.inflight.discard)
                    self.sent += 1
                    self.stage_sent += 1
                    self.bytes_sent += nbytes
                    self.records_sent += n
            await asyncio.sleep(self.tick)

    def emit(self, second):
        usage = resource.getrusage(resource.RUSAGE_SELF)
        payload = (
            self.index, second, self.stage_name, self.offered, self.sent,
            self.dropped, len(self.inflight), tuple(self.hs), tuple(self.errs),
            self.lat, self.lat_max, self.bytes_sent, self.records_sent,
            usage.ru_utime + usage.ru_stime, usage.ru_maxrss,
        )
        try:
            self.conn.send(payload)
        except (BrokenPipeError, OSError):
            self.finished = True
        self.offered = 0
        self.sent = 0
        self.dropped = 0
        self.hs = [0] * NSTATUS
        self.errs = [0] * NERR
        self.lat = array.array("f")
        self.lat_max = 0.0
        self.bytes_sent = 0
        self.records_sent = 0

    async def reporter(self):
        while not self.finished:
            boundary = math.floor(time.time()) + 1
            await asyncio.sleep(max(0.0, boundary - time.time()))
            self.emit(int(boundary) - 1)
            self.flush_ndjson()

    async def main(self):
        self.loop = asyncio.get_running_loop()
        reporter = self.loop.create_task(self.reporter())
        for start_offset, end_offset, stage in self.rows:
            if self.stop_evt.is_set() or self.stopping():
                break
            start_at = self.start_wall + start_offset
            end_at = self.start_wall + end_offset
            wait_s = start_at - time.time()
            if wait_s > 0:
                await asyncio.sleep(wait_s)
            await self.run_stage(start_at, end_at, stage, self.slots_by_stage[stage["name"]])
        deadline = time.time() + self.cfg["drain_s"]
        while self.inflight and time.time() < deadline and not self.term_evt.is_set():
            await asyncio.sleep(0.05)
        for task in list(self.inflight):
            task.cancel()
        self.finished = True
        reporter.cancel()
        self.emit(int(time.time()))
        self.flush_ndjson()
        if self.oserrors:
            err(f"child {self.index} unclassified socket errors: {self.oserrors}")
        try:
            self.conn.close()
        except OSError:
            pass


def child_entry(child):
    signal.signal(signal.SIGTERM, lambda *_: child.term_evt.set())
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    child.open_ndjson()
    try:
        asyncio.run(child.main())
    except KeyboardInterrupt:
        pass


class Aggregate:
    def __init__(self, workers):
        self.workers = workers
        self.reset()

    def reset(self):
        self.stage = "-"
        self.offered = 0
        self.sent = 0
        self.dropped = 0
        self.inflight = 0
        self.hs = [0] * NSTATUS
        self.errs = [0] * NERR
        self.lat = array.array("f")
        self.lat_max = 0.0
        self.bytes_sent = 0
        self.records_sent = 0
        self.seen = 0

    def add(self, msg):
        (_, _, stage, offered, sent, dropped, inflight, hs, errs, lat,
         lat_max, bytes_sent, records_sent, _, _) = msg
        self.stage = stage
        self.offered += offered
        self.sent += sent
        self.dropped += dropped
        self.inflight += inflight
        for i, v in enumerate(hs):
            self.hs[i] += v
        for i, v in enumerate(errs):
            self.errs[i] += v
        self.lat.extend(lat)
        if lat_max > self.lat_max:
            self.lat_max = lat_max
        self.bytes_sent += bytes_sent
        self.records_sent += records_sent
        self.seen += 1

    def row(self, second):
        if self.lat:
            ordered = sorted(self.lat)
            p50 = f"{ordered[int(len(ordered) * 0.50)]:.2f}"
            p95 = f"{ordered[int(len(ordered) * 0.95)]:.2f}"
            pmax = f"{self.lat_max:.2f}"
        else:
            p50 = p95 = pmax = ""
        return ",".join(str(v) for v in (
            second, self.stage, self.offered, self.sent, self.dropped, self.inflight,
            self.hs[0], self.hs[1], self.hs[2], self.hs[3], self.hs[4], self.hs[5],
            self.hs[6], self.hs[7],
            self.errs[0], self.errs[1], self.errs[2], self.errs[3],
            p50, p95, pmax, self.bytes_sent, self.records_sent,
        ))


class Parent:
    def __init__(self, cfg, rows, total_s, deadline_at):
        self.cfg = cfg
        self.rows = rows
        self.total_s = total_s
        self.deadline_at = deadline_at
        self.pending = {}
        self.cpu = {}
        self.rss = {}
        self.last_cpu_total = 0.0
        self.last_cpu_at = 0.0
        self.cpu_frac = 0.0
        self.cpu_peak = 0.0
        self.cpu_total = 0.0
        self.window = []
        self.window_stage = None
        self.totals = Aggregate(cfg["workers"])
        self.tripped = set()
        self.stop_evt = None
        self.term_evt = None
        self.cpu_limit_m = read_cpu_limit_m(cfg["cpu_limit_m"])
        self.throttled0 = read_throttling()
        self.stage_totals = None
        self.stage_open = None
        self.last_status_at = 0.0
        self.flushed_through = -1
        self.late_samples = 0
        self.lost_workers = []

    def stage_at(self, second, start_wall):
        offset = second + 0.5 - start_wall
        for start, end, stage in self.rows:
            if start <= offset < end:
                return stage
        return None

    def note_cpu(self, index, cpu_s, rss_kb):
        self.cpu[index] = cpu_s
        self.rss[index] = max(self.rss.get(index, 0), rss_kb)

    def refresh_cpu(self):
        usage = resource.getrusage(resource.RUSAGE_SELF)
        total = usage.ru_utime + usage.ru_stime + sum(self.cpu.values())
        self.cpu_total = total
        self.rss[-1] = max(self.rss.get(-1, 0), usage.ru_maxrss)
        now = time.time()
        span = now - self.last_cpu_at
        if not self.last_cpu_at:
            self.last_cpu_total = total
            self.last_cpu_at = now
            return
        if span < 2.0:
            return
        self.cpu_frac = (total - self.last_cpu_total) / span
        if self.cpu_frac > self.cpu_peak:
            self.cpu_peak = self.cpu_frac
        self.last_cpu_total = total
        self.last_cpu_at = now

    def check_stop_rule(self, stage, agg):
        if stage["name"] != self.window_stage:
            self.window_stage = stage["name"]
            self.window = []
        rule = stage.get("stop_rule")
        if rule is None or stage["name"] in self.tripped:
            return
        self.window.append((time.time(), agg.offered, agg.hs, agg.sent))
        cutoff = time.time() - rule["window_s"]
        while self.window and self.window[0][0] < cutoff:
            self.window.pop(0)
        if len(self.window) < min(10, int(rule["window_s"])):
            return
        reasons = []
        if rule["accept_ratio_min"] is not None:
            offered = sum(w[1] for w in self.window)
            good = sum(w[2][STATUS_INDEX.get(stage["expect_status"], STATUS_OTHER)]
                       for w in self.window)
            if offered and good / offered < rule["accept_ratio_min"]:
                reasons.append(f"accept_ratio={good / offered:.3f}")
        limit_m = self.cpu_limit_m
        if rule["cpu_frac_max"] is not None and limit_m:
            frac = self.cpu_frac / (limit_m / 1000.0)
            if frac > rule["cpu_frac_max"]:
                reasons.append(f"cpu_frac={frac:.3f}")
        if not reasons:
            return
        self.tripped.add(stage["name"])
        err(f"STOP RULE tripped on stage {stage['name']}: {'; '.join(reasons)} "
            f"(on_trip={rule['on_trip']})")
        if rule["on_trip"] == "end_run":
            self.stop_evt.set()

    def roll_stage(self, agg):
        if agg.stage != self.stage_open:
            self.close_stage()
            self.stage_open = agg.stage
            self.stage_totals = Aggregate(self.cfg["workers"])
            self.stage_totals.stage = agg.stage
        tot = self.stage_totals
        tot.offered += agg.offered
        tot.sent += agg.sent
        tot.dropped += agg.dropped
        for i, v in enumerate(agg.hs):
            tot.hs[i] += v
        for i, v in enumerate(agg.errs):
            tot.errs[i] += v
        tot.records_sent += agg.records_sent
        tot.bytes_sent += agg.bytes_sent
        if agg.lat_max > tot.lat_max:
            tot.lat_max = agg.lat_max
        tot.seen += 1

    def close_stage(self):
        tot = self.stage_totals
        if tot is None or not tot.seen:
            return
        codes = " ".join(
            f"{name}={tot.hs[i]}" for i, name in enumerate(
                ("202", "400", "411", "413", "422", "500", "502", "other"))
            if tot.hs[i]
        )
        errs = " ".join(
            f"{name}={tot.errs[i]}" for i, name in enumerate(
                ("conn_refused", "conn_timeout", "read_timeout", "reset"))
            if tot.errs[i]
        )
        rate = tot.sent / tot.seen if tot.seen else 0.0
        err(f"stage {self.stage_open} done: {tot.seen}s offered={tot.offered} "
            f"sent={tot.sent} ({rate:.1f}/s) offered_dropped={tot.dropped} "
            f"status[{codes or 'none'}] errors[{errs or 'none'}] "
            f"lat_max_ms={tot.lat_max:.2f} records={tot.records_sent}")

    def status(self):
        now = time.time()
        if now - self.last_status_at < 15.0:
            return
        self.last_status_at = now
        limit = self.cpu_limit_m
        frac = self.cpu_frac / (limit / 1000.0) if limit else 0.0
        throttled = read_throttling()
        extra = ""
        if throttled is not None and self.throttled0 is not None:
            extra = f" cfs_throttled_periods={throttled - self.throttled0}"
        err(f"generator cpu={self.cpu_frac * 1000:.0f}m peak={self.cpu_peak * 1000:.0f}m"
            + (f" limit={limit}m ({frac * 100:.0f}%)" if limit else "")
            + extra)

    def bucket(self, second):
        if second <= self.flushed_through:
            self.late_samples += 1
            err(f"late sample for second {second} arrived after it was written; "
                f"folding into {self.flushed_through + 1}")
            second = self.flushed_through + 1
        agg = self.pending.get(second)
        if agg is None:
            agg = Aggregate(self.cfg["workers"])
            self.pending[second] = agg
        return agg

    def flush(self, second, start_wall, out):
        agg = self.pending.pop(second)
        self.flushed_through = second
        scheduled = self.stage_at(second, start_wall)
        agg.stage = scheduled["name"] if scheduled is not None else "-"
        out.write(agg.row(second) + "\n")
        self.roll_stage(agg)
        out.flush()
        self.totals.offered += agg.offered
        self.totals.sent += agg.sent
        self.totals.dropped += agg.dropped
        for i, v in enumerate(agg.hs):
            self.totals.hs[i] += v
        for i, v in enumerate(agg.errs):
            self.totals.errs[i] += v
        self.totals.bytes_sent += agg.bytes_sent
        self.totals.records_sent += agg.records_sent
        if agg.lat_max > self.totals.lat_max:
            self.totals.lat_max = agg.lat_max
        stage = self.stage_at(second, start_wall)
        if stage is not None and stage["kind"] != "idle":
            self.check_stop_rule(stage, agg)


def describe(cfg, rows, total_s, slots_by_stage):
    lines = [f"target={cfg['target']} workers={cfg['workers']} "
             f"max_inflight={cfg['max_inflight']} tick_ms={cfg['tick_ms']}"]
    for start, end, stage in rows:
        slots = slots_by_stage[stage["name"]]
        if stage["kind"] == "idle":
            lines.append(f"  {start:7.0f}s +{stage['duration_s']:.0f}s "
                         f"{stage['name']:<20s} idle")
            continue
        sizes = sorted({s[1] for s in slots})
        counts = sorted({(s[2], s[3], s[4]) for s in slots})
        detail = ", ".join(f"n={n} processed={p} rejected={r}" for n, p, r in counts
                           if n)
        lines.append(
            f"  {start:7.0f}s +{stage['duration_s']:.0f}s {stage['name']:<20s} "
            f"{stage['kind']} rate={stage['rate']:g}/s expect={stage['expect_status']} "
            f"req_bytes={sizes[0]}..{sizes[-1]} {detail}"
            + (f" count={stage['count']}" if stage["count"] else "")
        )
    lines.append(f"  total stage time {total_s:.0f}s")
    return "\n".join(lines)


def dump_payloads(cfg, directory):
    os.makedirs(directory, exist_ok=True)
    written = []
    for stage in cfg["stages"]:
        if stage["kind"] != "jobs":
            continue
        for entry in stage["mix"]:
            bodies, processed, rejected = build_bodies(
                entry["n"], entry["reject_frac"], cfg["bodies_per_variant"]
            )
            for i, body in enumerate(bodies):
                name = f"n{entry['n']}_r{entry['reject_frac']}_{i}.json"
                path = os.path.join(directory, name)
                if path in written:
                    continue
                with open(path, "wb") as fh:
                    fh.write(body)
                written.append(path)
            err(f"variant n={entry['n']} reject_frac={entry['reject_frac']} "
                f"processed={processed} rejected={rejected} bytes={len(bodies[0])}")
    err(f"wrote {len(written)} payload files to {directory}")


def run(cfg, out):
    rows, total_s = schedule(cfg)
    addr, port, host_header = resolve_target(cfg)
    err(f"target {cfg['target']} resolved to {addr}:{port} host_header={host_header}")
    slots_by_stage = {s["name"]: build_slots(cfg, s, host_header) for s in cfg["stages"]}
    err("plan:\n" + describe(cfg, rows, total_s, slots_by_stage))
    raise_nofile(cfg["max_inflight"] // cfg["workers"] + 64)

    deadline_s = cfg["deadline_s"]
    ctx = mp.get_context("fork")
    stop_evt = ctx.Event()
    term_evt = ctx.Event()
    start_wall = math.floor(time.time() + cfg["start_grace_s"]) + 1.0
    load_at = start_wall + first_load_offset(rows)
    deadline_at = load_at + deadline_s if deadline_s else float("inf")

    parent = Parent(cfg, rows, total_s, deadline_at)
    parent.stop_evt = stop_evt
    parent.term_evt = term_evt

    conns = []
    procs = []
    for index in range(cfg["workers"]):
        recv, send = ctx.Pipe(duplex=False)
        child = Child(index, send, cfg, rows, addr, port, start_wall, deadline_at,
                      stop_evt, term_evt, slots_by_stage)
        proc = ctx.Process(target=child_entry, args=(child,), daemon=True)
        proc.start()
        send.close()
        conns.append(recv)
        procs.append(proc)

    def on_term(*_):
        err("SIGTERM received, stopping load")
        stop_evt.set()
        term_evt.set()

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)

    out.write(",".join(CSV_COLUMNS) + "\n")
    out.flush()
    err(f"T0 {load_at:.3f} first load packet; hard deadline "
        + (f"{deadline_at:.3f} (+{deadline_s:.0f}s)" if deadline_s else "none"))

    stages_end_at = start_wall + total_s - 1.0
    live = list(conns)
    announced = False
    while live:
        for conn in wait(live, timeout=0.25):
            try:
                msg = conn.recv()
            except (EOFError, OSError):
                live.remove(conn)
                if time.time() < stages_end_at and not term_evt.is_set():
                    parent.lost_workers.append(conns.index(conn))
                    err(f"WORKER {conns.index(conn)} PIPE CLOSED WHILE STAGES ARE STILL "
                        "RUNNING: the offered rate is now below the configured rate and "
                        "this run is not attributable")
                continue
            parent.bucket(msg[1]).add(msg)
            parent.note_cpu(msg[0], msg[13], msg[14])
        parent.refresh_cpu()
        parent.status()
        now = time.time()
        if not announced and now >= deadline_at:
            announced = True
            err("HARD DEADLINE reached, stopping load")
            stop_evt.set()
            term_evt.set()
        for second in sorted(parent.pending):
            if now >= second + 1 + cfg["report_grace_s"] or not live:
                parent.flush(second, start_wall, out)
    for proc in procs:
        proc.join(timeout=10)
    for index, proc in enumerate(procs):
        if proc.exitcode not in (0, None):
            parent.lost_workers.append(index)
            err(f"WORKER {index} EXITED {proc.exitcode}")
    parent.close_stage()

    limit_m = parent.cpu_limit_m
    peak_rss = "+".join(f"{v / 1024.0:.0f}" for _, v in sorted(parent.rss.items()))
    err("run complete: "
        f"offered={parent.totals.offered} sent={parent.totals.sent} "
        f"offered_dropped={parent.totals.dropped} "
        f"h202={parent.totals.hs[0]} hother={parent.totals.hs[7]} "
        f"errors={parent.totals.errs} "
        f"bytes_sent={parent.totals.bytes_sent} records_sent={parent.totals.records_sent} "
        f"lat_max_ms={parent.totals.lat_max:.2f} "
        f"cpu_s={parent.cpu_total:.2f} peak_cpu_m={parent.cpu_peak * 1000:.0f} "
        f"peak_rss_mib_per_proc={peak_rss}"
        + (f" cpu_limit_m={limit_m}" if limit_m else "")
        + (f" cfs_throttled_periods={read_throttling() - parent.throttled0}"
           if read_throttling() is not None and parent.throttled0 is not None else ""))
    if parent.lost_workers:
        err(f"RUN NOT ATTRIBUTABLE: workers lost during the run: "
            f"{sorted(set(parent.lost_workers))}")
    if parent.late_samples:
        err(f"{parent.late_samples} late per-second samples were folded forward")
    if cfg["on_complete"] == "idle" and not term_evt.is_set():
        err("on_complete=idle: holding the pod so /data can be copied; SIGTERM to exit")
        while not term_evt.is_set():
            time.sleep(0.2)
        err("SIGTERM during hold, exiting")


def main():
    parser = argparse.ArgumentParser(prog="loadgen")
    parser.add_argument("--config", required=True)
    parser.add_argument("--target")
    parser.add_argument("--print-plan", action="store_true")
    parser.add_argument("--dump-payloads")
    args = parser.parse_args()
    try:
        cfg = load_config(args.config)
    except (ConfigError, ValueError, KeyError) as exc:
        err(f"config error: {exc}")
        return 2
    if args.target:
        cfg["target"] = args.target
    if args.dump_payloads:
        dump_payloads(cfg, args.dump_payloads)
        return 0
    if args.print_plan:
        rows, total_s = schedule(cfg)
        _, _, host_header = resolve_target(cfg)
        slots = {s["name"]: build_slots(cfg, s, host_header) for s in cfg["stages"]}
        sys.stderr.write(describe(cfg, rows, total_s, slots) + "\n")
        return 0
    run(cfg, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
