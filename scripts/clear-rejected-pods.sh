#!/usr/bin/env bash
#
# scripts/clear-rejected-pods.sh - run after EVERY boot of the GPU node, before
# any harness run (week 6 A2; week-5 open item "boot admission race").
#
#   scripts/clear-rejected-pods.sh
#
# Deletes KServe predictor pods (any namespace, label
# serving.kserve.io/inferenceservice) that the kubelet rejected at admission:
# phase Failed + reason UnexpectedAdmissionError. Nothing else - see
# clear_rejected_pods in lib-pods.sh for why only that reason.
# step-load.sh also does this itself before each cycle; this script is the
# explicit boot step, so the cluster is clean for every tool, not just one.
# Exit: 0 (also when nothing was rejected) | 1 kubectl cannot reach a cluster.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib-pods.sh"
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi
kubectl version --request-timeout=10s >/dev/null 2>&1 || { echo "kubectl cannot reach a cluster" >&2; exit 1; }

SEL=serving.kserve.io/inferenceservice
n=0
for ns in $(kubectl get pods -A -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  while IFS= read -r line; do
    [ -n "$line" ] && { echo "$line"; n=$((n + 1)); }
  done < <(clear_rejected_pods "$ns" "$SEL")
done
echo "clear-rejected-pods: $n rejected predictor pod(s) deleted"
