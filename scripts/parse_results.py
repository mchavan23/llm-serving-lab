"""
scripts/parse_results.py - one benchmark run directory -> one tidy CSV.

Week 4 A6. Reads what scripts/benchmark.sh wrote and produces ONE ROW PER
MEASURED POINT (warmups excluded, anchor labelled). It also CHECKS the run:
any sidecar field that says "ERROR:", any missing file, or any leg without a
DONE marker is reported, and the exit code is 1. "The parser reads them" is
the A7 gate, so a silent pass on a broken run would defeat it.

    uv run --locked python scripts/parse_results.py benchmarks/results/<run-id>
    uv run --locked python scripts/parse_results.py <run dir> --out other.csv

Standard library only: nothing new to pin.

Definitions (match GuideLLM's own console output, checked on a7-kind-2):
  latency columns  - COMPLETED requests ("successful" bucket)
  throughput       - ALL requests ("total" bucket)
  units            - in the column name: _ms, _s, _pct, _mhz ...
"""

import argparse
import csv
import json
import sys
from pathlib import Path

# Files benchmark.sh writes for every point. A missing one is a problem.
POINT_FILES = [
    "point.json", "guidellm.json", "guidellm.log", "metrics-before.txt",
    "metrics-after.txt", "gauges.csv", "gpu.csv", "gpu-summary.json",
]

# A3 comparability rules (agreed 2026-10-03). Thresholds live here, once.
WAITING_PCT_LIMIT = 50.0   # flag 2: waiting > 0 in MORE than this % of gauge readings
PREFIX_HIT_LIMIT = 5.0     # flag 3: prefix cache hit rate above this %

COLUMNS = [
    "run_id", "leg", "is_anchor", "shape", "concurrency", "seed",
    "prompt_tokens", "output_tokens", "measured_s", "started_at", "status",
    "model_repo", "model_revision", "vllm_version", "kv_cache_tokens", "gpu_uuid",
    "requests_successful", "requests_errored", "requests_incomplete",
    "ttft_p50_ms", "ttft_p95_ms", "ttft_p99_ms", "itl_p50_ms", "itl_p95_ms",
    "e2e_p50_s", "e2e_p95_s", "output_tok_per_s", "requests_per_s",
    "server_prompt_tokens_mean", "server_ttft_mean_ms", "server_queue_mean_ms",
    "server_prefill_mean_ms", "server_decode_mean_ms",
    "batch_mean", "batch_max", "waiting_max", "waiting_pct", "kv_usage_max_pct",
    "gauge_samples", "preemptions", "prefix_hit_pct",
    "gpu_sm_clock_mean_mhz", "gpu_sm_clock_min_mhz", "gpu_temp_max_c", "gpu_power_mean_w",
    "flag_preemption", "flag_waiting", "flag_prefix_cache", "comparable",
]

problems: list[str] = []   # everything wrong with the run, reported at the end


def problem(msg: str) -> None:
    problems.append(msg)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as e:
        problem(f"{path}: unreadable ({e})")
        return {}


def find_errors(obj, path: Path, where: str = "") -> None:
    """Walk a sidecar JSON and report every value that starts with 'ERROR:'."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            find_errors(v, path, f"{where}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            find_errors(v, path, f"{where}[{i}]")
    elif isinstance(obj, str) and obj.startswith("ERROR:"):
        problem(f"{path}: {where.lstrip('.')} = {obj}")


def parse_prometheus(path: Path) -> dict[str, float]:
    """Prometheus text -> {metric name: value summed over all its series}.

    A line looks like:  vllm:num_preemptions_total{engine="0",model_name="x"} 3.0
    The value is after the LAST space (label values may contain spaces); the
    name is everything before '{'. Summing series handles any label split.
    """
    totals: dict[str, float] = {}
    if not path.exists():
        return totals
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        name_and_labels, _, value = line.rpartition(" ")
        name = name_and_labels.split("{", 1)[0]
        try:
            totals[name] = totals.get(name, 0.0) + float(value)
        except ValueError:
            continue
    return totals


def delta(before: dict, after: dict, name: str):
    """How much a counter grew during the point, or None if not scraped."""
    if name in before and name in after:
        return after[name] - before[name]
    return None


def hist_mean(before: dict, after: dict, base: str):
    """Mean of a histogram over the point: change in _sum / change in _count."""
    s = delta(before, after, base + "_sum")
    c = delta(before, after, base + "_count")
    if s is None or not c:          # not scraped, or no observations
        return None
    return s / c


def gauge_stats(path: Path, t0: float, t1: float) -> dict:
    """Stats of the 2-second gauge readings INSIDE the measured window [t0, t1]."""
    run, wait, kv = [], [], []
    with path.open(newline="") as f:
        for row in csv.DictReader(f):
            try:
                t = float(row["epoch_s"])
                r, w, k = (float(row[c]) for c in
                           ("num_requests_running", "num_requests_waiting", "kv_cache_usage_perc"))
            except (ValueError, TypeError):
                continue                       # blank cell = that scrape failed
            if t0 <= t <= t1:
                run.append(r); wait.append(w); kv.append(k)
    n = len(run)
    if n == 0:
        return {"gauge_samples": 0}
    return {
        "gauge_samples": n,
        "batch_mean": sum(run) / n,            # mean running requests = observed batch size
        "batch_max": max(run),
        "waiting_max": max(wait),
        "waiting_pct": 100.0 * sum(1 for w in wait if w > 0) / n,
        # vLLM names it "perc" but exports a FRACTION (0.0033 = 0.33%).
        "kv_usage_max_pct": 100.0 * max(kv),
    }


def session_for(sessions: list[dict], started_at: str) -> dict:
    """The environment record in force when the point started.

    A resumed run writes one session record per invocation (possibly on a
    different GPU). ISO-8601 'Z' strings sort in time order, so plain string
    comparison picks the latest record taken before this point began.
    """
    chosen = {}
    for s in sessions:
        if s.get("captured_at", "") <= started_at:
            chosen = s
    return chosen


def parse_point(run_dir: Path, leg_dir: Path, pdir: Path, leg_env: dict, sessions: list[dict]) -> dict:
    for f in POINT_FILES:
        if not (pdir / f).exists():
            problem(f"{pdir}: missing {f}")
    pt = load_json(pdir / "point.json")
    find_errors(pt, pdir / "point.json")
    gl = load_json(pdir / "guidellm.json")
    bench = (gl.get("benchmarks") or [{}])[0]
    m = bench.get("metrics", {})

    def pct(metric: str, p: str):
        return m.get(metric, {}).get("successful", {}).get("percentiles", {}).get(p)

    before = parse_prometheus(pdir / "metrics-before.txt")
    after = parse_prometheus(pdir / "metrics-after.txt")
    t0, t1 = bench.get("start_time"), bench.get("end_time")   # the measured window
    gauges = gauge_stats(pdir / "gauges.csv", t0, t1) if t0 and t1 else {"gauge_samples": 0}

    gpu = load_json(pdir / "gpu-summary.json")
    find_errors(gpu, pdir / "gpu-summary.json")
    has_gpu = isinstance(gpu.get("gpu_samples"), int)          # else "n/a:..." or "ERROR:..."

    preempt = delta(before, after, "vllm:num_preemptions_total")
    hits = delta(before, after, "vllm:prefix_cache_hits_total")
    queries = delta(before, after, "vllm:prefix_cache_queries_total")
    prefix_pct = 100.0 * hits / queries if hits is not None and queries else None

    ms = lambda v: None if v is None else 1000.0 * v          # seconds -> ms
    session = session_for(sessions, pt.get("started_at", ""))
    totals = m.get("request_totals", {})

    row = {
        "run_id": run_dir.name,
        "leg": pt.get("leg"),
        "is_anchor": leg_dir.name == "anchor",
        "shape": pt.get("shape"),
        "concurrency": pt.get("concurrency"),
        "seed": pt.get("seed"),
        "prompt_tokens": pt.get("prompt_tokens"),
        "output_tokens": pt.get("output_tokens"),
        "measured_s": pt.get("measured_s"),
        "started_at": pt.get("started_at"),
        "status": pt.get("status"),
        "model_repo": leg_env.get("model", {}).get("hf_repo"),
        "model_revision": leg_env.get("model", {}).get("hf_revision"),
        "vllm_version": leg_env.get("vllm", {}).get("version"),
        "kv_cache_tokens": leg_env.get("kv_cache", {}).get("size_tokens"),
        "gpu_uuid": session.get("gpu", {}).get("uuid"),
        "requests_successful": totals.get("successful"),
        "requests_errored": totals.get("errored"),
        "requests_incomplete": totals.get("incomplete"),
        "ttft_p50_ms": pct("time_to_first_token_ms", "p50"),
        "ttft_p95_ms": pct("time_to_first_token_ms", "p95"),
        "ttft_p99_ms": pct("time_to_first_token_ms", "p99"),
        "itl_p50_ms": pct("inter_token_latency_ms", "p50"),
        "itl_p95_ms": pct("inter_token_latency_ms", "p95"),
        "e2e_p50_s": pct("request_latency", "p50"),
        "e2e_p95_s": pct("request_latency", "p95"),
        "output_tok_per_s": m.get("output_tokens_per_second", {}).get("total", {}).get("mean"),
        "requests_per_s": m.get("requests_per_second", {}).get("total", {}).get("mean"),
        "server_prompt_tokens_mean": hist_mean(before, after, "vllm:request_prompt_tokens"),
        "server_ttft_mean_ms": ms(hist_mean(before, after, "vllm:time_to_first_token_seconds")),
        "server_queue_mean_ms": ms(hist_mean(before, after, "vllm:request_queue_time_seconds")),
        "server_prefill_mean_ms": ms(hist_mean(before, after, "vllm:request_prefill_time_seconds")),
        "server_decode_mean_ms": ms(hist_mean(before, after, "vllm:request_decode_time_seconds")),
        **gauges,
        "preemptions": preempt,
        "prefix_hit_pct": prefix_pct,
        "gpu_sm_clock_mean_mhz": gpu["clocks_sm_mhz"]["mean"] if has_gpu else None,
        "gpu_sm_clock_min_mhz": gpu["clocks_sm_mhz"]["min"] if has_gpu else None,
        "gpu_temp_max_c": gpu["temperature_c"]["max"] if has_gpu else None,
        "gpu_power_mean_w": gpu["power_draw_w"]["mean"] if has_gpu else None,
    }

    # The three A3 rules. None = could not be judged (input missing) -> a problem.
    flags = {
        "flag_preemption": None if preempt is None else preempt > 0,
        "flag_waiting": None if not gauges["gauge_samples"] else gauges["waiting_pct"] > WAITING_PCT_LIMIT,
        "flag_prefix_cache": None if prefix_pct is None else prefix_pct > PREFIX_HIT_LIMIT,
    }
    row.update(flags)
    if any(v is None for v in flags.values()):
        row["comparable"] = "unknown"
        problem(f"{pdir}: cannot judge comparability ({[k for k, v in flags.items() if v is None]})")
    else:
        row["comparable"] = row["status"] == "ok" and not any(flags.values())
    if row["status"] != "ok":
        problem(f"{pdir}: status {row['status']}")
    return row


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--out", type=Path, help="default: <run_dir>/results.csv")
    args = ap.parse_args()
    run_dir = args.run_dir.resolve()
    if not run_dir.is_dir():
        print(f"not a directory: {run_dir}", file=sys.stderr)
        return 2

    sessions = []
    for p in sorted(run_dir.glob("env-session-*.json")):
        s = load_json(p)
        find_errors(s, p)
        sessions.append(s)
    if not sessions:
        problem(f"{run_dir}: no env-session-*.json")
    sessions.sort(key=lambda s: s.get("captured_at", ""))
    if len({s.get("gpu", {}).get("uuid") for s in sessions}) > 1:
        print("NOTE: this run spans more than one GPU (see gpu_uuid per row)", file=sys.stderr)

    # A directory that is neither a leg nor a moved-aside attempt means a leg
    # died before its sidecar was written (e.g. never became Ready). Report it.
    for d in run_dir.iterdir():
        if d.is_dir() and ".failed-" not in d.name and not (d / "env-leg.json").exists():
            problem(f"{d}: leg directory without env-leg.json - leg never reached Ready")

    rows = []
    # A leg directory is one with env-leg.json; ".failed-<time>" copies are
    # earlier attempts that a resume moved aside - kept on disk, never parsed.
    for leg_dir in sorted(d for d in run_dir.iterdir()
                          if d.is_dir() and (d / "env-leg.json").exists() and ".failed-" not in d.name):
        if not (leg_dir / "DONE").exists():
            problem(f"{leg_dir}: no DONE marker - leg incomplete")
        leg_env = load_json(leg_dir / "env-leg.json")
        find_errors(leg_env, leg_dir / "env-leg.json")
        for pdir in sorted(d for d in leg_dir.iterdir() if (d / "point.json").exists()):
            if pdir.name == "warmup":
                continue                                   # discarded by design
            rows.append(parse_point(run_dir, leg_dir, pdir, leg_env, sessions))

    rows.sort(key=lambda r: r["started_at"] or "")         # run order
    out = args.out or run_dir / "results.csv"
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS)
        w.writeheader()
        for r in rows:
            w.writerow({k: ("" if r.get(k) is None else r.get(k)) for k in COLUMNS})

    flagged = sum(1 for r in rows if r["comparable"] is not True)
    print(f"{len(rows)} points -> {out}  ({flagged} not comparable)")
    for p in problems:
        print(f"PROBLEM: {p}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
