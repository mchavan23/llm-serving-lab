# GPU session log

Written by `scripts/session.sh`. One row per paid session. `EUR` is compute
only (EUR 1.47/h); storage and the flexible IPv4 accrue continuously and are
accounted separately in `benchmarks/cost-model.md`.

The `left as` column is the evidence for the week 6 idle-cost claim: on
Scaleway, powering off pauses compute billing but NOT storage or IP.

| date | server | start (UTC) | end (UTC) | GPU h | what was done | EUR | running EUR | left as |
|---|---|---|---|---|---|---|---|---|
| 2026-09-20 | 90aa98a2 | 19:49 | 20:12 | 0.38 | session 1: hardware validation - L40S/cc8.9 confirmed, FP8 served via CUTLASS kernel, block volume portability proven | 0.56 | 0.56 | stopped |
| 2026-09-27 | 90aa98a2 | 14:41 | 16:26 | 1.75 | session 2: platform bring-up - setup-gpu.sh proven from scratch (k3s default-runtime nvidia), FP8 served via KServe from hf://, B4 confirmed; MinIO images unavailable | 2.57 | 3.13 | stopped |
| 2026-09-27 | 90aa98a2 | 17:57 | 18:05 | 0.14 | session 3: four legs verified into SeaweedFS (34.13 GiB), FP8 served from s3://, verify-gpu.sh all green - Phase D exit criteria met | 0.21 | 3.34 | stopped |
