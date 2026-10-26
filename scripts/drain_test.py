#!/usr/bin/env python3
"""drain_test.py - week 6 A4, KIND ONLY. Constant load on a 2-replica ISVC,
delete one replica mid-load (what a scale-down does), count client errors.

  python3 scripts/drain_test.py <label> [--url http://localhost:8080] [--model qwen-0-5b]

Each request opens a NEW connection (Connection: close) so kube-proxy spreads
them over both replicas. At --kill-at s the NEWEST predictor pod is deleted
(the ReplicaSet scale-down choice for equal pods). Writes
benchmarks/results/drain-<label>/requests.jsonl + summary.json; prints counts.
Errors are classified relative to the deletion time. Standard library only.
"""
import argparse, json, subprocess, threading, time, urllib.request
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("label")
ap.add_argument("--url", default="http://localhost:8080")
ap.add_argument("--model", default="qwen-0-5b")
ap.add_argument("--ns", default="llm-serving")
ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--max-tokens", type=int, default=128)
ap.add_argument("--duration", type=float, default=150)
ap.add_argument("--kill-at", type=float, default=45)
a = ap.parse_args()
out = Path(__file__).resolve().parent.parent / "benchmarks/results" / f"drain-{a.label}"
sel = f"serving.kserve.io/inferenceservice={a.model}"

def kubectl(*args):
    return subprocess.run(["kubectl", *args], capture_output=True, text=True).stdout

pods = json.loads(kubectl("get", "pod", "-n", a.ns, "-l", sel, "-o", "json"))["items"]
live = [p for p in pods if p["status"].get("phase") == "Running" and not p["metadata"].get("deletionTimestamp")]
if len(live) != 2:
    raise SystemExit(f"need exactly 2 running replicas, found {len(live)}")
out.mkdir(parents=True, exist_ok=False)
victim = max(live, key=lambda p: p["metadata"]["creationTimestamp"])["metadata"]["name"]
spec = victim and json.loads(kubectl("get", "pod", "-n", a.ns, victim, "-o", "json"))["spec"]
c0 = next(c for c in spec["containers"] if c["name"] == "kserve-container")
meta = {"label": a.label, "victim": victim, "grace_s": spec.get("terminationGracePeriodSeconds"),
        "preStop": c0.get("lifecycle", {}).get("preStop"),
        "shutdown_timeout_arg": [x for x in c0.get("args", []) + c0.get("command", []) if "shutdown-timeout" in x],
        "workers": a.workers, "max_tokens": a.max_tokens, "duration_s": a.duration, "kill_at_s": a.kill_at}
print(json.dumps(meta))

rows, lock, t0 = [], threading.Lock(), time.time()
body = json.dumps({"model": a.model, "prompt": "Write a long story about a lighthouse keeper.",
                   "max_tokens": a.max_tokens, "ignore_eos": True}).encode()

def worker(i):
    while time.time() - t0 < a.duration:
        s = time.time(); r = {"worker": i, "start_s": round(s - t0, 3)}
        try:
            req = urllib.request.Request(a.url + "/v1/completions", data=body,
                                         headers={"Content-Type": "application/json", "Connection": "close"})
            with urllib.request.urlopen(req, timeout=300) as resp:
                j = json.loads(resp.read())
                r.update(status=resp.status, tokens=j["usage"]["completion_tokens"])
        except Exception as e:                      # noqa: BLE001 - every failure is data
            r.update(status="error", error=f"{type(e).__name__}: {e}"[:200])
        r["end_s"] = round(time.time() - t0, 3)
        with lock:
            rows.append(r)

ts = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(a.workers)]
for t in ts: t.start()
time.sleep(a.kill_at - 3)
# vLLM logs its shutdown mode (abort/drain). `kubectl logs -f` breaks when the
# pod vanishes, so poll the tail every second and keep the last good copy.
last_log = {"text": ""}
def log_poller():
    while time.time() - t0 < a.duration + 300:
        r = subprocess.run(["kubectl", "logs", "-n", a.ns, victim, "-c", "kserve-container", "--tail=60"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            break                                  # pod gone: keep what we have
        last_log["text"] = r.stdout
        time.sleep(1)
poller = threading.Thread(target=log_poller, daemon=True)
poller.start()
time.sleep(3)
kill_s = round(time.time() - t0, 3)
kubectl("delete", "pod", "-n", a.ns, victim, "--wait=false")
print(f"deleted {victim} at {kill_s}s", flush=True)
# record when the victim is actually gone (grace / drain length)
gone_s = None
while time.time() - t0 < a.duration + 300:
    if not kubectl("get", "pod", "-n", a.ns, victim, "-o", "name").strip():
        gone_s = round(time.time() - t0, 3); break
    time.sleep(1)
for t in ts: t.join(timeout=300)
poller.join(timeout=30)
(out / "victim.log").write_text(last_log["text"])
shutdown_lines = [x.strip()[-160:] for x in last_log["text"].splitlines() if "[shutdown]" in x]

ok = [r for r in rows if r["status"] == 200 and r.get("tokens") == a.max_tokens]
short = [r for r in rows if r["status"] == 200 and r.get("tokens") != a.max_tokens]
err = [r for r in rows if r["status"] == "error"]
summary = {**meta, "kill_s": kill_s, "victim_gone_s": gone_s,
           "victim_gone_after_delete_s": round(gone_s - kill_s, 1) if gone_s else None,
           "requests": len(rows), "ok_full": len(ok), "ok_but_short": len(short), "errors": len(err),
           "errors_in_flight_at_delete": sum(1 for r in err if r["start_s"] < kill_s),
           "errors_started_after_delete": sum(1 for r in err if r["start_s"] >= kill_s),
           "vllm_shutdown_log": shutdown_lines,
           "error_types": sorted({r["error"].split(":")[0] for r in err}),
           "error_end_minus_delete_s": sorted(round(r["end_s"] - kill_s, 1) for r in err)}
(out / "requests.jsonl").write_text("".join(json.dumps(r) + "\n" for r in sorted(rows, key=lambda r: r["start_s"])))
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({k: summary[k] for k in ("requests", "ok_full", "ok_but_short", "errors",
      "errors_in_flight_at_delete", "errors_started_after_delete", "error_types",
      "error_end_minus_delete_s", "victim_gone_after_delete_s", "vllm_shutdown_log")}, indent=1))
