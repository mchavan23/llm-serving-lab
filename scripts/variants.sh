# shellcheck shell=bash
# scripts/variants.sh -- SOURCED, not run. The four benchmark legs, in ONE
# place, so stage-models.sh (which uploads them) and verify-gpu.sh (which
# checks them) cannot drift apart.
#
#   <Hugging Face repo>|<revision SHA>|<prefix in the S3 bucket>
#
# Phase A verified all four against the HF API 2026-09-16/19. Changing this
# list changes the experiment: record it in the context doc's decision log.
#
# Revisions are PINNED to the snapshots staged and uploaded in GPU session 3
# (docs/evidence/session-3/stage-models.out) - i.e. the bytes now in S3.
# Unpinned, `hf download` fetches whatever `main` is on the day. The SHA sits
# in the MIDDLE so readers that take the first (repo) or last (prefix) field
# keep working.
# shellcheck disable=SC2034   # used by the scripts that source this file
VARIANTS=(
  "meta-llama/Llama-3.1-8B-Instruct|0e9e39f249a16976918f6564b8830bc894c89659|llama-3.1-8b-bf16"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8|870a1177ed082c0ba5dbefd62573ab8f91803f6a|llama-3.1-8b-fp8"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-quantized.w4a16|6a426ef8adc0b4b96408001a9628d71f01c9ceca|llama-3.1-8b-w4a16-gptq"
  "hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4|db1f81ad4b8c7e39777509fac66c652eb0a52f91|llama-3.1-8b-w4a16-awq"
)
