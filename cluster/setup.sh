#!/usr/bin/env bash
#
# cluster/setup.sh - reproducible host setup for the llm-serving-lab substrate.
#
# Idempotent: safe to re-run. Re-running reinstalls the pinned versions,
# which is the point - it is how the box gets rebuilt after a WSL reset.
#
# Target: WSL2 Ubuntu 24.04, x86_64, Docker Desktop integration enabled.

set -euo pipefail

# --- pinned versions -------------------------------------------------------
# kubectl is pinned to the same minor as the kind node image used in
# cluster/kind-config.yaml. Kubernetes supports a +/-1 minor skew between
# client and server, but matching exactly removes a class of confusing errors.
# k8s 1.36 rather than the newest 1.37: KServe and the NVIDIA GPU Operator
# trail the Kubernetes release train, so one minor back is the safer end.
KUBECTL_VERSION=v1.36.4
HELM_VERSION=v4.3.0
KIND_VERSION=v0.33.0

BIN=/usr/local/bin

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# --- kubectl ---------------------------------------------------------------
# NOTE: Docker Desktop's WSL integration plants its own kubectl at
# /usr/local/bin/kubectl as a symlink into /mnt/wsl/docker-desktop/.
# We replace it so the version is ours and recorded here, not Docker's.
echo "==> kubectl ${KUBECTL_VERSION}"
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256"
# The .sha256 file contains a bare hash; sha256sum --check needs "<hash>  <file>".
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
rm -f "${BIN}/kubectl"          # drop the symlink before writing a real file
install -m 0755 kubectl "${BIN}/kubectl"

# --- helm ------------------------------------------------------------------
# Helm 4. Chart API v2 charts (everything published today) work unchanged;
# the v3->v4 breakage is in CLI flags and plugins. Helm 3's final feature
# release was 2026-09-09, so new work starts on 4.
# Behaviour change worth remembering: Helm 4 defaults to server-side apply.
echo "==> helm ${HELM_VERSION}"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
sha256sum --check "helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz" linux-amd64/helm
install -m 0755 linux-amd64/helm "${BIN}/helm"

# --- kind ------------------------------------------------------------------
echo "==> kind ${KIND_VERSION}"
curl -fsSL -o kind "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
curl -fsSL -o kind.sha256 "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64.sha256sum"
# Checksum file names the asset "kind-linux-amd64"; we saved it as "kind".
awk '{print $1 "  kind"}' kind.sha256 | sha256sum --check
install -m 0755 kind "${BIN}/kind"

# --- uv on PATH everywhere -------------------------------------------------
# uv lives in ~/.local/bin, which is added to PATH by ~/.local/bin/env, sourced
# from .bashrc and .profile. Those only run in interactive or login shells, so
# `bash script.sh` cannot see uv. Symlinking into /usr/local/bin - already on
# the default PATH - makes it resolve in every shell. The symlink follows
# `uv self update`, which replaces the target in place.
echo "==> uv symlinks"
if [ -x "${HOME}/.local/bin/uv" ]; then
  ln -sf "${HOME}/.local/bin/uv"  "${BIN}/uv"
  ln -sf "${HOME}/.local/bin/uvx" "${BIN}/uvx"
else
  echo "WARNING: ~/.local/bin/uv not found; install uv first" >&2
fi

# --- verify ----------------------------------------------------------------
echo
echo "==> installed"
kubectl version --client
helm version --short
kind version
uv --version
