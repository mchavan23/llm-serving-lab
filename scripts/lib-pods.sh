# scripts/lib-pods.sh - pod selection shared by the harness and verify scripts.
# SOURCED, not executed:  . "$REPO_ROOT/scripts/lib-pods.sh"
#
# Why this exists (recipe fix 3, NOTES 2026-10-04): every script used to take
# `.items[0]` of a label query. The API returns pods sorted by NAME, and a label
# matches pods in ANY state, so `.items[0]` could be a Terminating pod during a
# rollout (which still reports phase Running), a Failed pod left behind by
# UnexpectedAdmissionError after a reboot (session 3), or one of two healthy
# replicas once KEDA scales to 2 (week 5). Nothing errors; the numbers are wrong.

# live_pods NS SELECTOR
#   Names of pods that are actually serving, one per line:
#   phase Running AND not being deleted AND condition Ready=True.
#   jq, not jsonpath: jsonpath cannot test that deletionTimestamp is ABSENT.
live_pods() {
  kubectl get pod -n "$1" -l "$2" -o json 2>/dev/null | jq -r '
    .items[]
    | select(.metadata.deletionTimestamp == null)
    | select(.status.phase == "Running")
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
    | .metadata.name'
}

# pod_report NS SELECTOR
#   Every pod the selector matches, live or not, with the fields that explain
#   why it is or is not live. A Failed pod shows its reason here, e.g.
#   UnexpectedAdmissionError - the post-reboot check the recipe asks for.
pod_report() {
  kubectl get pod -n "$1" -l "$2" -o json 2>/dev/null | jq -r '
    .items[]
    | "    \(.metadata.name)  phase=\(.status.phase)  reason=\(.status.reason // "-")"
      + "  ready=\((.status.conditions // []) | map(select(.type == "Ready")) | .[0].status // "-")"
      + "  terminating=\(if .metadata.deletionTimestamp then "yes" else "no" end)"'
}

# one_live_pod NS SELECTOR
#   For scripts that assume a single serving pod. Prints its name and returns 0
#   only if EXACTLY one pod is live; otherwise prints the count and pod_report
#   to stderr and returns 1. Two live pods is a deliberate failure: a script
#   that silently reads one of two replicas makes the other look idle.
one_live_pod() {
  local pods n
  pods=$(live_pods "$1" "$2")
  n=$(printf '%s' "$pods" | grep -c .)
  if [ "$n" -eq 1 ]; then
    printf '%s\n' "$pods"
    return 0
  fi
  echo "one_live_pod: expected 1 live pod for '-l $2' in $1, found $n" >&2
  pod_report "$1" "$2" >&2
  return 1
}

# clear_rejected_pods NS SELECTOR
#   Deletes pods the kubelet REJECTED AT ADMISSION: phase Failed AND reason
#   UnexpectedAdmissionError (week 5: on EVERY GPU boot the previous boot's
#   predictor pod is re-admitted before the NVIDIA device plugin registers the
#   GPU -> "Allocate failed due to no healthy devices present"; a fresh pod then
#   serves). Failed pods are never garbage-collected, so it stays and breaks
#   step-load's "exactly one pod" precondition. A rejected pod never ran a
#   container: it holds no data and no evidence beyond its message, which is
#   printed here. ANY OTHER Failed pod (OOMKilled, Evicted, ...) is left alone -
#   it is evidence and should still stop the harness.
#   Prints one line per deleted pod on stdout; returns 0 (also when none).
clear_rejected_pods() {
  local name msg
  kubectl get pod -n "$1" -l "$2" -o json 2>/dev/null | jq -r '
    .items[]
    | select(.status.phase == "Failed" and .status.reason == "UnexpectedAdmissionError")
    | "\(.metadata.name)\t\((.status.message // "-") | gsub("[\t\n]"; " "))"' |
  while IFS=$'\t' read -r name msg; do
    if kubectl delete pod -n "$1" "$name" --wait=true --timeout=60s >/dev/null 2>&1; then
      echo "cleared rejected pod $1/$name (UnexpectedAdmissionError: $msg)"
    else
      echo "clear_rejected_pods: FAILED to delete $1/$name" >&2
    fi
  done
  return 0
}
