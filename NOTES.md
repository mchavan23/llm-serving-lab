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
