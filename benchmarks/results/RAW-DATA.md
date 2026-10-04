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
