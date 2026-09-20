# Cost model - P1 llm-serving-lab

**Provider:** Scaleway | **Region/AZ:** PAR-2 | **Instance:** L40S-1-48G
**Written:** 2026-09-19 | **Kill criterion: EUR 60** (see below)

Every rate below is quoted excluding VAT and is cited to the provider's own
page with the date it was checked. Third-party price trackers are NOT used:
during selection they reported Verda's L40S at $1.37/h when the vendor's own
rate card said $1.45/h.

## 1. Verified rates

| Item | Rate | Source | Checked |
|---|---|---|---|
| L40S-1-48G (1x L40S 48GB, 8 vCPU EPYC 7413, 96 GB RAM) | EUR 1.47 / hour | scaleway.com/en/l40s-gpu-instance | 2026-09-19 |
| Block Storage 5K (up to 5,000 IOPS) | EUR 0.000118 / GB / hour (~EUR 0.086/GB/month) | scaleway.com/en/pricing/storage | 2026-09-19 |
| Block/Unified Snapshot | EUR 0.000044 / GB / hour | scaleway.com/en/pricing/storage | 2026-09-19 |
| Flexible IPv4 | EUR 0.004 / hour (~EUR 2.92/month) | scaleway.com/en/docs/instances/faq + pricing/virtual-instances | 2026-09-19 |
| Egress / ingress | not charged on GPU Instances (see note 3) | scaleway.com/en/gpu-instances | 2026-09-19 |

### Billing rules that drive the model
1. GPU Instances are billed **per minute of uptime**, including startup and
   standby time. Standby is charged as running.
2. **Powering off stops compute billing.** Storage volumes and the flexible
   IPv4 keep billing for their whole allocation period regardless of power
   state. IPv4 billing runs from reservation to deletion, even when detached.
3. Flexible IP billing is rounded up to a minimum of EUR 0.01 per IP, so very
   short-lived IPs cost more than the hourly rate suggests.
4. Scratch NVMe (1.6 TB, included in the instance price) is EPHEMERAL - it is
   destroyed when the machine is switched off. Nothing durable may live there.
   All 34 GiB of weights live on Block Storage. See A3.
5. Savings plans explicitly do NOT apply to L40S. On-demand is the only rate.

## 2. Assumptions (these are estimates, not measured)

Work proceeds in evening/weekend sessions with no fixed schedule, so the model
is parameterised on GPU-hours, with calendar time as a separate, much smaller
term.

| # | Session | Est. GPU-hours | Purpose |
|---|---|---|---|
| 1 | Bring-up: k3s, GPU operator, KServe, image pulls | 1.5 - 2.0 | first contact with real hardware |
| 2 | First leg end-to-end (BF16 only) | 1.0 - 1.5 | prove the path before spending on 4 legs |
| 3 | Shakedown sweep, all four legs | 2.0 - 2.5 | numbers deliberately thrown away |
| 4 | Clean measured sweep, all four legs | 2.0 - 3.0 | the numbers that go in the report |
| 5 | Contingency re-run | 1.5 - 2.0 | assume it is needed |
| | **Total** | **8 - 11** | |

Sessions 3 and 4 are separate on purpose: a first benchmark pass usually has a
methodology bug in it (no warmup, wrong max-model-len, silently queued
concurrency). Budgeting the throwaway makes it a plan instead of a failure.

## 3. Formula

    spend = (GPU-hours x 1.47) + (volume_GB x days x 24 x 0.000118) + (days x 24 x 0.004)

## 4. Scenarios (150 GB volume, 1 flexible IPv4)

| GPU-hours | Calendar | Compute | Storage | IPv4 | **Total** |
|---|---|---|---|---|---|
| 4 | 1 week | EUR 5.88 | EUR 2.97 | EUR 0.67 | **EUR 9.52** |
| 8 | 2 weeks | EUR 11.76 | EUR 5.95 | EUR 1.34 | **EUR 19.05** |
| 11 | 2 weeks | EUR 16.17 | EUR 5.95 | EUR 1.34 | **EUR 23.46** |
| 11 | 4 weeks | EUR 16.17 | EUR 11.89 | EUR 2.69 | **EUR 30.75** |
| 16 (two full re-runs) | 6 weeks | EUR 23.52 | EUR 17.84 | EUR 4.03 | **EUR 45.39** |

Stretching the calendar costs ~EUR 0.42/day for storage plus ~EUR 0.10/day for
the IP. Working slowly is cheap; re-running a sweep is not. Do not rush a run
to save calendar days.

### The real risk is not idle days
Leaving the instance powered on overnight costs ~EUR 17.6 (12h x 1.47) - more
than a month of idle storage. Mitigations, both required before first boot:
- the Phase B session wrapper always ends with a power-off;
- a Scaleway budget alert is configured before the first instance is created.

## 5. Currency

EUR 60 kill criterion. Conversion to INR is not fixed here because the rate
moves; convert at the time of reporting and state the date alongside the
figure.

## 6. Kill criterion

**If the running total crosses EUR 60, stop and reassess** rather than
continuing. At the planned 8-11 GPU-hours the expected total is EUR 19-31, so
EUR 60 is only reached if something has gone wrong roughly twice over.

Check the running total in the Scaleway console (Billing / Cost Manager) at
the end of every session and record it in the session log (Phase B, B3).

## 7. Known gaps

- All rates above are list prices read from the vendor's pages. None has yet
  been confirmed against an actual invoice; reconcile after session 1.
- Whether a Block Storage volume can be detached from a cheap CPU instance and
  reattached to the L40S (to download the 34 GiB of weights off GPU time) is
  NOT verified. If it works it saves ~EUR 0.9 per download cycle. Verify in
  the console before session 1.
- PAR-2 L40S stock and the account's GPU quota are unverified. New accounts
  can start at a zero GPU quota; a quota request may take hours to a day.
