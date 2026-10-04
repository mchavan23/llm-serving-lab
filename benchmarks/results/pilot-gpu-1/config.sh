# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/pilot.sh
#
# benchmarks/configs/pilot-gpu.sh -- SOURCED by scripts/pilot.sh.
# Week 4 Phase B step 6: open-loop pilot on FP8. Not a published result.

EXPECT_PLATFORM=gpu
NAMESPACE=llm-serving
ISVC=llama-fp8                   # must already be Ready (after the shakedown)

# Same tokenizer and workload as the measured sweep, so the knee found here
# applies to the closed-loop ladder.
TOKENIZER_REPO=meta-llama/Llama-3.1-8B-Instruct
TOKENIZER_REV=0e9e39f249a16976918f6564b8830bc894c89659
TOKENIZER_OFFLINE=1
PROMPT=1024
OUTPUT=256

# Own seed range: 542.. never overlaps 42-48 / 142-145 / 942.
SEED_BASE=542

# Offered rates, req/s. ESTIMATE: ~3.6 s per request alone (session 1); with
# batching, saturation guessed at 5-12 req/s. The list brackets that widely.
RATES=(1 2 4 6 8 10 12 16)
RATE_S=90                        # measured seconds per rate
EDGE_START_S=15                  # excluded: the engine ramps from empty
GAUGE_INTERVAL_S=1               # finer than the sweep's 2 s: the signal's shape is the point
DRAIN_TIMEOUT_S=300              # a saturated queue at 16 req/s can be long

# Saturated = completions < SAT_ACHIEVED_FRAC x delivered (throughput only;
# the gauges are what the pilot tests). Stop after this many in a row.
SAT_ACHIEVED_FRAC=0.9
STOP_AFTER_SATURATED=2

# Layer 2: a rate whose send lag p95 exceeds this is CLIENT-LIMITED and not
# used for the knee (laptop test: p95 <= 23 ms up to 32 req/s).
LAG_P95_LIMIT_MS=100
# Layer 3: client's sent count vs the server's access-log count, whole run.
ARRIVALS_TOLERANCE=2
