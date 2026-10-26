#!/usr/bin/env python3
"""wake_test.py - week 6: wake from zero through Knative's activator. FIRST TO CUT.

  python3 scripts/wake_test.py <label> --isvc llama-fp8-kn --url http://localhost:30880 [--rounds 2]

Patches the Knative-mode ISVC to minReplicas 0, then per round: wait until the
ISVC has NO pods (Knative scales an idle revision to zero after its stable
window, ~1-2 min) -> send ONE request (max_tokens 1, Host header = the ISVC's
host) through Kourier -> the activator holds it while a pod starts -> time to
response. The new pod's own timestamps split the wait:
  request -> pod created      (activator + autoscaler react)
  created -> scheduled        (scheduler; GPU free?)
  scheduled -> Ready          (storage copy + vLLM start; probe)
  Ready -> response           (activator forwards; first token)
Restores minReplicas 1 at the end (also on error). Needs kubectl and HTTP
access to Kourier (GPU host: localhost:30880).
Writes benchmarks/results/wake-<label>/summary.json.
"""
import argparse, json, subprocess, time, urllib.parse, urllib.request
from datetime import datetime
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("label")
ap.add_argument("--isvc", required=True)
ap.add_argument("--ns", default="llm-serving")
ap.add_argument("--url", required=True)
ap.add_argument("--rounds", type=int, default=2)
ap.add_argument("--zero-timeout", type=float, default=900)
ap.add_argument("--request-timeout", type=float, default=900)
a = ap.parse_args()
out = Path(__file__).resolve().parent.parent / "benchmarks/results" / f"wake-{a.label}"
out.mkdir(parents=True, exist_ok=False)

def kubectl(*args):
    r = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(f"kubectl {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout

def pods():
    return json.loads(kubectl("get", "pods", "-n", a.ns, "-l", f"serving.kserve.io/inferenceservice={a.isvc}", "-o", "json"))["items"]

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None

def set_min(n):
    kubectl("patch", "isvc", "-n", a.ns, a.isvc, "--type", "merge", "-p", json.dumps({"spec": {"predictor": {"minReplicas": n}}}))

isvc = json.loads(kubectl("get", "isvc", "-n", a.ns, a.isvc, "-o", "json"))
host = urllib.parse.urlparse(isvc["status"]["url"]).hostname
model = a.isvc
summary = {"label": a.label, "isvc": a.isvc, "host": host, "rounds": []}
try:
    set_min(0)
    for rnd in range(1, a.rounds + 1):
        t_w = time.time()
        while pods():                                    # any pod, incl. Terminating
            if time.time() - t_w > a.zero_timeout:
                raise SystemExit(f"round {rnd}: still has pods after {a.zero_timeout}s")
            time.sleep(5)
        zero_after = round(time.time() - t_w, 1)
        time.sleep(10)
        body = json.dumps({"model": model, "prompt": "Reply with one word.", "max_tokens": 1}).encode()
        req = urllib.request.Request(a.url.rstrip("/") + "/v1/completions", data=body,
                                     headers={"Content-Type": "application/json", "Host": host})
        t_req = time.time(); r = {"round": rnd, "waited_for_zero_s": zero_after}
        try:
            with urllib.request.urlopen(req, timeout=a.request_timeout) as resp:
                resp.read(); r["status"] = resp.status
        except Exception as e:                            # noqa: BLE001
            r.update(status="error", error=f"{type(e).__name__}: {e}"[:200])
        t_resp = time.time()
        r["response_s"] = round(t_resp - t_req, 2)
        p = sorted(pods(), key=lambda x: x["metadata"]["creationTimestamp"])
        if p:
            q = p[-1]; cond = {c["type"]: c for c in q["status"].get("conditions", [])}
            created, sched = ts(q["metadata"]["creationTimestamp"]), ts(cond.get("PodScheduled", {}).get("lastTransitionTime"))
            ready = ts(cond.get("Ready", {}).get("lastTransitionTime")) if cond.get("Ready", {}).get("status") == "True" else None
            rel = lambda x: round(x - t_req, 1) if x else None   # noqa: E731
            r.update(pod=q["metadata"]["name"], pod_created_s=rel(created), pod_scheduled_s=rel(sched),
                     pod_ready_s=rel(ready), ready_to_response_s=round(t_resp - ready, 1) if ready else None)
        summary["rounds"].append(r)
        print(json.dumps(r), flush=True)
finally:
    set_min(1)
    summary["restored_min_replicas"] = 1
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=1))
