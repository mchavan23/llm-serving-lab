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

**Answer first.** For an interactive service with few concurrent users, 4-bit
gives the best per-user speed and the most KV-cache room; for a busy service, or
one with long prompts, FP8 gives the best time to first token and the most
throughput.

**Question.** For one 8B model on one GPU, what does each weight format buy in
latency and throughput, and how does the answer change with load?

**Terms used in this report.**
- **Prefill** - the model reads the whole prompt in one pass. Heavy on compute.
  It ends with the first output token.
- **Decode** - the model then generates one token at a time. Each step re-reads
  all the weights from GPU memory, so it is limited by memory bandwidth.
- **TTFT** (time to first token) - how long a user waits before the answer
  starts: queueing + prefill. **ITL** (inter-token latency) - the gap between
  output tokens after that: the decode speed one user sees.
- **KV cache** - per-request working memory on the GPU (the attention keys and
  values of every token so far). Whatever the weights leave free becomes KV
  cache; more cache = more requests served at once.
- **Closed-loop load** - *c* simulated users, each sending its next request only
  when the previous one completes. *c* is the number of requests in flight.

**Setup (details in section 2).** Llama-3.1-8B-Instruct in four formats on one
NVIDIA L40S 48 GB, vLLM 0.29.0, identical server settings for every format.
Closed-loop load from GuideLLM 0.7.4 on the same machine, 300 s per point.
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
| BF16 | 64 | 553 / 736 | 54.9 | 1,121 |
| FP8 | 64 | **432 / 577** | **42.5** | **1,445** |
| GPTQ | 64 | 572 / 761 | 43.0 | 1,412 |
| AWQ | 64 | 569 / 758 | 42.7 | 1,422 |

c = 8 rows: appendix A.1. Output tokens/s across the whole ladder (c = 1, 2, 4, 8, 16, 32, 64):

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

**Answer first.** On price alone, renting one on-demand L40S to serve this model
loses to the cheapest per-token API - even with the GPU busy 100% of the time.
Against more typical API prices for a model of this size, self-hosting breaks
even only above roughly 35-60% sustained utilisation. Self-hosting a small model
is justified by things other than price: control of the model version, data
residency, latency guarantees, custom weights - or very high sustained load on
cheaper GPU capacity.

**Method.** Self-hosted cost = what the instance costs per hour while running ÷
the tokens it produces per hour. The hour rate is **EUR 1.494** all-in: compute
EUR 1.46988 + 150 GB volume EUR 0.0195 + IPv4 EUR 0.005 (Scaleway L40S-1-48G,
rates reconciled against the billing API, `benchmarks/cost-model.md`).
Throughput is section 3's c = 64, primary shape. **Utilisation** = the share of
paid hours the GPU spends serving at that load; an idle paid hour produces
nothing, so cost per token scales with 1 / utilisation.
The denominator is **1 million output tokens**. In the primary shape (1024 in /
256 out) each output token arrives with 4 input tokens, so a hosted API is
charged for **4M input + 1M output**: cost = 4 x input price + output price.

### 4.1 Self-hosted (measured)

EUR per 1M output tokens (with their 4M input tokens), by utilisation:

| leg | tok/s at c = 64 | 100% | 50% | 25% | 10% |
|---|---|---|---|---|---|
| BF16 (upper bound) | 1,121 | 0.370 | 0.740 | 1.48 | 3.70 |
| FP8 | 1,445 | **0.287** | 0.575 | 1.15 | 2.87 |
| INT4 GPTQ | 1,412 | 0.294 | 0.588 | 1.18 | 2.94 |
| INT4 AWQ | 1,422 | 0.292 | 0.584 | 1.17 | 2.92 |

*Valid at c = 64 latency: TTFT p95 0.58-0.76 s, ITL 42-55 ms (~18-24 tokens/s
per user). Source: `benchmarks/results/sweep-gpu-1/results.csv`, cost model.*

### 4.2 Hosted APIs (provider pages, fetched 2026-10-27)

| offer | price per 1M tokens (in / out) | EUR per 1M output (+4M input) |
|---|---|---|
| DeepInfra `Meta-Llama-3.1-8B-Instruct-Turbo` - **same model** (FP8) | $0.02 / $0.04 | **0.104** |
| DeepInfra `Qwen3.5-9B` - *different model, 9B-class market indicator* | $0.10 / $0.15 | 0.477 |
| Together `Qwen/Qwen3.5-9B` - *different model, 9B-class market indicator* | $0.17 / $0.25 | 0.806 |

*Sources: deepinfra.com/pricing; docs.together.ai/docs/serverless/models.md.
USD -> EUR at the ECB reference rate of 15 Sep 2026, 1.1539 (the latest found;
the 2026 range 1.13-1.18 moves any figure here by under 4%).*

Two market facts from the same check:
- **Llama 3.1 8B is being retired from per-token APIs.** Scaleway's Generative
  APIs and Together's serverless catalog no longer list it (older copies of
  Scaleway's page showed EUR 0.20 per 1M tokens; aggregator sites still quote
  $0.18 for Together). Only DeepInfra's offer was confirmed live on the
  provider's own page. Aggregator prices were out of date or mixed up model
  variants, so none are used here.
- **Managed dedicated serving costs more than doing it yourself.** Scaleway's
  managed deployment on the same L40S-1-48G lists **EUR 1.72/h**, 15% above this
  project's EUR 1.494 all-in - before the operational work, which is the point of
  paying for it.

### 4.3 Break-even

| self-hosted FP8 vs | break-even utilisation |
|---|---|
| DeepInfra, same model (EUR 0.104) | **never** - would need 276% |
| DeepInfra, 9B-class (EUR 0.477) | **60%** |
| Together, 9B-class (EUR 0.806) | **36%** |

*Break-even = self-hosted cost at 100% ÷ hosted cost.*

### 4.4 What the numbers say

1. **Utilisation moves cost ten times more than quantisation does.** Going from
   100% to 10% busy multiplies cost by 10; the best format beats BF16 by ~22%.
   The operational lever - keeping the GPU busy, or scaling it to zero when it
   is not (sections 5-7) - matters more than the format choice.
2. **A provider at scale wins on price for a popular small model.** They batch
   many customers' traffic onto large GPUs and keep them busy; one rented GPU
   for one workload cannot match that.
3. **Self-hosting has other reasons.** Pinning the model version (this very model
   is disappearing from APIs), keeping data in one jurisdiction, serving
   fine-tuned or private weights, and owning the latency budget are not on any
   per-token price list. At sustained high load on committed or cheaper GPU
   capacity, the price gap also closes.

### 4.5 Caveats

- **Latency is part of the price.** The self-hosted figures hold only at the
  c = 64 latencies above. Hosted-API latency was not measured here.
- **On-demand rates.** Reserved or committed GPU capacity, or a cheaper
  provider, lowers every self-hosted number; this report uses what was actually
  paid.
- **Quality not compared.** The hosted "Turbo" model is an FP8 build like this
  project's FP8 leg; the 9B-class rows are a different model entirely and only
  locate typical prices.
- **Prices move.** All hosted prices are as of 2026-10-27 and will change.

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

### A.1 Section 3 detail - primary shape (1024 / 256), c = 8

| leg | c | TTFT p50 / p95 (ms) | ITL p50 (ms) | output tok/s |
|---|---|---|---|---|
| BF16 | 8 | 290 / 352 | 25.0 | 307 |
| FP8 | 8 | **211 / 214** | 16.8 | 454 |
| GPTQ | 8 | 255 / 333 | 11.1 | 665 |
| AWQ | 8 | 257 / 489 | **10.7** | **686** |

*Source: `benchmarks/results/sweep-gpu-1/results.csv`.*

TODO - reproduce steps, raw-data Releases, per-session cost ledger.
