# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/pilot.sh
#
# benchmarks/configs/pilot-kind.sh -- SOURCED by scripts/pilot.sh.
# Test of the pilot script on kind against qwen-0-5b (CPU). Numbers are
# garbage; the test is: the queue builds at the top rates, drain reaches 0,
# early stop fires, every file is written and the summary is filled.

EXPECT_PLATFORM=kind
NAMESPACE=llm-serving
ISVC=qwen-0-5b

TOKENIZER_REPO=Qwen/Qwen2.5-0.5B-Instruct
TOKENIZER_REV=""                 # unpinned; allowed on kind only
TOKENIZER_OFFLINE=0
PROMPT=256                       # small: CPU prefill is slow
OUTPUT=16

SEED_BASE=542
RATES=(0.2 0.5 1 2 4)            # CPU should saturate somewhere in here
RATE_S=40
EDGE_START_S=10
GAUGE_INTERVAL_S=1
DRAIN_TIMEOUT_S=180

SAT_ACHIEVED_FRAC=0.9
STOP_AFTER_SATURATED=2

# Layer 2: a rate whose send lag p95 exceeds this is CLIENT-LIMITED and not
# used for the knee (laptop test: p95 <= 23 ms up to 32 req/s).
LAG_P95_LIMIT_MS=100
# Layer 3: client's sent count vs the server's access-log count, whole run.
ARRIVALS_TOLERANCE=2
