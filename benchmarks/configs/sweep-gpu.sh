# shellcheck shell=bash
# shellcheck disable=SC2034   # every variable here is read by scripts/benchmark.sh
#
# benchmarks/configs/sweep-gpu.sh -- SOURCED by scripts/benchmark.sh, not run.
# The MEASURED sweep (week 4, Phase B step 8-9). Every value below was settled
# in Phase A and is recorded in NOTES.md (A1 workload, A2 matrix, A5 lifecycle).
# Changing ANY of it after the sweep starts invalidates the comparison:
# "No configuration change between the start of step 8 and the end of step 9."

EXPECT_PLATFORM=gpu              # benchmark.sh refuses to run this config on kind
NAMESPACE=llm-serving

# Each leg's ISVC is rendered from this proven manifest: only metadata.name and
# storageUri change (B4 rule - every serving flag lives in the runtime).
BASE_MANIFEST=manifests/inferenceservice-llama-fp8.yaml

# <leg id>|<ISVC name = served model id>|<S3 prefix, as in variants.sh>|<size GiB>
# Order is the run order (A2). Sizes are the session-3 staged totals; they feed
# the disk preflight (the storage-initializer copies the leg into the pod).
LEGS=(
  "fp8|llama-fp8|llama-3.1-8b-fp8|8.47"
  "bf16|llama-bf16|llama-3.1-8b-bf16|14.97"
  "gptq|llama-gptq|llama-3.1-8b-w4a16-gptq|5.35"
  "awq|llama-awq|llama-3.1-8b-w4a16-awq|5.34"
)

# Anchor repeat (A2): this leg's point re-run LAST on a fresh pod.
ANCHOR_LEG=fp8
ANCHOR_SHAPE=primary
ANCHOR_C=16

# Disk preflight: refuse to start a leg unless free space on / is at least
# the leg's size + this margin (results, logs, GuideLLM per-request records).
DISK_MARGIN_GIB=3
READY_TIMEOUT_S=900              # BF16 copy + engine init; never timed for BF16

# Prompts are generated with ONE tokenizer for all four legs (same Llama 3.1
# tokenizer), so every leg receives byte-identical prompt text. The BF16 repo
# at its pinned revision, read from the VM's local HF cache with the network
# OFF: no gated download can happen mid-sweep. The disk fallback never
# deletes the BF16 staging copy, so the cache is always present.
TOKENIZER_REPO=meta-llama/Llama-3.1-8B-Instruct
TOKENIZER_REV=0e9e39f249a16976918f6564b8830bc894c89659
TOKENIZER_OFFLINE=1

# --- workload (A1) ----------------------------------------------------------
# Seed for a point = SEED_BASE + its index in the ladder, identical mapping on
# every leg: no point re-sends prompts an earlier point cached (prefix caching
# is ON), and every leg sees identical prompts at identical points.
PRIMARY_PROMPT=1024
PRIMARY_OUTPUT=256
PRIMARY_SEED_BASE=42
PRIMARY_LADDER=(1 2 4 8 16 32 64)          # PROVISIONAL until the pilot (step 7)

SHAPE2_PROMPT=3072                          # prefill-heavy (A2)
SHAPE2_OUTPUT=128
SHAPE2_SEED_BASE=142                        # own range: Faker's opening text is seed-only
SHAPE2_LADDER=(1 4 16 32)                   # stops at 32: BF16 fits ~48 at 3200 tokens

# Per-leg warmup: pays torch.compile / first-shape costs; files kept, never reported.
WARMUP_C=64
WARMUP_S=60
WARMUP_SEED=942

# --- timing (A2) ------------------------------------------------------------
# Measured seconds per point. Low rungs run longer so p95 rests on more than
# ~2 requests (c=1 ~80 requests, c=2 ~100). Shape 2's requests are short
# (~2 s at c=1), so 120 s gives ~60 even at c=1.
measured_s() {   # measured_s <shape> <concurrency>
  if [ "$1" = primary ] && [ "$2" -eq 1 ]; then echo 300
  elif [ "$1" = primary ] && [ "$2" -eq 2 ]; then echo 180
  else echo 120; fi
}
EDGE_START_S=20     # excluded: the closed-loop first wave prefills all at once
EDGE_END_S=10       # excluded: requests cut off by the time limit
GAUGE_INTERVAL_S=2  # vLLM gauges and nvidia-smi sampling period
