#!/usr/bin/env bash
#
# scripts/run-alive.sh <results-dir> - is the harness that owns this run alive?
#
# Prints RUNNING (exit 0) or STOPPED (exit 1); exit 2 on bad usage.
#
# Recipe fix 6 (NOTES 2026-10-04). benchmark.sh and pilot.sh hold an exclusive
# flock on <results-dir>/.lock for their whole life, and every child inherits
# it. So "lock is free" means the harness AND all its children (GuideLLM,
# samplers) have exited. Name matching cannot do this:
#   - `pgrep -x benchmark.sh` never matches: the `#!/usr/bin/env bash` shebang
#     makes the process `bash`, with the script only as an argument.
#   - `ps | grep '[b]enchmark.sh'` matches any process naming that file, and
#     misses an orphaned child still loading the GPU.
set -uo pipefail
dir=${1:-}
# Require an existing lock: flock(1) would otherwise CREATE one and say STOPPED.
if [ -z "$dir" ] || [ ! -f "$dir/.lock" ]; then
  echo "usage: $0 <results-dir>   (must contain .lock)" >&2; exit 2
fi
if flock -n "$dir/.lock" true; then echo STOPPED; exit 1; fi
echo RUNNING; exit 0
