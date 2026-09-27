#!/usr/bin/env bash
# Create the S3 credentials Secret + ServiceAccount that KServe's
# storage-initializer uses to pull models out of MinIO.
#
# P1 week 2, step 9.
#
# This is a SCRIPT rather than a committed manifest on purpose: the Secret
# contains MinIO's real credentials, which live in .env and are gitignored.
# A YAML file with those values baked in could not be committed, so the
# reproducible artifact is the script that builds it.
#
# Usage:  ./scripts/create-s3-secret.sh [namespace]

set -euo pipefail

NS="${1:-llm-serving}"
SECRET_NAME="minio-s3-creds"
SA_NAME="minio-sa"
# In-cluster address of the S3 store. SeaweedFS since 2026-09-27 (MinIO's
# images are no longer pullable). Override for any other S3 server.
S3_ENDPOINT="${S3_ENDPOINT:-seaweedfs-s3.seaweedfs.svc.cluster.local:8333}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

[ -f "$ENV_FILE" ] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }

# Parsed with partition-on-first-= and never sourced, matching the technique
# already used by upload_model.py. Sourcing .env would execute whatever it
# contains and would choke on values holding spaces or shell metacharacters.
get_env() {
  local key="$1" line
  line="$(grep -E "^${key}=" "$ENV_FILE" | head -1 || true)"
  [ -n "$line" ] || { echo "ERROR: $key missing from .env" >&2; exit 1; }
  printf '%s' "${line#*=}"
}

ACCESS_KEY="$(get_env MINIO_ROOT_USER)"
SECRET_KEY="$(get_env MINIO_ROOT_PASSWORD)"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# --- Secret -----------------------------------------------------------------
# The annotations are the entire point of this object. KServe reads them and
# translates each into an environment variable on the storage-initializer
# init container. Without them the initializer builds a default AWS client
# and tries to reach the real s3.amazonaws.com.
#
# Credential KEY NAMES are not arbitrary: they come from the live
# inferenceservice-config ConfigMap (s3AccessKeyIDName / s3SecretAccessKeyName).
kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -

kubectl annotate secret "$SECRET_NAME" -n "$NS" --overwrite \
  serving.kserve.io/s3-endpoint="${S3_ENDPOINT}" \
  serving.kserve.io/s3-usehttps=0 \
  serving.kserve.io/s3-region=us-east-1 \
  serving.kserve.io/s3-verifyssl=0 \
  serving.kserve.io/s3-usevirtualbucket=false

# Notes on each annotation, so this is defensible later:
#
#   s3-endpoint          In-cluster DNS of the S3 Service (SeaweedFS; was MinIO). NOT the value of
#                        MINIO_ENDPOINT in .env -- that one is host-facing
#                        (localhost), and inside a pod localhost is the pod.
#                        No scheme in the value; the scheme comes from
#                        s3-usehttps below.
#
#   s3-usehttps=0        MinIO here serves plain HTTP.
#
#   s3-region            MinIO ignores regions, but AWS SigV4 hashes the
#                        region into the request signature, so the client
#                        will not sign without one. Signing input, not
#                        routing input. Same reasoning as upload_model.py.
#
#   s3-verifyssl=0       Nothing to verify over plain HTTP.
#
#   s3-usevirtualbucket=false
#                        THE important one. Default (virtual-host) addressing
#                        would build
#                          http://models.minio.minio.svc.cluster.local:9000/...
#                        which does not resolve. Path style keeps the bucket
#                        in the path. This is the KServe equivalent of
#                        Config(s3={"addressing_style": "path"}) in
#                        upload_model.py -- see NOTES.md week 1.

# --- ServiceAccount ---------------------------------------------------------
# The InferenceService names this ServiceAccount; the ServiceAccount names the
# Secret. That indirection is how KServe finds the credentials.
kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA_NAME
  namespace: $NS
secrets:
  - name: $SECRET_NAME
YAML

echo
echo "--- created in namespace: $NS ---"
kubectl get sa "$SA_NAME" -n "$NS"
echo
echo "annotations on $SECRET_NAME (values deliberately not printed):"
kubectl get secret "$SECRET_NAME" -n "$NS" \
  -o jsonpath='{range .metadata.annotations}{@}{"\n"}{end}' \
  | tr ',' '\n' | grep s3 || true
echo
echo "secret data keys:"
kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{range .data}{@}{end}' \
  | tr ',' '\n' | cut -d'"' -f2 | grep AWS || true
