# benchmarks/configs/step-gpu-collapse.sh - Week 5 step-load test, OPTIONAL cycle.
# Sourced by scripts/step-load.sh. Decision (Manoj, 2026-10-25, 03aff2f):
# optional third cycle 3 -> 8 req/s, run LAST, first cut if session 5 runs long.
# 8 req/s collapses one replica (pilot: KV full, completions 4.5 req/s).
EXPECT_PLATFORM=gpu
NAMESPACE=llm-serving
ISVC=llama-fp8                     # week 4 FP8 leg, deployed with KEDA autoscaling (A6)
MODEL=llama-fp8                    # served model id = ISVC name (--served-model-name={{.Name}})
# One cycle = RATE:SECONDS stages. Baseline 3 req/s (well below the trigger and
# below the ~4.5-5 req/s oscillation band); step to 8 (one replica collapses);
# back to 3 for 480 s (scale-down needs ~6 min: 300 s window + 45 s + 15 s).
CYCLES=("3:180,8:480,3:480")
STEP_STAGE=1                       # index of the high stage; its end = step-down
SEED_BASE=1142                     # own range, apart from the main cycles
PROMPT=1024
OUTPUT=256
TOKENIZER_REPO=meta-llama/Llama-3.1-8B-Instruct
TOKENIZER_REV=0e9e39f249a16976918f6564b8830bc894c89659
TOKENIZER_OFFLINE=1
REQUIRE_KEDA=1
# Used only if no ScaledObject is found; normally the harness records the
# ScaledObject's own query. Constant: benchmarks/scaling-constants.md.
KEDA_QUERY='sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="llama-fp8"}[45s]))'
PRECONDITION_TIMEOUT_S=600         # wait for the previous cycle's scale-down
POLL_INTERVAL_S=1                  # cluster timeline
GPU_SAMPLE_MS=1000                 # per-GPU sampler
PROM_STEP_S=5                      # = scrape interval; finer adds nothing
DRAIN_MAX_S=600                    # after the last arrival, before the hard stop
SNAPSHOT_DELAY_S=30                # after the step-down; covers GuideLLM startup
