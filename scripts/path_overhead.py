#!/usr/bin/env python3
"""path_overhead.py - week 6: latency cost of the Knative data path.

  python3 scripts/path_overhead.py <label> \\
      --a-name standard --a-url http://<predictor ClusterIP>  --a-model llama-fp8 \\
      --b-name knative  --b-url http://localhost:30880 --b-host <isvc host> --b-model llama-fp8-kn \\
      [--pairs 200] [--load-seconds 120 --load-workers 16 --load-prompt-words 900 --load-max-tokens 256]

The SAME model behind two paths: A = Standard mode (client -> predictor
Service -> vLLM), B = Knative mode (client -> Kourier -> [activator] ->
queue-proxy -> vLLM). Each must be served by its own replica (GPU: one GPU each).

1. Overhead (always): --pairs pairs of identical requests, A and B in random
   order within each pair, concurrency 1, max_tokens=1, one fixed short prompt
   (repeated -> vLLM's prefix cache makes model time tiny), so the difference is
   the path. Result: per-path median/p95 (nearest rank, client-side, exact) and
   the MEDIAN PAIRED DIFFERENCE B - A with a bootstrap 95% interval.
2. Load (optional, --load-seconds > 0): closed loop, --load-workers workers,
   each path in turn for --load-seconds; requests/s and mean latency per path.
Standard library only (runs on the GPU host, or inside a pod on kind).
Writes benchmarks/results/overhead-<label>/ (or --out-dir) requests.jsonl + summary.json.
"""
import argparse, json, math, random, statistics, threading, time, urllib.request
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("label")
for p in ("a", "b"):
    ap.add_argument(f"--{p}-name", required=True)
    ap.add_argument(f"--{p}-url", required=True)
    ap.add_argument(f"--{p}-host", default=None)
    ap.add_argument(f"--{p}-model", required=True)
ap.add_argument("--pairs", type=int, default=200)
ap.add_argument("--warmup", type=int, default=10)
ap.add_argument("--load-seconds", type=float, default=0)
ap.add_argument("--load-workers", type=int, default=16)
ap.add_argument("--load-prompt-words", type=int, default=900)
ap.add_argument("--load-max-tokens", type=int, default=256)
ap.add_argument("--out-dir", default=None)
ap.add_argument("--seed", type=int, default=2026)
a = ap.parse_args()
paths = {x: {"name": getattr(a, f"{x}_name"), "url": getattr(a, f"{x}_url").rstrip("/"),
             "host": getattr(a, f"{x}_host"), "model": getattr(a, f"{x}_model")} for x in ("a", "b")}
out = Path(a.out_dir) if a.out_dir else Path(__file__).resolve().parent.parent / "benchmarks/results" / f"overhead-{a.label}"
out.mkdir(parents=True, exist_ok=False)
rng = random.Random(a.seed)

def call(p, prompt, max_tokens, timeout=600):
    hdr = {"Content-Type": "application/json", "Connection": "close"}
    if p["host"]:
        hdr["Host"] = p["host"]
    body = json.dumps({"model": p["model"], "prompt": prompt, "max_tokens": max_tokens, "ignore_eos": True}).encode()
    s = time.perf_counter(); r = {"path": p["name"], "wall": time.time()}
    try:
        with urllib.request.urlopen(urllib.request.Request(p["url"] + "/v1/completions", data=body, headers=hdr),
                                    timeout=timeout) as resp:
            j = json.loads(resp.read())
            r.update(status=resp.status, tokens=j["usage"]["completion_tokens"])
    except Exception as e:                          # noqa: BLE001 - every failure is data
        r.update(status="error", error=f"{type(e).__name__}: {e}"[:200])
    r["latency_ms"] = round(1000 * (time.perf_counter() - s), 3)
    return r

def nr(xs, q):                                      # nearest rank
    xs = sorted(xs)
    return xs[max(0, math.ceil(q * len(xs)) - 1)] if xs else None

rows = []
PROMPT = "Reply with one word."
for _ in range(a.warmup):                           # warm both paths; not recorded
    for x in ("a", "b"):
        call(paths[x], PROMPT, 1)
pairs = []
for i in range(a.pairs):
    order = ["a", "b"] if rng.random() < 0.5 else ["b", "a"]
    res = {x: call(paths[x], PROMPT, 1) for x in order}
    for x in order:
        res[x].update(phase="overhead", pair=i, first=(x == order[0]))
        rows.append(res[x])
    if res["a"]["status"] == 200 and res["b"]["status"] == 200:
        pairs.append(res["b"]["latency_ms"] - res["a"]["latency_ms"])

summary = {"label": a.label, "paths": paths, "pairs": a.pairs, "overhead": {}}
for x in ("a", "b"):
    lat = [r["latency_ms"] for r in rows if r["path"] == paths[x]["name"] and r["status"] == 200]
    summary["overhead"][paths[x]["name"]] = {
        "ok": len(lat), "errors": sum(1 for r in rows if r["path"] == paths[x]["name"] and r["status"] != 200),
        "median_ms": round(statistics.median(lat), 2) if lat else None, "p95_ms": nr(lat, 0.95)}
if pairs:
    boots = sorted(statistics.median(rng.choices(pairs, k=len(pairs))) for _ in range(2000))
    summary["overhead"]["paired_diff_b_minus_a_ms"] = {
        "median": round(statistics.median(pairs), 2), "ci95": [round(boots[49], 2), round(boots[1949], 2)],
        "n_pairs": len(pairs), "meaning": f"{paths['b']['name']} - {paths['a']['name']}, same request, back to back"}

if a.load_seconds > 0:
    lp = " ".join(["serving"] * a.load_prompt_words)
    summary["load"] = {"workers": a.load_workers, "seconds": a.load_seconds,
                       "prompt_words": a.load_prompt_words, "max_tokens": a.load_max_tokens}
    for x in ("a", "b"):
        got, lock, t_end = [], threading.Lock(), time.time() + a.load_seconds
        def w():
            while time.time() < t_end:
                r = call(paths[x], lp, a.load_max_tokens)
                r["phase"] = "load"
                with lock:
                    got.append(r)
        ts = [threading.Thread(target=w) for _ in range(a.load_workers)]
        t0 = time.time()
        for t in ts: t.start()
        for t in ts: t.join()
        dur = time.time() - t0
        ok = [r for r in got if r["status"] == 200]
        rows += got
        summary["load"][paths[x]["name"]] = {
            "ok": len(ok), "errors": len(got) - len(ok), "requests_per_s": round(len(ok) / dur, 3),
            "mean_latency_ms": round(statistics.mean(r["latency_ms"] for r in ok), 1) if ok else None,
            "output_tokens_per_s": round(sum(r["tokens"] for r in ok) / dur, 1)}
        time.sleep(10)                              # let the first path's queue empty

(out / "requests.jsonl").write_text("".join(json.dumps(r) + "\n" for r in rows))
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=1))
