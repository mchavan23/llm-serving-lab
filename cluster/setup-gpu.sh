#!/usr/bin/env bash
# =============================================================================
# setup-gpu.sh -- bring up a single-node GPU cluster on a Scaleway L40S VM.
#
#   k3s (containerd) + NVIDIA stack + cert-manager + KServe
#
# Design rules (week 3, Phase B):
#   * IDEMPOTENT  -- safe to re-run; every step checks "already done?" first.
#   * DETECT-FIRST -- the Scaleway GPU image ships driver/toolkit. We verify
#                     them, we do not reinstall over them.
#   * PINNED      -- no "latest" anywhere, or week 6 is unreproducible.
#   * FAIL LOUD   -- every stage asserts its result. A silent CPU fallback
#                    here burns a paid GPU session.
# =============================================================================
set -euo pipefail

# ---- pins -------------------------------------------------------------------
# All three GPU-stack versions verified against upstream on 2026-09-19:
#   k3s            v1.36.4+k3s1  STABLE channel (https://update.k3s.io/v1-release/channels).
#                                The "latest" channel was v1.37.0+k3s1 -- deliberately NOT
#                                used: a benchmark should not sit on a two-week-old minor.
#                                v1.36.4 also matches week 2's pinned kubectl.
#   device plugin  v0.20.0       deployments/static/nvidia-device-plugin.yml -> HTTP 200
#   gpu-operator   v26.7.0
# Override with env vars rather than editing this file. Re-verify if this script
# is still unused a month from now.
K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"                      # k3s STABLE channel, verified 2026-09-19
NVIDIA_DEVICE_PLUGIN_VERSION="${NVIDIA_DEVICE_PLUGIN_VERSION:-v0.20.0}"   # verified 2026-09-19
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.0}"                   # verified 2026-09-19
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"         # same as week 2
KSERVE_VERSION="${KSERVE_VERSION:-v0.20.0}"                     # same as week 2
HELM_VERSION="${HELM_VERSION:-v4.3.0}"                          # same as week 2
EXPECTED_GPU="${EXPECTED_GPU:-L40S}"
CUDA_SMOKE_IMAGE="${CUDA_SMOKE_IMAGE:-nvidia/cuda:12.4.1-base-ubuntu22.04}"

GPU_STACK="device-plugin"   # device-plugin (default) | operator
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
LOG_FILE="${LOG_DIR}/setup-gpu-$(date -u +%Y%m%dT%H%M%SZ).log"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu-stack=*) GPU_STACK="${1#*=}" ;;
    -h|--help) sed -n '1,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$GPU_STACK" =~ ^(device-plugin|operator)$ ]] || { echo "bad --gpu-stack"; exit 2; }

# Logging: re-exec ourselves once, with all output piped through tee.
# (Do NOT use `exec > >(tee ...)`: that logs asynchronously, so a die() message
# can flush AFTER the shell has exited -- errors then appear out of order, or
# during the next run. Found the hard way, 2026-09-19.)
if [[ -z "${_SETUP_GPU_LOGGING:-}" ]]; then
  mkdir -p "$LOG_DIR"
  _SETUP_GPU_LOGGING=1 "$0" "$@" 2>&1 | tee -a "$LOG_FILE"
  exit "${PIPESTATUS[0]}"          # exit with the SCRIPT's status, not tee's
fi

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    [ok] %s\n' "$*"; }
die()  { printf '\n!!! %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

say "setup-gpu.sh  stack=${GPU_STACK}  log=${LOG_FILE}"

# ---- 0. preflight: refuse to continue on the wrong machine ------------------
say "0. preflight"
[[ $EUID -eq 0 ]] || die "run as root (sudo -i)"
[[ -n "$K3S_VERSION" ]] || die "K3S_VERSION is unset. Pin it explicitly: K3S_VERSION=vX.Y.Z+k3sN $0"
. /etc/os-release; ok "os: ${PRETTY_NAME}"

have nvidia-smi || die "nvidia-smi not found -- this is not a GPU host, or the driver is missing"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
grep -qi "$EXPECTED_GPU" <<<"$GPU_NAME" \
  || die "expected ${EXPECTED_GPU}, host reports '${GPU_NAME}'. Refusing: benchmarks must run on the recorded card."
ok "gpu: ${GPU_NAME}  driver: ${DRIVER_VER}"
nvidia-smi --query-gpu=memory.total,compute_cap --format=csv,noheader | sed 's/^/    /'

# ---- 1. NVIDIA Container Toolkit (detect, install only if absent) -----------
say "1. NVIDIA Container Toolkit"
if have nvidia-ctk; then
  ok "already present: $(nvidia-ctk --version | head -1)"
else
  say "    not found -- installing from NVIDIA's apt repo"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq && apt-get install -y -qq nvidia-container-toolkit
  ok "installed: $(nvidia-ctk --version | head -1)"
fi

# ---- 2. k3s ------------------------------------------------------------------
say "2. k3s ${K3S_VERSION}"
if have k3s && k3s --version | grep -q "${K3S_VERSION%%+*}"; then
  ok "already installed: $(k3s --version | head -1)"
else
  curl -sfL https://get.k3s.io \
    | INSTALL_K3S_VERSION="${K3S_VERSION}" \
      INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --disable traefik --disable metrics-server" \
      sh -
  ok "installed: $(k3s --version | head -1)"
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl wait --for=condition=Ready node --all --timeout=5m
ok "node ready: $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

# ---- 3. wire k3s's containerd to the nvidia runtime -------------------------
# k3s does NOT read /etc/containerd/config.toml. It renders its own config from
# a template. Writing the template and restarting k3s is the supported path.
say "3. containerd runtime handler"
K3S_CONTAINERD_DIR=/var/lib/rancher/k3s/agent/etc/containerd
if k3s ctr --address /run/k3s/containerd/containerd.sock plugins ls 2>/dev/null | grep -q nvidia \
   || grep -q 'runtimes.nvidia' "${K3S_CONTAINERD_DIR}/config.toml" 2>/dev/null; then
  ok "nvidia runtime already registered with k3s containerd"
else
  mkdir -p "$K3S_CONTAINERD_DIR"
  # k3s auto-detects the nvidia runtime at startup when the binary is on PATH;
  # the template below makes it explicit and survives a k3s upgrade.
  cp "${K3S_CONTAINERD_DIR}/config.toml" "${K3S_CONTAINERD_DIR}/config.toml.tmpl" 2>/dev/null || true
  # --set-as-default=TRUE, deliberately. Verified against the KServe v0.20.0
  # CRDs: ClusterServingRuntime has NO runtimeClassName field (only affinity,
  # nodeSelector, tolerations, schedulerName, hostIPC, imagePullSecrets,
  # volumes, workerSpec), so the RuntimeClass below cannot be selected from
  # the ServingRuntime. InferenceService DOES expose
  # spec.predictor.runtimeClassName, but relying on it means every ISVC in
  # weeks 3-5 must remember it, and forgetting is a pod that starts and then
  # cannot find a GPU. This node exists only to serve models, so a
  # GPU-capable default runtime is the safer choice.
  nvidia-ctk runtime configure \
    --runtime=containerd \
    --config="${K3S_CONTAINERD_DIR}/config.toml.tmpl" \
    --runtime-name=nvidia \
    --set-as-default=true
  systemctl restart k3s
  kubectl wait --for=condition=Ready node --all --timeout=5m
  ok "nvidia runtime configured, k3s restarted"
fi

# RuntimeClass -- kept even though nvidia is now the DEFAULT handler, so a pod
# CAN still ask for it explicitly, and so `kubectl get runtimeclass` documents
# what the node supports.
kubectl apply -f - <<'YAML'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
YAML

# ---- 4. GPU stack ------------------------------------------------------------
say "4. gpu stack: ${GPU_STACK}"
if [[ "$GPU_STACK" == "device-plugin" ]]; then
  kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${NVIDIA_DEVICE_PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"
  kubectl -n kube-system rollout status ds/nvidia-device-plugin-daemonset --timeout=5m
else
  have helm || die "helm missing -- install helm ${HELM_VERSION} first"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
  helm repo update >/dev/null
  # driver.enabled=false : the host already has a driver (Scaleway image).
  # toolkit.enabled=false: installed in step 1 on the host.
  # CONTAINERD_* : k3s's paths, not the distro defaults.
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --version "${GPU_OPERATOR_VERSION}" -n gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set operator.defaultRuntime=containerd \
    --set-string toolkit.env[0].name=CONTAINERD_CONFIG \
    --set-string toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml \
    --set-string toolkit.env[1].name=CONTAINERD_SOCKET \
    --set-string toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
    --wait --timeout 15m
fi

# The real assertion: the NODE advertises a GPU as an allocatable resource.
say "   waiting for nvidia.com/gpu to appear as allocatable"
for i in $(seq 1 60); do
  COUNT="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  [[ -n "${COUNT:-}" && "${COUNT}" != "0" ]] && break
  sleep 10
done
[[ -n "${COUNT:-}" && "${COUNT}" != "0" ]] || die "node never advertised nvidia.com/gpu -- check: kubectl -n kube-system logs ds/nvidia-device-plugin-daemonset"
ok "allocatable nvidia.com/gpu = ${COUNT}"

# ---- 5. smoke test: a pod must actually see the card ------------------------
say "5. gpu pod smoke test"
kubectl delete pod gpu-smoke --ignore-not-found --wait=true >/dev/null
kubectl run gpu-smoke --image="${CUDA_SMOKE_IMAGE}" --restart=Never \
  --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"gpu-smoke","image":"'"${CUDA_SMOKE_IMAGE}"'","command":["nvidia-smi","-L"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}' \
  >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke --timeout=5m \
  || { kubectl describe pod gpu-smoke; die "smoke pod did not succeed"; }
kubectl logs gpu-smoke | sed 's/^/    /'
kubectl logs gpu-smoke | grep -qi "$EXPECTED_GPU" || die "pod ran but did not report a ${EXPECTED_GPU}"
kubectl delete pod gpu-smoke --wait=false >/dev/null
ok "a pod can see the ${EXPECTED_GPU}"

# ---- 6. cert-manager + KServe (same pins as week 2) -------------------------
say "6. cert-manager ${CERT_MANAGER_VERSION}"
if helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  ok "already installed"
else
  helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
  helm repo update >/dev/null
  helm install cert-manager jetstack/cert-manager \
    --version "${CERT_MANAGER_VERSION}" -n cert-manager --create-namespace \
    -f "${REPO_ROOT}/manifests/cert-manager-values.yaml" --wait --timeout 10m
fi
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=5m

say "7. KServe ${KSERVE_VERSION}"
helm status kserve-crd -n kserve >/dev/null 2>&1 || \
  helm install kserve-crd "oci://ghcr.io/kserve/charts/kserve-crd" \
    --version "${KSERVE_VERSION}" -n kserve --create-namespace --wait
helm status kserve -n kserve >/dev/null 2>&1 || \
  helm install kserve "oci://ghcr.io/kserve/charts/kserve-resources" \
    --version "${KSERVE_VERSION}" -n kserve \
    -f "${REPO_ROOT}/manifests/kserve-values.yaml" --wait --timeout 10m
kubectl -n kserve rollout status deploy/kserve-controller-manager --timeout=10m
kubectl get certificate -n kserve || true    # week-2 lesson: check this FIRST when an ISVC hangs

# ---- done --------------------------------------------------------------------
say "DONE"
cat <<SUMMARY
    gpu           : ${GPU_NAME} (driver ${DRIVER_VER})
    gpu stack     : ${GPU_STACK}
    k3s           : ${K3S_VERSION}
    cert-manager  : ${CERT_MANAGER_VERSION}
    kserve        : ${KSERVE_VERSION}
    allocatable   : nvidia.com/gpu = ${COUNT}
    log           : ${LOG_FILE}

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
SUMMARY
