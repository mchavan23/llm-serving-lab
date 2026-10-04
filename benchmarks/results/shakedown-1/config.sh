# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/benchmark.sh
#
# benchmarks/configs/shakedown-gpu.sh -- SOURCED by scripts/benchmark.sh.
# Week 4 Phase B step 5: the dress rehearsal. One leg, one point per shape,
# plus the anchor (benchmark.sh always runs it; it also proves the anchor
# path on the GPU, which has only run on kind).
#
# It SOURCES the measured sweep's config and overrides only what must differ,
# so everything else (tokenizer pin, shapes, seeds, edges, warmup, timeouts,
# disk margin) is literally the sweep's - the rehearsal proves the real
# configuration, not a lookalike.
#
# What the shakedown must show (context doc, Phase B step 5):
#   - files written and parse_results.py exits 0 on real hardware
#   - nvidia-smi sidecar fields hold real values (first run on a GPU)
#   - batch_mean at c=1 ~= 1 (kind read 0.5: CPU gauge lag)
#   - the first shape-2 request's TTFT is in line with the rest

# shellcheck source=benchmarks/configs/sweep-gpu.sh
. benchmarks/configs/sweep-gpu.sh

LEGS=("fp8|llama-fp8|llama-3.1-8b-fp8|8.47")   # the sweep's FP8 line, unchanged
PRIMARY_LADDER=(1)
SHAPE2_LADDER=(1)
ANCHOR_C=1                                      # the anchor must be a ladder point

measured_s() { echo 60; }                       # sweep: 300 s at c=1; 60 s is enough to check files
