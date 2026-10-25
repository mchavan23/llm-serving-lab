# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/pilot.sh
#
# benchmarks/configs/pilot-kind-a6.sh -- SOURCED by scripts/pilot.sh.
# Week 5 A6 step 3: capacity of ONE shrunk qwen replica on kind
# (manifests/inferenceservice-qwen-keda.yaml: cpu limit 4, KV cache 1 GiB).
# Gives the kind dry run its own baseline, step and threshold - the same way
# A3 derived 24/replica from pilot-gpu-1. Kind numbers are NOT results.
# 256/64: more decode time per request than the 256/16 test config, so more
# requests are in flight - the quantity the scaling metric counts. step-kind.sh
# uses the same shape.

EXPECT_PLATFORM=kind
NAMESPACE=llm-serving
ISVC=qwen-0-5b

TOKENIZER_REPO=Qwen/Qwen2.5-0.5B-Instruct
TOKENIZER_REV=""                 # unpinned; allowed on kind only
TOKENIZER_OFFLINE=0
PROMPT=256
OUTPUT=64

SEED_BASE=642                    # own range
RATES=(0.2 0.35 0.5 0.75 1 1.5 2)
RATE_S=90
EDGE_START_S=10
GAUGE_INTERVAL_S=1
DRAIN_TIMEOUT_S=300

SAT_ACHIEVED_FRAC=0.9
STOP_AFTER_SATURATED=2

LAG_P95_LIMIT_MS=100
ARRIVALS_TOLERANCE=2
