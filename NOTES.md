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

## 2026-09-13 — Week 1 step 4: first Python (boto3 upload)

### Environment

- `uv init --bare` + `uv add boto3`. `pyproject.toml` declares loose intent
  (`boto3>=1.43.93`); `uv.lock` pins all 7 resolved packages with hashes.
  Both are committed — `uv sync` then reproduces the environment exactly.
- uv provisioned **CPython 3.13.15** into `.venv` and ignored the system
  python3 (3.12.3). uv manages its own interpreters, so the project is
  independent of Ubuntu's system Python.
- Consequence: the command is `uv run python ...`. Plain `python script.py`
  runs system 3.12 with no boto3 installed.

### scripts/upload_model.py

Four decisions that carry weight:

- `Config(s3={"addressing_style": "path"})` — AWS defaults to virtual-host
  addressing (`https://<bucket>.s3.amazonaws.com/<key>`), which against MinIO
  becomes `http://models.localhost:9000/...` and does not resolve. Path style
  keeps the bucket in the path. **KServe's storage-initializer needs the
  equivalent setting in week 2 — this is half of why step 9 is the risky one.**
- `region_name="us-east-1"` — MinIO ignores the region, but the AWS SigV4
  algorithm hashes it into the signature, so botocore will not sign without
  one. It is a signing input, not a routing input.
- `ensure_bucket` catches `ClientError`, checks for 404/NoSuchBucket, and
  re-raises anything else. Without the re-raise, bad credentials or a dead
  server would be misread as "bucket missing".
- Keys are built with `relative_to(local_dir).as_posix()`. S3 has no
  directories; `subdir/tokenizer.json` is one flat key that happens to
  contain a slash. `relative_to` is what makes the script portable across
  source folders; `as_posix()` stops a Windows separator entering a key.

`.env` is parsed with `str.partition("=")`, never sourced — see the token
leak in the previous entry.

### Broke: DeleteObjects fails against MinIO

`s3.delete_objects()` (batch) returned
`MissingContentMD5: Missing required header for this request: Content-Md5`.

Cause: AWS moved from `Content-Md5` to CRC32 checksums, and current botocore
(1.43.93) no longer sends the MD5 header. MinIO's frozen RELEASE.2024-12-18
build still requires it for the batch-delete XML body.

Worked around with `delete_object()` (singular) in a loop — a plain DELETE
with no request body, so no checksum header is involved.

This is the archived-MinIO risk materialising for real: a maintained server
would have followed the SDK. Watch for the same class of drift in week 2 when
KServe's storage-initializer talks to this MinIO. If it recurs more widely,
the fix is to pin an older botocore or move to a maintained S3 implementation
— the only contract is the S3 API, so the swap is cheap.

## 2026-09-13 — Week 1 steps 5-6: model to S3, vLLM on CPU

### Model into MinIO

- Qwen2.5-0.5B-Instruct, `hf download --local-dir` (not the HF cache's
  blob/symlink layout). Weights live at `~/aify/models/`, outside the repo —
  `.gitignore` covers `*.safetensors`, but keeping a gigabyte of binaries out
  of the working tree entirely beats relying on an ignore rule.
- **`--local-dir` leaves a `.cache/huggingface/` tree** of 23 lock and
  metadata files. `rglob("*")` would have uploaded all of them. Patched
  `upload_folder()` to skip any path with a dot-prefixed component.
- `s3://models/qwen-0.5b/` — 9 objects, 0.93 GiB.
- `model.safetensors` ETag came back `87c8d983...-118`: the `-N` suffix means
  a multipart upload of 118 parts. `upload_file` chunked the 988 MB file at
  the 8 MB default threshold with no extra code. Consequence: **a multipart
  object's ETag is a hash-of-hashes and will never match a local md5sum** —
  verify with size and `head_object`, not checksum comparison.

### vLLM on CPU — the AVX-512 scare

Core Ultra 7 258V (Lunar Lake) has **no AVX-512 at all** — avx2 and avx_vnni
only. Intel dropped AVX-512 from consumer parts after Alder Lake. vLLM issue
#18660 (May 2025) reports the prebuilt CPU image SIGILLs without AVX-512, and
the `VLLM_CPU_DISABLE_AVX512` build arg no longer exists in current
`Dockerfile.cpu` — build args are down to `PYTHON_VERSION`, `VLLM_CPU_X86`,
`VLLM_CPU_ARM_BF16`.

Tested instead of planning around a year-old issue: pulled the image (7.8 GB)
and ran `python3 -c "import vllm"` with the entrypoint overridden. **Imported
fine, vLLM 0.29.0, exit 0.** Image label `ai.vllm.build.cpu-x86=true`; current
builds dispatch on ISA at runtime. No source build needed — that would have
cost hours of a 10-15 hr/week budget.

Technique worth reusing: `docker run --entrypoint python3 <img> -c "import X"`
isolates "do the compiled kernels run on this CPU" from "does the model load".
SIGILL surfaces as exit code 132 (128 + signal 4).

### Serving

    docker run -d --name vllm-cpu --shm-size=4g -p 8000:8000 \
      -v ~/aify/models/qwen2.5-0.5b-instruct:/models/qwen-0.5b:ro \
      -e VLLM_CPU_KVCACHE_SPACE=4 \
      public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest \
      /models/qwen-0.5b --served-model-name qwen-0.5b --max-model-len 2048

- `--shm-size=4g`: Docker's default `/dev/shm` is 64 MB; torch uses shared
  memory for inter-process tensors and crashes without more.
- `VLLM_CPU_KVCACHE_SPACE=4` (GiB) is the CPU analogue of
  `--gpu-memory-utilization`.
- `--served-model-name` decouples the API identifier from the filesystem
  path. `/v1/models` shows `"root": "/models/qwen-0.5b"` but `"id":
  "qwen-0.5b"`. This is what lets week 6's canary hold a stable model name
  across two different storageUris.
- Deliberately bind-mounts the local folder. The MinIO copy is unused here;
  fetching from S3 is KServe's job in week 2.

### Timings — and why they are not benchmarks

| request | wall time |
|---|---|
| first `/v1/completions`, 40 tokens | 59.1 s |
| second `/v1/chat/completions`, 30 tokens | 2.6 s |

Model load was 1.5 s and initial warmup 3.65 s, so the 59 s is not startup —
it is another `torch.compile` pass for a batch shape not seen during warmup.
Steady state is ~11 tok/s on 7 cores.

**Implication for week 5's GuideLLM harness: cold-start requests must be
discarded or TTFT numbers will be meaningless.** Plan an explicit warmup
phase. No performance conclusions come from this step — it exists to prove
the API contract and to know what healthy vLLM startup logs look like before
KServe is layered on top next week.

Benign warnings seen at startup, not errors: `get_mempolicy: Operation not
permitted` / `numa_migrate_pages failed` — the container lacks NUMA
capabilities under WSL2. Irrelevant on a single-socket laptop.
