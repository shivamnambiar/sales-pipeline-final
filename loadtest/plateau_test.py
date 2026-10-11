import json, os, sys, urllib.error, urllib.request, subprocess, time, threading, random

COMPOSE_FILE = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "docker-compose.yml"))
BASE_URL = "http://127.0.0.1:8000"
URL = BASE_URL + "/jobs"

CAP_RECORDS   = 200_000
PLATEAU_MIN   = 5
HARD_CAP_MIN  = 60
LOGFILE       = "plateau_log.csv"

def container_id(service):
    out = subprocess.run(["docker","compose","-f",COMPOSE_FILE,"ps","-q",service], capture_output=True, text=True)
    cid = out.stdout.strip()
    if out.returncode != 0 or not cid:
        sys.exit(f"no running {service} container for {COMPOSE_FILE} - start the stack with docker compose up -d")
    return cid

def require_ready():
    try:
        urllib.request.urlopen(BASE_URL + "/readyz", timeout=10).close()
    except Exception as e:
        sys.exit(f"api not ready at {BASE_URL}/readyz ({e}) - wait for the compose stack to finish starting")

CONTAINERS = {s: container_id(s) for s in ("api", "worker")}
require_ready()

def mem_mib(service):
    for path in ["/sys/fs/cgroup/memory.current","/sys/fs/cgroup/memory/memory.usage_in_bytes"]:
        out = subprocess.run(["docker","exec",CONTAINERS[service],"cat",path], capture_output=True, text=True)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            return int(out.stdout.strip())/1048576
    sys.exit(f"cannot read cgroup memory of the {service} container - check docker compose ps -a")

FAT = {'region':'x'*64,'amount':1.5,'sale_date':'2026-07-18'}
def make_body(n):
    return json.dumps({'records':[dict(FAT, order_id='x'*55+str(i)) for i in range(n)]}).encode()

SIZES = list(range(10_000, 50_001, 10_000))
BODIES = {n: make_body(n) for n in SIZES}

inflight = [0]
lock = threading.Lock()
sent = [0]; errs = [0]
err_kinds = {}
size_counts = {n: 0 for n in SIZES}
stop = [False]

def post_batch(n):
    try:
        with urllib.request.urlopen(urllib.request.Request(URL, BODIES[n],
            {'Content-Type':'application/json'}), timeout=120):
            return None
    except urllib.error.HTTPError as e:
        return f"HTTP {e.code}"
    except Exception as e:
        return type(e).__name__

def one_request(n):
    err = post_batch(n)
    with lock:
        inflight[0] -= n
        if err is None:
            sent[0] += 1
        else:
            errs[0] += 1
            err_kinds[err] = err_kinds.get(err, 0) + 1

def reserve_when_it_fits(n):
    while not stop[0]:
        with lock:
            if inflight[0] + n <= CAP_RECORDS:
                inflight[0] += n
                size_counts[n] += 1
                return True
        time.sleep(0.01)
    return False

def spawner():
    while not stop[0]:
        n = random.choice(SIZES)
        if not reserve_when_it_fits(n): break
        threading.Thread(target=one_request, args=(n,), daemon=True).start()

print("="*62)
print("  SUSTAINED LOAD TEST - random batch sizes, capped in-flight")
print(f"  cap: {CAP_RECORDS:,} records in flight | plateau rule: {PLATEAU_MIN} min")
print(f"  stack: {COMPOSE_FILE}")
print("="*62)
print()
print(f"  {'TIME':>7} | {'API MEM':>8} | {'API PEAK':>8} | {'WRK MEM':>8} | {'WRK PEAK':>8} | {'IN-FLIGHT':>9} | {'REQS':>6} | {'ERRS':>5}")
print(f"  {'-'*8}+{'-'*10}+{'-'*10}+{'-'*10}+{'-'*10}+{'-'*11}+{'-'*8}+{'-'*6}")

for _ in range(32):
    threading.Thread(target=spawner, daemon=True).start()

start = time.time()
api_peak = 0; wk_peak = 0; peak_time = start
with open(LOGFILE,"w") as f:
    f.write("elapsed_s,api_mem_MiB,api_peak_MiB,worker_mem_MiB,worker_peak_MiB,inflight_records,sent,errors\n")
    while True:
        el = time.time()-start
        m = mem_mib("api")
        wm = mem_mib("worker")
        if m > api_peak or wm > wk_peak:
            peak_time = time.time()
        api_peak = max(api_peak, m); wk_peak = max(wk_peak, wm)
        mins, secs = divmod(int(el), 60)
        print(f"  {f'{mins}:{secs:02d}':>7} | {f'{m:.0f}MiB':>8} | {f'{api_peak:.0f}MiB':>8} | {f'{wm:.0f}MiB':>8} | {f'{wk_peak:.0f}MiB':>8} | {inflight[0]:>9,} | {sent[0]:>6,} | {errs[0]:>5,}")
        f.write(f"{el:.0f},{m:.1f},{api_peak:.1f},{wm:.1f},{wk_peak:.1f},{inflight[0]},{sent[0]},{errs[0]}\n"); f.flush()

        since_peak = (time.time()-peak_time)/60
        if since_peak >= PLATEAU_MIN:
            print()
            print("="*62)
            print(f"  API MEMORY PLATEAU: {api_peak:.0f} MiB | WORKER PEAK: {wk_peak:.0f} MiB")
            print(f"  (neither container set a new peak for {PLATEAU_MIN} minutes - memory is stable)")
            print("="*62)
            break
        if el/60 >= HARD_CAP_MIN:
            print()
            print("="*62)
            print(f"  HARD CAP ({HARD_CAP_MIN} min) - memory still climbing | API peak {api_peak:.0f} MiB | WORKER peak {wk_peak:.0f} MiB")
            print(f"  possible memory leak - investigate before sizing")
            print("="*62)
            break
        time.sleep(3)

stop[0]=True

with lock:
    counts = dict(size_counts); kinds = dict(err_kinds); ok = sent[0]; failed = errs[0]

total_fired = sum(counts.values())
print()
print("  TRAFFIC COMPOSITION (batches fired per size):")
for n in SIZES:
    c = counts[n]
    pct = 100*c/total_fired if total_fired else 0
    bar = "#" * int(pct)
    print(f"    {n//1000:>3}k : {c:>5,}  {pct:4.1f}%  {bar}")
print(f"    total: {total_fired:,} batches, {sum(n*c for n,c in counts.items()):,} records sent")
print()
print(f"  REQUESTS: {ok:,} accepted | {failed:,} failed")
if kinds:
    print("    " + ", ".join(f"{k} x{v:,}" for k, v in sorted(kinds.items())))
    print("    some batches failed, so the peaks may not reflect full load - check the failures before sizing from them")

print(f"\n  full timeline saved to {os.path.abspath(LOGFILE)}")
