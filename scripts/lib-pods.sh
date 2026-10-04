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
