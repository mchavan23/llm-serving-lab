# shellcheck shell=bash
# scripts/variants.sh -- SOURCED, not run. The four benchmark legs, in ONE
# place, so stage-models.sh (which uploads them) and verify-gpu.sh (which
# checks them) cannot drift apart.
#
#   <Hugging Face repo>|<prefix in the S3 bucket>
#
# Phase A verified all four against the HF API 2026-09-16/19. Changing this
# list changes the experiment: record it in the context doc's decision log.
# shellcheck disable=SC2034   # used by the scripts that source this file
VARIANTS=(
  "meta-llama/Llama-3.1-8B-Instruct|llama-3.1-8b-bf16"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8|llama-3.1-8b-fp8"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-quantized.w4a16|llama-3.1-8b-w4a16-gptq"
  "hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4|llama-3.1-8b-w4a16-awq"
)
