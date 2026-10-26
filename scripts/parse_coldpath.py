#!/usr/bin/env python3
"""parse_coldpath.py - cold-path results (scripts/coldpath.sh). Week 5 A5.

    uv run python scripts/parse_coldpath.py <run-dir> [<run-dir> ...] [--csv FILE]

Per run writes <run-dir>/coldpath-summary.json; prints one comparison table for
all runs given (e.g. the type-change boot and the two restarts).

THE CLOCK. Time 0 = `scw start` on the laptop clock. VM-side times (prober,
systemd, Kubernetes) are moved onto it with vm_minus_laptop_s, the mean of the
offsets coldpath.sh measured at start and end; drift > 0.5 s or no offset is
flagged. Kubernetes timestamps have 1 s resolution. A Kubernetes time earlier
than this boot's kernel start is from the PREVIOUS boot and never used as a
stage.

SEGMENTS are consecutive milestones on the critical path: provisioning, OS + k3s,
node Ready -> predictor scheduled, wait for copy, model copy, engine start-up,
first request. A milestone not observed makes its two segments n/a; the time
they cover is shown as "unattributed", so the segments ALWAYS add up to the time
to first token and nothing disappears from the table.

Values: a number, or "n/a:<why>". Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import gzip
import json
import re
import sys
from datetime import datetime
from pathlib import Path

DRIFT_FLAG_S = 0.5
BOOT_SLACK_S = 5.0   # k8s times this close before the kernel start still count (1 s resolution, approx boot)
PREDICTOR_LABEL = "serving.kserve.io/inferenceservice"


def na(why: str) -> str:
    return f"n/a:{why}"


def load(p: Path):
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def epoch(ts):
    if not ts:
        return None
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", ts)
    if not m:
        return None
    tz = m.group(3) or "Z"
    return datetime.fromisoformat(m.group(1) + (m.group(2) or ".0")[:7] + ("+00:00" if tz == "Z" else tz)).timestamp()


def cond(pod: dict, ctype: str):
    for c in pod.get("status", {}).get("conditions", []) or []:
        if c.get("type") == ctype and c.get("status") == "True":
            return epoch(c.get("lastTransitionTime"))
    return None


def parse_run(run: Path) -> dict:
    cp = load(run / "coldpath.json")
    if not cp:
        return {"run": run.name, "error": "ERROR:coldpath.json unreadable"}
    ev = cp.get("events", [])

    def first(name, **match):
        for e in ev:
            if e.get("event") == name and all(e.get(k) == v for k, v in match.items()):
                return e
        return None

    t0e = first("start_command")
    if not t0e:
        return {"run": run.name, "error": "ERROR:no start_command event"}
    t0 = t0e["t"]
    flags: list[str] = []

    # ---- clock offset
    offs = [e["vm_minus_laptop_s"] for e in ev if e.get("event", "").startswith("clock_offset") and "vm_minus_laptop_s" in e]
    if offs:
        off = sum(offs) / len(offs)
        drift = offs[-1] - offs[0] if len(offs) > 1 else None
        if drift is not None and abs(drift) > DRIFT_FLAG_S:
            flags.append(f"clock drift {drift:+.2f} s during the run")
    else:
        off, drift = 0.0, None
        flags.append("no clock offset measured - VM times used as if clocks agreed")

    def L(t):            # laptop time -> s after scw start
        return round(t - t0, 1) if t is not None else None

    def V(t):            # VM time -> s after scw start
        return round(t - off - t0, 1) if t is not None else None

    tl: dict = {}
    running = first("api_state", state="running")
    tl["api_running"] = L(running["t"]) if running else None
    ssh = first("ssh_up")
    tl["ssh_up"] = L(ssh["t"]) if ssh else None
    if ssh and ssh.get("upper_bound"):
        flags.append("SSH up on the first try: its time is an upper bound")
    for name in ("session_started", "watcher_armed"):
        e = first(name)
        tl[name] = L(e["t"]) if e else None

    # ---- VM facts
    vm = run / "vm"
    facts = load(vm / "vm-facts.json") or {}
    boot = facts.get("boot_epoch")
    tl["kernel_boot_approx"] = V(boot)
    units = facts.get("units", {})
    tl["k3s_active"] = V((units.get("k3s.service") or {}).get("active"))
    ssh_units = [(units.get(u) or {}).get("active") for u in ("ssh.socket", "ssh.service", "sshd.service")]
    ssh_units = [x for x in ssh_units if x]
    tl["ssh_unit_active"] = V(min(ssh_units)) if ssh_units else None
    gpus_seen = len(facts.get("gpus", []))

    def this_boot(t):
        return t is not None and (boot is None or t >= boot - BOOT_SLACK_S)

    k8s = vm / "k8s"
    nodes = (load(k8s / "nodes.json") or {}).get("items", [])
    pods = (load(k8s / "pods.json") or {}).get("items", [])
    ignored_prev = 0

    def kt(t):           # k8s time -> stage time, only if from this boot
        nonlocal ignored_prev
        if t is None:
            return None
        if not this_boot(t):
            ignored_prev += 1
            return None
        return V(t)

    # Week 6 A7: "node Ready" is NOT observable on single-node k3s - while the
    # VM is off the API server is off too, nothing marks the node NotReady, so
    # its Ready condition never changes at boot (lastTransitionTime stays at the
    # first boot, 2026-09-27; kt() rightly drops it). Kept for the record; the
    # critical path below uses milestones every boot DOES produce instead.
    tl["node_ready"] = max((kt(cond(n, "Ready")) for n in nodes), default=None, key=lambda x: x if x is not None else -1e18)
    evs = (load(k8s / "events.json") or {}).get("items", [])

    def ev_match(reason, kind, name_sub="", msg_sub=""):
        return [e for e in evs if e.get("reason") == reason
                and (e.get("involvedObject") or {}).get("kind") == kind
                and name_sub in (e.get("involvedObject") or {}).get("name", "")
                and msg_sub in (e.get("message") or "")
                and this_boot(epoch(e.get("firstTimestamp") or e.get("eventTime")))]

    def ev_first(*args, **kw):
        ts = [epoch(e.get("firstTimestamp") or e.get("eventTime")) for e in ev_match(*args, **kw)]
        return min(ts) if ts else None
    k3s_start = None
    jp = k8s / "k3s-journal.txt.gz"
    if jp.exists():
        with gzip.open(jp, "rt", errors="replace") as fh:
            for line in fh:
                if "Starting k3s.service" in line:
                    t_j = epoch(line.split(" ", 1)[0])
                    if this_boot(t_j):
                        k3s_start = t_j
                        break
    tl["k3s_start"] = kt(k3s_start)
    tl["kubelet_started"] = kt(ev_first("Starting", "Node", msg_sub="kubelet"))
    tl["old_predictor_rejected"] = kt(ev_first("UnexpectedAdmissionError", "Pod", name_sub="predictor"))
    blocked = ev_match("FailedCreate", "ReplicaSet", name_sub="predictor", msg_sub="webhook")
    tl["kserve_leader"] = kt(ev_first("LeaderElection", "Lease", name_sub="kserve"))
    boot_race = {"replacement_blocked_attempts": sum(int(e.get("count") or 1) for e in blocked),
                 "blocked_first_s": kt(min((epoch(e.get("firstTimestamp")) for e in blocked), default=None)),
                 "blocked_last_s": kt(max((epoch(e.get("lastTimestamp")) for e in blocked), default=None)),
                 "why": "ReplicaSet cannot create the replacement predictor until KServe's pod-mutating "
                        "webhook (served by the KServe controller, itself restarting) answers"} if blocked else \
                {"replacement_blocked_attempts": 0}
    alloc = [n.get("status", {}).get("allocatable", {}).get("nvidia.com/gpu") for n in nodes]
    alloc_gpus = sum(int(a) for a in alloc if a and str(a).isdigit())
    dp = [p for p in pods if "nvidia-device-plugin" in p["metadata"]["name"]]
    tl["gpu_plugin_ready"] = max((kt(cond(p, "Ready")) for p in dp), default=None, key=lambda x: x if x is not None else -1e18) if dp else None
    sw = [p for p in pods if "seaweedfs" in p["metadata"]["name"]]
    sw_ready = [kt(cond(p, "Ready")) for p in sw]
    tl["seaweedfs_ready_last"] = max(sw_ready) if sw_ready and None not in sw_ready else None

    # ---- predictor
    preds = [p for p in pods if PREDICTOR_LABEL in (p["metadata"].get("labels") or {})]
    failed_now = [p for p in preds if p.get("status", {}).get("phase") == "Failed" and this_boot(epoch(p["metadata"]["creationTimestamp"]))]
    if failed_now:
        reasons = sorted({p["status"].get("reason") or "?" for p in failed_now})
        flags.append(f"admission race: {len(failed_now)} predictor pod(s) Failed this boot ({', '.join(reasons)})")
    live = [p for p in preds if not p["metadata"].get("deletionTimestamp") and cond(p, "Ready")]
    pred: dict = {}
    if live:
        p = sorted(live, key=lambda x: x["metadata"]["creationTimestamp"])[-1]
        pred["pod"] = p["metadata"]["name"]
        created = epoch(p["metadata"]["creationTimestamp"])
        pred["recreated_this_boot"] = this_boot(created)
        if not pred["recreated_this_boot"]:
            flags.append("predictor pod reused across the reboot (not recreated)")
        tl["predictor_created"] = kt(created)
        tl["predictor_scheduled"] = kt(cond(p, "PodScheduled"))
        init = {c["name"]: c for c in p["status"].get("initContainerStatuses", []) or []}
        si = init.get("storage-initializer", {})
        term = (si.get("state") or {}).get("terminated") or {}
        tl["copy_started"] = kt(epoch(term.get("startedAt")))
        tl["copy_finished"] = kt(epoch(term.get("finishedAt")))
        pred["copy_ran_this_boot"] = tl["copy_started"] is not None
        if pred["copy_ran_this_boot"]:
            flags.append(f"model copy ran this boot ({tl['copy_finished'] - tl['copy_started']:.0f} s)"
                         if tl["copy_finished"] is not None else "model copy ran this boot")
        pred["storage_initializer_restarts"] = si.get("restartCount", 0)
        if pred["storage_initializer_restarts"]:
            flags.append(f"storage-initializer restarted {pred['storage_initializer_restarts']}x")
        cont = {c["name"]: c for c in p["status"].get("containerStatuses", []) or []}
        kc = cont.get("kserve-container", {})
        tl["engine_started"] = kt(epoch(((kc.get("state") or {}).get("running") or {}).get("startedAt")))
        pred["engine_restarts"] = kc.get("restartCount", 0)
        tl["predictor_ready"] = kt(cond(p, "Ready"))
    else:
        pred["pod"] = na("no live predictor pod in the dump")

    # ---- prober
    probe = []
    try:
        probe = [json.loads(x) for x in (vm / "probe.jsonl").read_text().splitlines() if x.strip()]
    except OSError:
        flags.append("no probe.jsonl")
    pfirst = {}
    for e in probe:
        pfirst.setdefault(e["event"], e)
    tl["probe_k8s_api_up"] = V(pfirst["k8s_api_up"]["t"]) if "k8s_api_up" in pfirst else None
    tl["probe_isvc_found"] = V(pfirst["isvc_found"]["t"]) if "isvc_found" in pfirst else None
    tl["probe_models_ok"] = V(pfirst["models_ok"]["t"]) if "models_ok" in pfirst else None
    reqs = [e for e in probe if e["event"] == "request"]
    tl["first_token"] = V(reqs[0]["done"]) if reqs else None
    status = (vm / "PROBE_DONE").read_text().strip() if (vm / "PROBE_DONE").exists() else "missing"
    if status != "ok first_token":
        flags.append(f"prober status: {status}")
    if gpus_seen and alloc_gpus != gpus_seen:
        flags.append(f"allocatable GPUs {alloc_gpus} != GPUs nvidia-smi sees {gpus_seen}")
    if ignored_prev:
        flags.append(f"{ignored_prev} Kubernetes time(s) from the previous boot ignored")

    # ---- stop
    sc, ss = first("stop_command"), first("api_stopped")
    stop_s = round(ss["t"] - sc["t"], 1) if sc and ss else None

    # ---- critical-path segments (consecutive; sum = first_token)
    path = [("provisioning (scw start -> API running)", 0.0, tl.get("api_running")),
            ("OS boot (API running -> k3s start)", tl.get("api_running"), tl.get("k3s_start")),
            ("k3s start -> kubelet up", tl.get("k3s_start"), tl.get("kubelet_started"))]
    if tl.get("old_predictor_rejected") is not None:          # the admission race happened
        path += [("kubelet up -> old predictor rejected (admission race)", tl.get("kubelet_started"), tl.get("old_predictor_rejected")),
                 ("rejected -> replacement created (waits for KServe webhook)", tl.get("old_predictor_rejected"), tl.get("predictor_created"))]
    else:
        path += [("kubelet up -> predictor created", tl.get("kubelet_started"), tl.get("predictor_created"))]
    path += [("created -> scheduled", tl.get("predictor_created"), tl.get("predictor_scheduled")),
            ("wait for copy (scheduled -> copy start)", tl.get("predictor_scheduled"), tl.get("copy_started")),
            ("model copy", tl.get("copy_started"), tl.get("copy_finished")),
            ("engine start-up (copy done -> Ready)", tl.get("copy_finished"), tl.get("predictor_ready")),
            ("first request (Ready -> first token)", tl.get("predictor_ready"), tl.get("first_token"))]
    segments = {}
    for name, a, b in path:
        segments[name] = round(b - a, 1) if a is not None and b is not None else na("milestone not observed")
    known = [v for v in segments.values() if isinstance(v, float)]
    if tl.get("first_token") is not None:
        segments["unattributed (milestone not observed)"] = round(tl["first_token"] - sum(known), 1)
    seg_sum = round(sum(v for v in segments.values() if isinstance(v, float)), 1)

    return {
        "run": run.name, "label": cp.get("label"), "mode": cp.get("mode"),
        "commercial_type": cp.get("commercial_type"), "status": cp.get("status"),
        "time_to_first_token_s": tl["first_token"] if tl["first_token"] is not None else na("no first token"),
        "first_request_s": reqs[0]["total_s"] if reqs else na("no request"),
        "next_requests_s": [r["total_s"] for r in reqs[1:3]],
        "stop_s": stop_s if stop_s is not None else na("not stopped by this run"),
        "clock": {"vm_minus_laptop_s": round(off, 4), "drift_s": round(drift, 4) if drift is not None else None,
                  "resolution": "laptop/prober ~0.1 s; Kubernetes 1 s; kernel boot approximate"},
        "timeline_s": {k: (v if v is not None else na("not observed")) for k, v in tl.items()},
        "segments_s": segments, "segments_sum_s": seg_sum, "boot_race": boot_race,
        "predictor": pred, "gpus": {"nvidia_smi": gpus_seen, "allocatable": alloc_gpus},
        "flags": flags}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--csv")
    a = ap.parse_args()
    out = []
    for r in a.runs:
        s = parse_run(Path(r))
        if "error" not in s:
            (Path(r) / "coldpath-summary.json").write_text(json.dumps(s, indent=2) + "\n", encoding="utf-8")
        out.append(s)
    for s in out:
        if "error" in s:
            print(f"{s['run']}: {s['error']}")
            continue
        print(f"\n{s['run']} ({s['label']}, {s['commercial_type']}, status {s['status']})")
        print(f"  time to first token: {s['time_to_first_token_s']} s   first request {s['first_request_s']} s"
              f"   next {s['next_requests_s']}   stop {s['stop_s']} s")
        for k, v in s["segments_s"].items():
            print(f"    {k:<44} {v}")
        print(f"    {'(segments sum)':<44} {s['segments_sum_s']}")
        for f in s["flags"]:
            print(f"  FLAG {f}")
    if a.csv:
        keys = list(next(s for s in out if "error" not in s)["segments_s"].keys()) if any("error" not in s for s in out) else []
        with open(a.csv, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["run", "label", "commercial_type", "status", "time_to_first_token_s", "first_request_s", "stop_s", *keys, "flags"])
            for s in out:
                if "error" in s:
                    continue
                w.writerow([s["run"], s["label"], s["commercial_type"], s["status"], s["time_to_first_token_s"],
                            s["first_request_s"], s["stop_s"], *[s["segments_s"][k] for k in keys], "; ".join(s["flags"])])
    return 0


if __name__ == "__main__":
    sys.exit(main())
