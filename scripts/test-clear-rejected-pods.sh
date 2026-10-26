#!/usr/bin/env bash
# Week 6 A2 test, KIND ONLY: fake admission-rejected pods (unschedulable, status
# written by hand - a real rejection needs a GPU) + the real wait_one_replica
# from step-load.sh against the live KEDA qwen. Expect: N passed, 0 failed.
set -uo pipefail
cd ~/aify/llm-serving-lab
. scripts/lib-pods.sh
P=serving.kserve.io/inferenceservice
MSG='Allocate failed due to no healthy devices present; requested 1, but only 0 available (A2 FAKE)'
fake() {  # fake NS NAME LABELSPEC PHASE REASON
  local lbl=""; [ -n "$3" ] && lbl="\"labels\":{\"${3%%=*}\":\"${3#*=}\"},"
  kubectl apply -f - >/dev/null <<EOF
{"apiVersion":"v1","kind":"Pod","metadata":{"name":"$2","namespace":"$1",$lbl"annotations":{"a2-test":"fake"}},
 "spec":{"nodeSelector":{"a2-test":"no-such-node"},"containers":[{"name":"c","image":"registry.k8s.io/pause:3.10"}]}}
EOF
  [ "$4" = Pending ] && return 0
  kubectl patch pod -n "$1" "$2" --subresource=status --type=merge \
    -p "{\"status\":{\"phase\":\"$4\",\"reason\":\"$5\",\"message\":\"$MSG\"}}" >/dev/null
}
pass=0; fail=0
check() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }
exists() { kubectl get pod -n "$1" "$2" >/dev/null 2>&1; }

echo "== unit: namespace a2-test"
kubectl create ns a2-test >/dev/null 2>&1
fake a2-test rej-1   "$P=a2" Failed UnexpectedAdmissionError
fake a2-test evict-1 "$P=a2" Failed Evicted
fake a2-test pend-1  "$P=a2" Pending
fake a2-test other-1 ""      Failed UnexpectedAdmissionError
pod_report a2-test "$P=a2"
out=$(clear_rejected_pods a2-test "$P=a2"); echo "  output: $out"
check "rejected predictor pod deleted"        '! exists a2-test rej-1'
check "Evicted pod kept (evidence)"            'exists a2-test evict-1'
check "Pending pod kept"                       'exists a2-test pend-1'
check "unlabelled rejected pod kept"           'exists a2-test other-1'
check "output names the pod + message"         '[[ "$out" == *"a2-test/rej-1"*"no healthy devices"* ]]'
out=$(clear_rejected_pods a2-test "$P=a2"); check "second run: nothing to do, quiet" '[ -z "$out" ]'
kubectl delete ns a2-test --wait=false >/dev/null

echo "== integration: real wait_one_replica from step-load.sh, live KEDA qwen"
NAMESPACE=llm-serving; SEL="$P=qwen-0-5b"; DEPLOY=qwen-0-5b-predictor
HPA=$(kubectl get hpa -n llm-serving -o json | jq -r --arg d "$DEPLOY" '[.items[] | select(.spec.scaleTargetRef.name == $d)][0].metadata.name')
PRECONDITION_TIMEOUT_S=60; LOG=/tmp/a2-wait.log; : > "$LOG"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
eval "$(sed -n '/^wait_one_replica() {/,/^}/p' scripts/step-load.sh)"
fake llm-serving a2-rejected-qwen "$SEL" Failed UnexpectedAdmissionError
before=$(kubectl get pods -n llm-serving -l "$SEL" -o name | grep -c .)
echo "  pods matching $SEL before: $before (live qwen + fake rejected)"
t0=$(date +%s); wait_one_replica; rc=$?; dt=$(( $(date +%s) - t0 ))
check "precondition was broken before (2 pods)" '[ "$before" = 2 ]'
check "wait_one_replica returned 0 in ${dt}s"   '[ "$rc" = 0 ]'
check "fake rejected pod gone"                  '! exists llm-serving a2-rejected-qwen'
check "live qwen untouched (still 1 live)"      '[ "$(live_pods llm-serving "$SEL" | grep -c .)" = 1 ]'
check "clearing logged by the harness"          'grep -q "cleared rejected pod llm-serving/a2-rejected-qwen" "$LOG"'
echo "== CLI on kind (nothing rejected now)"; scripts/clear-rejected-pods.sh
echo "== RESULT: $pass passed, $fail failed"
