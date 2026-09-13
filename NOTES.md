# Build log

Running record of what was done, what broke, and why. Written as I go —
this is the raw material for the benchmark report in week 6.

Format: date, what I was trying to do, what happened, what fixed it.

---

## 2026-09-13 — Repo bootstrap

- WSL2 Ubuntu 24.04 confirmed. Canonical working copy is `~/aify/llm-serving-lab`
  inside the WSL filesystem, *not* on `/mnt/c` (drvfs is slow, mangles permission
  bits, and inotify doesn't fire there).
- Repo skeleton, .gitignore, .env.example created.
- Open: Docker Desktop WSL integration not yet enabled for this distro.

## 2026-09-13 — Week 1: substrate (kubectl/helm/kind + MinIO)

### Tooling

- Docker Desktop WSL integration now enabled and verified.
- `kubectl` was already present, but as a symlink into
  `/mnt/wsl/docker-desktop/cli-tools/` — Docker Desktop plants its own and
  owns the version. Replaced with a pinned v1.36.4 binary. `install` writes
  *through* a symlink, so the link has to be removed first or it fails trying
  to write into Docker's read-only mount.
- `uv` was never broken: `~/.local/bin/env` is sourced from `.bashrc` and
  `.profile`, so it resolves in any shell I type into. It only disappears in
  non-interactive shells (`bash script.sh`). Symlinked into `/usr/local/bin`
  so it resolves everywhere.
- Helm 4.3.0, not Helm 3. Chart API v2 charts work unchanged; the v3→v4
  breakage is in CLI flags and plugins. Helm 3's final feature release was
  2026-09-09. **Helm 4 defaults to server-side apply** — remember this when
  KServe's CRDs go in next week.
- Pinned Kubernetes 1.36, not the newest 1.37, because KServe and the NVIDIA
  GPU Operator trail the Kubernetes release train. kubectl pinned to the same
  minor as the kind node image, so there is no client/server skew at all.

### Cluster

- `kind` over `k3s` locally: `kind delete cluster` leaves nothing behind,
  and weeks 1–2 will break this cluster repeatedly. k3s installs a systemd
  unit and rewrites iptables in the distro — recovery means unpicking it.
  The YAML that matters (ServingRuntime, InferenceService, MinIO, KEDA) is
  identical on both, so nothing is lost porting to k3s on the GPU VM.
- `extraPortMappings` are a property of the node *container*, applied at
  creation. Changing them later means deleting and recreating the cluster.
- WSL sees 15Gi, not 32 — WSL2 defaults to ~50% of host RAM. The plan's
  "cap at 20GB" would have *raised* the ceiling. Left at default; revisit
  only under real memory pressure.

### MinIO

- **`minio/minio` was archived 2026-04-25** and the admin console was
  stripped from Community Edition in 2025. Chart repo still serves 5.4.0 and
  community images still pull from quay.io. Staying on it, pinned: it is a
  disposable dev dependency whose only contract is the S3 API, and every
  KServe example and its storage-initializer are tested against MinIO.
  Swapping it would add risk to week 2 step 9, which must not slip.
- Bitnami is not an option any more — images moved to `bitnamilegacy` with
  no updates, and the charts no longer work out of the box.
- **The chart's default memory request is 16Gi.** WSL has 15Gi total, so the
  pod would have sat `Pending` forever with only an "Insufficient memory"
  event to show for it. Overridden to 1Gi. Most likely silent failure in
  this step.
- Service `nodePort` values must equal the `containerPort` values in
  `cluster/kind-config.yaml` (30900/30901), or the host port mapping leads
  nowhere and MinIO looks healthy while being unreachable.

### Broke: `.env` was not a valid env file

Line 1 held the bare HF token with no `HF_TOKEN=` prefix. A setup script did
`set -a; . .env`, bash tried to execute the token as a command, and the token
was echoed in the resulting error — leaking it. Token rotated. `.env` was
gitignored from the start and had never been committed, so the repo was clean.

Two fixes:
1. `.env.example` now states that every line must be `KEY=VALUE`.
2. Scripts no longer source `.env`. They read one named key with
   `grep -m1 "^KEY=" .env | cut -d= -f2-`, which cannot execute anything.

Sourcing a file you did not fully validate runs it. Worth remembering.

### Verifying, not assuming

`curl http://localhost:9000/` returning **HTTP 403 with S3 `AccessDenied`
XML** is the success signal: a refused connection means the port chain is
broken, while 403 proves traffic reached MinIO *and* that anonymous access
is closed. A 200 would have been the bad outcome. `curl -o /dev/null` hides
the body and makes this look like a failure — print the body.
