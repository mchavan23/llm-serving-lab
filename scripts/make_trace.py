#!/usr/bin/env python3
"""make_trace.py - write a step-load trace for GuideLLM's `replay` profile.

Week 5 A4. One trace = one cycle of the step-load test, e.g.

    uv run python scripts/make_trace.py --stages 3:180,6:480,3:480 \
        --seed 1042 --prompt 1024 --output 256 --out <dir>

writes two files into <dir>:

  trace.csv    timestamp,input_length,output_length - one row per request.
               GuideLLM's `trace_synthetic` data kind builds a synthetic prompt
               of input_length tokens per row; the `replay` profile sends each
               row at start + timestamp. Open loop: nothing waits for replies.
  stages.json  the schedule on the SAME clock as trace.csv: each stage's start,
               end, rate and request count. The parser reads the step time
               from here.

Arrivals are Poisson: the gap to the next request is random (exponential) with
mean 1/rate, so the load is bursty the way real traffic is, not a metronome.
At a stage boundary drawing restarts at the boundary with the new rate - correct
for Poisson, which has no memory.

The clock: GuideLLM subtracts the FIRST timestamp from every row, so the first
request is always sent at 0. This script applies that shift itself and shifts
the stage boundaries by the same amount, so stage 0 starts slightly before 0
(by `shift_s`) and every later boundary is exactly where GuideLLM will put it.

Same --seed -> byte-identical files. Standard library only.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path


def parse_stages(text: str) -> list[tuple[float, float]]:
    """'3:180,6:480' -> [(3.0, 180.0), (6.0, 480.0)] as (rate req/s, seconds)."""
    stages = []
    for part in text.split(","):
        try:
            rate_s, dur_s = part.split(":")
            rate, dur = float(rate_s), float(dur_s)
        except ValueError:
            sys.exit(f"bad stage '{part}': want RATE:SECONDS, e.g. 3:180")
        if rate <= 0 or dur <= 0:
            sys.exit(f"bad stage '{part}': rate and seconds must be > 0")
        stages.append((rate, dur))
    return stages


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--stages", required=True, help="RATE:SECONDS,... e.g. 3:180,6:480,3:480")
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--prompt", type=int, required=True, help="input tokens per request")
    ap.add_argument("--output", type=int, required=True, help="output tokens per request")
    ap.add_argument("--out", required=True, help="directory to write trace.csv + stages.json")
    a = ap.parse_args()

    stages = parse_stages(a.stages)
    rng = random.Random(a.seed)          # own generator: nothing else can disturb it

    # 1. Draw arrival times on a clock where stage 0 starts at 0.
    arrivals: list[float] = []
    bounds: list[tuple[float, float]] = []
    t0 = 0.0
    for rate, dur in stages:
        end = t0 + dur
        t = t0
        while True:
            t += rng.expovariate(rate)   # exponential gap, mean 1/rate
            if t >= end:
                break
            arrivals.append(t)
        bounds.append((t0, end))
        t0 = end
    if not arrivals:
        sys.exit("no arrivals drawn - stages too short for their rates")

    # 2. Shift to GuideLLM's clock: first request at exactly 0.
    shift = round(arrivals[0], 3)
    rows = [round(t, 3) - shift for t in arrivals]

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with open(out / "trace.csv", "w", encoding="utf-8") as f:
        f.write("timestamp,input_length,output_length\n")
        for t in rows:
            f.write(f"{t:.3f},{a.prompt},{a.output}\n")

    # 3. Stage table on the same clock, with counts as a sanity check.
    table = []
    for (rate, dur), (start, end) in zip(stages, bounds):
        s, e = round(start - shift, 3), round(end - shift, 3)
        n = sum(1 for t in rows if s <= t < e)
        table.append({"rate_rps": rate, "duration_s": dur, "start_s": s, "end_s": e,
                      "requests": n, "achieved_rps": round(n / dur, 3)})
    meta = {"generator": "scripts/make_trace.py", "seed": a.seed, "stages_arg": a.stages,
            "prompt_tokens": a.prompt, "output_tokens": a.output, "shift_s": shift,
            "total_requests": len(rows), "last_arrival_s": rows[-1], "stages": table}
    (out / "stages.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

    for st in table:
        print(f"stage {st['rate_rps']:g} req/s  {st['start_s']:9.3f} -> {st['end_s']:9.3f} s"
              f"  {st['requests']:5d} req  ({st['achieved_rps']:.3f} req/s)")
    print(f"total {len(rows)} requests, shift {shift} s -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
