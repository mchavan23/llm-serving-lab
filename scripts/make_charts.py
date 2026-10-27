#!/usr/bin/env python3
"""make_charts.py - the report's three figures, from committed data only.

  uv run --group report python scripts/make_charts.py

Writes docs/img/{fig-formats,fig-cost,fig-relief}.svg. SVG is text (diffable)
and made byte-stable (fixed hash salt, no date), so re-running on the same
data changes nothing. matplotlib is in the `report` dependency group only - the
GPU VM's environment (default groups) does not include it.
"""
import csv, json
from pathlib import Path
import matplotlib
matplotlib.use("svg")
import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "img"
OUT.mkdir(parents=True, exist_ok=True)
plt.rcParams.update({"svg.hashsalt": "llm-serving-lab", "font.size": 10,
                     "axes.spines.top": False, "axes.spines.right": False})
LEGS = [("bf16", "BF16"), ("fp8", "FP8"), ("gptq", "INT4 GPTQ"), ("awq", "INT4 AWQ")]
def save(fig, name):
    fig.tight_layout()
    fig.savefig(OUT / name, metadata={"Date": None})
    plt.close(fig)
    print("wrote", OUT / name)

# ---- figure 1: formats x concurrency (section 3), primary shape 1024/256
rows = [r for r in csv.DictReader(open(ROOT / "benchmarks/results/sweep-gpu-1/results.csv"))
        if r["shape"] == "primary" and r["is_anchor"] in ("0", "False", "false", "")]
fig, (a1, a2) = plt.subplots(1, 2, figsize=(10, 3.8))
for leg, label in LEGS:
    pts = sorted((int(r["concurrency"]), float(r["output_tok_per_s"]), float(r["itl_p50_ms"]))
                 for r in rows if r["leg"] == leg)
    c = [p[0] for p in pts]
    a1.plot(c, [p[1] for p in pts], marker="o", label=label)
    a2.plot(c, [p[2] for p in pts], marker="o", label=label)
for ax, title, yl in ((a1, "Throughput", "output tokens / s"), (a2, "Per-user decode speed", "ITL p50 (ms) - lower is faster")):
    ax.set_xscale("log", base=2); ax.set_xticks([1, 2, 4, 8, 16, 32, 64]); ax.set_xticklabels([1, 2, 4, 8, 16, 32, 64])
    ax.set_xlabel("concurrent users (closed loop)"); ax.set_ylabel(yl); ax.set_title(title); ax.grid(alpha=0.3)
a1.legend(frameon=False)
fig.suptitle("Llama-3.1-8B on 1x L40S, 1024 in / 256 out (sweep-gpu-1)", fontsize=10)
save(fig, "fig-formats.svg")

# ---- figure 2: cost per 1M output tokens vs utilisation (section 4)
RATE = 1.494                     # EUR/h all-in, benchmarks/cost-model.md
FP8_TPS = next(float(r["output_tok_per_s"]) for r in rows if r["leg"] == "fp8" and r["concurrency"] == "64")
EURUSD = 1.1539                  # ECB 15 Sep 2026
HOSTED = [("DeepInfra, same model ($0.02/$0.04)", 4 * 0.02 + 0.04),
          ("DeepInfra, 9B-class ($0.10/$0.15)", 4 * 0.10 + 0.15),
          ("Together, 9B-class ($0.17/$0.25)", 4 * 0.17 + 0.25)]   # USD per 1M out + 4M in, provider pages 2026-10-27
full = RATE / (FP8_TPS * 3600) * 1e6
u = [x / 100 for x in range(5, 101)]
fig, ax = plt.subplots(figsize=(7, 4))
ax.plot([x * 100 for x in u], [full / x for x in u], lw=2, label=f"self-hosted FP8 (EUR {full:.3f} at 100%)")
for label, usd in HOSTED:
    eur = usd / EURUSD
    ax.axhline(eur, ls="--", lw=1)
    ax.text(6, eur * 1.06, f"{label}: EUR {eur:.3f}", fontsize=8)
ax.set_yscale("log"); ax.set_xlim(5, 100)
ax.set_xlabel("GPU utilisation (% of paid hours serving at c = 64)")
ax.set_ylabel("EUR per 1M output tokens (+4M input)")
ax.set_title("Self-hosted vs per-token API - prices as of 2026-10-27")
ax.grid(alpha=0.3, which="both"); ax.legend(frameon=False, loc="upper right")
save(fig, "fig-cost.svg")

# ---- figure 3: time to relief, stacked (section 5)
RUNS = [("run 1", "20261026T0401Z-step-gpu"), ("repeat", "20261026T0513Z-step-gpu-repeat")]
SEG = [("detect (45 s window)", None, "metric_crosses_s"), ("HPA decision", "metric_crosses_s", "hpa_rescale_event_s"),
       ("model copy", "pod_scheduled_s", "model_copy_done_s"), ("container start", "model_copy_done_s", "engine_started_s"),
       ("vLLM start-up", "engine_started_s", "pod_ready_s"), ("endpoint", "pod_ready_s", "first_request_on_replica2_s"),
       ("backlog drains", "first_request_on_replica2_s", "relief_s")]
fig, ax = plt.subplots(figsize=(9, 2.6))
for i, (label, run) in enumerate(RUNS):
    so = json.load(open(ROOT / "benchmarks/results" / run / "cycle-01/step-summary.json"))["scale_out"]
    left = 0.0
    for j, (name, a, b) in enumerate(SEG):
        w = so[b] - (so[a] if a else 0.0)
        if a == "metric_crosses_s":          # decision -> scheduled is 0 s in both runs (GPU free)
            w = so["pod_scheduled_s"] - so[a]
        ax.barh(i, w, left=left, color=f"C{j}", label=name if i == 0 else None)
        left += w
    ax.text(left + 3, i, f"{so['relief_s']:.0f} s", va="center")
ax.set_yticks(range(len(RUNS))); ax.set_yticklabels([r[0] for r in RUNS]); ax.invert_yaxis()
ax.set_xlabel("seconds after the 3 -> 6 req/s step"); ax.set_xlim(0, 300)
ax.legend(ncol=4, fontsize=8, frameon=False, loc="upper center", bbox_to_anchor=(0.5, -0.35))
ax.set_title("Time to relief, segment by segment (FP8, KEDA 1 -> 2 replicas)")
save(fig, "fig-relief.svg")
