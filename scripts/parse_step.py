#!/usr/bin/env python3
"""parse_step.py - results of a step-load run (scripts/step-load.sh). Week 5 A4.

    uv run python scripts/parse_step.py benchmarks/results/<run-id>

For every cycle-NN/ with a DONE marker it writes
  cycle-NN/step-summary.json  the cycle's results (below)
  cycle-NN/timeline-5s.csv    one aligned row per 5 s, for the report's charts
and for the run
  step-summary.csv            one row per cycle, headline numbers
and prints a short table. Values follow the sidecar convention: a number, or a
string "n/a:<why>" (does not apply) or "ERROR:<why>" (should have been there).

THE CLOCK. Every time is "seconds after the step" (negative = before). The step
is placed from GuideLLM's own record - the scheduled time of the first request
(trace time 0) plus the high stage's start in stages.json - not from when the
harness launched GuideLLM (~9 s of client start-up in between). Kubernetes,
Prometheus and the timeline use the same machine's clock.

RELIEF (NOTES "Week 5 A4"). TTFT p95 in 30 s windows by SEND time, evaluated
every 5 s; a window's time is its end. Baseline = TTFT p95 of the baseline
stage minus its first 30 s (client warm-up sends the first requests late).
  degraded = first window after the step with p95 > 1.5 x baseline
  relief   = first window after that back within 1.5 x baseline and staying
             there for 60 s, all before the step-down.
No degradation is a result, not an error: scale-out was fast enough.

Standard library only. p95 is nearest-rank: the value below which 95% of the
requests fall, taken from the data, never interpolated.
"""
from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import re
import sys
from datetime import datetime
from pathlib import Path

WINDOW_S = 30.0       # relief window
EVAL_S = 5.0          # window evaluated every ...
BOUND_X = 1.5         # "within 1.5 x baseline"
HOLD_S = 60.0         # relief must hold this long
WARMUP_S = 30.0       # dropped from the start of the baseline
MIN_WINDOW_N = 10     # fewer requests in a window -> no p95 for it
TAIL_S = 120.0        # "end of step" steady state = last 120 s before step-down,
                      # never reaching back before the step
TOLERANCE = 1.1       # HPA acts beyond +10%: scale-up level = threshold x 1.1
LAG_FLAG_MS = 100.0   # send lag above this (after warm-up) is flagged
GAP_FLAG_S = 3.0      # timeline gap above this is flagged


def na(why: str) -> str:
    return f"n/a:{why}"


def err(why: str) -> str:
    return f"ERROR:{why}"


def p95(xs: list[float]) -> float | None:
    if not xs:
        return None
    s = sorted(xs)
    return s[math.ceil(0.95 * len(s)) - 1]


def epoch(ts: str | None) -> float | None:
    """Kubernetes / kubectl --timestamps ISO time -> epoch seconds.
    Handles 'Z' and nanosecond fractions (trimmed to microseconds)."""
    if not ts:
        return None
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", ts)
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    tz = m.group(3) or "Z"
    tz = "+00:00" if tz == "Z" else tz
    return datetime.fromisoformat(m.group(1) + frac + tz).timestamp()


def rel(t: float | None, origin: float) -> float | str:
    return round(t - origin, 1) if t is not None else na("not observed")


def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


# ------------------------------------------------------------ prometheus ---
def prom_by_pod(path: Path) -> dict[str, list[tuple[float, float]]]:
    """query_range export -> {pod: [(t, value)]}, series with the same pod
    (e.g. one per finished_reason) summed at each timestamp."""
    doc = load(path)
    if not doc or doc.get("status") != "success":
        return {}
    acc: dict[str, dict[float, float]] = {}
    for s in doc["data"]["result"]:
        pod = s["metric"].get("pod", "_total")
        d = acc.setdefault(pod, {})
        for t, v in s["values"]:
            try:
                d[float(t)] = d.get(float(t), 0.0) + float(v)
            except ValueError:
                pass
    return {p: sorted(d.items()) for p, d in acc.items()}


def value_at(series: list[tuple[float, float]], t: float) -> float | None:
    """Last value at or before t."""
    i = bisect.bisect_right([x[0] for x in series], t) - 1
    return series[i][1] if i >= 0 else None


# --------------------------------------------------------------- relief ---
def windows(reqs: list[dict], start: float, end: float) -> list[tuple[float, float | None, int]]:
    """[(window end, TTFT p95 ms or None, n)] every EVAL_S from start to end."""
    sends = [r["send"] for r in reqs]
    out = []
    t = start
    while t <= end + 1e-9:
        lo = bisect.bisect_right(sends, t - WINDOW_S)
        hi = bisect.bisect_right(sends, t)
        xs = [reqs[i]["ttft"] for i in range(lo, hi)]
        out.append((t, p95(xs) if len(xs) >= MIN_WINDOW_N else None, len(xs)))
        t += EVAL_S
    return out


def find_relief(win, step: float, down: float, bound: float):
    """(degraded_t, relief_t, why). Times absolute; None when not found."""
    after = [w for w in win if step < w[0] <= down and w[1] is not None]
    deg = next((w[0] for w in after if w[1] > bound), None)
    if deg is None:
        return None, None, "no window above the bound before step-down"
    for w in after:
        if w[0] <= deg or w[1] > bound:
            continue
        hold = [x for x in after if w[0] <= x[0] <= w[0] + HOLD_S]
        if w[0] + HOLD_S <= down and all(x[1] <= bound for x in hold):
            return deg, w[0], ""
    return deg, None, "not back within the bound for 60 s before step-down"


# ---------------------------------------------------------------- cycle ---
def parse_cycle(d: Path) -> dict:
    cy, st, gl = load(d / "cycle.json"), load(d / "stages.json"), load(d / "guidellm.json")
    if not (cy and st and gl):
        return {"cycle": d.name, "error": err("cycle.json, stages.json or guidellm.json unreadable")}
    b = gl["benchmarks"][0]["requests"]
    ok_reqs, bad_reqs = b.get("successful", []), b.get("errored", [])
    allt = [r["info"]["timings"] for r in ok_reqs + bad_reqs + b.get("incomplete", [])]
    origin = min(t["targeted_start"] for t in allt)            # trace time 0
    si = cy.get("step_stage", 1)
    stages = st["stages"]
    t_step = origin + stages[si]["start_s"]
    t_down = origin + stages[si]["end_s"]
    t_end = origin + stages[-1]["end_s"]
    t_base0 = origin + max(stages[0]["start_s"], 0.0) + WARMUP_S

    reqs = sorted(({"send": r["info"]["timings"]["request_start"],
                    "target": r["info"]["timings"]["targeted_start"],
                    "end": r["info"]["timings"]["request_end"],
                    "ttft": r["time_to_first_token_ms"],
                    "itl": r["inter_token_latency_ms"]} for r in ok_reqs), key=lambda r: r["send"])

    def span(lo, hi):
        return [r for r in reqs if lo <= r["send"] < hi]

    base = span(t_base0, t_step)
    base_ttft = p95([r["ttft"] for r in base])
    out: dict = {"cycle": d.name, "stages": cy["stages"], "seed": cy["seed"],
                 "achieved_rps": [s["achieved_rps"] for s in stages]}
    if base_ttft is None:
        out["error"] = err("no baseline requests")
        return out
    bound = BOUND_X * base_ttft
    out["baseline"] = {"requests": len(base), "ttft_p95_ms": round(base_ttft, 1),
                       "itl_p95_ms": round(p95([r["itl"] for r in base]), 2),
                       "relief_bound_ms": round(bound, 1)}

    win = windows(reqs, origin + WINDOW_S, t_end)
    deg, rel_t, why = find_relief(win, t_step, t_down, bound)
    high = [w for w in win if t_step < w[0] <= t_down and w[1] is not None]
    peak = max(high, key=lambda w: w[1]) if high else None
    out["relief"] = {
        "degraded_s": rel(deg, t_step) if deg else na(why),
        "time_to_relief_s": rel(rel_t, t_step) if rel_t else na(why),
        "peak_window_ttft_p95_ms": round(peak[1], 1) if peak else na("no windows"),
        "peak_at_s": rel(peak[0], t_step) if peak else na("no windows"),
        "peak_x_baseline": round(peak[1] / base_ttft, 2) if peak else na("no windows")}

    tail_lo = max(t_down - TAIL_S, t_step)
    tail_s = t_down - tail_lo
    tail = span(tail_lo, t_down)
    done_tail = [r for r in reqs if tail_lo <= r["end"] < t_down]
    out["end_of_step"] = {
        "window_s": round(tail_s, 1), "requests_sent": len(tail),
        "ttft_p95_ms": round(p95([r["ttft"] for r in tail]), 1) if tail else na("no requests"),
        "itl_p95_ms": round(p95([r["itl"] for r in tail]), 2) if tail else na("no requests"),
        "offered_rps": round(len(tail) / tail_s, 2),
        "completed_rps": round(len(done_tail) / tail_s, 2)}

    # ---- scale-out stages
    timeline = [json.loads(x) for x in (d / "timeline.jsonl").read_text().splitlines() if x.strip()] \
        if (d / "timeline.jsonl").exists() else []
    timeline = [x for x in timeline if "error" not in x]
    keda = prom_by_pod(d / "prom" / "keda-query.json").get("_total", [])
    thr = cy.get("keda_threshold") or ""
    stg: dict = {}
    if thr:
        level = float(thr) * TOLERANCE
        cross = next((t for t, v in keda if t > t_step and v > level), None)
        before = [v for t, v in keda if t_base0 <= t <= t_step]
        stg["metric_crosses_s"] = rel(cross, t_step)
        stg["metric_scale_up_level"] = round(level, 2)
        if before and max(before) > level:
            stg["WARN_metric_above_level_before_step"] = round(max(before), 2)
    else:
        stg["metric_crosses_s"] = na("no ScaledObject threshold recorded (KEDA off)")

    ev = load(d / "events.json") or {"items": []}
    hpa_up = []
    for e in ev["items"]:
        if e.get("involvedObject", {}).get("kind") != "HorizontalPodAutoscaler" or e.get("reason") != "SuccessfulRescale":
            continue
        m = re.search(r"New size: (\d+)", e.get("message", ""))
        if m and int(m.group(1)) >= 2:
            for k in ("eventTime", "firstTimestamp", "lastTimestamp"):
                t = epoch(e.get(k))
                if t is not None and t >= t_step - 2:
                    hpa_up.append(t)
    stg["hpa_rescale_event_s"] = rel(min(hpa_up), t_step) if hpa_up else na("no rescale-up event after the step")
    desired = [(x["t"], (x.get("hpa") or {}).get("desired") or (x.get("deploy") or {}).get("spec")) for x in timeline]
    tl_up = next((t for t, v in desired if t > t_step and v and v >= 2), None)
    stg["timeline_desired_2_s"] = rel(tl_up, t_step) if tl_up else na("desired never reached 2")

    snap = load(d / "at-stepdown" / "pods.json") or {"items": []}
    new = sorted((p for p in snap["items"] if (epoch(p["metadata"]["creationTimestamp"]) or 0) > t_step - 5),
                 key=lambda p: p["metadata"]["creationTimestamp"])
    pod2 = new[0]["metadata"]["name"] if new else None
    if new:
        p = new[0]
        conds = {c["type"]: c for c in p["status"].get("conditions", [])}
        init = {c["name"]: c for c in p["status"].get("initContainerStatuses", [])}
        cont = {c["name"]: c for c in p["status"].get("containerStatuses", [])}
        si_term = (init.get("storage-initializer", {}).get("state", {}) or {}).get("terminated", {})
        kc = cont.get("kserve-container", {})
        started = ((kc.get("state") or {}).get("running") or {}).get("startedAt")
        ready = conds.get("Ready", {})
        stg.update({
            "replica2_pod": pod2,
            "pod_created_s": rel(epoch(p["metadata"]["creationTimestamp"]), t_step),
            "pod_scheduled_s": rel(epoch(conds.get("PodScheduled", {}).get("lastTransitionTime")), t_step),
            "model_copy_done_s": rel(epoch(si_term.get("finishedAt")), t_step),
            "engine_started_s": rel(epoch(started), t_step),
            "pod_ready_s": rel(epoch(ready.get("lastTransitionTime")) if ready.get("status") == "True" else None, t_step)})
        if len(new) > 1:
            stg["WARN_more_new_pods"] = [x["metadata"]["name"] for x in new[1:]]
    else:
        stg["replica2_pod"] = na("no pod created after the step (in the step-down snapshot)")
    ep2 = next((x["t"] for x in timeline if x["t"] > t_step and x.get("endpoints_ready", 0) >= 2), None)
    stg["in_endpoints_s"] = rel(ep2, t_step) if ep2 else na("endpoints never reached 2")

    # access logs: first request on replica 2, and the load split once it is Ready
    posts: dict[str, list[float]] = {}
    for f in (d / "at-stepdown" / "logs").glob("*.log"):
        if f.name.endswith(".storage-initializer.log"):
            continue
        ts = []
        for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
            if "POST /v1/chat/completions" in line:
                t = epoch(line.split(" ", 1)[0])
                if t is not None:
                    ts.append(t)
        posts[f.name[:-4]] = ts
    if pod2:
        first = next((t for t in sorted(posts.get(pod2, [])) if t > t_step), None)
        stg["first_request_on_replica2_s"] = rel(first, t_step)
    stg["relief_s"] = out["relief"]["time_to_relief_s"]
    out["scale_out"] = stg

    share: dict = {}
    if pod2 and isinstance(stg.get("pod_ready_s"), float):
        ready_t = t_step + stg["pod_ready_s"]
        succ = prom_by_pod(d / "prom" / "success.json")
        for pod, ts in sorted(posts.items()):
            n_log = sum(1 for t in ts if ready_t <= t < t_down)
            s = succ.get(pod, [])
            a, z = value_at(s, ready_t), value_at(s, t_down)
            # arrivals (access log, logged when the response starts) and
            # completions (success counter) differ: a replica draining a backlog
            # completes more than arrives. The split is judged on arrivals.
            share[pod] = {"arrivals_access_log": n_log,
                          "completions_prometheus": round(z - (a or 0.0)) if z is not None else na("no series")}
        tot = sum(v["arrivals_access_log"] for v in share.values())
        for v in share.values():
            v["arrival_share_pct"] = round(100 * v["arrivals_access_log"] / tot, 1) if tot else na("no requests")
        out["load_share_after_ready"] = {"from_s": stg["pod_ready_s"], "to_s": round(t_down - t_step, 1), "pods": share}
    else:
        out["load_share_after_ready"] = na("no second replica Ready")

    waiting = prom_by_pod(d / "prom" / "waiting.json")
    running = prom_by_pod(d / "prom" / "running.json")
    out["peak_per_pod"] = {pod: {"waiting_max": max((v for t, v in waiting.get(pod, []) if t_step < t <= t_down), default=None),
                                 "running_max": max((v for t, v in running.get(pod, []) if t_step < t <= t_down), default=None)}
                           for pod in sorted(set(waiting) | set(running))}

    # ---- scale-down and replica changes
    dn = next((t for t, v in desired if t > t_down and v == 1), None) if tl_up else None
    gone = None
    if pod2:
        gone = next((x["t"] for x in timeline if x["t"] > t_down and
                     not any(p["name"] == pod2 and not p["deleting"] for p in x.get("pods", []))), None)
    seq = []
    for _, v in desired:
        if v is not None and (not seq or seq[-1] != v):
            seq.append(v)
    out["scale_down"] = {
        "desired_1_after_stepdown_s": rel(dn, t_down) if dn else na("no scale-up, or never back to 1"),
        "replica2_deleting_after_stepdown_s": rel(gone, t_down) if gone else na("no replica 2, or not deleted in the cycle"),
        "replica_sequence": seq,
        "oscillation": len(seq) > 3 or (len(seq) == 3 and seq != [1, 2, 1])}

    # ---- data quality
    lags = [(r["send"] - r["target"]) * 1000 for r in reqs if r["send"] >= origin + WARMUP_S]
    gaps = [b["t"] - a["t"] for a, b in zip(timeline, timeline[1:])]
    lag99 = sorted(lags)[math.ceil(0.99 * len(lags)) - 1] if lags else None
    out["quality"] = {
        "successful": len(ok_reqs), "errored": len(bad_reqs),
        "send_lag_p99_ms_after_warmup": round(lag99, 1) if lag99 is not None else na("no requests"),
        "timeline_ticks": len(timeline), "timeline_max_gap_s": round(max(gaps), 2) if gaps else na("no timeline"),
        "prometheus_export": cy.get("prometheus_export"),
        "flags": [f for f, bad in (
            ("errored requests", len(bad_reqs) > 0),
            ("send lag p99 > %g ms" % LAG_FLAG_MS, lag99 is not None and lag99 > LAG_FLAG_MS),
            ("timeline gap > %g s" % GAP_FLAG_S, bool(gaps) and max(gaps) > GAP_FLAG_S),
            ("Prometheus export failed", not cy.get("prometheus_export")),
            ("scaled out but replica 2 missing from the step-down snapshot", bool(tl_up) and not pod2),
            ("replica count oscillated", out["scale_down"]["oscillation"])) if bad]}

    # ---- aligned 5 s timeline for charts
    pods = sorted(set(waiting) | set(running))
    rows = []
    sends = [r["send"] for r in reqs]
    ends = sorted(r["end"] for r in reqs)
    wmap = {round(w[0], 3): w[1] for w in win}
    t = origin + EVAL_S
    while t <= t_end + EVAL_S:
        tick = next((x for x in reversed(timeline) if x["t"] <= t), None)
        row = {"t_after_step_s": round(t - t_step, 1),
               "ttft_p95_30s_ms": round(wmap[round(t, 3)], 1) if wmap.get(round(t, 3)) else "",
               "sent_rps": (bisect.bisect_right(sends, t) - bisect.bisect_right(sends, t - EVAL_S)) / EVAL_S,
               "completed_rps": (bisect.bisect_right(ends, t) - bisect.bisect_right(ends, t - EVAL_S)) / EVAL_S,
               "keda_metric": round(value_at(keda, t), 2) if keda and value_at(keda, t) is not None else "",
               "desired_replicas": ((tick.get("hpa") or {}).get("desired") or (tick.get("deploy") or {}).get("spec")) if tick else "",
               "ready_pods": sum(1 for p in tick.get("pods", []) if p["ready"] == "True" and not p["deleting"]) if tick else ""}
        for i, pod in enumerate(pods):
            row[f"pod{i + 1}_running"] = value_at(running.get(pod, []), t) if pod in running else ""
            row[f"pod{i + 1}_waiting"] = value_at(waiting.get(pod, []), t) if pod in waiting else ""
        rows.append(row)
        t += EVAL_S
    out["timeline_pods"] = {f"pod{i + 1}": pod for i, pod in enumerate(pods)}
    with open(d / "timeline-5s.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()) if rows else ["t_after_step_s"])
        w.writeheader()
        w.writerows(rows)
    return out


HEAD = [("cycle", lambda s: s["cycle"]), ("stages", lambda s: s.get("stages")),
        ("baseline_ttft_p95_ms", lambda s: s.get("baseline", {}).get("ttft_p95_ms")),
        ("degraded_s", lambda s: s.get("relief", {}).get("degraded_s")),
        ("time_to_relief_s", lambda s: s.get("relief", {}).get("time_to_relief_s")),
        ("peak_x_baseline", lambda s: s.get("relief", {}).get("peak_x_baseline")),
        ("hpa_rescale_s", lambda s: s.get("scale_out", {}).get("hpa_rescale_event_s")),
        ("pod_ready_s", lambda s: s.get("scale_out", {}).get("pod_ready_s", na("no replica 2"))),
        ("end_ttft_p95_ms", lambda s: s.get("end_of_step", {}).get("ttft_p95_ms")),
        ("scale_down_s", lambda s: s.get("scale_down", {}).get("desired_1_after_stepdown_s")),
        ("flags", lambda s: "; ".join(s.get("quality", {}).get("flags", [])) or "-")]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("run_dir")
    run = Path(ap.parse_args().run_dir)
    cycles = sorted(p for p in run.glob("cycle-[0-9][0-9]") if (p / "DONE").exists())
    if not cycles:
        print(f"no DONE cycles in {run}", file=sys.stderr)
        return 1
    summaries = []
    for c in cycles:
        s = parse_cycle(c)
        (c / "step-summary.json").write_text(json.dumps(s, indent=2) + "\n", encoding="utf-8")
        summaries.append(s)
    with open(run / "step-summary.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([h for h, _ in HEAD])
        for s in summaries:
            w.writerow([g(s) for _, g in HEAD])
    for s in summaries:
        print("  ".join(f"{h}={g(s)}" for h, g in HEAD))
    return 0


if __name__ == "__main__":
    sys.exit(main())
