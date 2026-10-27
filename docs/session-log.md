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
| 2026-10-03 | 90aa98a2 | 16:34 | 21:56 | 5.37 | session 4: measured sweep | 7.89 | 11.23 | stopped |
| 2026-10-26 | 90aa98a2 | 02:51 | 05:02 | 2.19 | watcher: run 20261026T0440Z-step-gpu-collapse COMPLETE [L40S-2-48G @ 2.93982/h] | 6.44 | 17.67 | stopped |
| 2026-10-26 | 90aa98a2 | 05:07 | 05:34 | 0.44 | watcher: run 20261026T0513Z-step-gpu-repeat COMPLETE [L40S-2-48G @ 2.93982/h] | 1.29 | 18.96 | stopped |
| 2026-10-26 | 90aa98a2 | 06:00 | 06:04 | 0.07 | coldpath coldpath-restart-2-20261026T0559Z (restart-2) [L40S-2-48G @ 2.93982/h] | 0.21 | 19.17 | stopped |
| 2026-10-27 | 90aa98a2 | 02:45 | 03:35 | 0.85 | session 6: Knative canary FP8->AWQ, data-path overhead, wake from zero [L40S-2-48G @ 2.93982/h] | 2.50 | 21.67 | stopped |
