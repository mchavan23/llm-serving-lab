# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/benchmark.sh
#
# benchmarks/configs/sweep-kind.sh -- SOURCED by scripts/benchmark.sh, not run.
# The A7 DRY-RUN on kind against qwen-0-5b. Numbers are garbage; the gate is
# that the harness completes UNATTENDED, writes every file, the parser reads
# them, and no sidecar field is "ERROR:".
#
# Same structure as sweep-gpu.sh so the SAME code paths run. Differences, and
# why:
#  - two legs that both deploy qwen-0-5b: exercises delete -> preflight ->
#    apply -> Ready, resume and the anchor's fresh pod, with the one model
#    kind can serve;
#  - tiny ladders and short points: CPU decode is ~6-8 tok/s;
#  - shape 2 is 1536/16, not 3072/128: the CPU runtime's max-model-len is
#    2048, so a 3072-token prompt would be rejected;
#  - primary prompt stays 1024 so A7 can check the server-side prompt count
#    (A1 carry-forward); output cut to 32 to keep requests short;
#  - tokenizer unpinned and online (Qwen, ungated, not a measured model).

EXPECT_PLATFORM=kind
NAMESPACE=llm-serving
BASE_MANIFEST=manifests/inferenceservice-qwen.yaml

LEGS=(
  "qwen-a|qwen-0-5b|qwen-0.5b|0.93"
  "qwen-b|qwen-0-5b|qwen-0.5b|0.93"
)

ANCHOR_LEG=qwen-a
ANCHOR_SHAPE=primary
ANCHOR_C=2

DISK_MARGIN_GIB=3
READY_TIMEOUT_S=600              # 219 s measured on kind 2026-10-03

TOKENIZER_REPO=Qwen/Qwen2.5-0.5B-Instruct
TOKENIZER_REV=""                 # empty = unpinned; allowed on kind only
TOKENIZER_OFFLINE=0

PRIMARY_PROMPT=1024
PRIMARY_OUTPUT=32
PRIMARY_SEED_BASE=42
PRIMARY_LADDER=(1 2)

SHAPE2_PROMPT=1536
SHAPE2_OUTPUT=16
SHAPE2_SEED_BASE=142
SHAPE2_LADDER=(1 2)

WARMUP_C=2
# 120, not 20: A7 run 1 (a7-kind-1) showed the FIRST request on a fresh CPU
# pod takes ~64 s to first token (compile on the first unseen shape), so a
# 30 s warmup window ended with 0 successful requests.
WARMUP_S=120
WARMUP_SEED=942

# 90, not 40: shape 2's 1536-token prompts are a shape the warmup never saw;
# if that triggers a fresh compile, the request must be able to FINISH inside
# the window so the effect is visible in the data instead of failing the point.
measured_s() { echo 90; }
EDGE_START_S=5
EDGE_END_S=5
GAUGE_INTERVAL_S=2
