# Scaling constants - week 5 time-to-relief budget

Every stage between "load rises" and "the second replica takes traffic", with its
value, where the value comes from, and whether it is a knob. Written 2026-10-25
(A3). Measured = observed on our clusters; Source = read in the pinned code;
Pilot = derived from session-4 `pilot-gpu-1`.

## The scaling rule (Manoj, 2026-10-25)

| item | value | basis |
|---|---|---|
| metric | `vllm:num_requests_running` (requests in flight) | decision, NOTES "Week 5 A3 decision" |
| KEDA query | `sum(avg_over_time(vllm:num_requests_running{namespace="llm-serving",isvc="<isvc>"}[45s]))` | sum = TOTAL across pods (KEDA AverageValue divides by threshold) |
| threshold | 24 per replica - a setpoint, not an alarm | decision |
| replicas | ceil(total / 24), min 1, max 2 | KEDA `scaler.go:105-107` (AverageValue default) |
| HPA tolerance | acts only beyond +/-10%: scale-up above ~26.4 | Kubernetes HPA default |

## Stages of time-to-relief (one replica -> two)

| # | stage | value | basis | knob? |
|---|---|---|---|---|
| 1 | load rises -> vLLM gauge moves | immediate | Measured (kind) | no |
| 2 | Prometheus scrape | data age 0-5 s (mean ~2.5) | Measured (kind, `timestamp()`), `scrape_interval: 5s` | yes, `manifests/prometheus.yaml` |
| 3 | 45 s smoothing reaches 26.4 | ~28 s on a 4 -> 6 req/s step | Pilot replay (`w5-a3-step.py`): 15 s window false-triggers at 4 req/s (29.4); 30 s margin +0.3; **45 s margin +1.9**, same 28 s; 60 s 31.5 s | yes, query window |
| 4 | HPA sync asks KEDA, KEDA queries Prometheus live | <= 15 s | Source (`scale_handler.go:853-859`); kind: no override of `--horizontal-pod-autoscaler-sync-period` (default 15 s). **k3s: confirm in session 5** | cluster flag only |
| - | KEDA `pollingInterval` (30 s) | **not in the path** at min >= 1 | Source (`IsPollingIntervalRelevant`, `scaledobject_types.go:304-318`) | n/a |
| 5 | HPA scale-up stabilisation | 0 s | KServe `inferenceservice-config` `autoscaler` key (live, kind) | yes |
| 6 | pod scheduled, image cached, model copied | kind: storage copy ~6 s; GPU: measure in session 5 | Measured (A0 sidecar, kind) | no |
| 7 | vLLM engine start -> "Application startup complete" | kind ~98 s; GPU ~95 s | Measured (A0 sidecar / session 4) | not in week 5 |
| 8 | startup probe sees it -> pod Ready | **<= 5 s** (was up to 30 s) | `startupProbe.periodSeconds: 5` since 2026-10-25; kind before the change: 16 s | yes, ServingRuntime |
| 9 | Service endpoint updated -> traffic | ~1 s | Kubernetes endpoints controller; measure in session 5 | no |

**Expected time-to-relief on the GPU, 4 -> 6 req/s step:** detection (stages 2-4)
~30-48 s, then pod start (6-9) ~100 s + model copy -> **~2.2-2.5 min plus copy**.
Before the probe change, stage 8 alone could add 25 s more.

## Scale-down

| item | value | basis |
|---|---|---|
| condition | ceil(total / 24) = 1, i.e. total <= 24 (at 2 replicas the per-pod ratio is then <= 0.5, far outside the 10% tolerance) | HPA |
| stabilisation window | 300 s (HPA keeps the HIGHEST desired count seen in the window) | KServe config, live on kind |
| known oscillation band | ~4.5-5 req/s - 1 replica slightly too few, 2 too many | NOTES "Week 5 A3 decision"; A4 places steps deliberately |

## Measurement rule (learned 2026-10-25)
On kind under load, read Prometheus through a **port-forward**, never through the
API-server proxy: CPU vLLM saturates the laptop and the proxy stalls ~25 s, which
looks exactly like Prometheus lag but is not (`timestamp()` shows 0-5 s).
