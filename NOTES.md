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

### vLLM images are hardware-specific — the runtime does NOT port

Correcting a sloppy claim: one vLLM image does *not* serve both CPU and GPU.
The CPU image has no CUDA runtime and no GPU kernels. Week 3 on the L40S needs
a different image.

What is portable is the **interface**, not the binary:

Unchanged across CPU and GPU:
- API surface: `/v1/completions`, `/v1/chat/completions`, `/v1/models`,
  `/health`, `/metrics`
- CLI args: `--served-model-name`, `--max-model-len`, model path as first
  positional
- Prometheus metric names — so the benchmark harness and the KEDA scaler work
  against both without change
- The KServe `ServingRuntime` YAML shape; only `image:` and a few args differ
- The model artifacts in MinIO — genuinely hardware-independent

Changes on GPU:

| CPU (week 1-2, kind)                        | GPU (week 3, L40S)          |
|---------------------------------------------|-----------------------------|
| `public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo` | `vllm/vllm-openai` (Docker Hub) |
| `VLLM_CPU_KVCACHE_SPACE=4` (GiB)            | `--gpu-memory-utilization 0.9` |
| `--shm-size=4g`                             | `--shm-size=4g` + `--gpus all` |
| no quantization                             | FP8 / AWQ — the week 4 benchmark axis |

Note vLLM publishes GPU images to Docker Hub but CPU images only to AWS
public ECR. Different registries, no login needed for either.

### `/health` returns an empty body

`curl -s localhost:8000/health` prints nothing and that is the healthy case:
HTTP 200 with `content-length: 0`. Use `curl -i` or
`curl -o /dev/null -w '%{http_code}'` for endpoints that signal through status
codes. Same class of mistake as reading the MinIO 403 as a failure — the
status code is the payload.

### torch.compile cache is thrown away on container removal

The AOT-compiled graphs land in `/root/.cache/vllm/torch_compile_cache/`
inside the container. Nothing is mounted there, so every fresh `docker run`
recompiles. That is part of the 59 s first-request cost. If startup time
starts to matter, mount a volume at that path — and note that KServe pods in
week 2 have the same problem unless the ServingRuntime declares a volume.

### Verification

`scripts/verify.sh` checks every layer (tooling, docker, kind + published
ports, MinIO pod/PVC/API, boto3 + model objects, vLLM health/models/generation)
and exits non-zero on failure. Run it after any WSL restart. It exists so that
when week 2 breaks, the question "which layer" is answered in 10 seconds.

Its generation probe uses `/v1/completions` with prompt `2+2=` and returns
`4答案:Assistant`. That is correct behaviour, not a bug: `/v1/completions` is
raw continuation with no chat template applied, so a 0.5B model drifts
immediately after answering. Use `/v1/chat/completions` for anything where
output quality is being judged.

---

## 2026-09-16 — Week 2 steps 7-10: cert-manager, KServe, ServingRuntime, InferenceService

End state: `qwen-0-5b` InferenceService READY, serving real completions at
`localhost:8080` through kind's port mapping. Steps 7-10 done; step 11
(GuideLLM) deliberately skipped — see "Why step 11 was skipped" below.

### Housekeeping first

WSL raised from the 15 GiB default to a 20 GiB cap via `%USERPROFILE%\.wslconfig`
(`memory=20GB`, `swap=8GB`, `autoMemoryReclaim=gradual`). `memory=` is a
ceiling claimed on demand, NOT a reservation — but without
`autoMemoryReclaim` the VM ratchets to its high-water mark and never returns
memory to Windows. That setting is the one doing the real work.

Deliberately did not set `networkingMode`. Default NAT is what makes the kind
host-port mappings reachable from Windows; mirrored mode would put ports
8080/9000/9001 at risk for no gain here.

Removing the week 1 `vllm-cpu` container freed **7.5 GiB**, not the ~2 GB
estimated. Worth recalibrating: a vLLM process costs far more resident memory
than the model weights suggest. For the 0.5B model, ~7.5 GiB resident of which
0.93 GiB is weights and 4 GiB is `VLLM_CPU_KVCACHE_SPACE`.

### KServe renamed RawDeployment to Standard

From v0.20, `deploymentMode` takes `Standard` or `Knative`. "RawDeployment"
is retired. Same thing — plain Deployment + Service + HPA, no Knative. Older
docs and this project's week 1 notes use the old name.

### Helm 4 does not honour `null` to delete an inherited chart value

`kserve.controller.resources.limits.cpu: null` did NOT remove the chart's
default 100m limit. Neither did
`--set kserve.controller.resources.limits.cpu=null`. Helm 4.3.0 coalesces the
chart's own values.yaml into the user's, and null did not delete the key —
verified by rendering both ways. Workaround: override with a value high
enough not to bind (`cpu: "1"`).

This mattered because the KServe controller pod also SERVES the admission
webhooks. A throttled webhook missing its 10s timeout surfaces as a confusing
InferenceService failure, not as a CPU problem.

Note this applies to Helm value coalescing only. Plain manifests have no merge
step, so simply omitting `limits.cpu` in the ServingRuntime worked fine.

### cert-manager: who injects what

The chicken-and-egg (cert-manager's webhook needs a cert; cert-manager issues
certs) is broken by the webhook **self-generating** its CA into a Secret on
startup. cainjector then copies it into the webhook configurations. Caught in
the logs:

    18:09:35  E  secrets "cert-manager-webhook-ca" not found
    18:09:35  I  could not find any ca data in data source for target
    18:09:40  I  Updated object  kind=validatingwebhookconfiguration
    18:09:40  I  Updated object  kind=mutatingwebhookconfiguration

**cainjector cannot invent a CA — it only copies one that already exists.** So
an empty `caBundle` has two distinct causes with different fixes: cainjector
down, or the source missing.

Two annotations, different dependency chains:

| annotation | points at | needs |
|---|---|---|
| `cert-manager.io/inject-ca-from-secret` | a Secret, directly | cainjector only |
| `cert-manager.io/inject-ca-from` | a Certificate | cainjector AND the controller |

cert-manager's own webhook uses the first (it cannot depend on its own
issuance path during bootstrap). **KServe uses the second.** So if KServe's
`caBundle` is ever empty, check `kubectl get certificate -n kserve` FIRST —
cainjector will be innocent and its logs will just say it cannot find CA data.

Also: the chart's `crds.enabled` defaults to **false**. Miss it and all three
pods come up healthy while every Certificate fails as an unknown kind — a
green-looking failure.

The `startupapicheck` Job is a Helm hook with delete-on-success, so it is gone
by the time you look. Default timeout 1m is optimistic on cold kind; raised to
5m.

### `_example` in ConfigMaps makes grep lie

`grep defaultDeploymentMode` on the rendered KServe ConfigMap returned
`"Serverless"`, suggesting the `Standard` setting had not applied. It had. The
hit was inside the `_example` key, a documentation blob KServe ships in the
same ConfigMap. Parsing the YAML gave the real value.

**Parse rendered Kubernetes YAML; do not grep it.** Charts embed examples and
comments in data.

### `kind load` stores only the tag — digest pinning backfires

The ServingRuntime originally pinned the image by digest, which is the more
reproducible choice. It is wrong here. `kind load docker-image` registers
exactly ONE named reference in the node's containerd store:

    $ docker exec <node> ctr -n k8s.io images ls | grep vllm
    public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest

No digest reference. containerd matches `imagePullPolicy: IfNotPresent`
against the literal reference string, so a digest-pinned image is judged
absent and triggers a full 7.8 GB pull from ECR — exactly what side-loading
exists to avoid.

Using the tag locally; the digest of the image in use is recorded in the
manifest comment. **On the GPU VM (week 3+) the image is pulled from a
registry rather than side-loaded, so switch back to the digest form there.**

Verify a load actually finished with:

    docker exec <node> ctr -n k8s.io images check | grep vllm
    # complete (15/15)  1.7 GiB/1.7 GiB  true

`crictl images` listing it only means a record exists, not that content is
complete. And do NOT check with `pgrep -f 'kind load'` — that matches its own
wrapping shell and reports RUNNING forever. Use `pgrep -x kind`.

### ServingRuntime vs InferenceService

Same relationship as StorageClass to PVC. The runtime is a reusable pod
template describing HOW to run a class of models; it contains no model and
deploys nothing. The InferenceService says WHICH model. One runtime serves
many InferenceServices — each gets its OWN Deployment, pod and vLLM process.
Creating more InferenceServices does not create more runtimes.

Matched either by `modelFormat.name` against `supportedModelFormats` with
`autoSelect: true`, or by naming `predictor.model.runtime` explicitly. This
project sets `autoSelect: false` and names the runtime, so a mistake fails
loudly instead of matching something unintended.

`{{.Name}}` in the runtime's args is templated with the InferenceService's
name at reconcile time — that is the mechanism that keeps a runtime generic.

Container name `kserve-container` is not arbitrary; KServe merges the
InferenceService's `predictor.model` overrides onto that literal name.

Upstream's `kserve-vllmserver` runtime ships `resources: 2Gi` — that would
OOM-kill (exit 137) during weight loading for this model, before the KV cache
is even allocated. A memory LIMIT is a hard cgroup ceiling; the process does
not balloon past it, it dies at it.

A memory-backed emptyDir (`/dev/shm`) counts against the container's memory
limit, and an unsized one defaults to half the node's RAM. Size it explicitly.

### The storage-initializer is injected into PODS, not Deployments

`kubectl get deploy -o yaml` shows NO `initContainers`. The pod mutating
webhook operates on Pods, downstream of the Deployment. Debug this by
inspecting pods.

    Deployment spec:  clean, just the kserve-container
    Pod spec:         + storage-initializer init container
                      + emptyDir `kserve-provision-location`
                      + that emptyDir mounted at /mnt/models in BOTH containers

That shared emptyDir is the whole trick: the init container writes, the model
container reads, which is why the runtime can hardcode `/mnt/models` and still
serve from S3.

### S3 config lives on the Secret, never in the URI

`storageUri: s3://models/qwen-0.5b` is bucket + prefix only. No host, port,
scheme, region or addressing style. All of that comes from annotations on the
Secret that `serviceAccountName` resolves to — which is what lets the same
InferenceService manifest move unchanged from MinIO-on-kind to real S3.

    InferenceService.spec.predictor.serviceAccountName
      -> ServiceAccount.secrets[] -> Secret annotations -> env on the init container

Week 1's boto3 findings map across exactly:

| upload_model.py | KServe annotation | resulting env |
|---|---|---|
| `endpoint_url` | `serving.kserve.io/s3-endpoint` | `S3_ENDPOINT`, `AWS_ENDPOINT_URL` |
| `addressing_style: "path"` | `serving.kserve.io/s3-usevirtualbucket: "false"` | `S3_USER_VIRTUAL_BUCKET` |
| `region_name` | `serving.kserve.io/s3-region` | `AWS_DEFAULT_REGION` |

Two traps:

- The endpoint annotation carries **no scheme**. KServe composes
  `AWS_ENDPOINT_URL` by gluing the scheme from `s3-usehttps` onto it.
- The env var is **`S3_USER_VIRTUAL_BUCKET`**, not `S3_USE_...` — an upstream
  typo. Grepping for `S3_USE_VIRTUAL_BUCKET` finds nothing and leads to the
  wrong conclusion that the annotation did not apply.

The endpoint must be the in-cluster Service DNS
(`minio.minio.svc.cluster.local:9000`), not `.env`'s host-facing
`MINIO_ENDPOINT` — inside a pod, `localhost` is the pod.

Credential key names `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are not
convention; they are configured in the live `inferenceservice-config`
ConfigMap (`s3AccessKeyIDName` / `s3SecretAccessKeyName`). The values are
MinIO's `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD` — MinIO speaks S3, so its
user and password *are* the access key and secret key. These are root
credentials mounted into every pod using the ServiceAccount; a real deployment
would mint a scoped MinIO service account with read-only access to one bucket.

Built by `scripts/create-s3-secret.sh` rather than a committed manifest,
because the values come from gitignored `.env`.

### Result: step 9 worked first time

    Copying contents of s3://models/qwen-0.5b to local
    Found 9 objects ... model.safetensors (988097824 bytes)
    Successfully copied s3://models/qwen-0.5b to /mnt/models
    Model downloaded in 9.11 seconds

0.93 GiB in 9.11 s, and the storage-initializer stayed inside its 1Gi memory
limit — it streams to disk rather than buffering.

### No ingress: the NodePort chain

`disableIngressCreation: true` is required. Left at its default, KServe
creates an Ingress with class `istio` for every InferenceService. This
cluster has no ingress controller (`kubectl get ingressclass` is empty), so
that Ingress never gets an address — and because KServe folds ingress
readiness into the InferenceService status, **the InferenceService sits
not-Ready on top of a perfectly healthy serving pod.** Every instinct sends
you to look at the model.

Reaching the endpoint therefore needs a hand-written NodePort Service. Four
hops, three of which are the number 8080 and are unrelated:

    curl localhost:8080        WSL or Windows
      |  kind-config.yaml: hostPort 8080 -> containerPort 30800
    kind node :30800           nodePort
      |  kube-proxy
    Service (targetPort 8080)
      |
    pod :8080                  vLLM, from the runtime's --port=8080

`targetPort` is the field that matters. Copying KServe's ClusterIP Service
(`port: 80, targetPort: 8080`) and setting `targetPort: 80` gives connection
refused with a healthy-looking Service and a correctly populated Endpoints
list, because nothing in the pod listens on 80.

The container declares **no `containerPort` at all**. That is fine —
`containerPort` is documentation; kube-proxy routes to `podIP:targetPort`
regardless. Not a lead worth chasing.

### Model name changed from week 1

The InferenceService is named `qwen-0-5b` (hyphens — the name becomes DNS
labels). The runtime's `--served-model-name={{.Name}}` resolves to that, so
requests must send `"model": "qwen-0-5b"`, NOT week 1's `"qwen-0.5b"`.

Did not override the arg in the InferenceService this week. Whether KServe
appends the InferenceService's `args` to the runtime's or replaces them is
still unverified, and two conflicting `--served-model-name` flags in one
command line was not worth discovering during step 9. The generated pod shows
a single clean arg list, so `{{.Name}}` alone is confirmed working.

### torch.compile cache on a PVC — partial win, upstream bug

Attached a 2Gi PVC at `/root/.cache/vllm` via the **InferenceService**, not
the runtime. A cluster-scoped runtime referencing a namespaced PVC by name
would silently require every consuming namespace to have a PVC of that name.

Measured by deleting the pod and comparing:

    cold  (empty PVC)    init engine took 99.36 s
    warm  (populated)    init engine took 57.03 s

42% faster, but NOT for the designed reason:

    WARNING Compiling model again due to a load failure from
            /root/.cache/vllm/torch_compile_cache/torch_aot_compile/190b07.../rank_0_0/model
            reason: 'function' object has no attribute 'finalize_loading'

**vLLM 0.29.0 saves its AOT-compiled model and cannot load its own artifact
back.** It silently recompiles and re-saves (cache grew 5.5M -> 7.2M). The
saving came entirely from the `inductor_cache/` subtree, where individual
kernel compilations did hit. If `finalize_loading` is fixed upstream, that
57 s should drop considerably — worth re-testing on a later vLLM.

Also: `Loading weights took 0.49 s` on restart vs `3.69 s` cold is the NODE'S
PAGE CACHE, not the PVC. It evaporates on a WSL restart. Do not attribute it
to anything we built.

### Canary is not available in Standard mode

KServe's `canaryTrafficPercent` is supported only in Serverless (Knative)
mode. **This conflicts with the week 6 scope**, which assumes Standard mode
plus a canary rollout between two model versions.

Weighted traffic splitting will need something in front of the two predictor
Services — Gateway API `HTTPRoute` with weighted `backendRefs` is the
lightest (a Deployment plus CRDs, not a full mesh); alternatives are Istio
`VirtualService`, nginx-ingress canary annotations, or the crude
replica-count trick (one Service selecting both, 9 pods : 1 pod).

Name the tension honestly in the write-up: Standard mode was chosen to keep
Istio and Knative out, and every clean traffic-splitting option puts something
back in front.

Related, from the same design: a canary means both versions answer to ONE
API-facing model name while loading different `storageUri`s. `{{.Name}}`
cannot do that, because Kubernetes object names must be unique. Week 6 needs
the literal `--served-model-name` override — hence the append-vs-replace
question above must be settled before then.

### No metrics-server on this cluster

`kubectl top` fails with `Metrics API not available`. Consequences:

- no per-pod memory visibility when attributing footprint
- any HPA emits `FailedGetResourceMetric` on a loop

Suppressed the HPA with `serving.kserve.io/autoscalerClass: none` on the
InferenceService — autoscaling is a week 4 concern and the events stream is
needed for debugging. Decide in week 4 whether to install metrics-server or
rely on GuideLLM plus container-level stats.

### Why step 11 was skipped

GuideLLM against an ~11 tok/s CPU endpoint produces numbers already written
off as unrepresentative (see week 1, "Timings — and why they are not
benchmarks"). The benchmark harness belongs on the rented GPU. Removing the
week 1 container also discarded its compile cache, so step 10's first request
paid the full cold cost — which is exactly the contamination week 5's harness
must design around.

### Kubernetes version is ahead of KServe's tested range

Cluster is 1.36.4; KServe 0.20's documented support tops out around 1.34.
Nothing has broken. If something odd appears — a webhook rejecting on an API
version, a CRD field pruned — that is the first hypothesis, not the last.

### Incidental

`$HOME` is `/root` in this WSL Ubuntu; the default user is root. That is why
the runtime can write to `/root/.cache/vllm` without a securityContext fight,
and it is NOT something to replicate on the GPU VM.

The kind node reports the vLLM image as 1.84 GB where Docker reports 7.8 GB —
compressed layer accounting vs uncompressed. Same image.

---

## Week 3 - provisioning path, written before any GPU was rented

Everything below was settled on the laptop at zero spend.

### KServe appends `args`; it does not replace them

`pkg/controller/v1beta1/inferenceservice/utils/utils.go`,
`MergeRuntimeContainers()` (KServe v0.20.0): every other field merges by
strategic patch, but `args` is special-cased to concatenate - runtime args
first, InferenceService args appended. The call path for our models is
`predictor.go` -> `MergeServingRuntimeAndInferenceServiceSpecs(...,
isvc.Spec.Predictor.Model.Container, ...)` on the container named
`kserve-container`.

Practical consequences:
- A runtime flag can never be silently dropped by an ISVC that sets one arg.
- An "override" is really a duplicate flag. vLLM parses with argparse, so the
  last occurrence wins and it works - but by argparse semantics, not by KServe
  design, and `kubectl get pod -o yaml` shows both.
- Rule: shared flags live in the runtime, each InferenceService carries only
  `storageUri`.

Answered from source rather than from an experiment. Source says *why*; one
experiment only says *what happened once*.

### ClusterServingRuntime cannot select a RuntimeClass

Checked the v0.20.0 CRD schemas directly. `ClusterServingRuntime`'s pod-level
keys are affinity, annotations, hostIPC, imagePullSecrets, labels, nodeSelector,
schedulerName, tolerations, volumes, workerSpec - no `runtimeClassName`.
`InferenceService` does have `spec.predictor.runtimeClassName`.

So a RuntimeClass alone cannot make KServe pods use the nvidia runtime handler.
Either every ISVC sets `runtimeClassName`, or nvidia becomes containerd's
default runtime. Chose the default (`nvidia-ctk runtime configure
--set-as-default=true`): this node exists only to serve models, and nothing can
forget it. The RuntimeClass object is still created, so a pod *can* ask
explicitly and `kubectl get runtimeclass` documents what the node supports.

### k3s does not read /etc/containerd/config.toml

k3s regenerates `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` on every
start. Edits there vanish. The supported override is the `.tmpl` file beside it,
and the socket is `/run/k3s/containerd/containerd.sock`. Most GPU-on-Kubernetes
guides configure Docker's `daemon.json` instead, which k3s never consults.

### `exec > >(tee ...)` logs asynchronously

First version of `setup-gpu.sh` logged that way. A `die()` message from one run
only flushed during the *next* run, so errors appeared out of order. Replaced
with a single re-exec of the script piped through `tee`, preserving the script's
exit status via `PIPESTATUS[0]`. On a paid clock, an error that appears after
you have moved on is worse than no logging.

### Assert on the node, not on the DaemonSet

A running device-plugin pod means nothing. The assertion that matters is
`node.status.allocatable."nvidia.com/gpu"` being present and non-zero; without
it a GPU pod sits Pending forever. Then a real CUDA pod runs `nvidia-smi -L` and
its output is grepped for the expected card - container start succeeding is not
the same as the container seeing the GPU.

### Two bugs caught by testing session.sh before first use

1. Usage/`--help` required the config file, so a bare `session.sh` died
   complaining about `.session.env` instead of printing help. Argument dispatch
   now happens before the config check.
2. The running-total function summed the *cumulative* column of the session log
   rather than the per-session cost. A log holding EUR 8.82 of real spend
   reported EUR 20.58 - the EUR 60 kill criterion would have tripped at roughly
   EUR 26 of actual spend.

Both are the ordinary kind of bug. The point is that they were found on a
laptop, not at EUR 1.47/hour.

### Provider selection: the trap is what "stopped" means

- **Hyperstack** lists an **L40**, not an L40S. Same Ada silicon, same 864 GB/s,
  but roughly half the dense FP8 throughput (362 vs 733 TFLOPS) - which is
  precisely the leg this report is built on. Also: SHUTOFF still bills at the
  full VM rate; only HIBERNATED drops to storage charges.
- **Verda** (ex-DataCrunch) has the L40S at $1.45/h, but its docs are explicit
  that shutdown instances keep charging, and hibernate was removed. Teardown
  means DELETE + reattach volumes, and a zero prepaid balance deletes volumes
  (96h recovery). Third-party price trackers said $1.37/h; the vendor's own rate
  card said $1.45. Trackers are not sources.
- **Scaleway** pauses compute billing on power-off. Storage and the flexible
  IPv4 keep billing regardless of power state, and the 1.6 TB scratch NVMe
  included in the instance price is destroyed on power-off, so nothing durable
  may live there.

Compute cost across the whole project differs by about EUR 4 between providers.
The stop semantics differ by far more than that in operational risk.

### Load generator runs on the VM

Pune to EU is 150-250 ms RTT against a TTFT in tens of milliseconds, and an SSH
tunnel is a single TCP connection so concurrency would queue behind itself.
GuideLLM therefore runs co-located with vLLM. Two consequences: the report must
state that the numbers exclude client-side network latency, and the VM needs
>= 8 vCPU / >= 32 GB RAM so the load generator does not starve the server
(L40S-1-48G gives 8 vCPU / 96 GB).

## 2026-09-27 - Week 3 Phase D, GPU session 2: platform bring-up

Evidence: `docs/evidence/session-2/`. Commits d6f4c14 .. (this one).

**k3s auto-detection DID fire.** k3s v1.36.4 found nvidia-container-runtime on
PATH and rendered an `nvidia` handler itself, but left `default_runtime_name`
unset, so the default was runc. Exactly the state D1 predicted: a pod naming
the RuntimeClass gets the GPU, a KServe predictor (which cannot name it) does
not. Snapshot: `config.toml.k3s-first-render`.

**Step 3 rewritten to k3s's own `default-runtime: nvidia`** in
/etc/rancher/k3s/config.yaml. The template approach was wrong for this k3s:
it renders containerd 2.x `version = 3` config whose header says to use
`config-v3.toml.tmpl`, and copying the rendered file into a template freezes
every other k3s default. Asserted against the regenerated config; smoke 5b
(no runtimeClassName) and the real predictor pod both see the L40S.

**Script bugs found on first hardware contact, all fixed:**
- helm was never installed on the device-plugin path; step 6 would have died
  silently (`helm repo add || true` swallowed "command not found"). Step 1b.
- `kubectl wait node --all` straight after k3s start errors at once: the API
  answers before the kubelet registers the Node, and --timeout only covers
  objects that already exist. `wait_node_ready()`.
- A poller of mine matched the process NAME; the script runs as
  `bash cluster/setup-gpu.sh`. Match argv with `ps -eo args | grep '[s]...'`.

**MinIO is gone.** Docker Hub `minio/minio` deleted 2026-09-11; quay.io
`minio/minio` locked to authenticated pulls 2026-09-24. Our pinned tag cannot
be pulled anywhere. The laptop's kind copy cannot be exported either: kind's
containerd discards compressed layers after unpacking. The LAPTOP MinIO works
only until the kind cluster is rebuilt. Replacement to be chosen off the clock
(candidates: cgr.dev/chainguard/minio, bitnamilegacy/minio, SeaweedFS/Garage).

**Served instead from hf://** (interim, `inferenceservice-llama-fp8-hf.yaml`):
FP8 leg on KServe, ISVC Ready, correct completion, `/metrics` has
`vllm:num_requests_waiting` and the TTFT histogram. Engine identical to the
session 1 bare `docker run`: CutlassFP8ScaledMMLinearKernel, FLASH_ATTN,
KV 205,856 tokens (50.26x), init 41.7 s vs 40.7 s.

**KServe storage-initializer OOMKilled** (exit 137, 1Gi default) ~4 s into an
8.5 GiB hf:// download. Raised to 8Gi in kserve-values.yaml
(`kserve.storage.resources`). The legacy `storageInitializer` key in the
inferenceservice-config ConfigMap still reads 1Gi; the pod got 8Gi, so in
v0.20 that key is not what sets the limit.

**B4 confirmed on a real pod:** ISVC arg `--max-model-len=2048` appended as
arg #8 after the runtime's seven; engine served max_model_len 2048
(argparse last-wins).

**Single-GPU rollout deadlock:** changing the ISVC left the new pod Pending
forever - RollingUpdate starts the new pod before stopping the old, which
holds `nvidia.com/gpu: 1`. Fix: predictor `deploymentStrategy: Recreate`.
Every week 4 ISVC needs it.

**From-scratch run:** k3s + helm wiped, `setup-gpu.sh` re-run on the final
script with no intervention - all steps green (`setup-scratch.out`).

Other: uv on the VM picked Python 3.14.7 (laptop: 3.13.15) - no
`.python-version` pins it. `verify.sh` is kind-specific; adapt for the GPU
cluster. .env on the VM (root volume, 0600) holds HF_TOKEN + MinIO creds.

## 2026-09-27 - Week 3 Phase D, GPU session 3: weights in our own S3 - PHASE D DONE

Evidence: `docs/evidence/session-3/`. ~10 GPU-minutes.

- `stage-models.sh` (SeaweedFS instead of MinIO): four legs HF -> staging (HF
  cache, kept) -> S3, each verified file-for-file and byte-for-byte:
  BF16 13 files 14.97 GiB (rev 0e9e39f2), FP8 10 / 8.47 (870a1177),
  GPTQ 7 / 5.35 (6a426ef8), AWQ 11 / 5.34 (db1f81ad). 34.13 GiB in ~2.5 min;
  BF16 downloaded at ~640 MB/s.
- FP8 served from `s3://models/llama-3.1-8b-fp8` (Recreate, no
  runtimeClassName). storage-initializer pulled 8.47 GiB from SeaweedFS in
  14 s (24 s from HF in session 2). Engine init 41.8 s - same as sessions 1-2.
- **`verify-gpu.sh`: all checks passed** (first run on hardware).
- k3s, SeaweedFS's absence, KServe etc. all survived power-off: node Ready and
  every pod Running within ~30 s of boot.
- **Different physical GPU after power-cycle**: UUID GPU-d81842c3... vs
  GPU-20dd86a4... in session 2. Same model/driver/cc, but "same card" is not
  guaranteed between sessions -> record the UUID with every week 4 run.
- **Disk: a THIRD copy of the served weights.** The storage-initializer copies
  the model into the pod's emptyDir on the root volume, so the served leg
  exists 3x (HF-cache staging, S3, pod). With FP8 served: 112 GiB used of 135,
  23 GiB free. BF16 (15 GiB) served instead still fits (~6 GiB more), but the
  A3 budget missed this term. Week 4: serve one leg at a time (Recreate
  already guarantees that) and watch free space; options if needed - drop the
  HF-cache staging copies (S3 is verified against them already) or KServe's
  modelcar/PVC paths that avoid the copy.

## 2026-10-03 - Week 4 Phase A, A1: the synthetic workload - SETTLED

Read from the installed GuideLLM 0.7.4 and the running engine, not from docs.

**Shape: 1024 prompt tokens / 256 output tokens, fixed (stdev 0), identical
on all four legs.** Prompt + output = 1280, well inside `max-model-len=4096`.

Why this shape:
- Chat/RAG-like. The prompt is 4x the output, so prefill (drives TTFT) and
  decode (drives inter-token latency) both show up clearly.
- KV cache headroom keeps the legs comparable. Llama 3.1 8B costs 128 KiB of KV
  cache per token (32 layers x 8 KV heads x 128 dims x 2 (K,V) x 2 bytes BF16;
  from config.json). KV stays BF16 on every leg - we quantize weights, not the
  cache - so the per-token cost is the same on all four. One request peaks at
  1280 x 128 KiB = 160 MiB. FP8 measured 205,856 KV tokens in session 1
  (~25 GiB) = ~160 such requests; BF16, with ~6.5 GiB more weights, is
  ESTIMATED at ~120. A ladder topping out near 64 should stay clear of
  preemption on every leg. At 2048/512 BF16 would fit ~60 and preempt alone at
  the top, comparing memory exhaustion against speed. Confirm each leg's real
  capacity from vLLM's startup line.
- 256 output tokens keep requests short: ~3.6 s at c=1 on FP8 (~71 tok/s).
  Caveat carried to A2: at c=1 a 3-min point completes only ~45 requests, so
  its p95 rests on ~2 samples. Give low rungs a longer duration.
- Report caveat: cost per million tokens holds for THIS shape only.

Known weakness, deferred to A2 (time budget on paper first): weight-only INT4
(GPTQ/AWQ, W4A16) tends to help decode and can hurt prefill; FP8 W8A8 helps
both. One balanced shape can blur that. Candidate second shape: prefill-heavy
3072/128 on a short ladder, ~+30-50% GPU time.

**Seed: base 42, set explicitly; each ladder point uses seed = 42 + point
index, the same mapping on every leg.** Warmup uses its own seed; the anchor
repeat reuses leg 1's original seed.
- Why: vLLM 0.29 runs with `enable_prefix_caching=True` (read from the running
  qwen-0-5b pod log). GuideLLM builds prompts from Faker text seeded by the
  seed, so one seed everywhere would re-send prompts the engine has cached and
  understate TTFT, by a different amount at each point. A per-point seed means
  no point is pre-cached by an earlier one, and the same seed per point across
  legs means every leg sees identical prompts.
- The anchor repeat is safe on its original seed: it runs on a fresh pod
  (Recreate) with an empty cache.
- Rejected: `--no-enable-prefix-caching`. It moves a server constant away from
  the production default and adds a choice to justify.
- Check in A7: measured points should show a prefix cache hit rate near 0%
  (only the shared chat-template header should hit).

Facts from the installed tool that the harness depends on:
- **CLI drift:** there is no `guidellm benchmark`; the command is `guidellm run`.
  Workload: `--data kind=synthetic_text,prompt_tokens=1024,output_tokens=256`.
  Seed: `--seed kind=static,value=N` (default 42).
- Output length is enforced, not hoped for: with `output_tokens` set, GuideLLM
  sends `max_tokens=N`, `stop=None`, `ignore_eos=True`
  (`backends/openai/request_handlers.py`). So a model that tends to stop early
  cannot look faster by doing less work.
- Prompts are built by encoding Faker text with a tokenizer ("processor"),
  truncating to exactly N tokens and decoding. Two follow-ups for A5/A7: (1) pin
  ONE processor (the BF16 repo at its pinned SHA) for all four legs so the
  prompt text is identical; (2) decode-then-re-encode may not land on exactly
  1024 server-side - check the server-reported prompt token count in the
  dry-run.

## 2026-10-03 - Week 4 Phase A, A2: the matrix on paper - SETTLED (provisional ladder)

Read from installed GuideLLM 0.7.4: `--profile kind=concurrent` accepts a list
of streams, but one invocation shares one seed, so the harness runs ONE
`guidellm run` per point (A1's per-point seeds). The profile has
`rampup_duration`, `warmup`, `cooldown` to exclude a point's edges from stats;
runtime limit via `--constraint kind=max_duration`. Exact syntax settled in A5.

Two different warmups, not to be confused:
- **Per-leg warmup** (~60 s at c=64, discarded): pays one-time engine costs
  (torch.compile / unseen batch shapes, week 1 finding) before measuring.
- **Per-point edge exclusion** (~20 s start, ~10 s end): in a closed loop all
  c requests start at once, so the first wave prefills together and looks
  unusually bad; the end is cut mid-request. Neither is steady state.

Matrix:
- Legs in order: **FP8, BF16, GPTQ, AWQ.** FP8 is already served after the
  pilot - one model swap saved.
- Primary shape 1024/256, ladder **1, 2, 4, 8, 16, 32, 64** (PROVISIONAL until
  the pilot). Doubling covers single-user to saturation in 7 points; top 64
  stays under BF16's estimated ~120-request KV capacity, so no leg preempts.
- Measured time per point: **c=1 300 s (~80 req), c=2 180 s (~100), c=4..64
  120 s (130+)** - so low-rung p95 does not rest on ~2 requests.
- **Second shape 3072/128 on 1, 4, 16, 32**, run on each leg while it is
  already served (no extra swaps). Shows the prefill-vs-decode split between
  weight-only INT4 and FP8 W8A8 that one balanced shape blurs. Ladder stops at
  32: 3200 tokens x 128 KiB = 400 MiB per request, BF16 fits ~48.
- **Anchor: FP8, primary shape, c=16, re-run last.** Mid-ladder, below the
  likely knee, so run-to-run noise should be lowest.

Seed ranges (implementation call, recorded because it protects A1's claim):
primary points 42..48, second-shape points 142..145, leg warmup 942. Faker
seeded identically yields the same opening text regardless of requested
length, so sharing seeds between shapes would let a 3072-token prompt hit the
cache of an earlier 1024-token prompt's prefix. Separate ranges prevent that.

Time budget (ESTIMATES; swap uses session 3's FP8 14 s copy + 42 s engine
init, BF16's 15 GiB copy never timed):
- Per leg: swap ~3-4 min, warmup ~1.5, primary 18 measured + ~5 overhead,
  second shape 8 measured + ~3 overhead -> ~38 min. x4 -> ~2 h 30 min.
- Anchor repeat (swap back + one point): ~7 min.
- Rest of session (start, verify, snapshot, shakedown, pilot, ladder): ~40 min.
- **Session ~3 h 20 min, ~EUR 5.** Over the original 2.5-3 h plan by choice:
  the second shape costs ~40 min / ~EUR 1 and is the most likely finding.

## 2026-10-03 - Week 4 Phase A, A3: what gets captured - SETTLED

Read from the running engine (`/metrics` of the qwen-0-5b pod via the API
server proxy, 592 lines) and from a real GuideLLM 0.7.4 probe run against it
(64/16 tokens, c=2, 30 s). Both dumps in `docs/evidence/week-4/`; the probe
JSON doubles as the A6 parser fixture.

**vLLM 0.29 metric names (CPU build; the Phase B shakedown re-checks on GPU):**
- Gauges, sampled every 2 s during a point, recorded as mean + max:
  `vllm:num_requests_running` (mean = observed batch size),
  `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc`.
- Counters, snapshot before/after each point, recorded as the delta:
  `vllm:num_preemptions_total`, `vllm:prefix_cache_hits_total`,
  `vllm:prefix_cache_queries_total`, `vllm:prompt_tokens_total`,
  `vllm:generation_tokens_total`.
- Histograms, snapshot before/after, delta = server-side cross-check of
  GuideLLM's client-side numbers: `vllm:time_to_first_token_seconds`,
  `vllm:inter_token_latency_seconds`, `vllm:request_queue_time_seconds`,
  `vllm:request_prefill_time_seconds`, `vllm:request_decode_time_seconds`,
  `vllm:request_prompt_tokens`. Prefill/decode time is the direct view of the
  second shape's INT4-vs-FP8 question.
- `vllm:cache_config_info` once per leg into the sidecar: exact
  `kv_cache_size_tokens` (replaces the A1 KV estimates), `block_size`,
  `enable_prefix_caching`, `cache_dtype` (proves KV dtype is identical per leg).
- Limitation: GuideLLM excludes a point's edges; server counters cannot, so
  server-side deltas include them. For preemptions this errs strict.

**Comparability rules (agreed).** A point is flagged NOT COMPARABLE - kept in
the raw results, marked, and stated in the report - if:
1. `num_preemptions_total` delta > 0 (KV thrash);
2. `num_requests_waiting` > 0 for most of the point (a scheduler limit such as
   max-num-seqs is binding, not the model; this also answers from data whether
   max-num-seqs ever binds);
3. prefix cache hit rate > 5% (the A1 seed scheme leaked; only the shared
   chat-template header should hit).

**GuideLLM 0.7.4 output, as actually written:**
- Working invocation: `guidellm run --backend kind=openai_http,target=...,model=...
  --tokenizer kind=hf_auto,model=<HF repo> --data kind=synthetic_text,...
  --seed kind=static,value=N --profile kind=concurrent,streams=N
  --constraint kind=max_duration,seconds=N --output kind=json,path=...`.
  Tokenizer also takes `load_kwargs` (incl. `revision`) - used in A5 to pin it.
- JSON: `benchmarks[].metrics.<metric>.{successful,errored,incomplete,total}`
  each with `mean, median, count, percentiles{p50,p95,p99,...}`. Metrics used:
  `time_to_first_token_ms`, `inter_token_latency_ms`, `time_per_output_token_ms`,
  `request_latency`, `output_tokens_per_second`, `requests_per_second`,
  `request_concurrency`, `request_totals`.
- Per-request records kept (`requests.successful[]`, with start/end times), so
  any statistic can be recomputed from the raw file.
- `metadata` carries `guidellm_version` and `python_version` - two sidecar
  fields for free.
- Requests cut off by the time limit land in `incomplete` and are excluded
  from `successful` stats (probe: 11 successful, 1 incomplete).

**Two A1 checks already answered by the probe:**
- Every request reported prompt 93 = 64 synthetic + 29 chat-template tokens
  (Qwen's default system prompt), output exactly 16. So the decode/re-encode
  round-trip held, and output length is enforced. Report the prompt as
  "1024 synthetic + template" with the measured server-side total; the Llama
  3.1 template also embeds today's date, so a sweep crossing midnight UTC can
  shift it by a token - check the per-request counts.
- Probe TTFT: median 785 ms, p95 11,754 ms. The first requests paid one-time
  compile cost, and with 11 requests p95 is effectively the slowest one. A live
  demonstration of why the per-leg warmup and the low-rung durations exist.

## 2026-10-03 - Week 4 Phase A, A4 (part 1): scheduler limits PINNED

`--max-num-seqs=256 --max-num-batched-tokens=2048` added to the GPU runtime's
controlled-variables block (and mirrored on the kind CPU runtime so the A7
dry-run proves they reach the generated pod spec).

- Why pin: vLLM 0.29.0 picks these itself when unset but does not report the
  choice - not in the engine's startup config line, not in `/metrics`
  (`cache_config_info` has no scheduler fields). Unset, the sidecar could not
  record them and a vLLM upgrade could change them silently.
- Why these values: they ARE vLLM 0.29.0's defaults for this card, read from
  `vllm/engine/arg_utils.py:get_batch_defaults` inside the running pod:
  device memory < 70 GiB (L40S = 46 GiB), OPENAI_API_SERVER -> 2048 / 256.
  (>= 70 GiB non-A100 -> 8192 / 1024; >= 160 GiB -> 16384 / 1024.) So the
  results describe an untuned deployment, now with the values written down.
  Read from the CPU image's copy of 0.29.0; moot once pinned.
- Rejected: tuning to 8192 (likely more throughput at high concurrency, worse
  inter-token latency; makes the results "our tuned config" and the design
  rule is to hold the scheduler, not tune it). Rejected: leaving unset
  (unrecordable).
- Effect to state in the report: 2048 tokens per step means a 1024-token
  prompt prefills in one step and a 3072-token prompt is chunked over two;
  at high concurrency prompts share the budget, which raises TTFT.
- Verified on kind: ClusterServingRuntime re-applied, qwen ISVC deleted and
  re-created, generated pod args show both flags, `verify.sh` all green.
  (Ready took 219 s on CPU - irrelevant to GPU timings.)

## 2026-10-03 - Week 4 Phase A, A4 (part 2): `scripts/sidecar.sh`

Bash + jq, four subcommands: `session` (once per session: GPU identity,
k8s version, gpu-stack, repo commit, client Python + GuideLLM), `leg` (once
per leg after Ready: model repo + HF revision via variants.sh, vLLM version
from `/version`, image + digest + GENERATED args from the pod, KV capacity /
dtype / prefix caching / memory utilisation from `cache_config_info`,
storage-initializer copy time and pod-created-to-Ready time), `gpu-sample`
(nvidia-smi every 2 s into a CSV, run in the background during a point) and
`gpu-summary` (mean/min/max per column).

Field convention: value | `n/a:<why>` (absent by design) | `ERROR:<what>`
(collection failed). A7 gate: no `ERROR:` anywhere. A failed field never makes
the script exit non-zero - an unattended sweep must not die on a missing
field; the gap must be visible in the file.

Tested on kind: all fields populated, GPU fields `n/a:no GPU on kind`, no
ERROR; leg timings storage_copy 12 s, created-to-Ready 218 s. Summary maths
checked against a hand-made CSV (incl. an `[N/A]` row, skipped). Negative
test: a missing ISVC yields 13 visible ERROR fields and exit 0.
NOT yet exercised: the nvidia-smi paths (session GPU row, gpu-sample) - first
run is the Phase B shakedown (step 5). shellcheck not installed; not run.
Repo commit on the laptop gets a `-dirty` suffix if the tree has uncommitted
changes; on the VM it comes from `.deployed-commit`.

## 2026-10-03 - Week 4 Phase A, A5 (part 1): harness design + sweep configs

**Correction to the plan: `Recreate` does not keep the legs apart.** It
replaces pods WITHIN one InferenceService. Each leg is its own ISVC (own
Deployment), so applying leg 2 while leg 1 exists asks for a second GPU and
the new pod sits Pending forever. The harness therefore DELETES the previous
leg's ISVC and waits for its pod to be gone before applying the next. That is
also the only moment the disk preflight is meaningful (the old leg's emptyDir
is freed only then). `Recreate` stays on the manifests; the harness does not
rely on it.

**Decided: fresh pod for every leg, FP8 included** (reverses A2's "reuse the
pilot-served FP8 pod"). All four legs get an identical lifecycle - created,
Ready, warmup, measured - so leg 1 cannot differ by having served 10-15 min of
open-loop pilot traffic. Cost: one extra swap, ~3-4 min, ~EUR 0.09.

Lifecycle per leg: skip if DONE (resume) -> partial dir moved aside to
`<leg>.failed-<time>` -> delete ISVC, wait pod gone -> disk preflight
(free < size + 3 GiB STOPS the run) -> render ISVC from the proven base
manifest (only name + storageUri change) and apply -> wait Ready (timeout =
leg failed, continue to next leg) -> leg sidecar -> warmup -> primary ladder
-> shape-2 ladder -> DONE. Then the anchor, same lifecycle, one point. Exit
non-zero if any leg failed; a re-run redoes only failed legs.

Configs: `benchmarks/configs/sweep-gpu.sh` (the measured sweep, A1/A2 values)
and `sweep-kind.sh` (A7 dry-run: two legs both deploying qwen-0-5b so swap,
preflight, resume and anchor paths run; tiny ladders; shape 2 = 1536/16
because the CPU runtime caps max-model-len at 2048). Checked: every GPU leg
resolves to its pinned revision in variants.sh; seeds 42..48 / 142..145,
anchor c=16 -> seed 46; tokenizer revision == variants.sh BF16 pin.
Tokenizer on GPU: BF16 repo at the pinned SHA, loaded OFFLINE from the VM's
HF cache (never deleted by the disk fallback).

## 2026-10-03 - Week 4 Phase A, A5 (part 2): `scripts/benchmark.sh`

The unattended harness, implementing the part-1 lifecycle. Facts read from the
installed GuideLLM before writing it:
- Every `--option` accepts a full JSON object as well as `key=value`
  (`utils/click_pydantic.py`). The harness builds each option with `jq -nc`:
  quoting-safe, and the only form that carries nested settings.
- Per-point edge exclusion works: profile `warmup:{value:20,mode:"duration"}`,
  `cooldown:{value:10,...}`. Probe (5/5 of 30 s): `warmup_duration` 5.0,
  `cooldown_duration` 5.0, `duration` 20.0, and 0 incomplete requests (the
  earlier probe without cooldown had 1).
- Tokenizer revision pin: `load_kwargs:{revision:...}` is applied AND recorded
  in GuideLLM's own results config, so each result file says which tokenizer
  revision made its prompts.

Guards, all tested on kind: config for the wrong platform -> exit 2 before
creating anything; any required config variable missing -> exit 2 naming it;
GPU config without a pinned tokenizer revision -> exit 2; a resumed run whose
config differs from the frozen `config.sh` -> exit 2; a second harness on the
same run dir -> exit 2 (flock); disk preflight short -> exit 3, whole run.

Per point: `point.json` (workload, seed, tokenizer, times, exit, request
counts, status), `guidellm.json` + `.log`, `metrics-before/after.txt` (full
`/metrics`; deltas computed in A6), `gauges.csv` (running / waiting / KV every
2 s), `gpu.csv` + `gpu-summary.json`. A point is `ok` only if GuideLLM exited 0
AND at least one request succeeded (a run where every request errors also
exits 0). Each invocation writes its own `env-session-<time>.json`; if a
resumed run spans more than one GPU UUID the log warns.

Building blocks tested as the real function text extracted from the script:
seed mapping (c=16 -> 46, c=64 -> 48, missing c caught); disk read from the
kind node's /var/lib/kubelet (where the emptyDir lands), impossible request
refused; ISVC render (qwen render == base manifest, live apply "unchanged";
BF16 render changes only name + storageUri, not `name: vLLM`); gauge parsing
on live metrics. shellcheck clean. NOT yet run end to end - that is A7.
Lesson twice today: a comment LINE starting with the linter's own name is
parsed as a directive. Reword, don't wrap there.

## 2026-10-03 - Week 4 Phase A, A7: dry-run on kind - gate items 1-3 PASSED

**Run 1, `a7-kind-1` (stopped, kept as evidence).** Leg 1's warmup failed
correctly: GuideLLM exited 0 with 0 successful requests, and the harness's
"exit 0 AND >= 1 success" rule marked it failed, kept the evidence
(`failure.txt`) and moved on to leg 2. Cause: the FIRST request on a fresh CPU
pod took ~64 s to first token (one-time compile) and the kind warmup window
was 30 s. Not a harness bug - kind config undersized. Stopped by killing the
harness's process group (setsid leader, found via the run lock with `fuser`).
`sweep-kind.sh`: warmup 20 -> 120 s, points 40 -> 90 s (`56311ec`). The frozen
config made the old run id unresumable, as designed: new run id.

**Run 2, `a7-kind-2`: COMPLETE, exit 0, unattended, 30 min.** Two legs and the
anchor, each on a fresh pod (Ready 120-121 s on CPU); 12 points all `ok`, every
point with its 8 files, every leg with env-leg.json + rendered isvc.yaml +
DONE, one session record, frozen config.sh. **No `ERROR:` field anywhere.**
Every `n/a:` is a designed kind case (no GPU, image entrypoint, qwen not a
benchmark leg, unpinned kind tokenizer). Raw run committed as evidence and as
the A6 parser's input.

Findings:
- **Shape 2 needs no warmup of its own.** First 1536-token request TTFT
  3.8 s, in line with the rest: the ~64-67 s compile is once per engine, not
  per prompt length (on CPU). Check the same on the GPU from the first leg's
  per-request records (first shape-2 request vs the rest).
- **Server-side prompt counts correct:** 1053 = 1024 + 29 and 1565 = 1536 + 29
  (Qwen chat template). A1 carry-forward closed for kind.
- **Gauges** move once warm (running peaks at 2 at c=2). In run 1 they stayed
  0 through the stuck first step: consistent with vLLM updating them when a
  scheduler step COMPLETES. So a gauge can lag by up to one step - matters
  only for very long steps.
- **The pinned 2048-token budget is visible:** at c=2 TTFTs alternate
  ~2.5 s / ~5.5 s - two 1053-token prompts (2106) exceed one step's budget,
  so one waits for part of the other's prefill.
- **Results size, for Phase C:** GuideLLM keeps ~10 KB per request. The GPU
  sweep will complete thousands of requests at high concurrency, so expect
  ~10+ MB per high-c point and ~100+ MB per sweep. Raw results are still
  committed; Phase C may need to compress them (GitHub refuses files > 100 MB).

Remaining for the A7 gate: item 4, "the parser reads them" = A6.

## 2026-10-03 - Week 4 Phase A, A6: `scripts/parse_results.py` - and A7 PASSED

One run directory -> `results.csv`, one row per MEASURED point (warmups
excluded, anchor labelled `is_anchor`), 49 columns. Standard library only.
It also CHECKS the run and exits 1 on any problem: a sidecar field
`ERROR:...`, a missing point file, a leg without DONE, a leg directory
without env-leg.json (died before Ready), a point whose comparability cannot
be judged. Exit 0 only for a clean run.

Definitions, checked against GuideLLM's own console output on a7-kind-2:
latency columns from COMPLETED requests (`successful`), throughput from ALL
requests (`total`) - GuideLLM's own split. Units in column names (TTFT/ITL
are ms in the JSON, end-to-end latency is s). Gauge stats use only readings
inside the MEASURED window (`benchmarks[0].start_time..end_time`, after the
edges are cut). Counter/histogram values are before/after deltas (include the
edges; noted in A3). vLLM's `kv_cache_usage_perc` is a FRACTION despite the
name (1053 tokens / 349,440 = 0.0030, matches) -> x100.

A3 rules, thresholds in one place: preemptions > 0; waiting > 0 in MORE than
50% of the window's gauge readings (agreed today; the raw `waiting_pct` is in
the CSV so it can be re-judged); prefix cache hit rate > 5%.

Tests: a7-kind-2 -> 9 points, exit 0, every column filled except the four GPU
columns (empty on kind, correct). a7-kind-1 -> exit 1, both legs reported
(qwen-a no DONE; qwen-b never reached Ready - the parser first ignored this
silently; fixed). Injected `ERROR:` field -> exit 1 naming file and field.

What the dry-run data already shows:
- Anchor vs original (qwen-a, c=2): TTFT p50 5026 vs 4998 ms, output 8.4 vs
  8.7 tok/s - within ~1-4% even on CPU. The drift check works.
- Server-side mean prompt tokens 1053 / 1565 on every point (vLLM histogram):
  A1's prompt-length carry-forward closed from the server's side.
- CAVEAT for the GPU: `batch_mean` is 0.5 at c=1 (expected ~1). Same gauge
  lag as A7: vLLM updates gauges when a scheduler step completes, and a CPU
  prefill step takes ~2.5 s. GPU steps are milliseconds, so it should vanish.
  **Shakedown check (Phase B step 5): batch_mean at c=1 ~= 1.**

**A7 GATE PASSED:** completed unattended (exit 0), every file written, the
parser reads them (exit 0), every sidecar field populated (no `ERROR:`).
**Phase A is complete. The GPU boot is unblocked.**

## 2026-10-03 - Week 4 Phase B prep: the open-loop pilot (step 6) - script built and tested on kind

Step 6 had no script: `benchmark.sh` runs closed loop only. Built
`scripts/pilot.sh` + `benchmarks/configs/pilot-gpu.sh` / `pilot-kind.sh`.
It runs against an ISVC that is already Ready and creates or deletes nothing.
Per rate: Poisson arrivals -> gauges sampled -> drain to empty -> one summary
row. Early stop after 2 saturated rates in a row. Seeds 542.. (outside 42-48,
142-145, 942). GPU rates 1,2,4,6,8,10,12,16 req/s, 90 s each after a 15 s
excluded ramp - an ESTIMATE bracketing the guessed knee (~3.6 s per request
alone in session 1), not a measurement.

**GuideLLM 0.7.4 bug: Poisson arrivals with >1 worker are not Poisson.**
`AsyncPoissonStrategy.next_request_time` creates its `random.Random(seed)`
lazily in EACH worker process, all with the same seed, while the time offset
is shared. With the default 10 workers every gap repeats exactly 10 times
(pilot-kind-1: 3.275 s x10, 0.884 s x10, ...). The long-run mean is right,
but a 50 s window rests on 2-3 random draws: "0.2 req/s" sent 28 requests,
"0.5 req/s" sent 10. `constant` is unaffected (one shared request index).
Closed loop (`concurrent`) is unaffected (no randomness).
**Decided: the pilot runs ONE worker (`GUIDELLM__MAX_WORKER_PROCESSES=1`)**
for true Poisson, chosen over `constant` because real traffic is bursty and
the KEDA question is whether the signal survives bursts. pilot-kind-1 is kept
as the evidence.

**Risk of one worker, and the checks.** One Python process sends, holds every
in-flight stream and timestamps every token. Overloaded, it sends late (the
offered rate silently drops) and stamps late (TTFT/ITL inflate) - both look
exactly like GPU saturation. Mitigation in three layers:
1. `scripts/client-capacity.sh` (laptop, free): the one-worker client against
   `guidellm mock-server` with KNOWN timing (TTFT 50 ms, ITL 15 ms, 256 tok),
   so any excess is the client's own error. capacity-laptop-1:
   8/16/24/32 req/s -> send-lag p95 5/14/23/10 ms, 0 sends >100 ms at <=16,
   14 of 1498 at 24, 5 of 1899 at 32 (isolated); delivered within Poisson
   noise; ITL +0.6-1 ms. **PASS to 2x the pilot's top rate.** TTFT reads
   ~+10 ms at EVERY rate - a fixed per-request overhead (localhost HTTP + the
   mock), not load; vLLM's server-side TTFT histogram is the cross-check.
   Worker CPU sat at ~90-97% at every rate including 8, so CPU% is NOT a load
   indicator for GuideLLM (busy event loop); recorded, not judged.
   0.7.4's mock-server crashes with `--processor` (loads via the abstract
   `PreTrainedTokenizer`); run it without, its MockTokenizer is fine here.
   Laptop result; the VM's CPU differs, so layer 2 stays as the guard.
2. Send lag per rate (`request_start - targeted_start`, measured window):
   p95 > 100 ms -> `client_limited=1`, not used for the knee.
3. Server-side arrival count, independent of the client (below).

**vLLM behaviour found on the way (kind, vLLM 0.29 CPU; confirm on GPU):**
- **It aborts requests when the client disconnects, queued ones included.**
  Controlled test: 16 running + 11 waiting at GuideLLM's cut-off -> 0/0 by the
  next engine log line. So the drain between rates is abort cleanup (seconds),
  not a backlog being worked off.
- **Aborted requests are counted nowhere in `/metrics`**:
  `request_success_total{finished_reason="abort"}` stayed 0. vLLM 0.29 has no
  "requests received" metric. So layer 3 counts `POST /v1/chat/completions`
  lines in the pod's ACCESS LOG since the rate began: 49 sent = 49 logged.
  The GPU runtime does not disable the access log (session-3 pod log has them).
- **`kubectl logs -l <selector>` returns only the last 10 lines per pod** by
  default, silently. Cost an hour of misreading. Always use the pod name.

**Finding: the backlog builds in `running`, not `waiting` - waiting is LATE.**
pilot-kind-2/3, rate 2: delivered 1.82 req/s, completed 1.0-1.4, running
climbing 0 -> 29-33, **waiting 0 the whole time**. vLLM keeps ADMITTING new
requests into the batch while it has room (max-num-seqs 256, KV nearly
empty), so overload shows as a growing batch and slower requests. Waiting
rose only at rate 4, once running reached ~60 (likely the 2048-token per-step
budget; not proven). On the GPU the same mechanism suggests waiting stays 0
until KV (~160 requests at 1280 tokens) or max-num-seqs binds - well past the
latency knee. **If the GPU confirms it, KEDA on `num_requests_waiting` alone
scales late; `num_requests_running` or KV usage is the earlier signal.** This
is the week 5 question the pilot exists to answer.

**Saturation rule revised (agreed).** First version: waiting > 0 in >50% of
readings AND completions < 90% of offered. It missed rate 2 (saturated, but
waiting 0) and was circular - the pilot TESTS whether waiting tracks
saturation, so waiting cannot define it. **Now: saturated = completions in
the window < 90% of requests DELIVERED in the window** (delivered, not
nominal: Poisson noise moves it ~10% at low rates). Gauges are observed:
waiting/running mean, max, % > 0, and least-squares SLOPES (req/s; positive
= backlog building). Check on kind rate 4: running + waiting slopes 3.3/s vs
delivered - completed 3.6/s - two independent views agree.

Smaller facts:
- Above saturation GuideLLM may report NO latency: it computes TTFT only for
  requests SENT inside the measured window, and none of those completed
  (kind rate 4: 10 successful, all sent during the warmup). Written as `NA`,
  never 0. Completion rate is the meaningful number there.
- `requests_per_second.successful.mean` is not completions / time (0.42 at
  0.2 offered). Completions are counted from the per-request records instead.
- Gauge period is ~1.3 s, not the configured 1 s: each kubectl scrape takes
  ~0.3-0.4 s. Recorded per rate as `gauge_period_s`.
- Low-rate send lag: ~1 send in 20-40 goes out 50-90 ms late at ANY rate,
  mostly after long idle gaps (process wake-up or GC). At 0.2-0.5 req/s on
  kind (7-14 sends in window) p95 is effectively the max, so it reads 84-88 ms;
  at 1 req/s p95 was 6 ms. Not client load. On the GPU the lowest rate gives
  ~90 sends, so p95 ignores one-offs; the 100 ms limit stays.
- gawk reserves `compl` (bitwise complement) - it broke a variable name.

Evidence: `benchmarks/results/pilot-kind-1` (the seed bug), `pilot-kind-3`
(final script: rates 0.2-2 ok, 2 and 4 saturated, early stop fired, arrivals
match within 1, no client-limited rate), `capacity-laptop-1`. pilot-kind-2
not kept (first rate broken by the gawk bug, old saturation rule; its finding
reproduced in -3).

## 2026-10-03 - Week 4 Phase B prep: VM-side prerequisites (gap 2) - checked on the laptop

The harness assumes three things on the VM that A7 (kind) never exercised.
All answered for free; what remains is `scripts/preflight-vm.sh`, run once at
Phase B step 2 right after `verify-gpu.sh` is green (~1 min, stops at the
first failure).

**1. Tokenizer loads OFFLINE at the pinned revision.** `stage-models.sh`
used `hf download --revision <sha>` WITHOUT `--local-dir`, so session 3 put
BF16 in the standard HF cache: `/root/.cache/huggingface/hub/models--meta-llama
--Llama-3.1-8B-Instruct/snapshots/0e9e39f2...` (session-3 stage-models.out),
on the root volume. GuideLLM's `hf_auto` is a plain
`AutoTokenizer.from_pretrained(repo, revision=sha)`. Laptop test, throwaway
`HF_HOME`: online into an empty cache transformers fetches exactly FOUR files
(`tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`,
`config.json`); then offline, fresh process, no token, GuideLLM's own loader:
vocab 128256. Negative control: offline with a wrong revision FAILS - no
silent fallback, so a pass proves the pinned revision was used.

**2. uv provisions Python 3.13 + the locked venv.** Session 3 (2026-09-27)
predates the `.python-version` 3.13 and GuideLLM pins (2026-09-28), so the
VM's `.venv` is Python 3.14.7 without GuideLLM: the first sync rebuilds it.
Cold rehearsal on the laptop: `git archive HEAD` into /tmp, empty
`UV_CACHE_DIR` + `UV_PYTHON_INSTALL_DIR`, `UV_PYTHON_PREFERENCE=only-managed`
-> `uv sync --locked` exit 0 in 27 s, Python 3.13.15, GuideLLM 0.7.4, torch
2.14.0+cpu, 1.4 GB total (inside the 21 GiB disk threshold's "GuideLLM
install"). Same uv 0.12.13 on the VM -> same 3.13.15. The preflight syncs
explicitly instead of trusting the first `uv run` to notice the mismatch.

**3. Predictor ClusterIP reachable from the VM.** Already proven in session
3: `verify-gpu.sh` runs ON the VM and reached `llama-fp8-predictor` by
ClusterIP:port exactly as `target_url` does (/v1/models, a chat completion
"OK", /metrics). It re-runs every session at step 2.

**Found on the way: one more path never run on the VM** - the harness and the
pilot read /metrics through the API-SERVER PROXY
(`kubectl get --raw .../pods/<pod>:8080/proxy/metrics`), proven on kind only.
If it failed on k3s every gauge would be empty. Added to the preflight.

`scripts/preflight-vm.sh <sweep-config> <isvc>` - tokenizer repo/revision
come from the SAME config the harness reads. Checks: (1) sync + Python 3.13.x
+ GuideLLM == uv.lock; (2) the four files in the pinned snapshot + offline
load via GuideLLM's loader, no token; (3) proxy /metrics has
num_requests_waiting + running; (4) access log: count POST lines, send ONE
request, count again, must rise by exactly 1 (the pilot's layer-3 method,
tested directly). Tested on kind: kind config PASS; Llama @ pin offline from
the throwaway cache PASS; wrong revision FAILS at the file check (exit 1).

## 2026-10-03 - Week 4 Phase B prep: shakedown config (gap 3)

Phase B step 5 ("one leg, one point") had no config: benchmark.sh only runs
whole sweeps, and `sweep-gpu.sh` would start the full ~2.5 h sweep.
`benchmarks/configs/shakedown-gpu.sh` SOURCES `sweep-gpu.sh` and overrides
only: LEGS = FP8 (the sweep's own line), PRIMARY_LADDER=(1), SHAPE2_LADDER=(1),
ANCHOR_C=1 (the anchor must be a ladder point), measured_s = 60 s. Everything
else is literally the sweep's, so the rehearsal proves the real config.
Static check: both configs loaded in clean subshells, all 26 harness
variables + measured_s dumped and diffed - exactly those five differ; seeds
42 / 142 = the sweep's c=1 seeds. (First attempt compared two EMPTY dumps and
showed "no differences"; the check now refuses an incomplete dump.)
benchmark.sh always runs the anchor and has no switch to skip it; not adding
one, to keep the A7-gated harness unchanged. Cost ~5 min / ~EUR 0.12, and it
runs the anchor path on the GPU for the first time. Shakedown total est.
~15 min, ~EUR 0.37. It gives the step 5 checks: files + parser on real
hardware, nvidia-smi sidecar values, batch_mean at c=1 ~= 1, first shape-2
request TTFT vs the rest.
