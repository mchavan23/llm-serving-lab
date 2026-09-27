# RUNBOOK

Operational sequences for the lab. `NOTES.md` explains *why* things are the
way they are; this file is *what to run*, in order.

All commands assume `cd ~/aify/llm-serving-lab` inside WSL2 Ubuntu, and that
Docker Desktop is running with WSL integration enabled for this distro.

---

## Check state first

```bash
./scripts/verify.sh
```

Checks tooling, Docker, the kind cluster and its published ports, SeaweedFS (S3), the
model objects in S3, and vLLM. Exits non-zero on failure. Run this before
assuming anything is broken — it tells you *which layer* is at fault.

---

## Cold rebuild (after a WSL reset, or on a new machine)

Nothing below survives a WSL distro reset except what is in git. The model
weights and Docker images are re-downloadable.

### 1. Tools

```bash
bash cluster/setup.sh
```

Installs pinned kubectl / helm / kind and symlinks `uv`. Idempotent.

### 2. Cluster

```bash
kind create cluster --config cluster/kind-config.yaml --wait 120s
kubectl get nodes -o wide
docker port llm-serving-lab-control-plane
```

Expect one `Ready` node on v1.36.4 and three published ports
(8080/9000/9001 -> 30800/30900/30901).

### 3. S3 store (SeaweedFS)

MinIO was replaced on 2026-09-27: its images are no longer publicly pullable
(Docker Hub repo deleted 2026-09-11, quay.io auth-only since 2026-09-24).
SeaweedFS 4.47 serves the same S3 API, so nothing that talks to it changed.

Credentials live in `.env` (gitignored). If `.env` is missing, copy
`.env.example` and fill it in - `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` can
be any values, e.g. `openssl rand -hex 24`.

```bash
scripts/install-seaweedfs.sh --kind     # --kind adds NodePort 30900 -> localhost:9000

kubectl -n seaweedfs get pods,svc,pvc
curl -i http://localhost:9000/
```

Healthy SeaweedFS answers `HTTP 403` with an `AccessDenied` XML body, exactly
as MinIO did. A refused connection means the port chain is broken; a `200`
would mean anonymous access is open.

On the GPU node run it WITHOUT `--kind`: ClusterIP only, never a NodePort on
the public IP (`scripts/stage-models.sh` does this for you).

The credentials Secret is created with SERVER-SIDE apply. Client-side
`kubectl apply` copies the whole Secret into the `last-applied-configuration`
annotation, where any `kubectl get -o yaml` prints it.

Never source `.env` - a malformed line becomes a shell command. Parse the
keys you need.

**Rollback / cleanup:** the old MinIO release is still installed on the
laptop kind cluster (Service switched to ClusterIP, data kept). It runs only
because kind already unpacked its image; it cannot be reinstalled. Remove it
with `helm uninstall minio -n minio && kubectl delete ns minio`.

### 4. Python environment

```bash
uv sync
```

Recreates `.venv` exactly from `uv.lock`. Every Python command afterwards is
`uv run python ...` — plain `python` is the system 3.12 with nothing installed.

### 5. Model

```bash
uv run hf download Qwen/Qwen2.5-0.5B-Instruct \
  --local-dir ~/aify/models/qwen2.5-0.5b-instruct

uv run python scripts/upload_model.py \
  ~/aify/models/qwen2.5-0.5b-instruct qwen-0.5b
```

Skip the download if `~/aify/models/` survived. The upload is idempotent.

### 6. KServe stack (week 2 -- replaces the week 1 standalone vLLM container)

The week 1 `docker run` of vLLM is gone; KServe runs it as a pod now.

```bash
# 6a. cert-manager -- issues the TLS certs KServe's admission webhooks need.
#     On OpenShift the service CA operator does this; kind has no equivalent.
helm repo add jetstack https://charts.jetstack.io --force-update
helm install cert-manager jetstack/cert-manager \
  --version v1.21.2 -n cert-manager --create-namespace \
  -f manifests/cert-manager-values.yaml --wait --timeout 10m

# 6b. KServe. CRDs are a SEPARATE chart and must go first.
helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --version v0.20.0 -n kserve --create-namespace --wait

helm install kserve oci://ghcr.io/kserve/charts/kserve-resources \
  --version v0.20.0 -n kserve \
  -f manifests/kserve-values.yaml --wait --timeout 10m

# 6c. Side-load the 7.8 GB vLLM CPU image into the kind node. Without this
#     the node pulls it from ECR. Takes several minutes.
docker pull public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest
kind load docker-image public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest \
  --name llm-serving-lab

#     Confirm it actually finished -- `crictl images` listing it is NOT proof:
docker exec llm-serving-lab-control-plane ctr -n k8s.io images check | grep vllm
#     want: complete (15/15)  1.7 GiB/1.7 GiB  true

# 6d. Runtime, credentials, model, endpoint.
kubectl apply -f manifests/servingruntime-vllm-cpu.yaml
./scripts/create-s3-secret.sh llm-serving     # reads .env, never commits it
kubectl apply -f manifests/pvc-compile-cache.yaml
kubectl apply -f manifests/inferenceservice-qwen.yaml
kubectl apply -f manifests/nodeport-qwen.yaml

kubectl wait --for=condition=Ready isvc/qwen-0-5b -n llm-serving --timeout=20m
```

First start is slow: ~6-9 s to pull the model from S3, then ~100 s of
`torch.compile` warmup. The startupProbe allows 30 minutes on purpose.

We do NOT install `kserve-runtime-configs` (KServe's prebuilt
ClusterServingRuntimes). Its vLLM runtime uses the CUDA image, which cannot
start without an NVIDIA GPU, and having it alongside ours would create real
ambiguity about which runtime served a request.

---

## Daily start (after a reboot, nothing reset)

The kind cluster and SeaweedFS restart themselves with Docker, and so now does
the KServe predictor pod -- it is a Deployment, not a bare container.

```bash
./scripts/verify.sh                         # layer-by-layer check
kubectl get isvc -n llm-serving             # READY should be True
./scripts/test-api.sh                       # end-to-end, through the platform
```

`wsl --shutdown` destroys the WSL VM; the cluster and SeaweedFS come back with
Docker afterwards, but give Docker Desktop a minute to re-engage. `/proc/uptime`
is the honest signal that the VM actually cycled -- `wsl --list --verbose` will
report a distro as Running seconds after a shutdown.

---

## Using it

```bash
./scripts/test-api.sh                                  # default prompt
./scripts/test-api.sh "Explain etcd in one sentence"
./scripts/test-api.sh "Write a haiku about YAML" 120   # prompt + max_tokens
```

No S3 web console: SeaweedFS's UIs are not exposed. Use the S3 API (below).

Raw curl, if you want to see the wire format:

```bash
# what model id is served -- MUST match the "model" field below
curl -s localhost:8080/v1/models | jq -r '.data[].id'

# generate
curl -s localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-0-5b",
       "messages":[{"role":"user","content":"What is Kubernetes?"}],
       "max_tokens":80,"temperature":0}' | jq -r '.choices[0].message.content'

# metrics - queue depth (KEDA signal) and TTFT histogram (benchmark source)
curl -s localhost:8080/metrics | grep -E 'num_requests|time_to_first_token'
```

**The model id is `qwen-0-5b`, with hyphens.** Week 1 used `qwen-0.5b` with a
dot. It changed because the runtime passes `--served-model-name={{.Name}}` and
`{{.Name}}` is the InferenceService's name, which must be a valid DNS label.
Sending the old name returns a 404, not a completion.

Expect poor answers. It is a 0.5B model -- in testing it confidently listed
`nagios` and `syslog-ng` as Linux schedulers. The stack is what is being
proven here, not the model.

### Upload another model

```bash
uv run python scripts/upload_model.py <local_dir> <s3_prefix>
```

Creates the bucket if absent, skips dot-prefixed paths (the `.cache/` tree
that `hf download --local-dir` leaves behind).

### Inspect what is in S3

```bash
uv run python -c "
import sys; sys.path.insert(0,'scripts')
from pathlib import Path
from upload_model import read_env, make_client
env = read_env(Path('.env'))
for o in make_client(env).list_objects_v2(Bucket=env['S3_BUCKET']).get('Contents', []):
    print(f\"{o['Size']:>14,}  {o['Key']}\")
"
```

---

## Teardown

```bash
# Stop serving, keep the cluster. Frees ~8 GB.
kubectl delete -f manifests/inferenceservice-qwen.yaml

# Everything. Removes the cluster, S3 (SeaweedFS) data, the compile-cache PVC, and the
# side-loaded image -- the next cold rebuild re-does the 7.8 GB kind load.
kind delete cluster --name llm-serving-lab
```

`kind delete` destroys the PVCs, so the S3 store's contents and the torch.compile
cache are both gone. Re-upload the model from `~/aify/models/` afterwards.

`manifests/nodeport-qwen.yaml` is hand-written and NOT owned by KServe, so
deleting the InferenceService leaves it behind. Harmless, but its selector
will not follow a rename.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `curl localhost:9000` refused | Cluster gone or Docker Desktop not running. `kind get clusters` |
| SeaweedFS pod `Pending` | PVC not bound or memory too large for the host. `kubectl -n seaweedfs describe pod` |
| KServe storage-initializer `AccessDenied` | Secret credentials out of step with `.env` after a rotation. Re-run `scripts/install-seaweedfs.sh --kind` and `scripts/create-s3-secret.sh` |
| Service unreachable despite running pod | `nodePort` does not match a `containerPort` in `cluster/kind-config.yaml` (30800/30900/30901) |
| `curl localhost:8000/health` prints nothing | **This is success.** HTTP 200 with an empty body. Use `curl -i` |
| vLLM container exits with code 132 | SIGILL — compiled kernels need an instruction set this CPU lacks. Verify with `docker run --rm --entrypoint python3 <image> -c "import vllm"` |
| First request takes ~60s, later ones ~3s | `torch.compile` on an unseen batch shape. Expected. Benchmarks must discard cold starts |
| `boto3` not found | Missing `uv run` prefix, or `.venv` absent. `uv sync` |
| `ModuleNotFoundError: upload_model` | Script run from outside the repo root, or missing `sys.path.insert(0,'scripts')` |
| InferenceService not-Ready but the pod is 1/1 and serving | An Ingress KServe created that nothing reconciles. `disableIngressCreation: true` must be set in `manifests/kserve-values.yaml` |
| InferenceService stuck, no init container on the pod | Check `kubectl get certificate -n kserve` FIRST. KServe uses `inject-ca-from` (a Certificate), so the cert-manager *controller* must be healthy, not just cainjector |
| `404 model not found` from a working endpoint | Sending `qwen-0.5b` (week 1, dot) instead of `qwen-0-5b` (hyphens). `curl -s localhost:8080/v1/models` |
| Predictor pod OOMKilled, exit 137 | `limits.memory` below ~8 GiB. Memory-backed `/dev/shm` also counts against that limit |
| Node pulling 7.8 GB despite `kind load` | Image referenced by digest. `kind load` registers only the TAG; containerd matches the literal reference string |
| Pod events spam `FailedGetResourceMetric` | No metrics-server. Suppress with `serving.kserve.io/autoscalerClass: none` |
| `grep` on a rendered chart ConfigMap shows the wrong value | The `_example` key. Parse the YAML, do not grep it |

### Port map

| Host port | Goes to | Status |
|---|---|---|
| 8000 | `vllm-cpu` container directly | RETIRED in week 2; KServe replaced it |
| 8080 | kind node :30800 -> `qwen-0-5b-nodeport` -> pod :8080 | live, inference endpoint |
| 9000 | kind node :30900 -> SeaweedFS :8333 | live, S3 API |
| 9001 | kind node :30901 | unused since MinIO was retired (was its console) |

Ports bind on `0.0.0.0`, so they are reachable from other machines on the
network. S3 credentials are the only protection.
