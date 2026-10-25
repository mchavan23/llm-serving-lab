# benchmarks/configs/step-gpu-shakedown.sh - Week 5 Phase B step 6: one SHORT
# step cycle on the GPU before the paid unattended runs (step-gpu.sh).
# Sourced by scripts/step-load.sh. Same as step-gpu.sh except the cycle and seed.
#
# What it must show, cheaply (~8 min, ~EUR 0.40 at EUR 2.94/h):
#   - KEDA decides 1 -> 2 on the GPU, replica 2 schedules on GPU 2, takes traffic;
#   - the running total at 3 req/s (A4 interpolated ~14; the main cycles'
#     scale-down depends on it staying under 24);
#   - the harness and parser read real two-GPU records.
# Cycle and why:
#   - 3 req/s 120 s: shorter than the main 180 s, still enough for a baseline
#     (the parser drops the first 30 s as warm-up).
#   - 6 req/s 300 s: relief is expected ~2.2-2.5 min after the step
#     (scaling-constants.md), so 300 s is the shortest step that still shows
#     replica 2 Ready and serving.
#   - 3 req/s 60 s: a short tail so the step-down and the snapshot taken 30 s
#     after it fall inside the run. Scale-down is NOT awaited here: the main
#     run's first cycle waits up to 600 s for one replica and records it.
EXPECT_PLATFORM=gpu
NAMESPACE=llm-serving
ISVC=llama-fp8                     # FP8 leg with KEDA (manifests/inferenceservice-llama-fp8-keda.yaml)
MODEL=llama-3.1-8b-fp8             # served model name
CYCLES=("3:120,6:300,3:60")
STEP_STAGE=1                       # index of the high stage; its end = step-down
SEED_BASE=1242                     # own range, apart from main (1042) and collapse (1142)
PROMPT=1024
OUTPUT=256
TOKENIZER_REPO=meta-llama/Llama-3.1-8B-Instruct
TOKENIZER_REV=0e9e39f249a16976918f6564b8830bc894c89659
TOKENIZER_OFFLINE=1
REQUIRE_KEDA=1
KEDA_QUERY='sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="llama-fp8"}[45s]))'
PRECONDITION_TIMEOUT_S=600         # exactly one replica Ready before the cycle
POLL_INTERVAL_S=1                  # cluster timeline
GPU_SAMPLE_MS=1000                 # per-GPU sampler
PROM_STEP_S=5                      # = scrape interval; finer adds nothing
DRAIN_MAX_S=600                    # after the last arrival, before the hard stop
SNAPSHOT_DELAY_S=30                # after the step-down; covers GuideLLM startup
