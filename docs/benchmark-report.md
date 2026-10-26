# Self-hosted LLM inference on one L40S: quantization, autoscaling and cost

*llm-serving-lab - benchmark report. Draft in progress (2026-10-26): sections
marked TODO are not written yet. Every number below is traceable to a committed
file; the source is named under each table.*

## 0. TL;DR

TODO - written last.

## 1. What was built

TODO.

## 2. Method

TODO.

## 3. Quantization x concurrency

**Question.** For one 8B model on one GPU, what does each weight format buy in
latency and throughput, and how does the answer change with load?

**Setup (details in section 2).** Llama-3.1-8B-Instruct in four formats on one
NVIDIA L40S 48 GB, vLLM 0.29.0, identical server settings for every format.
Closed-loop load from GuideLLM 0.7.4 on the same machine: *c* concurrent users,
each sending its next request when the previous one completes, 300 s per point.
Two request shapes: **primary** 1024 prompt / 256 output tokens, and
**long-prompt** 3072 / 128. Concurrency, not batch size, is the variable:
vLLM's continuous batching makes the batch an output of the scheduler.

| leg | checkpoint (Hugging Face) | weights | KV cache (tokens) |
|---|---|---|---|
| BF16 | `meta-llama/Llama-3.1-8B-Instruct` | 16-bit | 154,176 |
| FP8 | `RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8` | 8-bit float, W8A8 | 205,856 |
| INT4 GPTQ | `RedHatAI/Meta-Llama-3.1-8B-Instruct-quantized.w4a16` | 4-bit int, W4A16 | 232,464 |
| INT4 AWQ | `hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4` | 4-bit int, W4A16 | 232,768 |

Smaller weights leave more of the GPU for the KV cache: ~120 full requests'
worth at BF16, ~160 at FP8, ~181 at 4-bit.

### 3.1 Results - primary shape (1024 / 256)

| leg | c | TTFT p50 / p95 (ms) | ITL p50 (ms) | output tok/s |
|---|---|---|---|---|
| BF16 | 1 | 101 / 103 | 21.4 | 46 |
| FP8 | 1 | **73 / 74** | 14.2 | 69 |
| GPTQ | 1 | 87 / 90 | 8.2 | 118 |
| AWQ | 1 | 86 / 88 | **7.8** | **124** |
| BF16 | 8 | 290 / 352 | 25.0 | 307 |
| FP8 | 8 | **211 / 214** | 16.8 | 454 |
| GPTQ | 8 | 255 / 333 | 11.1 | 665 |
| AWQ | 8 | 257 / 489 | **10.7** | **686** |
| BF16 | 64 | 553 / 736 | 54.9 | 1,121 |
| FP8 | 64 | **432 / 577** | **42.5** | **1,445** |
| GPTQ | 64 | 572 / 761 | 43.0 | 1,412 |
| AWQ | 64 | 569 / 758 | 42.7 | 1,422 |

Output tokens/s across the whole ladder (c = 1, 2, 4, 8, 16, 32, 64):

| leg | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| BF16 | 46 | 87 | 166 | 307 | 531 | 812 | 1,121 |
| FP8 | 69 | 134 | 252 | 454 | 752 | 1,104 | 1,445 |
| GPTQ | 118 | 222 | 398 | 665 | 974 | 1,244 | 1,412 |
| AWQ | 124 | 232 | 415 | 686 | 996 | 1,264 | 1,422 |

*Source: `benchmarks/results/sweep-gpu-1/results.csv` (session 4, 2026-10-03).
TTFT = time to first token, ITL = inter-token latency, both client-side;
percentiles by nearest rank.*

### 3.2 Results - long-prompt shape (3072 / 128)

| leg | c | TTFT p50 / p95 (ms) | ITL p50 (ms) | output tok/s |
|---|---|---|---|---|
| BF16 | 1 | 277 / 280 | 21.8 | 42 |
| FP8 | 1 | **212 / 216** | 14.6 | 62 |
| GPTQ | 1 | 266 / 271 | 8.5 | 95 |
| AWQ | 1 | 266 / 269 | **8.1** | **99** |
| BF16 | 32 | 792 / 987 | 96.0 | 314 |
| FP8 | 32 | **623 / 776** | **76.0** | **396** |
| GPTQ | 32 | 817 / 1,018 | 88.7 | 337 |
| AWQ | 32 | 815 / 1,015 | 88.3 | 339 |

*Source: as above, shape2 rows (c = 1, 4, 16, 32).*

### 3.3 What the numbers say

1. **At low load, 4-bit decodes fastest.** At c = 1, AWQ generates a token every
   7.8 ms against FP8's 14.2 ms: 1.8x the per-user speed. A single stream is
   limited by reading the weights from GPU memory for every token, and 4-bit
   weights are the smallest. The advantage shrinks as load rises: at c = 8,
   4-bit still leads FP8 by ~50% in throughput; at c = 64 the gap is gone.
2. **FP8 has the lowest time to first token at every load, on both shapes**
   (c = 1: 73 ms vs 86-87 ms for 4-bit; long prompts: 212 vs 266 ms). The first
   token is dominated by prefill - processing the whole prompt at once - which
   is compute-bound. The L40S runs FP8 matrix maths natively; W4A16 formats keep
   16-bit activations and unpack their 4-bit weights on the fly.
3. **At high load FP8 also wins throughput - slightly on the primary shape, clearly
   on long prompts.** c = 64 primary: 1,445 vs 1,412-1,422 tok/s (+2%). Long
   prompts, c = 32: 396 vs 337-339 tok/s (+17%), with lower ITL too. The more
   prefill in the mix, the more FP8's compute advantage shows.
4. **GPTQ and AWQ are equal within measurement error.** They differ by 1-4%
   everywhere. Both run on the same Marlin W4A16 kernels in vLLM, and the GPU
   warmed slightly over the 2.5-hour sweep (c = 1 clock 2,510 MHz in the first
   leg, 2,474 MHz in the last, ~1.5%) - the same size as the gap, and AWQ ran
   last. Neither is claimed faster.
5. **BF16 is slowest everywhere and was not saturated at c = 64** (+38% from
   c = 32 to 64, still climbing). Its column is "throughput at c = 64", not its
   maximum - so the quantized formats' advantage over BF16 at full load
   (26-29% more throughput, i.e. 20-22% lower cost per token) is an upper bound.

**In one line:** for an interactive service with few concurrent users, 4-bit
gives the best per-user speed and the most KV-cache room; for a busy service,
or one with long prompts, FP8 gives the best time to first token and the most
throughput.

### 3.4 Caveats

- **Speed only, not quality.** The two 4-bit checkpoints come from different
  publishers with different calibration; output quality was not measured here
  (eval gates are the subject of P3). "4-bit" alone is ambiguous - every 4-bit
  number carries its algorithm label.
- **One card, one model size, one software version.** The crossover points are
  for L40S + vLLM 0.29.0 + an 8B model; a GPU with more memory bandwidth, or a
  larger model, moves them.
- **Run-to-run stability was checked, not assumed.** An anchor point (FP8,
  c = 16) re-run on a fresh pod 2 h 13 min later matched within 0.6% on every
  metric.
- **One unexplained point.** Long-prompt 4-bit TTFT p50 at c = 4 (714 ms) is
  higher than at c = 16 (589 ms). Most likely closed-loop lockstep: same-length
  requests finish together, return together, and their prefills queue. Not
  investigated further; it does not change any finding.

## 4. Cost per million tokens

TODO - the central claim; needs dated, cited hosted-API prices.

## 5. Autoscaling

TODO.

## 6. Cold start

TODO.

## 7. Knative: canary, data-path overhead, wake from zero

TODO - kind mechanics done; GPU numbers after session 6 (or "not measured, and why").

## 8. Platform lessons

TODO.

## 9. Limits and next steps

TODO.

## Appendix - reproduce, raw data, cost ledger

TODO.
