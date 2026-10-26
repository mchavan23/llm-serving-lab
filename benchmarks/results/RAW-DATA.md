# Raw GuideLLM records

Every benchmark point writes `guidellm.json`: one record per request, including
the generated text. They are large (~260 MiB for session 4), so from session 4
on they are **not committed**. They are published, compressed, as an asset on a
GitHub Release, and this repo holds their checksums. Everything else a run
writes (`results.csv`, `point.json`, sidecars, gauges, GPU samples, metrics
snapshots, logs) is committed in the run directory.

`guidellm.json` files from the earlier kind dry-runs (`a7-kind-*`, `pilot-kind-*`)
are committed as they were.

## Session 4 (2026-10-03): measured sweep on 1x L40S

- Runs: `sweep-gpu-1`, `shakedown-1`, `pilot-gpu-1`, `session-4-boot`
- Release: `results-session-4`
- Asset: `llm-serving-lab-session-4-guidellm-raw.tar.xz` (59.1 MiB, 60 files)
- Asset SHA-256: `a620cfa378f807d0c67db0c3a0242350334e6a030362adfd4c2d1af0bede0ea6`
- Per-file SHA-256: [`session-4-guidellm.sha256`](session-4-guidellm.sha256)

## Session 5 (2026-10-26): KEDA scale-out on 2x L40S

- Runs: `20261026T0401Z-step-gpu` (main, 2 cycles), `20261026T0440Z-step-gpu-collapse`,
  `20261026T0513Z-step-gpu-repeat` (restart-1 boot)
- Release: `results-session-5`
- Asset: `llm-serving-lab-session-5-guidellm-raw.tar.xz` (42.9 MiB, 4 files)
- Asset SHA-256: `7d4891087650a88f1d0f545fde65019dbce67199012b2095916fe82bf3bc9fd4`
- Per-file SHA-256: [`session-5-guidellm.sha256`](session-5-guidellm.sha256)
- NOT yet included: the shakedown run `20261026T0325Z-step-gpu` is still on the
  VM (both L40S types were out of stock when a pull boot was tried, 2026-10-26).
  When pulled, its record is added to this release as a second asset with its
  own manifest; its parsed results are in NOTES.md ("Week 5 Phase B").
- Cold-path runs (`coldpath-*`) write no `guidellm.json`.

The restore steps below apply with `session-4` replaced by `session-5`; the
parser for these runs is `scripts/parse_step.py`.

## Restore and verify

From the repo root:

```bash
gh release download results-session-4 -p 'llm-serving-lab-session-4-guidellm-raw.tar.xz'
sha256sum llm-serving-lab-session-4-guidellm-raw.tar.xz      # compare with the line above
tar -xJf llm-serving-lab-session-4-guidellm-raw.tar.xz       # files land at their run paths
sha256sum -c benchmarks/results/session-4-guidellm.sha256     # 60 x OK
uv run --locked python scripts/parse_results.py benchmarks/results/sweep-gpu-1
```

The archive is built deterministically (sorted names, fixed owner and mtime), so
the same files always produce the same asset hash.
