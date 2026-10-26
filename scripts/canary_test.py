#!/usr/bin/env python3
"""canary_test.py - week 6 A5, KIND ONLY: KServe/Knative canary mechanics under load.

  python3 scripts/canary_test.py <label> [--url http://localhost:8080]

Phases on ONE Knative-mode ISVC (manifests/inferenceservice-qwen-canary.yaml):
  v1        CANARY_VERSION=v1, 100%                       (baseline)
  canary    CANARY_VERSION=v2, canaryTrafficPercent 20    (new revision, 20%)
  rollback  canaryTrafficPercent 0                        (all back to v1)
  canary2   canaryTrafficPercent 20                       (v2 again, no new revision)
  promote   canaryTrafficPercent removed                  (v2 100%)
Load runs throughout (each request a new connection, Host header = the ISVC's
host, via Kourier). Per phase: client requests/errors, and the SERVER-side
request count per Knative revision (Prometheus, vllm:time_to_first_token_seconds
_count by revision, A3) over the phase's steady window [ready + SETTLE, end] -
i.e. the measured split vs the configured one. Transition windows (apply ->
ready) are reported separately: that is where a switch would cut requests.
Writes benchmarks/results/canary-<label>/{requests.jsonl,phases.json,summary.json}.
"""
import argparse, copy, json, subprocess, threading, time, urllib.parse, urllib.request
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("label")
ap.add_argument("--url", default="http://localhost:8080")
ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--max-tokens", type=int, default=32)
ap.add_argument("--settle", type=float, default=15, help="s after ready before the steady window")
ap.add_argument("--ready-timeout", type=float, default=600)
a = ap.parse_args()
NS, ISVC = "llm-serving", "qwen-canary"
PHASES = [("v1", "v1", "keep", 60), ("canary", "v2", 20, 180), ("rollback", "v2", 0, 90),
          ("canary2", "v2", 20, 120), ("promote", "v2", None, 150)]

def kubectl(*args, inp=None):
    r = subprocess.run(["kubectl", *args], input=inp, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"kubectl {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout

def prom(query, t):
    q = urllib.parse.urlencode({"query": query, "time": f"{t:.3f}"})
    j = json.loads(kubectl("-n", "monitoring", "exec", "deploy/prometheus", "--",
                           "wget", "-qO-", f"http://localhost:9090/api/v1/query?{q}"))
    return {r["metric"].get("revision", "?"): float(r["value"][1]) for r in j["data"]["result"]}

def counts(t):
    return prom(f'sum by (revision) (vllm:time_to_first_token_seconds_count{{namespace="{NS}",isvc="{ISVC}"}})', t)

base = yaml.safe_load((ROOT / "manifests/inferenceservice-qwen-canary.yaml").read_text())
def manifest(version, pct):
    m = copy.deepcopy(base)
    for e in m["spec"]["predictor"]["model"]["env"]:
        if e["name"] == "CANARY_VERSION":
            e["value"] = version
    if isinstance(pct, int):
        m["spec"]["predictor"]["canaryTrafficPercent"] = pct
    return m

def traffic():
    s = json.loads(kubectl("get", "isvc", "-n", NS, ISVC, "-o", "json"))
    ready = any(c["type"] == "Ready" and c["status"] == "True" for c in s.get("status", {}).get("conditions", []))
    tr = s.get("status", {}).get("components", {}).get("predictor", {}).get("traffic", [])
    gen_ok = s["metadata"]["generation"] == s.get("status", {}).get("observedGeneration")
    return ready and gen_ok, tr

def latest_pct(tr):
    return sum(x.get("percent", 0) for x in tr if x.get("latestRevision"))

out = ROOT / "benchmarks/results" / f"canary-{a.label}"
out.mkdir(parents=True, exist_ok=False)

# ---- start from v1 at 100% (fresh ISVC)
kubectl("apply", "-f", "-", inp=json.dumps(manifest("v1", "keep")))
t_wait = time.time()
while True:
    ok, tr = traffic()
    if ok and latest_pct(tr) == 100:
        break
    if time.time() - t_wait > a.ready_timeout:
        raise SystemExit(f"v1 not ready: {tr}")
    time.sleep(3)
host = urllib.parse.urlparse(json.loads(kubectl("get", "isvc", "-n", NS, ISVC, "-o", "json"))["status"]["url"]).hostname
print(f"v1 ready, host {host}", flush=True)

rows, lock, stop, t0 = [], threading.Lock(), threading.Event(), time.time()
body = json.dumps({"model": ISVC, "prompt": "Count slowly:", "max_tokens": a.max_tokens, "ignore_eos": True}).encode()
def worker(i):
    while not stop.is_set():
        s = time.time(); r = {"worker": i, "start": s}
        try:
            req = urllib.request.Request(a.url + "/v1/completions", data=body, headers={
                "Content-Type": "application/json", "Connection": "close", "Host": host})
            with urllib.request.urlopen(req, timeout=300) as resp:
                r.update(status=resp.status, tokens=json.loads(resp.read())["usage"]["completion_tokens"])
        except Exception as e:                      # noqa: BLE001 - every failure is data
            r.update(status="error", error=f"{type(e).__name__}: {e}"[:200])
        r["end"] = time.time()
        with lock:
            rows.append(r)
ts = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(a.workers)]
for t in ts: t.start()

phases = []
for name, ver, pct, hold in PHASES:
    applied = time.time()
    if name != "v1":
        kubectl("apply", "-f", "-", inp=json.dumps(manifest(ver, pct)))
    want = 100 if pct in (None, "keep") else pct
    while True:
        ok, tr = traffic()
        if ok and latest_pct(tr) == want:
            break
        if time.time() - applied > a.ready_timeout:
            raise SystemExit(f"phase {name}: traffic never reached latest={want}%: {tr}")
        time.sleep(2)
    ready = time.time()
    print(f"{name}: applied {applied - t0:.1f}s ready {ready - t0:.1f}s traffic "
          + ", ".join(f"{x['revisionName']}={x.get('percent', 0)}%" for x in tr), flush=True)
    time.sleep(hold)
    end = time.time()
    phases.append({"phase": name, "version": ver, "canary_pct": pct, "applied": applied, "ready": ready,
                   "end": end, "traffic": tr})
stop.set()
for t in ts: t.join(timeout=300)
time.sleep(12)                                       # one more scrape after the last phase

summary = {"label": a.label, "workers": a.workers, "max_tokens": a.max_tokens, "settle_s": a.settle, "phases": []}
for p in phases:
    lo, hi = p["ready"] + a.settle, p["end"]
    c0, c1 = counts(lo), counts(hi)
    srv = {rev: round(c1[rev] - c0.get(rev, 0.0)) for rev in c1}
    srv = {k: v for k, v in srv.items() if v > 0}
    tot = sum(srv.values())
    steady = [r for r in rows if lo <= r["start"] and r["end"] < hi]
    trans = [r for r in rows if r["end"] >= p["applied"] and r["start"] < p["ready"] + a.settle]
    summary["phases"].append({
        "phase": p["phase"], "configured": {x["revisionName"]: x.get("percent", 0) for x in p["traffic"]},
        "apply_to_ready_s": round(p["ready"] - p["applied"], 1),
        "steady_window_s": round(hi - lo, 1),
        "server_requests_by_revision": srv,
        "server_share_pct": {k: round(100 * v / tot, 1) for k, v in srv.items()} if tot else {},
        "client_steady": {"requests": len(steady), "errors": sum(r["status"] == "error" for r in steady)},
        "client_transition": {"requests": len(trans), "errors": sum(r["status"] == "error" for r in trans),
                              "error_types": sorted({r["error"].split(":")[0] for r in trans if r["status"] == "error"})}})
summary["client_total"] = {"requests": len(rows), "errors": sum(r["status"] == "error" for r in rows),
                           "short": sum(r["status"] == 200 and r.get("tokens") != a.max_tokens for r in rows)}
pods = kubectl("get", "pods", "-n", NS, "-l", f"serving.kserve.io/inferenceservice={ISVC}", "-o",
               "jsonpath={range .items[*]}{.metadata.labels.serving\\.knative\\.dev/revision} {.status.phase}{\"\\n\"}{end}")
summary["pods_at_end"] = pods.split("\n")
(out / "requests.jsonl").write_text("".join(json.dumps({**r, "start": round(r["start"] - t0, 3), "end": round(r["end"] - t0, 3)}) + "\n"
                                            for r in sorted(rows, key=lambda r: r["start"])))
(out / "phases.json").write_text(json.dumps([{**p, **{k: round(p[k] - t0, 3) for k in ("applied", "ready", "end")}} for p in phases], indent=2) + "\n")
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=1))
