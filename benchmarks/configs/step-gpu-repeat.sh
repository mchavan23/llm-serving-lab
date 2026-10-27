# benchmarks/configs/step-gpu-repeat.sh - ONE more 3 -> 6 cycle, run on the
# restart-1 boot (owner, 2026-10-26). Identical to step-gpu.sh except CYCLES
# (one cycle) and the run it belongs to.
# Why seed 1042 (= step-gpu.sh cycle 1): main cycle 2 (seed 1043) scaled out
# during its 3 req/s baseline (trace ran at 3.30 req/s, total peaked 27.2 >
# 26.4), so it is not a step response. Seed 1042's baseline peaked at 19.4, so
# this cycle is a clean second measurement AND a repeat of the same trace -
# the difference to cycle 1 is run-to-run (and possibly host-to-host) variation.
EXPECT_PLATFORM=gpu
NAMESPACE=llm-serving
ISVC=llama-fp8                     # week 4 FP8 leg, deployed with KEDA autoscaling (A6)
MODEL=llama-fp8                    # served model id = ISVC name (--served-model-name={{.Name}})
CYCLES=("3:180,6:480,3:480")
STEP_STAGE=1                       # index of the high stage; its end = step-down
SEED_BASE=1042                     # cycle n uses SEED_BASE + n - 1; own range
PROMPT=1024
OUTPUT=256
TOKENIZER_REPO=meta-llama/Llama-3.1-8B-Instruct
TOKENIZER_REV=0e9e39f249a16976918f6564b8830bc894c89659
TOKENIZER_OFFLINE=1
REQUIRE_KEDA=1
KEDA_QUERY='sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="llama-fp8"}[45s]))'
PRECONDITION_TIMEOUT_S=600         # wait for the previous cycle's scale-down
POLL_INTERVAL_S=1                  # cluster timeline
GPU_SAMPLE_MS=1000                 # per-GPU sampler
PROM_STEP_S=5                      # = scrape interval; finer adds nothing
DRAIN_MAX_S=600                    # after the last arrival, before the hard stop
SNAPSHOT_DELAY_S=30                # after the step-down; covers GuideLLM startup
