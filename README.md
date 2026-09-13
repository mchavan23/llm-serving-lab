# llm-serving-lab

A self-hosted LLM inference platform on Kubernetes, built to produce an honest
benchmark report: what open-model serving actually costs and how it actually
performs, including the idle GPU time that vendor comparisons tend to leave out.

**Status:** in progress. See [NOTES.md](NOTES.md) for the build log.

## What this is

| Layer | Choice |
|---|---|
| Cluster | kind (local, CPU-only dev) / k3s (rented GPU VM) |
| GPU | NVIDIA GPU Operator, driver component disabled (driver pre-installed on host) |
| Serving runtime | vLLM |
| Control plane | KServe `InferenceService`, RawDeployment mode |
| Model storage | MinIO (S3-compatible) |
| Load harness | GuideLLM |
| Model | Llama-3.1-8B-Instruct — FP16 baseline, FP8, AWQ INT4 |

## The deliverable

`docs/benchmark-report.md` — TTFT, throughput and p95 latency across batch sizes
and quantizations, plus cost per million tokens self-hosted vs a hosted API with
idle GPU time included. Raw GuideLLM output is committed under
`benchmarks/results/` so every number in the report is traceable to a run.

## Layout

```
cluster/      kind config and cluster install scripts
manifests/    ServingRuntime, InferenceService, MinIO, KEDA
scripts/      Python: model upload, benchmark driver, results parsing
benchmarks/   run configs and raw results
docs/         the benchmark report
```

## Running it

Requires WSL2 or Linux, Docker, and a Hugging Face read token.
Copy `.env.example` to `.env` and fill it in. Setup steps accumulate in
`cluster/setup.sh` as the project progresses.

## Scope

Deliberately narrow: single node, single GPU, one model. Multi-GPU, tensor
parallelism and llm-d are explicitly out of scope and belong to a follow-on
project.
