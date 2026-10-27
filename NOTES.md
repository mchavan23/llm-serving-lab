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

## 2026-10-03 - Week 4 Phase B, GPU session 4: steps 1-7 (pre-sweep) and the ladder decision

Boot 16:34:02Z (`scw instance server start --wait`), meter t0 16:34:26Z
(`session.sh start`). GPU `GPU-38ec497c-fd4c-5675-4b13-5c06df440881`, serial
1324123012145, driver 580.126.20, 350 W limit, max SM 2520 MHz. Kernel
**6.8.0-142-generic** (sessions 1-3: -106; packages updated between sessions,
driver unchanged). Snapshot: `benchmarks/results/session-4-boot/env-session.json`
(no ERROR fields). The VM runs `ae70fee`; this NOTES entry is committed after it
and changes no code the sweep runs.

**Step 1 findings.** `session.sh start` does NOT boot the VM - it refuses unless
the API already says `running`; boot is `scw ... server start --wait` first. The
log's compute EUR therefore misses ~25 s of boot (billing API covers it). Its
SSH-rule path ran live for the first time: home IP had changed, rule moved
`.193/32 -> .223/32`, re-check matched.

**Step 2 findings.**
- Re-ship guarded by checksumming all 49 VM files against `4cd054f` (all
  matched), so overwriting lost nothing. `s3-sa`/`s3-creds` created; the FP8 pod
  re-rolled on `s3-sa` and its storage-initializer pulled from S3 in 15 s; only
  then were `minio-sa`/`minio-s3-creds` deleted (reverse of the plan's order:
  old path kept until the new one was proven).
- **Recipe gap:** the VM's `.env` is host-specific. `stage-models.sh:58` had
  pointed `S3_ENDPOINT` at the SeaweedFS ClusterIP; re-sending the laptop `.env`
  put back `localhost:9000` (kind NodePort) and `verify-gpu.sh` section 6 failed.
  Fixed with the same sed (`http://10.43.61.45:8333`). KServe never reads `.env`
  (endpoint is on the Secret), so serving was unaffected. Fix the recipe in Phase C.
- **Stale pod:** a session-3 predictor pod sat `Failed / UnexpectedAdmissionError`
  for 6 days ("Allocate failed due to no healthy devices present": kubelet
  re-admitted it at boot before the device plugin registered the GPU). Failed
  pods are never garbage-collected. Hazard: every script picks the pod with
  `-l serving.kserve.io/inferenceservice=<isvc>` + `.items[0]` (name order); the
  live pod sorted first only by luck. Deleted (YAML kept as evidence outside the
  repo). Phase C: select the Running, non-terminating pod.
- `verify-gpu.sh` all green; `preflight-vm.sh` all five checks passed (venv
  3.13.15 + GuideLLM 0.7.4 = uv.lock; tokenizer files at pin `0e9e39f2` and
  OFFLINE load, vocab 128256; /metrics via API-server proxy; access log +1 per
  request).

**Step 4: disk, fallback NOT triggered.** 21.63 GiB free with FP8 served
(threshold 21.00). Breakdown confirmed: containerd 31, SeaweedFS PV 34.6, FP8
emptyDir 8.5, staging 35 GiB. (`du` on /var/lib/kubelet/pods showed 43 GiB:
the SeaweedFS PV counted twice through its bind mount - `findmnt` shows the
source.) BF16 peak estimate: 21.63 + 8.47 - 14.97 = ~15.1 GiB free. The
harness's own guard saw 30.29 free vs 11.47 needed after deleting FP8.

**Step 5: shakedown `shakedown-1` - all checks PASS.** Unattended, 12.6 min,
parser exit 0, 3 points all comparable, no ERROR.
- nvidia-smi sidecar paths: real values (50 samples per point).
- `batch_mean` at c=1 = **1.0** (kind 0.5 was CPU gauge lag, gone on GPU).
  Shape 2 at c=1 reads 0.89: idle gaps between ~2 s requests, not batching.
- First shape-2 request TTFT 211.1 ms vs median 211.3 of the other 43: the
  compile cost is per engine, paid in the leg warmup. No shape-2 warmup needed.
- Anchor repeat (fresh pod) vs original, c=1: TTFT p50 72.9 vs 74.0 ms,
  server TTFT 69.9 vs 70.2 ms (~1.5%). Drift check works on GPU.
- Server prompt tokens 1058 / 3106 = synthetic + 34 (Llama 3.1 template).
  Prefix hit 3.0% / 1.0% = 34/1058, 34/3106: only the template header hits.
- Fresh FP8 pod Ready after 121 s, twice.
- SM clock dips (min 1935 / 1650 / 2265 MHz; means 2507 / 2424 / 2514) at
  ~250 of 350 W. Probably idle moments at c=1. Phase C: locate them in time.

**Step 6: open-loop pilot `pilot-gpu-1` (FP8) - the reason for the ladder,
NOT an independent result.** client_limited 0 at every rate (lag p95 <= 5.7 ms);
arrivals_match 1 at every rate (rate 8: 883 sent / 882 logged, within 1 -
likely the last send aborted at cut-off). Early stop after rates 6 and 8.

| offered | delivered | completed | TTFT p50/p95 ms | running mean/max | waiting mean/max |
|---|---|---|---|---|---|
| 1 | 0.96 | 0.96 | 95 / 131 | 4.0 / 8 | 0 / 0 |
| 2 | 2.05 | 2.08 | 103 / 167 | 10.1 / 23 | 0 / 0 |
| 4 | 3.58 | 3.43 | 115 / 221 | 22.0 / 36 | 0 / 0 |
| 6 | 6.21 | 5.51 SAT | 245 / 490 | 91.4 / 116 | 0.06 / 2 |
| 8 | 8.36 | 4.49 SAT | 10836 / 16090 | 173.2 / 183 | 135 / 286 |

- **Knee:** FP8 saturates between 4 and 6 req/s; max sustained ~5.5 req/s
  (~1,400 output tok/s at 1024/256).
- **KEDA answer: `num_requests_waiting` is a LATE signal on the GPU too
  (confirms kind).** Saturated at rate 6 (TTFT p95 ~4x baseline, running
  +0.48/s) while waiting averaged 0.06. Waiting rose only at rate 8, once
  running reached ~180 = KV cache full (~205k tokens), by which point TTFT p50
  was 10.8 s. vLLM admits into the running batch until KV memory runs out.
  Week 5 should scale on `num_requests_running` (or KV usage), not waiting alone.
- Phase C: completions FELL 5.5 -> 4.5 req/s past KV saturation - consistent
  with preemption thrash; confirm from the pilot's metrics files.

**Step 7: closed-loop ladder DECIDED - keep 1, 2, 4, 8, 16, 32, 64 (Option A,
Manoj).** Reasoning: by Little's law (in flight = throughput x latency) the
engine held ~22 in flight unsaturated at rate 4 and was saturated before ~90 in
flight at rate 6, so c=16 sits below the knee, 32 near it, 64 on or near the
plateau - the provisional ladder already brackets the knee. Its top stays under
FP8's KV capacity (~160 full-length requests) and BF16's estimate (~120);
96/128 would likely preempt on BF16 and break comparability at the top.
Rejected: adding c=48 (+~11 min, edits sweep-gpu.sh after the shakedown and
shifts c=64's seed). Second shape (1, 4, 16, 32) and anchor (FP8 c=16)
unchanged. **`sweep-gpu.sh` is unchanged from `ae70fee`.**

## 2026-10-04 - Week 4 Phase B steps 8-11 and Phase C: the measured sweep

**Sweep `sweep-gpu-1`** (steps 8-9, one invocation, config `sweep-gpu.sh` at
`ae70fee`, unchanged): 17:54:08Z -> COMPLETE 20:28:33Z (2 h 34 min,
unattended). 4 legs x 11 points + anchor, **every point ok, no re-runs**, one
GPU UUID (`...0881`) throughout. Parser: 45 points, 0 not comparable.
**Steps 10-11:** 495 files pulled, byte-identical by SHA-256; `session.sh end`
powered off via the API and confirmed `stopped` before its first-ever billing
read. Session 5.37 h, EUR 7.89 (estimate EUR 5): ~77 min (~EUR 1.90) was the
VM idle after COMPLETE, waiting for a check-in. The billing line's "project
total EUR 26.57" double-counts: the API already included ~EUR 7.57 of this
session (11.11 -> 18.68), so the real total is ~EUR 19.

**Raw data: plan B.** `guidellm.json` (60 files, 260 MiB) is no longer
committed. It is published as Release `results-session-4`
(asset SHA-256 `a620cfa3...0ea6`, deterministic tar.xz, 59.1 MiB, verified by
re-downloading) with a per-file manifest in the repo
(`benchmarks/results/RAW-DATA.md`, `session-4-guidellm.sha256`). Found while
committing: the scratch `*.log` rule had swallowed every run log since the kind
runs; now un-ignored under `benchmarks/results/` (96 logs). Secret-value scan of
all tracked files clean. Open: the 26 kind-run `guidellm.json` files (60 MB) are
still in history - decide before the week-6 public flip whether to rewrite.

### Sanity checks

**1. Curve shape - passes, with a qualification.** Throughput rises on every
leg; latency (ITL, e2e) rises with concurrency on every leg. Gain c=32 -> 64:
GPTQ +13.5%, AWQ +12.5% (flattening), FP8 +31%, BF16 +38% (still climbing).
c=64 is near saturation for 4-bit; FP8's 1,445 tok/s matches the pilot's
open-loop limit (~1,400); **BF16's true maximum is above what was measured**.
Wording: "throughput at c=64", not "max throughput", for BF16.
Shape-2 4-bit TTFT p50 714 ms at c=4 vs 589 at c=16: likely closed-loop
lockstep (same-length requests finishing and re-arriving together, prefills
queueing). The only waiting>0 points are the same c=4 points (max 1). Not
investigated further.

Output tok/s, primary 1024/256 (c = 1, 2, 4, 8, 16, 32, 64):
- BF16  46, 87, 166, 307, 531, 812, 1121
- FP8   69, 134, 252, 454, 752, 1104, 1445
- GPTQ  118, 222, 398, 665, 974, 1244, 1412
- AWQ   124, 232, 415, 686, 996, 1264, 1422

**Crossover:** at low load 4-bit wins (c=1 AWQ 124 vs FP8 69 tok/s, ITL 7.8
vs 14.2 ms: single-stream decode is weight-read bound, 4-bit weights are
smallest). At c=64 FP8 overtakes (compute-bound; FP8 native on L40S tensor
cores, W4A16 unpacks weights). GPTQ vs AWQ within 1-4% everywhere (same Marlin
kernels, as predicted).

**2. Card constant - passes.** Anchor (FP8 c=16, fresh pod, 2 h 13 min later)
vs original: tok/s +0.1%, TTFT p50/p95 -0.4/-0.6%, ITL 0.0%, server decode
-0.1%, SM clock +0.5%. **No performance drift.** The SM clock is NOT flat: it
falls with load in every leg (~2,500 MHz at c=1 to ~2,000-2,180 at c=64,
~1,760-1,850 shape-2 c=32) as power rises to 310-334 W of the 350 W limit,
and recovers at each leg's c=1 - boost management tracking workload, not time.
(Correction: in session I guessed the c=1 dips were idle moments; they are not.)
**Heat soak:** c=1 max temp rose 70/72/73/76 C over FP8/BF16/GPTQ/AWQ, c=1
clock 2510/2514/2486/2474 MHz - later legs ~1-1.5% slower at equal load. Same
size as the GPTQ-AWQ gap, and AWQ ran last: **GPTQ and AWQ are equal within
measurement error; claim neither as faster.**

**3. Sidecars and flags - pass.** 50 point dirs, identical 8-file set, zero
`ERROR:`. Same vLLM 0.29.0 image (`...dacd72c51ae1`), gmu 0.8, pinned
revisions. Zero preemptions on 45 points; KV peak 66% (BF16 shape-2 c=32).
Prefix hit 3.0% / 1.0% everywhere = the 34-token template header.
KV capacity measured: BF16 154,176 / FP8 205,856 / GPTQ 232,464 / AWQ 232,768
tokens (~120 / 160 / 181 / 181 full 1,280-token requests; BF16 estimate of
~120 was right).
**Cold start:** storage copy BF16 24 s / FP8 15 / GPTQ 10 / AWQ 9, but
pod-created -> Ready = 120-121 s for every leg. That uniformity is almost
certainly the readiness-probe schedule, not vLLM (step 2 log: "startup
complete" ~95 s after container start). Claim: **cold start <= 120 s, of which
copy 9-24 s**; true engine time not recoverable (pods gone). Matters for week 5
scale-to-zero.

### First-pass cost per 1M output tokens (approved method)

EUR 1.494/h all-in running (compute 1.46988 billed + 150 GB SBS 0.0195 +
IPv4 0.005, reconciled rates); throughput at c=64, primary shape; denominator
output tokens (each also carries 4 input tokens at 1024/256); idle time as a
utilisation factor.

| model | tok/s | 100% | 50% | 25% | 10% |
|---|---|---|---|---|---|
| BF16 (upper bound) | 1,121 | 0.370 | 0.740 | 1.48 | 3.70 |
| FP8 | 1,445 | 0.287 | 0.575 | 1.15 | 2.87 |
| GPTQ | 1,412 | 0.294 | 0.588 | 1.18 | 2.94 |
| AWQ | 1,422 | 0.292 | 0.584 | 1.17 | 2.92 |

- Utilisation moves cost 10x across the range; quantisation ~22%. The
  operational lever (keep busy / scale to zero) dominates the format choice.
- Quantised ~20-22% cheaper than BF16 at full load (upper bound on BF16's gap).
  FP8/GPTQ/AWQ equal within error (~2.5% spread).
- Valid only at c=64 latency: TTFT p95 0.58-0.76 s, per-user ~18-24 tok/s
  (ITL 42-55 ms). Every cost figure in the report must carry its latency.

### Recipe fixes for the next GPU session (DONE 2026-10-04 - see "Week 5 A0" below)

1. Step 2: after re-sending `.env`, re-apply the VM `S3_ENDPOINT` (ClusterIP).
2. Step 1 wording: boot is `scw ... start --wait`, then `session.sh start`.
3. Pod selection: every script uses `.items[0]` by label; select the Running,
   non-terminating pod. After any reboot, check for `UnexpectedAdmissionError`.
4. Sidecar: record kernel version; record vLLM's own startup timestamps.
5. `session.sh end`: say when the billing API already includes the session.
6. Polling: `pgrep -x benchmark.sh` never matches (env re-execs bash) - use
   `ps ... | grep '[b]enchmark.sh'`.

**Session 4 closed. Week 4 Phase C complete.**

## 2026-10-04 - Week 5 A0: recipe fixes + auto-teardown watcher (laptop, free)

### The six recipe fixes
- **3. Pod selection.** New `scripts/lib-pods.sh` (sourced). `live_pods` = phase
  Running AND no `deletionTimestamp` AND Ready=True (jq: jsonpath cannot test that
  a field is absent; a Terminating pod still reports phase Running).
  `one_live_pod` returns a name only if EXACTLY one pod is live, else the count and
  `pod_report` (phase / reason / ready / terminating) on stderr - which is also the
  post-reboot `UnexpectedAdmissionError` check. Used by `pod_of` in benchmark.sh and
  pilot.sh, sidecar.sh `leg`, preflight-vm.sh, and the SeaweedFS + runtimeClass
  checks in verify.sh / verify-gpu.sh. **Two live pods fails on purpose**: reading
  one of two replicas makes the other look idle; all-replica sampling is A4 harness
  work. Tested on kind: 1 pod, 0 pods, 2 pods (CoreDNS). Failed + Terminating pods
  sorted ahead of the live one tested with STUB pod JSON only - first real test at
  the next GPU reboot.
- **6. Polling.** New `scripts/run-alive.sh <results-dir>`: RUNNING / STOPPED from
  the run's flock; exit 2 if `.lock` is missing (flock would create one and say
  STOPPED). Cause of the old failure verified: a `#!/usr/bin/env bash` script runs
  as process `bash`, so `pgrep -x benchmark.sh` never matches. The lock stays held
  while ANY child lives, so an orphaned GuideLLM still counts as running. Chosen
  over `ps | grep '[b]enchmark.sh'`, which matches any process naming the file and
  misses orphans.
- **4. Sidecar.** Session record gains `kernel`. Leg record gains `startup`
  (container_started_at, model_loaded_at, model_load_s, engine_init_done_at,
  engine_init_s, compile_s, api_ready_at, pod_ready_at) from
  `kubectl logs --timestamps` + pod status, and `timings_s` gains
  `container_start_to_api_ready` and `api_ready_to_pod_ready`. Whole seconds (jq's
  `fromdateiso8601` rejects fractions). kind: pod created -> Ready 120 s =
  **98 s vLLM + 16 s probe lag** (+6 s copy) - the split session 4 could not
  recover. Parse checked against session-4 GPU log lines (41.79 s init,
  26.58 s compile, 4.79 s load). CPU build: `compile_s` n/a.
- **5. Billing wording.** `session.sh start` stores the billed total as the state
  line's third field. `end` adds only the part of this session's compute the
  billing API has not counted yet (growth since start minus storage + IPv4
  accrual) and prints which case applied. Session-4-shaped numbers: 19.12 whether
  the API caught up fully, partly or not at all (old method: 27.01). Pre-fix state
  files fall back to the old upper bound, labelled. Errs LOW if a non-compute
  charge appears mid-session; the printed basis makes that checkable. Arithmetic
  tested in isolation; the API path first runs in session 5.
- **1. S3_ENDPOINT.** Recipe line in week 5 Phase B step 2. Not scripted: a ship
  script cannot be tested without a GPU boot.
- **2. Boot wording.** Already correct in week 5 Phase B step 1.

### Auto-teardown watcher
`scripts/teardown-watch.sh --max-hours H [--run RUN_ID] [--poll S]`, laptop-side,
detached. Calls `session.sh end` when the run's lock frees (COMPLETE, INCOMPLETE or
crash - the status line goes into the session-log note) or at the ceiling. Pulls
the run's results first (10 min cap; a failure loses nothing - the VM root volume
survives power-off). Every ssh call time-boxed at 60 s. Retries `end` 3x, then logs
GAVE UP. One watcher at a time: a new one replaces the old (arm ceiling-only at
boot, re-arm with `--run` later). Log `.teardown-watch.log`, gitignored.
- **Why on the laptop:** Scaleway docs (checked 2026-10-04): an OS-level `poweroff`
  puts the Instance in STANDBY, billed as running. Only the API power-off pauses
  compute billing, and the API key exists only on the laptop.
- **WSL survives being left alone:** a detached heartbeat ran unbroken for 3.5 min
  with nothing on Windows talking to WSL. **NOT tested: Windows sleep.** The laptop
  must not sleep during a session.
- Tested against a fake VM (local dir, `bash -c` for ssh, echo for `end`):
  COMPLETE, INCOMPLETE (not mistaken for COMPLETE), ceiling, closed elsewhere,
  replacement, refusal without a session. Real ssh / scw path first runs in
  session 5.
- **Contract for A4:** the step-load harness must hold `<results-dir>/.lock` like
  benchmark.sh, or the watcher can only use the ceiling.

### Found, deferred to A1
`session.sh` hard-codes `RATE_GPU_HOUR=1.47` (L40S-1-48G). On L40S-2-48G every
cost line and the EUR 60 kill check would read HALF the compute spend. Set it per
instance (`.session.env`) as part of the instance change.

## 2026-10-04 - Week 5 A1: the two-GPU node (laptop, free)

### Type change in place: supported
`scw instance server get-compatible-types` for the stopped `L40S-1-48G` lists
`L40S-2-48G` (16 vCPU, 2 GPU, 192 GiB, EUR 2.93982/h), `available` in fr-par-2
(L40S-4/-8 in `shortage`). Docs' conditions met: stopped, no placement group. The
150 GB SBS root volume `llm-serving-lab-system` stays attached (the CLI reports it
under `Volumes`, capital V - `.volumes` is null). Procedure: stopped ->
`scw instance server update <id> zone=fr-par-2 commercial-type=L40S-2-48G` -> start.
**Not done now, on purpose:** done as session 5's first action. `available` is not
a reservation (stock is only tested at boot), the instance bills only while
running, and the boot after the change IS A5's cold-path measurement onto an
existing platform. Reversible while stopped. Rebuild via `setup-gpu.sh` only if
the change fails.

### Single-GPU assumptions found and fixed
- `verify-gpu.sh`: allocatable had to be `= 1` (FAILs on 2) -> must equal the GPUs
  the host sees. Name/driver were checked on GPU 0 only (`head -1`) -> every row.
  New optional `EXPECTED_GPU_COUNT` (the host cannot know what the type should
  have; set 2 in session 5 to catch a card that failed to appear). Recreate check
  kept, reason corrected: a rollout deadlocks whenever every GPU is in use; KEDA
  changing replicas does not go through the strategy.
- `sidecar.sh session`: recorded GPU 0 only -> adds `gpu_count` and `gpus[]`
  (index, uuid, name, serial, driver, power limit, max SM clock). `gpu` kept as
  GPU 0 because `parse_results.py` reads it.
- Fine as they were: `setup-gpu.sh` (allocatable `!= 0`, smoke pods request 1 GPU),
  ServingRuntime (`--tensor-parallel-size=1`, 1 GPU per replica = replica scaling).
- Tested on a fake 2-GPU host (shimmed `nvidia-smi` / `kubectl`): 2 good GPUs pass;
  allocatable 1 vs host 2 fails; one wrong card fails ("2 of 3 match").
- **Known break, deferred to A4:** `gpu-sample` / `gpu-summary` average all GPUs
  together - on two GPUs an idle card dilutes a busy one. Needs a per-GPU summary,
  which changes the parser's input; A4 redesigns the harness for two replicas.

### Compute rate from the API
`session.sh` no longer has a rate constant. `start` reads the instance's current
`commercial_type` and its `hourly_price` from the API (live: `L40S-1-48G 1.46988`)
and stores type + rate in the state line; `status` and `end` use it, and each
session-log row now carries `[type @ rate/h]`. If the lookup fails at `start` the
session still opens (warns; `RATE_GPU_HOUR` in `.session.env` is a fallback) -
refusing would leave a running instance that `end` and the watcher cannot close.
`cost-model.md` gains the L40S-2-48G row.

### Interface names
None hard-coded in the repo; k3s config sets only `default-runtime`. Residual risk
outside the repo: the VM's cloud-init network config. Same instance family, so
low; checkable only by booting. Fallback: Scaleway web console, or revert the type.

## 2026-10-25 - Week 5 A2: KServe 0.20 + KEDA, verified from source (laptop, free)

Sources: KServe `v0.20.0` (`1fb7810`) and KEDA `v2.21.0` (`626ded5`), shallow
clones under `~/src/`. Every claim below cites a file.

### KServe side
- **Opt-in:** ISVC annotation `serving.kserve.io/autoscalerClass: keda`.
  `autoscaler_reconciler.go:91-96` picks exactly ONE reconciler per class; `keda`
  gets `KedaReconciler` and no KServe HPA.
- **What it generates** (`keda_reconciler.go:187-278`): one ScaledObject named like
  the predictor Deployment, `scaleTargetRef` = that Deployment, min/max from the
  predictor's `minReplicas`/`maxReplicas`. Triggers from
  `spec.predictor.autoScaling.metrics`; type `External` + backend `prometheus`
  maps `serverAddress`/`query`/`target.value` to KEDA's `serverAddress`/`query`/
  `threshold` (115-145). No `metricType` set. Stabilisation windows from the
  ISVC's `autoScaling.behavior`, else the `autoscaler` key of
  `inferenceservice-config` - live on kind: **up 0 s, down 300 s**.
  `pollingInterval`/`cooldownPeriod` are not settable through KServe.
- **Who owns `replicas`:** `deployment_reconciler.go:170-171` sets it only for
  class `none`; 257-258 and 476-480 ignore and STRIP it from the patch for every
  other class ("to avoid the conflict between HPA and Deployment"). With `keda`,
  KEDA's HPA is the only writer. Predicted failure mode retired.
- **Install order:** the KEDA CRD check runs once, in `SetupWithManager`
  (`controller.go:634`, called from `cmd/manager/main.go`). Without the CRDs KServe
  runs and skips the ScaledObject watch. **Install KEDA, then restart
  `kserve-controller-manager`**, or KServe creates ScaledObjects but never watches
  them.

### KEDA side
- **Version: v2.21.0** (2026-09-23). KEDA's own matrix: 2.21 = Kubernetes
  1.34-1.36, the only release tested on our 1.36 (kind `v1.36.4`, k3s
  `v1.36.4+k3s1`). KServe compiles against 2.18 (EOL, tested to 1.33); the
  `keda.sh/v1alpha1` ScaledObject fields KServe writes all exist in 2.21 - A7
  proves it on kind. Breaking changes in 2.21 (scaler token auth, Temporal) do
  not touch us. Note for verify scripts: ScaledObject HPA health moved from
  `Ready` to a new `HPAActive` condition. Install from the release asset
  `keda-2.21.0.yaml`.
- **metrics-server:** not needed. KEDA serves `external.metrics.k8s.io`;
  metrics-server serves `metrics.k8s.io`. Only ONE provider may hold
  `external.metrics.k8s.io` (KEDA docs, Cluster page) - the KEDA install step
  must refuse if another APIService already does (guard, both clusters).
- **Target type:** `scaler.go:105-107` - no `metricType` -> `AverageValue`, so
  the HPA computes replicas = ceil(query result / threshold). **The Prometheus
  query must return the TOTAL across pods.**
- **What sets the 1->2 decision delay:** with `minReplicaCount >= 1` and no
  cached metrics, `IsPollingIntervalRelevant()` is false
  (`scaledobject_types.go:304-318`): KEDA's 30 s `pollingInterval` plays no part.
  The HPA drives scaling; on each HPA sync KEDA queries Prometheus LIVE
  (`scale_handler.go:853-859`, no `useCachedMetrics` from KServe). 2.21's #8031
  lets KEDA's own loop reuse those HPA observations instead of re-querying
  (799-802). So: **detection delay ~ Prometheus scrape interval + up to one HPA
  sync (Kubernetes default 15 s)**, then pod start (~98 s vLLM + probe lag, A0).
  Confirm the 15 s on both clusters (`--horizontal-pod-autoscaler-sync-period`)
  in the install checks.

### Budget check-in (2026-10-25)
Billed EUR 31.72 of 60, up from ~19 on 2026-10-04: all standing cost while
stopped (EUR 0.588/day x 21 days = 12.35; disk + IPv4). Projected end ~EUR 53-55
- margin ~EUR 5-7, below one failed two-GPU session. Decision: no infra change
(IP release or disk snapshot save little and add risk before a paid session);
reduce idle days instead.

## 2026-10-25 - Week 5 A3 decision: scaling metric and threshold (Manoj)

**Decision (Manoj): scale on `sum(vllm:num_requests_running)`, threshold = 24 per
replica** (KEDA trigger `threshold: "24"`; HPA AverageValue -> replicas =
ceil(total / 24), acting above ~26.4 because of the HPA's 10% tolerance).

Evidence: session-4 pilot `pilot-gpu-1` gauges (FP8, 1 GPU, 1024/256, 90 s/rate):

| offered | state | TTFT p95 | running mean/max | KV mean/max |
|---|---|---|---|---|
| 1 | healthy | 131 ms | 3.5 / 8 | 2% / 5% |
| 2 | healthy | 167 ms | 8.6 / 23 | 5% / 13% |
| 4 | healthy | 221 ms | 19.6 / 36 | 11% / 20% |
| 6 | saturated | 490 ms | 75.7 / 116 | 43% / 65% |
| 8 | collapsed | 16 s | 144.5 / 183 | 81% / 100% |

Reasoning:
- **running over KV:** equivalent here (KV ~= running / 180, fixed lengths); running
  is in plain units and ties to latency via Little's law; a KV threshold would be
  ~13%. Known limit: with mixed request lengths KV weights long prompts, running
  does not.
- **The threshold is a SETPOINT, not an alarm.** The HPA drives each pod toward
  the target. A high value (40-60, between "healthy" and "saturated") oscillates:
  6 req/s on 2 replicas = ~14 running each = 28 total, ceil(28/50) = 1 -> scale
  down after 300 s -> saturate -> scale up, ~7 min period. With 24: 4 req/s on 1
  replica stays 1 (~20); 6 req/s on 1 scales up (>26.4); 6 req/s on 2 holds 2
  (ceil(28/24) = 2); 4 req/s on 2 scales back down (ceil(17/24) = 1).

Fragilities, stated in advance:
- Thin margin at 4 req/s: mean ~20 vs trigger ~26.4, samples to 36 - the query's
  smoothing window carries this (set in A3 implementation).
- A load band (~4.5-5 req/s) oscillates for ANY threshold: 1 replica slightly too
  few, 2 too many. The 300 s scale-down window slows it, does not stop it. A4 must
  place the load steps deliberately: avoid the band, or show it as a finding.
- ~14 running per pod at 3 req/s is INTERPOLATED (rates 2 and 4 measured). The
  session-5 shakedown checks it before the paid measurement runs.

## 2026-10-25 - Week 5 A3: metrics pipeline, smoothing, probe, constants (laptop, free)

### Prometheus (`manifests/prometheus.yaml`)
v3.15.0 pinned by digest (v3.15.1 was 4 days old - under the 2-week rule). ONE
job: vLLM predictor pods in `llm-serving`, every 5 s; Role (not ClusterRole) for
pod discovery; emptyDir, 2-day retention (feeds KEDA, not a record). The runtime
declares no containerPort, so relabelling builds `<pod IP>:8080`. `promtool`
(checksum-verified, same release) passes. On kind: target `up`, query returns
data. **Freshness measured with `timestamp()` through a port-forward: newest
sample 0-5 s old (mean ~2.5).** KEDA `serverAddress`:
`http://prometheus.monitoring.svc:9090`.

**Measurement trap found:** through the API-server proxy, Prometheus appeared
~25 s behind the pod. It was the proxy: CPU vLLM saturates the laptop and proxy
calls stall. Scrapes never failed (5-10 ms, `up` = 1) and stored data was on
time. Rule: on kind under load, read Prometheus through a port-forward.

### Smoothing window: 45 s
Replayed `pilot-gpu-1` raw gauges (4 req/s then 6 req/s back to back) through
rolling means; trigger 26.4 (24 x 1.1):

| window | max at 4 req/s (false-trigger margin) | 4 -> 6 step crosses after |
|---|---|---|
| 15 s | 29.4 (would false-trigger) | 20.2 s |
| 30 s | 26.1 (+0.3) | 28.1 s |
| **45 s** | **24.5 (+1.9)** | **28.1 s** |
| 60 s | 23.8 (+2.6) | 31.5 s |

45 s: as fast as 30 s, six times the margin. Query:
`sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="<isvc>"}[45s]))`.

### Startup probe: 30 s -> 5 s (both runtimes)
Session 4's uniform "120 s to Ready" was the probe grid (first check 30 s, then
every 30 s), not vLLM. Now `periodSeconds: 5`, `failureThreshold` x6 (same
grace: GPU 20 min, CPU 30 min), `timeoutSeconds: 4`. **Measured on kind:
`api_ready_to_pod_ready` 16 s -> 3 s.**

### qwen ISVC on kind: Recreate
Applying the probe change left the new pod Pending ("Insufficient cpu": 8-CPU
node, qwen requests 4, the old pod still held 4) - kind's ISVC used the default
RollingUpdate. Now `deploymentStrategy: Recreate`, as on the GPU ISVCs.
**A6 risk:** min 1 / max 2 on kind needs two 4-CPU replicas on that node next
to Prometheus, SeaweedFS and the control plane - the second will not fit. A6
must lower qwen's CPU request for the dry run.

### Sidecar caveat (found in this restart)
`engine_init_done_at` (06:59:23) came AFTER `api_ready_at` (06:59:04) - the
EngineCore subprocess's stdout is buffered, so the kubelet timestamp marks when
the line ARRIVED. Use `engine_init_s` (vLLM's own duration) and `api_ready_at`
(APIServer, matched the probe within 3 s); do not use `engine_init_done_at` as a
point in time. Engine init on kind varied 59 s -> 96 s between restarts.

### Constants
`benchmarks/scaling-constants.md`: every time-to-relief stage with value, basis
and knob. kind: no `--horizontal-pod-autoscaler-sync-period` override (15 s);
k3s to confirm in session 5. Expected GPU time-to-relief ~2.2-2.5 min + model
copy. Scale-down when total <= 24 (not 21.6 - corrected while writing).

## 2026-10-25 - Week 5 A4 decision: step height and cycles (Manoj)

**Decision (Manoj): two cycles of 3 -> 6 req/s are the main result; an optional
third cycle of 3 -> 8 req/s runs LAST and is the first thing cut if session 5
runs long.** FP8, open loop, 1024/256, as week 4.

Facts it was decided on (pilot-gpu-1, 90 s per rate; A3 constants):
- One replica: healthy to 4 req/s, saturates ~5.5. Two replicas: ~11.
- Relief arrives ~2.2-2.5 min after the step (A3 budget) - longer than any
  pilot hold, so whether 6 req/s stays "degraded" that long is unmeasured.
- 3 -> 6: ~10% over one replica's capacity; a queue builds slowly; most likely
  degrades without collapsing - measures the scale-out mechanics.
- 3 -> 8: one replica collapses within seconds (KV full, completions fall to
  4.5 in the pilot); relief then includes draining the backlog - the worst case.
  Run last so a collapsed replica cannot contaminate the main cycles.
- Neither level is in the ~4.5-5 req/s oscillation band; 3 req/s on 2 replicas
  (~14 running each, interpolated - shakedown checks it) totals > 24 only
  briefly, so scale-down is reached. 6 on 2 replicas (~28 total) holds 2.
- Cost: ~19 min per cycle at EUR 2.94/h = ~EUR 0.93; two EUR 1.86, three
  EUR 2.79, against a ~EUR 5-7 margin.

Design calls made with it (A4, explained in the A4 entry when built):
- One seeded Poisson trace per cycle, run by GuideLLM 0.7.4's `replay` profile
  (verified on kind: one invocation, two stages, sends within 7 ms of schedule
  after the first request; prompts distinct; same chat-template overhead as
  week 4's synthetic data). One run per cycle: a crash loses one cycle; the gap
  between runs falls in baseline with one replica, nothing measured there.
- Cycle: 3 req/s 180 s -> step 480 s -> 3 req/s 480 s (scale-down needs ~6 min:
  300 s window + 45 s smoothing + 15 s sync). Precondition per cycle: exactly
  one pod Ready.
- Time-to-relief: step -> TTFT p95 (30 s windows, by send time) back within
  1.5x the baseline p95 and staying there for 60 s; stages timestamped.

## 2026-10-25 - Week 5 A4: step-load harness and parser built

Decision record: "Week 5 A4 decision" above (`03aff2f`). Built in four pieces,
each tested on kind before the next.

**1. `scripts/make_trace.py`** (`95dbdb3`) - seeded piecewise-Poisson trace for
GuideLLM 0.7.4's `replay` profile (`trace_synthetic` data: timestamp,
input_length, output_length per row) + `stages.json`, the stage table on
GuideLLM's clock. GuideLLM subtracts the first timestamp, so the script does the
same and shifts the boundaries with it. Main cycle (seed 1042): 523 / 2,934 /
1,406 requests, achieved 2.91 / 6.11 / 2.93 req/s; gaps mean 1/rate, CV
0.97-1.01; same seed byte-identical; GuideLLM's own loader reads it with the step
at 179.904 s.

**2. Per-GPU sampling** (`95dbdb3`, `sidecar.sh`) - A0/A1 contract. `gpu-sample`
rows carry GPU index + uuid, add utilization and memory, optional interval
(default 2000 ms unchanged). `gpu-summary` writes `gpus[]`, never averaged
across cards; the week-4 top-level fields are kept identical for one GPU (all 68
week-4 summaries reproduce exactly from raw gpu.csv) and become
`n/a:multi-gpu` for more, so parse_results.py leaves them empty. Untestable
here: real two-card nvidia-smi (standard field names; first use session 5).

**3. `scripts/step-load.sh` + `step-gpu.sh` / `step-gpu-collapse.sh`**
(`7578b1a`, threshold/step_stage in cycle.json in this commit). Mirrors
benchmark.sh: guards, frozen config, resume by run-id, COMPLETE/INCOMPLETE.
Holds `<results>/.lock` for its whole life (A0 contract). Per cycle: one
replica (one pod, live, Deployment 1, HPA desired 1; waits up to 600 s for the
previous scale-down) -> leg sidecar -> trace -> 1 s cluster timeline (HPA
desired/current/metric, Deployment, pods, ready endpoints) + per-GPU sampler ->
replay -> pod JSON + logs snapshot 30 s after the step-down -> Prometheus range
export (running, waiting, KV, success per pod; the ScaledObject's own query) +
namespace Events -> DONE. Design calls and why:
- **`Connection: close` on every request.** kube-proxy balances per connection;
  GuideLLM's httpx pool keeps idle connections 5 s, so a reused pool could keep
  all traffic on replica 1 after replica 2 is Ready. Measured on kind: without
  the header GuideLLM still opened a new connection per request (27/27) - cause
  not found in its code, so not relied on; the header makes it guaranteed. Cost:
  one in-cluster TCP connect per request. The parser checks the split.
- **Engine gauges from Prometheus after the cycle, not live polling**: it
  already scrapes every pod every 5 s, keeps a deleted pod's series, and avoids
  the API-server proxy that stalls under load on kind. 5 s = what KEDA sees.
- **Snapshot after the step-down**: replica 2 is deleted ~6 min later and its
  pod conditions + startup logs go with it.
- Discovery of the ScaledObject/HPA by what they scale (`<isvc>-predictor`),
  not by generated names. Prometheus: ClusterIP on GPU, port-forward on a port
  kubectl picks on kind (18080 was taken during testing).
Smoke tests on kind (no KEDA): 2 cycles COMPLETE, 98/94 requests, 0 errors;
lock held then released; no leftover processes; GuideLLM sent exactly the 53
high-stage requests stages.json lists; resume skips DONE; changed config, wrong
platform and a missing ScaledObject are refused (the last INCOMPLETE). Poller
first ticked 1.35 s (sleep after reads) - fixed to sleep the remainder: 1.007 s.
Findings: GuideLLM starts sending ~9 s after launch; the first 1-2 requests of a
cycle are sent up to 1.2 s late (client warm-up), then <= 31 ms.

**4. `scripts/parse_step.py`** - per cycle `step-summary.json` +
`timeline-5s.csv`; per run `step-summary.csv`. Clock: the step from GuideLLM's
own first scheduled request + stages.json, not the launch time. Baseline drops
its first 30 s (warm-up). **Relief refined** (my call): within 1.5x baseline is
trivially true right after the step, before a queue builds, so relief is
measured from a degradation: degraded = first 30 s window (by send time, every
5 s) above 1.5x baseline; relief = first window after that within 1.5x and
holding 60 s, all before the step-down. No degradation is reported as a result.
Stages after the step: KEDA query > threshold x 1.1, HPA rescale Event (and
timeline), replica 2 created / scheduled / model copy done / engine started /
Ready, in endpoints, first request in its access log. Also load share per pod
after Ready (access logs, cross-checked with the Prometheus counter), peak
damage, the step's last 120 s (clamped to the step), scale-down timing,
replica sequence (anything but 1 -> 2 -> 1 = oscillation), quality flags.
Tests: relief rule 5/5 synthetic cases (incl. a dip shorter than 60 s and a
recovery too late to hold). Real kind overload (1 -> 8 -> 1 req/s, 256/64, no
KEDA): degraded +5.3 s, no relief, peak 216x baseline, last-45 s 8.29 offered vs
0.07 completed; KEDA fields `n/a:<why>`; KEDA query 18.9 -> 53 while waiting
0 -> 155. Quality flag fired correctly: send lag p99 154 ms - qwen saturating the
laptop CPUs slows the client on the same machine (the GPU VM's client does not
share CPUs with the model).

**Not yet tested - A6/A7 on kind:** the scale-out path (HPA/ScaledObject fields,
two pods, rescale Events, load share, scale-down). `step-kind.sh` is written in
A6: its rates depend on qwen's capacity under KEDA on kind.

## 2026-10-25 - Week 5 A5 design: cold-path measurement

**What is on the VM at boot.** benchmark.sh deletes ISVCs only BEFORE each leg,
never after the final anchor leg, and no manual delete is recorded - so the FP8
anchor `llama-fp8` is most likely still deployed, and session 5's boot brings
the whole stack back on its own. Not verifiable without booting (rule: no GPU
boot before A7); the measurement handles both cases.

**Boots measured (my call; Manoj: "make the correct design call regardless" of
the margin).** Three boots, measured identically:
1. Session 5's first boot, right after the L40S-2-48G type change - reported,
   labelled "first boot after type change", NOT the typical number (possibly a
   different physical host, first boot with 2 GPUs, session-4 leftover platform).
2. + 3. Two deliberate API stop/start restarts at the END of session 5, onto the
   finished platform (Prometheus, KEDA, FP8 ISVC min 1) - the headline
   "stopped VM -> first token" figure. Two, because one sample cannot separate
   a typical restart from an unlucky one (admission race, slow SeaweedFS, copy
   re-run); a third adds little. Real stop/start via the API, not an in-VM
   reboot - that is the operation users run. ~15-20 billed min, ~EUR 0.75-1.00.
The restarts stay inside session 5's meter (slight overstatement while stopped -
the safe direction). The stop is timed too (`scw stop` -> API `stopped` = when
compute billing ends). Before building: check teardown-watch.sh cannot read a
planned stop as "session over".

**Stages, as seconds after `scw start`:** API running, SSH up (laptop polls,
2 s); kernel boot, k3s active (VM's systemd/kernel record); node Ready, GPU
device plugin Ready + allocatable, SeaweedFS Ready (Kubernetes condition
times); predictor scheduled -> storage-initializer done -> engine started ->
Ready (pod/container times); first token + TTFT of requests 1-3 (prober).

**Design calls:**
- Read timestamps the system already writes (Kubernetes, systemd, kernel) after
  everything is up; live only where nothing records it: API running and SSH
  (laptop), first token (prober).
- Prober is self-contained, sent over SSH: the VM runs session 4's code until
  step 2 re-ships the repo.
- Laptop (WSL) and VM clocks: offset measured over SSH and recorded.
- Session meter + teardown watcher armed as soon as the API says running.
- Recorded and flagged, not hidden: model copy re-run (8.47 GiB), init
  restarts while SeaweedFS starts, the admission race (Failed pod replaced).
- No ISVC at boot -> platform stages only, predictor stages n/a; step 5's KEDA
  deploy gives "apply -> first token" separately.

## 2026-10-25 - Week 5 A5 correction: every boot is its own session

Read teardown-watch.sh and session.sh before building (A5 build piece 1).
The design above ("restarts stay inside session 5's meter") is replaced:
- **Conflict:** Phase B step 7 re-arms the watcher with `--run` on the last
  step-load run, so it ends session 5 when that run stops - before restarts
  planned inside session 5.
- **Hazard:** with the VM stopped inside an open session, a ceiling hit runs
  `session.sh end` -> `scw ... stop` on a stopped instance; under `set -e` that
  likely errors before the session row is written, the watcher retries 3x and
  logs "MAY STILL BE BILLING" - a false alarm and a lost cost row. (Ceiling mode
  itself only reads the state file and the clock; `--run` mode only counts
  failed polls while the VM is down - neither would tear down wrongly.)
**Now:** `coldpath.sh` per boot: `scw start` -> `session.sh start` -> ceiling
watcher -> measure -> (restart boots) `session.sh end`, the stop timed to the
API's `stopped`. A VM is never stopped inside an open session, so session.sh and
the watcher keep their proven semantics; the step-7 watcher's end of session 5
becomes the stop before restart 1 (no idle billing waiting for Manoj); each
restart gets an exact session-log row (the overstatement note is void).
Phase B step 9 = after session 5 ends, `coldpath.sh` twice. Step 1's boot keeps
its session open for session 5 (ceiling 3.5 h).

## 2026-10-25 - Week 5 A5: cold-path tooling built

Design: "Week 5 A5 design" + "A5 correction" above (every boot its own session).
Phase B use: step 1 = `scripts/coldpath.sh --keep --label type-change` (replaces
the manual `scw start --wait` + `session.sh start` + ceiling watcher); step 9 =
after session 5 has ENDED, `scripts/coldpath.sh --end --label restart-1`, then
`--label restart-2`; then `parse_coldpath.py` over all three runs.

**`scripts/coldpath.sh`** (`bb78b5a`, laptop clock) - scw start -> API running
(2 s polls) -> session.sh start -> ceiling watcher -> SSH up -> clock offset
(best of 5 round trips) -> ship coldpath-vm.sh, prober detached -> wait
PROBE_DONE -> collect -> pull -> offset again -> --end: session.sh end, stop
timed. Safety: --end always ends the session it opened; a VM started without a
session is powered off by the script (no watcher could see it); status starts
"failed:incomplete" so no failure reads as success. Dry run with fakes (nothing
touched Scaleway): happy --end / --keep, no SSH, refusals (no results dir),
session.sh start failure (VM stopped), prober never done (still collected).

**`scripts/coldpath-vm.sh`** (`eb8a900`, VM clock, no repo files) - probe: k8s
API -> ISVC -> Service -> /v1/models -> 1-token NON-streamed completion every
1 s until 3 succeed (a streamed one would time the headers, which vLLM sends
before the first token). collect: boot epoch (now - uptime), systemd unit
times, GPUs, raw JSON of nodes/pods/ISVCs/events, predictor logs, k3s journal.
Tested on kind incl. a REAL predictor restart (pod deleted): created +0 s,
scheduled +5, copy +6..+17 (11 s), engine +18, Ready +155, first token +234 s;
first request 75.7 s (one-time compile, week 1 saw ~64 s), next 0.08 / 0.13 s.
Two bugs found and fixed: the /v1/models stage dropped its error count on
success; the prober slept 1 s after every advancing stage (up to 4 s of
artificial delay on a real boot). The kind scheduling delay (+5 s) is most
likely the new pod waiting for the old one's 4 CPUs - the A6 blocker, not GPU.

**`scripts/parse_coldpath.py`** (this commit) - per run coldpath-summary.json,
a comparison table across runs, optional CSV. Time 0 = `scw start`; VM times
moved onto the laptop clock with the mean measured offset (drift > 0.5 s or no
offset flagged); Kubernetes times earlier than this boot's kernel start are the
previous boot and never used. Critical-path segments (provisioning, OS + k3s,
node Ready -> scheduled, wait for copy, copy, engine start-up, first request)
plus "unattributed (milestone not observed)", so they ALWAYS add up to the time
to first token (first version silently lost 65 s when node Ready was missing).
Flags: offset, SSH upper bound, copy ran this boot, init restarts, admission
race (Failed predictor pod this boot), pod reused across the reboot, prober
status, allocatable != nvidia-smi GPUs. Tests on a fixture built from the real
kind restart: first token 333.6 s as constructed; a 5 s clock offset applied to
every VM-side time (incl. Kubernetes) is fully removed (no stage differs);
drift and admission-race flags fire; segments sum = first token in all four.

**Untestable before session 5:** real scw/SSH timing, k3s/ssh units, nvidia-smi
on the VM, the k3s journal; same calls as session.sh / the watcher / sidecar.

## 2026-10-25 - Week 5 A6: kind dry run (KEDA + qwen + step-load harness)

**Setup** (`86f5e51` + this commit). KEDA v2.21.0 (keda-2.21.0.yaml sha256
b43c89ff...f6d7), installed BEFORE restarting the KServe controller (A2); no
other external.metrics provider existed. KServe then logs an EventSource for
`*v1alpha1.ScaledObject`. `manifests/inferenceservice-qwen-keda.yaml` - KIND
ONLY; the week-2 `inferenceservice-qwen.yaml` stays the reference for the week-4
kind runs (the cluster now runs the KEDA one).
- Memory: one qwen as configured used 9.3 GiB (4 GiB CPU KV cache) of WSL's
  19.5; KV cache 1 GiB -> ~6.1 GiB/pod, two fit.
- **Thread pinning bug (found by measurement):** vLLM's CPU default ("auto")
  pins 7 OMP threads to cores 0-6 regardless of the CPU limit; against a 4-CPU
  quota it was throttled almost every period and 0.2 req/s completed NOTHING in
  90 s; both replicas would also share cores 0-6. Fix:
  VLLM_CPU_OMP_THREADS_BIND=nobind + OMP_NUM_THREADS = the limit.
- **KServe 0.20 trap:** for External metrics it reads ONLY `target.value` and
  writes threshold "0" if missing (keda_reconciler.go:124) - KEDA would scale to
  max at once. The manifest uses target {type: Value, value: ...}; verified in the
  generated ScaledObject. **Applies to the GPU manifest too.**
- Metric path verified: pod gauge -> Prometheus (<= one 5 s scrape) -> 45 s
  smoothing -> KEDA external metric -> HPA (KEDA <= one sync behind).
- A fresh pod's `running` gauge reads 0 while its first requests sit in the
  one-time compile (~60-75 s on kind): replica 2 under-reports for ~1 min after
  Ready (the week-5 predicted failure point, seen).
- Pod Ready can precede its Service endpoint: a warm-up sent at once failed in
  0.0007 s. Warm-ups now retry until HTTP 200 and check each pod's access log.

**Capacity** (pilot.sh; new `REPLICAS` setting, default 1 unchanged: gauges
summed across pods = the totals KEDA sees; drain and arrivals over all pods):
- a6-capacity-2 (4 cores, 1 replica): healthy to ~0.5 req/s, saturated 0.75.
- a6-capacity-3 (3 cores, 1 replica): healthy ~0.25 (running 0.9), saturated
  ~0.33, collapsing 0.54 (completions stuck at 0.31).
- a6-capacity-4 (3 cores each, 2 replicas): healthy to ~0.58 (running total
  6.7), near the limit 0.86 (18), collapsed 0.98 (0.30 completed). Replica 2
  adds ~1.3-1.6x - but each replica is slower when both are busy (TTFT p95
  2.9 s at 0.48 vs 1.3 s for one replica at 0.25).

**Runs** (step-load.sh + parse_step.py, one cycle each, 0 errors):
| | a6-step-kind-1 | a6-step-kind-2 |
|---|---|---|
| config | 0.25/0.6/0.25, threshold 3, 4 cores | 0.2/0.4/0.2 (step = 2x baseline, as GPU), threshold 1.25, 3 cores |
| metric crosses -> HPA decides | +39.6 -> +48.6 s | +25.8 -> +26.8 s |
| replica 2 created / copy done / Ready | +48.6 / +56.6 / +213.6 s | +26.8 / +32.8 / +172.8 s |
| first request on replica 2 | +216.9 s | +176.3 s |
| arrival split after Ready | 45 / 55 % | 44 / 56 % |
| relief (1.5x baseline TTFT p95) | n/a | n/a (end of step 4.4 s vs 2.0 s bound) |
| scale-down within the cycle | no (baseline on 2 hovered at threshold) | no (total 1.4-1.6 vs 1.25) |
| scale-down after the load stopped | yes, "All metrics below target" | yes, ~4 min after |
| client send lag p99 | 2.1 s (flagged) | 4.2 s (flagged) |
Run 1's threshold came from ONE-replica numbers only (my method error); run 2
re-tuned to 3 cores per replica (leaving 2 for client + Kubernetes) and derived
the threshold from one AND two replicas. Run 2 also met a real Poisson cluster
(0.55 req/s for 2 min in a 0.4 stage) - at kind's ~24 requests/min, +-40% per
minute is normal.

**Why kind cannot show relief (evidence, not tuning):** two replicas on this
laptop serve at TTFT p95 2.5-5.4 s even when healthy (run 2 after recovery;
a6-capacity-4 2.9 s at 0.48), one replica at baseline 1.35 s - so "within 1.5x
of baseline" is physically unreachable. 8 cores (Core Ultra 7 258V: 4
performance + 4 low-power, no hyper-threading) shared by two replicas, the load
generator, Prometheus, KEDA and the harness; replicas throttled 15-35 % of CPU
periods; the client itself sent 4 s late. On the GPU each replica has its own
card. Two re-tune attempts; a third would fight the same 8 cores.

**Relief code path on real data** (run 2, bound loosened as a CODE check only,
not a result): 3x -> degraded +167.6 s, relief +377.6 s; 4x -> +177.6 / +287.6 s;
consistent with the windowed series (TTFT p95 75 s at Ready -> ~4 s by +303 s);
1.5x correctly n/a. Parser fix from the runs: per-pod "requests" split into
arrivals (access log) and completions (counter) - a replica draining a backlog
completes more than arrives (run 1: 133 vs 200).

**A6 conclusion (Manoj, 2026-10-25: stop tuning kind, close A6 this way).**
Proven on real data: KEDA 1 -> 2 under load (twice), 2 -> 1 after the load
drops (twice), every stage recorded and cross-checked, the parser's stage
breakdown, load split, degradation, peak, quality flags and relief logic. First
seen on the GPU: relief by the real 1.5x definition and a scale-down INSIDE a
cycle - both kind hardware limits, both code paths tested.

## 2026-10-25 - Week 5 A7: gate PASSED (Manoj) - GPU boot cleared

Gate criteria (section 8 A7) against the A6 evidence (`a6-step-kind-1`, `-2`):
- KEDA 1 -> 2 under load: MET, twice (HPA decision 9 s / 1 s after the metric
  crossed; replica 2 Ready +214 / +173 s; arrival split ~45/55).
- 2 -> 1 after cooldown: MET, twice, after the load stopped. Scale-down INSIDE
  a cycle not shown (baseline on two replicas sat at the kind threshold).
- Harness records unattended: MET (step-load.sh: 1 s timeline, Prometheus
  export, Events, snapshots, .lock held/released, 0 errors).
- Parser produces time-to-relief: PARTLY - stage breakdown, split, degradation,
  peak from real data; relief at 1.5x is n/a on kind (hardware), logic proven
  on real windows with a loosened bound. Accepted when A6 was closed.
First seen on the GPU, by design: relief at 1.5x and in-cycle scale-down.

Checked at the gate: the ISVC's `target.type: Value` only tells KServe which
field holds the threshold. The generated HPA on kind is `type: AverageValue`,
`averageValue: 1.250` (ScaledObject sets no metricType; KEDA's default), so
replicas = ceil(total / threshold) as scaling-constants.md assumes. With Value
the HPA would compute currentReplicas x total / threshold and the scale-down
point at 2 replicas would halve.

Open before session 5 (laptop): FP8 KEDA manifest; a repo install script for
Prometheus + KEDA (pinned, one-provider guard, then KServe controller restart -
on kind both came from scratch scripts); Phase B text aligned with coldpath.sh /
the --run watcher; k3s HPA sync period as a named check.

## 2026-10-26 - Week 5 Phase B: GPU session 5 (L40S-2-48G) + restart-1 (repeat cycle) + restart-2

Sessions (billing API via session.sh): session 5 02:51:12-05:03:25Z, 2.19 h,
EUR 6.44; restart-1 05:07:43-05:34:46Z, 0.44 h, EUR 1.29 (cold path + repeat
cycle); restart-2 06:00-06:05Z, 0.07 h, EUR 0.21. **Project total EUR 40.43**
(kill limit EUR 60, unchanged). Instance stopped, still L40S-2-48G.

### What ran
- Type change L40S-1 -> L40S-2 (stopped), boot via `coldpath.sh --keep`.
- Step 2: VM repo `ae70fee` -> `521a5b5` (guard: 217 files byte-identical first).
  `.env` NOT re-sent: identical except `S3_ENDPOINT`, which on the VM already
  points at the SeaweedFS ClusterIP. `create-s3-secret.sh` not run: `s3-sa` /
  `s3-creds` exist since session 4 (the Phase B text still said minio -> s3).
  `verify-gpu.sh` with `EXPECTED_GPU_COUNT=2`: all checks passed.
- Env snapshot `session-5-boot/env-session.json` (on the VM only, see below):
  GPU0 `GPU-b661d192...` (serial 1324323007842), GPU1 `GPU-d80971ad...`
  (1324323011282), driver 580.126.20, 350 W, 2520 MHz, kernel 6.8.0-142, k3s
  v1.36.4. New physical cards vs session 4 (type change = new host).
- `install-autoscaling.sh`, first real k3s run: every check passed; **HPA sync
  period: no override -> 15 s default** (time-to-relief stage 4).
- `inferenceservice-llama-fp8-keda.yaml`: ScaledObject threshold "24", min 1 /
  max 2; HPA `AverageValue` 24; live metric read (ValidMetricFound). Ready 3 min
  after apply (Recreate).
- Shakedown `20261026T0325Z-step-gpu`, main `20261026T0401Z-step-gpu` (2 cycles),
  collapse `20261026T0440Z-step-gpu-collapse` (Manoj: run it), repeat
  `20261026T0513Z-step-gpu-repeat` on the restart-1 boot (Manoj), cold paths for
  all three boots.

### Bugs found on the GPU and fixed (all committed, pushed, shipped)
1. `521a5b5` coldpath.sh: `setsid nohup ... &` inside ssh's `bash -c` kept ssh's
   stdout open -> ssh waited out REMOTE_TIMEOUT (60 s) -> "failed:start prober"
   while the prober ran. Now `setsid -f`. Verified on the VM (old rc=124 after
   timeout, new rc=0 in 1 s). A5 had tested against a different remote.
   The type-change boot's VM records were collected and pulled by hand; they parse.
2. `16525e2` all three GPU step configs had `MODEL=llama-3.1-8b-fp8` (the S3
   name). vLLM serves the ISVC name `llama-fp8` -> every request 404, no load,
   KEDA 0/24. Run `20261026T0321Z-step-gpu` stopped after ~2.5 min (kept on the
   VM as the failed record). step-load.sh now checks MODEL against /v1/models and
   exits 2 before any load.
3. Watcher timing (operator error, mine): the decision on an extra cycle was asked
   while the `--run` watcher was armed on the collapse run; it ended session 5 at
   05:00:37Z before the answer arrived. Rule: when a decision could extend a
   session, re-arm ceiling-only FIRST (free, reversible), then ask.

### Step-response results (s after the 3 -> 6 req/s step)
| | shakedown* | main c1 (seed 1042) | repeat (seed 1042) |
|---|---|---|---|
| metric > 26.4 | 13.3 | 18.5 | 19.1 |
| HPA 1 -> 2 | 21.3 | 31.5 | 28.1 |
| model copy done | 36.3 | 46.5 | 42.1 |
| engine started | 37.3 | 48.5 | 44.1 |
| replica 2 Ready | 141.3 | 151.5 | 149.1 |
| first request on replica 2 | 141.9 | 152.7 | 149.2 |
| **relief** (TTFT p95 within 1.5x) | **180** | **245.1** | **260.1** |
| peak window TTFT p95 | 756 ms | 29.6 s | 28.0 s |
| split after Ready | 47.9/52.1 | 49.8/50.2 | 52.7/47.3 |
| end-of-step TTFT p95 | 182 ms | 180 ms | 185 ms |
| 2 -> 1 after step-down | n/a (not awaited) | 318.7 | 315.1 |
| errored / send lag p99 | 0 / 5.8 ms | 2 / 433.6 ms | 3 / 6.7 ms |
*shakedown: 3:120,6:300,3:60; its run dir is on the VM only.

- Same trace twice: every stage to Ready within 4.4 s, relief within 15 s (~6%),
  across a restart (possibly other physical cards).
- Dominant stage: engine start-up (~100-105 s from engine start to Ready), not the
  decision (~21-32 s) nor the copy (~15 s). Relief 3-4.3 min vs the 2.2-2.5 min
  estimate in scaling-constants.md (engine start was underestimated).
- The ~28-30 s TTFT peak is server-side backlog on one replica (~150 s at
  6 req/s), not client lag: the repeat had p99 send lag 6.7 ms and the same peak.
  Shakedown peak was far lower (shorter baseline, other seed): backlog size is
  trace-dependent.
- **Main cycle 2 (seed 1043) is not a step response**: its baseline trace ran at
  3.30 req/s, the summed running gauge reached 27.2 > 26.4 at 121 s, so KEDA
  scaled out 58 s BEFORE the step (replica 2 Ready 62 s after the step, "relief"
  66 s). Parser flagged it ("no rescale-up event after the step"). The 24
  threshold's headroom at a 3 req/s baseline is thin (cycle 1 max 19.4).
- Scale-down 2 -> 1 inside the 480 s low stage in every awaited cycle (315-328 s:
  300 s stabilisation + window). The shakedown's 2 -> 1 at 03:38:08Z (5 min after
  its load).
- Collapse (3 -> 8): HPA 12.4 s, Ready 133.4 s, **no relief** (not back within
  1.5x for 60 s before step-down; end-of-step TTFT p95 10.2 s; peak 348x). Two
  replicas do not carry 8 req/s. Scale-down 329.4 s.

### Errored requests: all at scale-down
2 + 11 + 3 + 9 (main c1, c2, repeat, collapse), all
`RemoteProtocolError: peer closed connection without sending complete message
body`. Every one started 1-5 s before replica 2 was marked deleting and all
ended together ~30 s after it (= terminationGracePeriodSeconds 30). So: requests
routed to the replica being removed are cut, not drained. Relief and scale-out
numbers are unaffected (errors are at the end of each cycle). Open for week 6:
graceful drain on scale-down (preStop delay + vLLM shutdown behaviour).

### Cold path (parse_coldpath.py, t0 = `scw start`)
| boot | first token | provisioning | copy | engine start-up | Ready -> token | unattributed |
|---|---|---|---|---|---|---|
| type-change | 253.1 s | 23.5 | 13.0 | 137.0 | 2.2 | 76.4 |
| restart-1 | 252.1 s | 25.4 | 13.0 | 137.0 | 2.0 | 73.7 |
| restart-2 | 255.8 s | 19.9 | 14.0 | 136.0 | 2.0 | 82.9 |
Consistent ~4.2 min. "node Ready" and "predictor scheduled" were not observed on
any boot, so OS + k3s + scheduling (~74-83 s) is unattributed, not lost - open
item for the parser/collector. The type-change boot parses from the salvaged VM
records (status keeps `failed:start prober`).

### Boot admission race: every boot
The predictor pod from the previous boot was rejected (`UnexpectedAdmissionError`,
"no healthy devices") on the type-change boot and on restart-1; a fresh pod came
up and served each time. Harmless for serving, but it breaks the harness's
"exactly one pod" precondition until the rejected pod is deleted (done by hand
before the repeat run). Recipe fix 3 is still open.

### Left on the VM (stopped; root volume keeps them)
`20261026T0325Z-step-gpu` (shakedown), `20261026T0321Z-step-gpu` (404 run),
`session-5-boot/` - pull at the next boot. Raw `guidellm.json` (200 MiB for the
three pulled runs) is not committed: Release asset per RAW-DATA.md.

## 2026-10-26 - Week 5 Phase C: time-to-relief broken down, cost note, exit criteria

Sources: committed `cycle-*/step-summary.json` of `20261026T0401Z-step-gpu`,
`20261026T0513Z-step-gpu-repeat`, `20261026T0440Z-step-gpu-collapse`; shakedown
numbers from its parse on the VM (run dir not yet pulled, see Phase B entry).
Clock: s after the 3 -> 6 req/s step (cluster timestamps, 1 s resolution for
Kubernetes events; access logs and timeline sub-second).

### Time to relief = sum of consecutive segments (two clean cycles, same trace)
| segment | what it is | main c1 | repeat | share |
|---|---|---|---|---|
| step -> metric > 26.4 | 45 s `avg_over_time` window filling | 18.5 | 19.1 | 7-8% |
| metric -> HPA decision | HPA 15 s sync + KEDA metric read | 13.0 | 9.0 | 3-5% |
| decision -> pod scheduled | scheduler (GPU 1 free) | 0.0 | 0.0 | 0% |
| scheduled -> copy done | storage-initializer, 8 GB from SeaweedFS | 15.0 | 14.0 | 5-6% |
| copy done -> engine started | container start | 2.0 | 2.0 | 1% |
| engine started -> Ready | vLLM load + compile + CUDA graphs | 103.0 | 105.0 | 40-42% |
| Ready -> first request | endpoint update | 1.2 | 0.1 | ~0% |
| first request -> relief | backlog on replica 1 drains | 92.4 | 110.9 | 38-43% |
| **time to relief** | | **245.1** | **260.1** | |

Side columns, same segments: shakedown (3:120,6:300,3:60) 13.3 / 8.0 / 0 / 15.0
/ 1.0 / 104.0 / 0.6 / 38.1 -> relief 180; collapse (3 -> 8) 13.4 / HPA 12.4
(event resolution: decision logged within the same second as the crossing) /
0 / 16.0 / 2.0 / 103.0 / 0.5 -> **no relief** (two replicas below 8 req/s).
Main cycle 2 is not a step response (scaled out 58 s before the step, Phase B
entry) and is left out of the breakdown.

Reading it:
- Pod start (copy + engine) is half of time to relief and is the same in every
  run (~103-105 s engine start). The decision path (window + HPA) is ~28-32 s,
  11-13%. Faster detection (shorter window, lower threshold) can save at most ~30 s.
- The drain segment depends on how big the backlog grew while replica 1 was
  alone (~150 s at 6 req/s): 38 s after a 120 s baseline/300 s step trace
  (shakedown), 92-111 s on the main trace. Everything that shortens pod start
  also shrinks the backlog, so it saves twice.
- Engine start on scale-out (~104 s) is ~33 s shorter than on a cold boot
  (136-137 s, copy done -> Ready). Not explained yet (warm node: k3s, image,
  driver already up); note only.
- Load split after Ready ~50/50 in every cycle: no connection pinning (the
  harness uses `Connection: close`).

### Cost note: latency bought, not money
- Replica 2 lived from the decision to its deletion: (480 - 31.5) + 318.7 =
  767 s in main c1, 767 s in the repeat - 67% of the 1140 s cycle; it served
  for ~647 s of that.
- On one 2-GPU node (EUR 2.94/h) the second GPU is billed all the time, whether
  replica 2 exists or not. Pod autoscaling here saves NO money; it buys ~4-4.3
  min time-to-relief instead of never (one replica at 6 req/s keeps queueing).
- Saving money needs node-level scaling (second node or a type change on demand).
  Estimate, not measured: it adds the node's own start to pod start - cold path
  provisioning ~20-25 s + OS/k3s/scheduling ~75-83 s (unattributed in the cold
  path) - so time to relief would move from ~4.2 to roughly ~6 min, and with
  this load shape could save at most ~33% of the second GPU's EUR 1.47/h.

### Predicted failure points vs what happened
- Connection pinning: did NOT happen (splits 47.9/52.1, 49.8/50.2, 52.7/47.3).
- KServe and KEDA both writing `replicas`: did NOT happen (KEDA's HPA only;
  replica sequence 1 -> 2 -> 1, no oscillation, every cycle).
- First-request compile spike on replica 2: NOT measurable with what was
  recorded. GuideLLM records do not say which replica served a request, and the
  Prometheus export kept running/waiting/success/KV only, not the per-pod TTFT
  histogram (Prometheus storage did not survive the stop). The aggregate peak
  (160 s) is ~8 s after replica 2's first request, but it is the replica-1
  backlog and cannot be split. For week 6: export the per-pod
  `vllm:time_to_first_token_seconds` histogram.
- Boot admission race: HAPPENED on every boot (Phase B entry); harmless for
  serving, breaks the one-pod precondition until the rejected pod is deleted.
- Not predicted: scale-down cuts in-flight requests (all errored requests).

### Exit criteria (section 8, Week 5)
- KEDA 1 -> 2 and 2 -> 1 on the GPU node, driven by engine metrics: MET (every
  cycle, metric = summed `vllm:num_requests_running`).
- Time-to-relief over >= 2 step cycles, broken into components: MET (main c1 +
  repeat, table above; shakedown as a third, shorter cycle).
- Per-replica request split recorded: MET.
- Cold path measured once: MET (three boots, ~252-256 s).
- Results committed, raw per the Release convention, session logged: MET
  (`9826a16`, Release `results-session-5` at `bb70f17`, docs/session-log.md),
  except the shakedown run, still on the VM (GPU stock).

## 2026-10-26 - Week 6 planning: GPU stock + watcher

- Stock check (`scw instance server-type list`), 2026-10-26 ~08:55Z: every GPU
  type in fr-par-2, fr-par-1 and pl-waw-2 in `shortage` (L40S-1/2/4/8,
  H100 all sizes, B300, L4-4/8); L4-1/L4-2 `scarce`; only RENDER-S (P100)
  `available`. Instance stopped as L40S-1-48G; a stopped instance holds no GPU,
  so `start` needs a free physical server of its type.
- Idle cost split (billing API, Oct): block volume 150 GB at EUR 0.00013/GB/h =
  EUR 0.468/day; flexible IPv4 EUR 0.005/h = EUR 0.120/day. Total EUR 0.588/day.
  Project total EUR 40.60 (Sep 9.51 + Oct 31.09).
- `scripts/gpu-stock-watch.sh`: polls every 3 min, logs all GPU types to
  `~/.gpu-stock-watch/stock.log`, alerts on `L40S-2-48G` != shortage with an
  on-top Windows dialog + looping alarm (WSL interop, `-EncodedCommand`, so no
  execution-policy or quoting issues); re-alerts every 15 min while in stock;
  alerts after 5 consecutive API failures. Never starts the instance.
  Test alert confirmed on screen (Manoj). Started 08:57Z.
- Week 6 plan: context doc section 8 (route B, GPU deadline Fri 30 Oct).

## 2026-10-26 - Week 6 A1: Knative Serving + Kourier on kind

`scripts/install-knative.sh` (new), `manifests/kserve-values.yaml`
(+`disableIstioVirtualHost: true`), `manifests/inferenceservice-qwen-knative.yaml`
(smoke test). Ran twice on kind; second run identical = idempotent.

- **Versions:** Knative Serving 1.21.1 + net-kourier 1.21.1 = what KServe
  v0.20.0's own installer uses (`hack/setup/quick-install/*.sh`:
  `KNATIVE_SERVING_VERSION=1.21.1`; go.mod `knative.dev/serving v0.48.1`).
  Newer Serving patches exist (1.21.3); "the version KServe tests" chosen.
  Release files by full sha256 (in the script); Knative images digest-pinned upstream.
- **Envoy:** kourier.yaml ships `envoyproxy/envoy:v1.36-latest` (FLOATING).
  Replaced in-stream by `v1.36.13@sha256:93e25ef0...` (= that tag on
  2026-10-26; released 2026-10-12). Script fails if the upstream line changes.
- **Kourier Service:** upstream `type: LoadBalancer` -> NodePort 30880, changed
  in-stream before apply (k3s servicelb would otherwise bind 80/443 on the VM).
  Docker Desktop: the kind node IP (172.18.0.2) is not the laptop's network;
  only mapped port 30800 reaches the laptop. Load to Kourier on kind = A5 question.
- **KServe:** helm upgrade, same chart v0.20.0, same values file. KServe checks
  Knative CRDs at start (controller.go:629) -> restart. Without
  `disableIstioVirtualHost` it logs an error + warning event per reconcile
  (controller.go:366). Default mode still Standard; per-ISVC annotation
  `serving.kserve.io/deploymentMode: Knative` (v0.20 name; NOT "Serverless").
- **Storage-initializer (side check):** the upgrade also applied the file's
  `kserve.storage.resources` (8Gi limit, `f27007a`) to kind for the first time.
  The chart writes it to the **ClusterStorageContainer `default`** (now 8Gi),
  NOT to the inferenceservice-config `storageInitializer` block (1Gi, unchanged).
  (I first misread the unchanged ConfigMap as "the key is ignored" - wrong object.)
- **Knative tag resolution (kind only):** Knative resolves image tags to
  digests before running a revision. The CPU runtime image
  `public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest` was side-loaded into
  kind 2026-09-16 (content `sha256:e42aae44c784ab72040853d60ce3e791ee409483bc86c4a68d8e6bccc4b01609`,
  imageID `import-2026-09-16`); the node holds it only under the tag, and
  public.ecr.aws is unreachable from inside kind -> revision `ContainerMissing`
  ("failed to resolve image to digest ... context deadline exceeded").
  Fix: kind-only `registries-skipping-tag-resolving` += public.ecr.aws. The GPU
  runtime image is digest-pinned, so k3s needs nothing. Also on record: the kind
  CPU runtime is on a floating tag (kind latency is never reported).
- **Knative restricts pod specs:** PVCs are rejected unless
  `kubernetes.podspec-persistent-volume-claim` is enabled -> the Knative qwen
  has no compile-cache PVC. **A6 must check the GPU manifests for this.**
- **Grace period:** a revision pod from the failed first attempt sat
  `Terminating` for minutes - Knative sets terminationGracePeriodSeconds from
  the revision timeout (300 s default). Relevant to A4 (drain).
- **Smoke (qwen-kn, 1 CPU req / 2 limit):** Ready next to Ready Standard
  qwen-0-5b; pod 2/2 (vLLM + queue-proxy). From inside the cluster via
  `kourier.kourier-system` with `Host: qwen-kn-predictor.llm-serving.example.com`:
  `GET /v1/models` 200 `['qwen-kn']`, `server: envoy`; completion 200 (58.7 s,
  first request = compile on 2 CPUs, no cache; not a measurement).
  Standard `:8080` unaffected throughout; qwen-0-5b pod not restarted.
  KServe created `ksvc/qwen-kn-predictor` = proof it uses Knative.
- Kind after install: 5.78 of 8 CPU requested (+1 for Knative/Kourier).
  Smoke ISVC deleted after the test (manifest kept for A5).

## 2026-10-26 - Week 6 A2: boot admission race (recipe fix 3, closed)

- **Mechanism (why it broke the harness):** `live_pods` already ignored the
  rejected pod (phase Failed). What broke was `step-load.sh`'s
  `wait_one_replica`: it also requires exactly ONE pod in total, and a Failed
  pod is never garbage-collected -> count 2 until deleted by hand (week 5).
- **Fix:** `clear_rejected_pods NS SELECTOR` in `lib-pods.sh` deletes ONLY
  phase Failed + reason `UnexpectedAdmissionError` (never ran a container, no
  data), printing name + message. Other Failed pods (OOMKilled, Evicted) are
  evidence and still stop the harness. Called:
  - inside `wait_one_replica` before counting -> the harness heals itself;
  - `scripts/clear-rejected-pods.sh` (all namespaces, predictor label) = the
    explicit boot step, right after boot, before any harness run (A6 puts it in
    the Phase B runbook).
  NOT in `coldpath-vm.sh`: a measurement stays read-only, and it reaches the
  model via the Service, so the rejected pod does not affect it.
- **Test on kind** (`scripts/test-clear-rejected-pods.sh`; fake pods, status
  written by hand since a real rejection needs a GPU): 11/11 pass - rejected
  deleted; Evicted, Pending, unlabelled kept; second run quiet; real
  `wait_one_replica` with a fake rejected pod beside the live KEDA qwen: 2 pods
  -> cleared -> returned 0 in 1 s, live qwen untouched, clearing logged.
  CLI counted 1 then 0. **Still to see on the GPU:** a real rejection at boot.

## 2026-10-26 - Week 6 A3: per-pod TTFT export

- **Why:** the client (GuideLLM) cannot tell which replica served a request, so
  per-replica / per-revision latency must come from the server: vLLM's
  `vllm:time_to_first_token_seconds` histogram.
- **vLLM 0.29 buckets are coarse** (s): 0.001 0.005 0.01 0.02 0.04 0.06 0.08 0.1
  0.25 0.5 0.75 1 2.5 5 7.5 10 20 40 80 160 640 2560. A percentile from them is
  an interpolated ESTIMATE. So: `_sum/_count` gives an EXACT mean per pod - the
  number to compare revisions on - and p50/p95 are always reported WITH their
  bucket bounds (`ttft_p95_ms_est` + `ttft_p95_bucket_ms`).
- **Export** (`step-load.sh`, per cycle): `sum by (pod, revision[, le])` of
  `_bucket`, `_sum`, `_count` -> `prom/ttft-{bucket,sum,count}.json`.
- **Prometheus** (`manifests/prometheus.yaml`): new `revision` label from the
  pod's Knative revision label (absent on Standard pods). Prometheus runs without
  `--web.enable-lifecycle` and never reloads a changed ConfigMap, so the
  Deployment template now carries `llm-serving-lab/config-version` - bump it with
  every config change and `apply` restarts the pod (verified: pod replaced, new
  config live). Otherwise `install-autoscaling.sh` on the GPU would apply a new
  config and keep running the old one.
- **Parser** (`parse_step.py`): `hist_quantile` (Prometheus semantics: linear in
  bucket, lower bound 0, +Inf -> highest finite bound; 5 unit cases pass),
  `ttft_per_pod(d, from, to)` (deltas; pod first seen later counts from 0;
  counter reset -> error). Per cycle: `ttft_per_pod.whole_cycle`,
  `.after_replica2_ready`, `.check_vs_client` (counts + means; client includes
  network). Week-5 runs parse unchanged (`n/a: run predates week 6 A3`).
- **Kind CPU (found here):** Knative + Kourier REQUEST 1.0 CPU; replica 2 went
  `Pending` ("Insufficient cpu": 5.78 + 3 > 8) in run 1. `install-knative.sh`
  now lowers their requests to 25m each on kind only (limits untouched; their
  CPU HPAs are inert on kind - no metrics-server, targets `<unknown>`).
  Total 4.93 -> two qwen fit again (7.93 of 8).
- **Validation runs** (`benchmarks/configs/step-kind-a3.sh`, one 10-min cycle
  0.2 -> 0.4 -> 0.2 req/s; kind; not measurements):
  - `a3-step-kind-1` (one pod - replica 2 Pending): server 177 = client 177
    requests; **mean server 1646.8 / client 1654.4 ms (client +7.6 ms)**; p50 est
    1738 in (1000, 2500] vs client 1400; p95 est 4078 in (2500, 5000] vs client
    3325. True values inside the buckets; estimates off by 340-750 ms -> the
    design above.
  - `a3-step-kind-2` (two pods): warm pod mean **250 ms** (134 req); NEW replica
    mean **18.5 s** (43 req), **28.8 s after it reported Ready** (p95 est 71 s in
    (40, 80] s). Ready long before fast: first requests pay vLLM's compile on new
    batch shapes (week 5 prediction, first time visible per pod). Server 177 vs
    client 176: GuideLLM's scheduler_state shows `processing_requests: 1` at
    the end - one request served but missing from the client report. Now in
    `check_vs_client.requests_client_processing_at_end`; both runs reconcile.

## 2026-10-26 - Week 6 A4: graceful drain on scale-down

- **Root cause (source, vLLM 0.29.0, `entrypoints/launchers/launcher.py`):**
  `--shutdown-timeout` defaults to **0 = "abort"**: on SIGTERM vLLM aborts
  in-flight requests. `>0` = "drain": finish in-flight requests up to N s, then
  exit. (Week 5 GPU symptom: connections hung until the 30 s grace SIGKILL.)
- **Fix** (`inferenceservice-qwen-keda.yaml`, `inferenceservice-llama-fp8-keda.yaml`):
  1. model `args: --shutdown-timeout=90` (appended to the runtime's - verified
     in the generated Deployment);
  2. `lifecycle.preStop: sleep 10` - deletion removes the endpoint and starts
     preStop at the same time; new requests can still arrive for a few seconds;
     SIGTERM waits until they stop;
  3. `terminationGracePeriodSeconds: 120` (>= 10 + 90 + margin).
  GPU manifest: server-side dry-run accepts it; first real run = session 6.
- **Test** (`scripts/drain_test.py`, kind): qwen pinned at 2 replicas (temporary
  `minReplicas: 2` patch), 4 workers, each request a new connection, 128 tokens
  (`ignore_eos`), the NEWEST replica deleted at ~47 s (= scale-down's pick).
  | run | grace | preStop | drain flag | requests | errors | victim gone after delete |
  |---|---|---|---|---|---|---|
  | drain-before-1 | 30 | - | - | 69 | **9** (4 in flight, **5 started after the delete**) | 1.5 s |
  | drain-after-1 | 120 | sleep 10 | 90 | 44 | **0** | 15.9 s |
  | drain-after-2 | 120 | sleep 10 | 90 | 60 | **0** | 15.5 s |
  Before: errors `ConnectionResetError` / `RemoteDisconnected` / `HTTPError`,
  all 0.2 s after the delete; vLLM log `mode=abort timeout=0s`, EngineCore
  force-killed. The 5 started-after-delete errors are the endpoint race.
  After-2 vLLM log: `mode=drain timeout=90s`, `request processing complete`,
  `all workers exited gracefully` (after-1 log not captured: `kubectl logs -f`
  dies with the pod -> the test now polls the tail every second).
- **Which part did the work on kind:** SIGTERM came 10 s after the delete and
  vLLM had nothing left in flight - the preStop sleep covered the ~6-8 s kind
  requests. Drain mode is the net for longer requests (GPU under load).
- Fewer requests in after-1 (44) than before (69): before, errors returned
  instantly and workers re-sent at once; after, the victim holds its CPU 15 s
  longer, so its replacement starts later. Not a drain effect.
- Knative-mode pods drain via queue-proxy - checked in A5, not here.
- `drain_test.py` creates its results dir only after the 2-replica check (an
  aborted first start had left an empty dir).

## 2026-10-26 - Week 6 A5: canary on kind (mechanics)

`manifests/inferenceservice-qwen-canary.yaml` (Knative mode; revisions differ
ONLY in env `CANARY_VERSION`, same model/settings - kind proves mechanics, a
switch is the only variable). `scripts/canary_test.py` drives it under constant
load (4 workers, each request a new connection with the ISVC's Host header via
Kourier, 32 tokens `ignore_eos`), waits per phase until KServe's status shows
the expected split, holds, and reads the SERVER-side split from the A3
per-revision counter over each phase's steady window (ready + 15 s -> end).
Setup: KEDA qwen + its NodePort removed (CPU; port 30800), Kourier's NodePort
moved 30880 -> 30800 for the test, all restored afterwards.

Run `canary-kind-1` - **943 requests, 0 errors, 0 short**:
| phase | configured (00001/00002) | server share | apply -> traffic set | errors steady / transition |
|---|---|---|---|---|
| v1 | 100 / - | 100 / - | 0.2 s | 0 / 0 |
| canary | 80 / 20 | **79.0 / 21.0** (143 / 38) | 127.7 s (new revision cold start) | 0 / 0 |
| rollback | 100 / 0 | 100 / 0 (127) | **3.0 s** | 0 / 0 |
| canary2 | 80 / 20 | **78.8 / 21.2** (130 / 35) | 2.6 s (v2 still warm) | 0 / 0 |
| promote | 0 / 100 | 0 / 100 (217) | 2.6 s | 0 / 0 |

- Split within sampling noise (38 of 181 = 21%; binomial 95% ~15-27%).
- Knative routes to a new revision only once it is Ready: the 128 s cold
  start is invisible to clients (100% stayed on v1 meanwhile). After rollback
  the 0% revision kept its pod (min-scale 1), so canary2 switched in 2.6 s.
- **Drain in Knative mode is built in:** the generated pod has a preStop on the
  vLLM container `httpGet /wait-for-drain :8022` (queue-proxy) and grace 300 s
  - vLLM gets SIGTERM only after queue-proxy has no requests in flight. v1's
  pod was removed after promote with 0 errors, with NO `--shutdown-timeout`.
  **A6: do NOT add our own preStop to Knative-mode GPU manifests** (it would
  replace Knative's). `--shutdown-timeout` harmless there, not required.
- **Limit (honest):** v1's pod was removed ~2 min after traffic had already left
  it, so this run shows clean SWITCHES and that the drain hook is wired; it does
  not force termination with requests in flight (A4's test did that for
  Standard mode).
- Server count per phase vs client "steady" differ by a few requests (window
  edges vs 5 s scrape); split is judged on the server count.

## 2026-10-26 - Week 6 A6: GPU manifests, GPU-path tools, session-6 runbook

- **Knative accepts `vllm-gpu-runtime` as-is** (kind: GPU runtime applied
  temporarily, Knative-mode GPU ISVCs created; pods Pending only for
  `Insufficient nvidia.com/gpu/cpu/memory`): startupProbe, `/dev/shm` emptyDir
  (Memory), securityContext all kept; Knative injects preStop `/wait-for-drain`;
  grace = ISVC `timeout`. The image is digest-pinned -> no tag resolution.
  **An unschedulable new revision is marked FAILED** -> apply only when a GPU is free.
- **New GPU manifests** (both validated the same way, then removed from kind):
  `inferenceservice-llama-fp8-kn.yaml` (Knative twin of FP8; overhead + wake),
  `inferenceservice-llama-canary.yaml` (FP8 v1 -> AWQ v2 by `storageUri`; one
  ISVC = one served name). `timeout: 600` (activator holds a request during a
  cold start; 300 s default too close to ~150-250 s + first-request compile).
- **`canary_test.py` generalised**: `--manifest`, `--v2-storage-uri`,
  `--phases gpu` (adds **canary50**: at 20% the canary carries a quarter of v1's
  load, so latencies are only comparable at 50/50), `--prompt-words`; per phase
  the EXACT mean TTFT per revision (A3 `_sum/_count`). v1 warmed with 8 requests
  before the load (a fresh vLLM's first requests pay compile); v2's warm-up is
  kept - a canary's first users really see it.
- **Kind run `canary-kind-gpupath-1`** (GPU code path: `--phases gpu`,
  `--v2-storage-uri s3://models/qwen-0.5b/` - same model, trailing slash = new
  revision): **1243 requests, 0 errors**. canary 20%: 36/216 = 16.7% (95%
  ~11.7-21.6); canary50: 203/410 = 49.5%. Mean TTFT: canary phase v1 617 / v2
  **6545 ms** (v2 warming up); canary50 v1 583 / v2 616 ms - **identical
  models, 6% apart = the comparison's noise floor on kind**. v1 phase 54 s mean
  = load started at v1 Ready (fixed by the warm-up above).
  Closed-loop client: a slower revision gets fewer completions (workers wait),
  a small bias against it; Kourier itself splits by weight.
- **Activator in path:** SKS mode `Proxy` for both revisions while serving
  (Knative defaults, target-burst-capacity 211). The overhead number is "with
  Knative defaults: Kourier + activator + queue-proxy". Recorded on the GPU.
- **`wake_test.py`** (kind `wake-kind-1`, qwen-kn, 2 rounds): 200 both;
  **167.9 s / 153.3 s** to response; pod created ~0 s after the request (the
  activator reacts at once), Ready 110.9 / 99.6 s, response 57.0 / 53.7 s after
  Ready (first-request compile on 2 CPUs). Idle -> zero 204 / 96 s. **Changing
  `minReplicas` creates a new revision** (min-scale lives on the revision
  template): 0 -> one cold start, back to 1 -> another.
- **`path_overhead.py`** (kind `overhead-kind-1`, client inside the qwen pod -
  CODE PATH ONLY, numbers not meaningful: the client shares a predictor's CPU,
  CPU limits differ): 100 pairs each path, 0 errors; Knative - Standard median
  +10.2 ms (95% 4.8-14.6); load phase completed.
- **Runbook:** context doc section 8, Week 6 Phase B (canary FIRST, then
  overhead, then wake = first to cut).

## 2026-10-26 - Week 6 A7: cold path fully attributed (laptop, existing data)

Week 5's "unattributed ~74-83 s" (API running -> predictor scheduled) is now
attributed from data the three session-5 boots ALREADY collected - parser
change only (`scripts/parse_coldpath.py`), no GPU. Time box 1 h, ~40 min used.
- **Why "node Ready" was never observed:** on single-node k3s the API server is
  off while the VM is off, so nothing marks the node NotReady; its Ready
  condition never changes at boot (lastTransitionTime 2026-09-27 = first boot),
  and the parser correctly drops times from earlier boots. Not a collector bug.
- **Replacement milestones** (all present on every boot): k3s journal
  `Starting k3s.service` (k3s start), Node event `Starting kubelet`, Pod event
  `UnexpectedAdmissionError` on the old predictor, the replacement pod's
  creation; plus ReplicaSet `FailedCreate ... failed calling webhook` events.
| segment (s) | type-change | restart-1 | restart-2 |
|---|---|---|---|
| provisioning (scw start -> API running) | 23.5 | 25.4 | 19.9 |
| OS boot (API running -> k3s start) | 21.5 | 17.2 | 23.7 |
| k3s start -> kubelet up | 3.9 | 7.5 | 7.2 |
| kubelet up -> old predictor rejected | 1.0 | 1.0 | 1.0 |
| **rejected -> replacement created** | **50.0** | **48.0** | **51.0** |
| created -> scheduled | 0.0 | 0.0 | 0.0 |
| wait for copy / copy | 1 / 13 | 1 / 13 | 1 / 14 |
| engine start-up | 137.0 | 137.0 | 136.0 |
| Ready -> first token | 2.2 | 2.0 | 2.0 |
| **unattributed** | **0.0** | **0.0** | **0.0** |
- **Finding:** ~50 s of every ~4.2 min cold start is the admission race's
  knock-on: the old predictor is rejected (GPU not registered yet), and the
  ReplicaSet cannot create its replacement until KServe's pod-mutating webhook
  answers - the KServe controller is itself restarting. 13 refused attempts
  per boot (first ~58-62 s, last ~78-83 s after scw start); the replacement
  appears ~20 s after the last refusal, LIKELY the ReplicaSet's retry back-off
  (not proven from this data). Same on all three boots.
- New output: `boot_race` (attempts, first/last refusal) in coldpath-summary.json.
  Segment names changed (`OS + k3s ...` / `node Ready -> ...` replaced).
- For the report: the engine start-up (136-137 s) is still the biggest single
  segment; the webhook wait is the second, and it is a platform-ordering cost,
  not a model cost.

## 2026-10-27 - Week 6 Phase B: GPU session 6 (L40S-2-48G)

**Session:** stock alarm 02:32Z (L40S-2-48G `scarce`), Manoj "go"; type change
L40S-1 -> L40S-2 OK; `coldpath.sh --keep --label session-6` 02:44:44Z; ended
`session.sh end` 03:36Z, confirmed `stopped`. **0.85 h, EUR 2.50** (estimate
EUR 6-7.5). Project total **EUR 43.56**. Every runbook step ran; nothing cut.
VM repo at `f4150a9` (re-shipped). Ceiling watcher 3.5 h, never reached.

**Runbook fix (found live):** step 2 (`clear-rejected-pods.sh`) needs the repo
re-shipped FIRST - the script did not exist on the VM yet. Order now: boot ->
re-ship -> clear rejected pods -> pull leftovers -> verify -> installs.

### Boot (`coldpath-session-6-20261027T0244Z`, A7 parser)
First token **256.9 s**, unattributed 0.0: provisioning 21.0, OS boot 23.1,
k3s -> kubelet 7.6, -> old predictor rejected 1.0, **-> replacement 52.0
(KServe webhook; 13 refused attempts, 62.7-83.7 s)**, copy 14, engine start-up
136, Ready -> first token 2.2. Fourth boot with the same ~50 s webhook wait.
- **A2 on real hardware:** `clear-rejected-pods.sh` deleted **2** pods, both
  `UnexpectedAdmissionError: ... no healthy devices present` (Week 5 message).
- **Week-5 leftovers pulled**, manifest hash VM = laptop:
  `20261026T0325Z-step-gpu` (35 files), `20261026T0321Z-step-gpu` (10),
  `session-5-boot/` (1).
- `verify-gpu.sh` (2 GPUs): all checks passed. Installs on k3s: autoscaling
  EXIT 0 (Prometheus restarted with config-version 2, `revision` label live;
  KEDA sha256 ok); `install-knative.sh` EXIT 0 (Knative 1.21.1, Kourier 1.21.1,
  Envoy pinned, Kourier NodePort 30880, `disableIstioVirtualHost=true`, default
  mode Standard). **Nothing listening on :80/:443** (`ss -ltn`). Disk 28 GiB
  free with no predictor.

### Canary FP8 -> AWQ (`canary-session6`, `--phases gpu`, 16 workers, 900-word prompt, 256 tokens)
**4,336 requests, 0 errors, 0 short.** Activator in path (SKS `Proxy`, both).
| phase | configured 00001/00002 | server share | requests | mean TTFT server (ms) |
|---|---|---|---|---|
| v1 (FP8) | 100/- | 100/- | 192 | 44.3 |
| canary | 80/20 | **78.8/21.2** | 595/160 | 43.9 / 21.4 |
| rollback | 100/0 | 100/0 | 311 | 44.7 |
| canary50 | 50/50 | **50.7/49.3** | 614/598 | **42.2 / 22.9** |
| promote | 0/100 | 0/100 | 951 | 26.2 |
- AWQ revision cold start (apply -> traffic set) 123.7 s, invisible to clients.
  Rollback 2.6 s, canary50 2.5 s, promote 2.6 s.
- FP8 revision removed after promote, under load: 0 errors (Knative drain, real GPU).
- **CAVEAT - cached prompt:** `canary_test.py` repeats ONE prompt, so vLLM's
  prefix cache skips almost all prefill; server TTFT ~= one decode step, where
  4-bit is faster. That is why AWQ < FP8 here, the opposite of Week 4 (unique
  prompts, 3% prefix hits). Valid as revision-vs-revision under identical
  conditions; NOT comparable with Week 4 TTFT.

### Knative data-path overhead (`overhead-session6`)
A = Standard `llama-fp8` via predictor ClusterIP; B = `llama-fp8-kn` via Kourier
-> activator (Proxy) -> queue-proxy. One GPU each. 200 pairs, random order,
max_tokens 1: standard median 17.98 ms (p95 18.70), knative 18.93 (p95 20.06);
**paired difference +0.99 ms (95% 0.95-1.05)**. Load (16 workers, 900/256,
120 s each): standard 1,057.0 tok/s, mean 3,873.8 ms; knative 1,054.2 tok/s,
3,884.0 ms (**-0.3% / +0.26%**). 0 errors either way.

### Wake from zero (`wake-session6`, `llama-fp8-kn`)
Standard `llama-fp8` deleted first (the min-scale change creates a revision
that needs a free GPU - A6). 2 rounds: **121.3 s / 121.25 s**, both 200; pod
created at the request (-0.1 / +0.2 s), Ready 120.9 / 121.2 s, response 0.4 /
0.1 s after Ready. Idle -> zero 215 / 98 s. The activator held both requests.

### Closing
All results pulled + verified before the stop (`canary-session6`,
`overhead-session6`, `wake-session6`, `session-6-vm-logs` = the VM logs).
Cluster restored to the week-5 state (KEDA `llama-fp8` re-applied, Knative twin
deleted). GPU stock watcher stopped (job done).
