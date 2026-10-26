# benchmarks/configs/step-kind.sh - Week 5 step-load test, A6/A7 DRY RUN on kind.
# Week 6 A3 copy of step-kind.sh: one 10-min cycle to validate the TTFT
# histogram export (per pod, server vs client). Not a measurement.
# Sourced by scripts/step-load.sh. Kind numbers are NOT results: this run proves
# the mechanism (KEDA 1 -> 2 -> 1, the harness records it, the parser computes
# time-to-relief) before any GPU time is spent.
# Same STRUCTURE as step-gpu.sh: step = 2 x baseline, so on two replicas each
# carries the baseline load and TTFT can genuinely return to baseline.
# From a6-capacity-3 / -4 (3 cores per replica; one tops out ~0.3 req/s, two
# ~0.7-0.8): baseline 0.2 req/s (~0.8 running, under threshold 1.25 x 1.1),
# step 0.4 (~133% of one replica), back to 0.2. a6-step-kind-1 used 0.25/0.6
# with threshold 3 from one-replica numbers only: no relief, no scale-down.
# High stage 600 s, not 480: on kind replica 2 needs ~2.5-3 min to Ready plus a
# ~60-75 s first-request compile, and relief must then hold 60 s.
EXPECT_PLATFORM=kind
NAMESPACE=llm-serving
ISVC=qwen-0-5b
MODEL=qwen-0-5b
CYCLES=("0.2:120,0.4:300,0.2:180")   # week 6 A3: one SHORT cycle - validates the per-pod TTFT export end to end
STEP_STAGE=1
SEED_BASE=9162                     # own range (week 6 A3)
PROMPT=256
OUTPUT=64
TOKENIZER_REPO=Qwen/Qwen2.5-0.5B-Instruct
TOKENIZER_REV=""                   # unpinned; allowed on kind only
TOKENIZER_OFFLINE=0
REQUIRE_KEDA=1
# Fallback only; the harness records the ScaledObject's own query and threshold.
KEDA_QUERY='sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="qwen-0-5b"}[45s]))'
PRECONDITION_TIMEOUT_S=600
POLL_INTERVAL_S=1
GPU_SAMPLE_MS=1000
PROM_STEP_S=5
DRAIN_MAX_S=600
SNAPSHOT_DELAY_S=30
