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

### Reconciled against the billing API, 2026-09-27

After session 1 (EUR 4.59 total), actual billed quantities vs the list prices
above:

| Item | Listed | Actual | Note |
|---|---|---|---|
| L40S-1-48G | EUR 1.47 / h | EUR 1.46988 / h | matches; billed 25 min for a 24.1 min run, so per-minute rounds UP |
| Block Storage 5K | EUR 0.000118 / GB / h | **~EUR 0.00013 / GB / h** (~EUR 0.095/GB/month) | ~10% higher than listed |
| Flexible IPv4 | EUR 0.004 / h | **EUR 0.005 / h** | 25% higher than listed |

Consequence: **a stopped instance costs ~EUR 0.588/day**, not the EUR 0.52/day
used earlier - 150 GB volume EUR 0.468 + IPv4 EUR 0.12.

This is the dominant line in the project so far. Of the first EUR 4.59,
EUR 0.63 was compute and **EUR 3.96 was the machine waiting**. The lever on
total cost is calendar time, not GPU hours: every idle week costs ~EUR 4.12.
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

- ~~All rates above are list prices; none confirmed against an invoice.~~
  **RECONCILED 2026-09-27** against the billing API - see the note under the
  rate table. Two rates were low: Block Storage and the flexible IPv4.
- ~~Whether a Block Storage volume can be detached from a cheap CPU instance and
  reattached to the L40S is NOT verified.~~ **VERIFIED 2026-09-20, session 1.**
  Full round trip: L40S -> detach -> DEV1-S -> detach -> L40S, sha256 checksums
  intact in both directions, no reformat, both detaches done with the source
  instance RUNNING. The weight download CAN therefore run on a DEV1-S at
  EUR 0.008976/h instead of the L40S at EUR 1.47/h, a ~164x rate difference.

  **CORRECTED 2026-09-27.** An earlier version of this bullet claimed ~EUR 0.85
  saved per download cycle. That rested on a ~35 min transfer time guessed
  before any hardware existed. Session 1 measured the real bandwidth: 8.47 GiB
  in 18.4 s, ~460 MB/s. 34.2 GiB is therefore ~80 s of wall time, ~EUR 0.03 of
  GPU clock - call it EUR 0.12-0.25 allowing for per-file overhead and Hugging
  Face throttling. A dedicated 100 GB weights volume costs ~EUR 0.31/DAY on top
  of the root volume, so it pays back in under three days and loses money every
  day after. **Not implemented for P1.** The portability result stands and
  still matters for nodes rebuilt often, or for far more than 34 GiB; it is
  simply not worth it for one node and one download.
- ~~PAR-2 L40S stock and the account's GPU quota are unverified.~~ **VERIFIED:**
  quota L40S-1-48G 0/2 in PAR 2, type reported `availability: available`, and an
  instance was created on first attempt 2026-09-20 with no quota request needed.
