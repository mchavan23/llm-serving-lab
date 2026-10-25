# benchmarks/configs/step-kind.sh - Week 5 step-load test, A6/A7 DRY RUN on kind.
# Sourced by scripts/step-load.sh. Kind numbers are NOT results: this run proves
# the mechanism (KEDA 1 -> 2 -> 1, the harness records it, the parser computes
# time-to-relief) before any GPU time is spent.
# Same proportions as step-gpu.sh, from a6-capacity-2 (one shrunk qwen replica
# healthy to ~0.5 req/s, saturated by 0.75; manifests/inferenceservice-qwen-keda.yaml):
#   baseline 0.25 req/s (~50% of one replica; ~1.3 running, under the 3.3
#   scale-up level of threshold 3), step 0.6 (~110-120%), back to 0.25.
# High stage 600 s, not 480: on kind replica 2 needs ~2.5 min to Ready plus a
# ~75 s first-request compile, and relief must then hold 60 s.
EXPECT_PLATFORM=kind
NAMESPACE=llm-serving
ISVC=qwen-0-5b
MODEL=qwen-0-5b
CYCLES=("0.25:180,0.6:600,0.25:480")
STEP_STAGE=1
SEED_BASE=9142                     # own range (kind)
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
