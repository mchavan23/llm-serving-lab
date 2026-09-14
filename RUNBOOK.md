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

Checks tooling, Docker, the kind cluster and its published ports, MinIO, the
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

### 3. MinIO

Credentials live in `.env` (gitignored). If `.env` is missing, copy
`.env.example` and fill it in — `MINIO_ROOT_PASSWORD` can be any value, e.g.
`openssl rand -hex 16`.

```bash
helm repo add minio https://charts.min.io/
helm repo update

helm upgrade --install minio minio/minio \
  --namespace minio --create-namespace \
  --version 5.4.0 \
  --values manifests/minio-values.yaml \
  --set rootUser="$(grep -m1 '^MINIO_ROOT_USER=' .env | cut -d= -f2-)" \
  --set rootPassword="$(grep -m1 '^MINIO_ROOT_PASSWORD=' .env | cut -d= -f2-)" \
  --wait --timeout 5m

kubectl -n minio get pods,svc,pvc
curl -i http://localhost:9000/
```

Healthy MinIO answers `HTTP 403` with an `AccessDenied` XML body. A refused
connection means the port chain is broken; a `200` would mean anonymous
access is open.

Never source `.env` — a malformed line becomes a shell command. Parse the
keys you need, as above.

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

### 6. vLLM

```bash
docker run -d --name vllm-cpu \
  --shm-size=4g \
  -p 8000:8000 \
  -v ~/aify/models/qwen2.5-0.5b-instruct:/models/qwen-0.5b:ro \
  -e VLLM_CPU_KVCACHE_SPACE=4 \
  public.ecr.aws/q9t5s3a7/vllm-cpu-release-repo:latest \
  /models/qwen-0.5b \
  --served-model-name qwen-0.5b \
  --max-model-len 2048 \
  --host 0.0.0.0 --port 8000
```

First run pulls 7.8 GB. Startup takes ~2 minutes: weight load, KV cache
allocation, then `torch.compile` warmup. Watch it with
`docker logs -f vllm-cpu` until `Application startup complete`.

---

## Daily start (after a reboot, nothing reset)

The kind cluster and MinIO restart themselves with Docker. vLLM does not,
because it was started without a restart policy.

```bash
docker start vllm-cpu      # if it exists but is stopped
./scripts/verify.sh
```

---

## Using it

Interactive API explorer (browser): <http://localhost:8000/docs>
MinIO console (browser): <http://localhost:9001>, credentials from `.env`

```bash
# health - HTTP 200 with an EMPTY body. `curl -s` alone prints nothing.
curl -i localhost:8000/health

# what model name is served
curl -s localhost:8000/v1/models

# generate
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen-0.5b",
  "messages": [{"role":"user","content":"Explain a Kubernetes Service in two sentences."}],
  "max_tokens": 120,
  "temperature": 0.7
}' | python3 -m json.tool

# metrics - queue depth (KEDA signal) and TTFT histogram (benchmark source)
curl -s localhost:8000/metrics | grep -E '^vllm:(num_requests_waiting|time_to_first_token)'
```

Use `/v1/chat/completions`, not `/v1/completions`, when judging output
quality. The latter is raw continuation with no chat template applied, so the
model drifts immediately after answering.

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
for o in make_client(env).list_objects_v2(Bucket=env['MINIO_BUCKET']).get('Contents', []):
    print(f\"{o['Size']:>14,}  {o['Key']}\")
"
```

---

## Teardown

```bash
docker rm -f vllm-cpu               # frees ~2 GB RAM; image stays cached
kind delete cluster --name llm-serving-lab   # removes cluster AND MinIO data
```

`kind delete` destroys the PVC, so anything in MinIO is gone. Re-upload from
`~/aify/models/` afterwards.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `curl localhost:9000` refused | Cluster gone or Docker Desktop not running. `kind get clusters` |
| MinIO pod `Pending` | Memory request too large for the host. `kubectl -n minio describe pod` — the chart default is 16Gi and WSL has ~15Gi |
| Service unreachable despite running pod | `nodePort` does not match a `containerPort` in `cluster/kind-config.yaml` (30800/30900/30901) |
| `curl localhost:8000/health` prints nothing | **This is success.** HTTP 200 with an empty body. Use `curl -i` |
| vLLM container exits with code 132 | SIGILL — compiled kernels need an instruction set this CPU lacks. Verify with `docker run --rm --entrypoint python3 <image> -c "import vllm"` |
| First request takes ~60s, later ones ~3s | `torch.compile` on an unseen batch shape. Expected. Benchmarks must discard cold starts |
| `boto3` not found | Missing `uv run` prefix, or `.venv` absent. `uv sync` |
| `ModuleNotFoundError: upload_model` | Script run from outside the repo root, or missing `sys.path.insert(0,'scripts')` |

### Port map

| Host port | Goes to | Status |
|---|---|---|
| 8000 | `vllm-cpu` container directly | live, not via Kubernetes |
| 8080 | kind node :30800 | reserved for KServe (week 2) |
| 9000 | kind node :30900 -> MinIO | live, S3 API |
| 9001 | kind node :30901 -> MinIO | live, web console |

Ports bind on `0.0.0.0`, so they are reachable from other machines on the
network. MinIO credentials are the only protection.
