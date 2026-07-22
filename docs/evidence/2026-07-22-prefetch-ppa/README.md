# Prefetch and PPA Closure Evidence (2026-07-22)

This address-free package is the public roll-up for the July 22 replay,
sensitivity, synthesis, implementation, timing, and power closure. English is
authoritative; the reader-oriented Chinese translation is
[`zh/README.zh.md`](zh/README.zh.md).

## Decision

The combined gate decision is
`DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`. The deployment wrapper therefore
keeps `ENABLE_PREFETCH=0` by default. Full P3 and P3-lite remain research
profiles that require explicit elaboration-time opt-in.

This is a measured negative result, not a validation failure. Every replay
campaign and the Vivado evidence manifest passed integrity checks; the design
failed the required performance, area, setup-timing, power, and
achieved-frequency execution-time gates.

## Main replay result

All rows use the same 25 attributable windows, 2-way/4-set/16-byte-line/VC4
geometry, true zero-bubble producer, and fixed-latency-2 periodic-ready memory
model.

| Variant | Off cycles | On cycles | Delta | Byte overhead | Harmful / neutral / helpful | Issued / merged / installed |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| legacy | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P1 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P2 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| full P3 | 850,547 | 850,546 | -1 | 0% | 4 / 16 / 5 | 508 / 508 / 0 |
| P3-lite | 850,547 | 850,578 | +31 | 0% | 9 / 8 / 8 | 1,301 / 1,301 / 0 |

P3-lite slowed aggregate replay by 0.0036447% and had 16/25 non-slow
windows. It passed bandwidth, per-window maximum slowdown, and attributed
write-back gates, but failed the required 1% aggregate improvement and 20/25
non-slow-window gates. The parameter sweep did not reverse the conclusion:
the best point, `PF_ON_REFILL=16`, still added 17 cycles.

Sensitivity establishes the structural boundary. The frozen legacy policy
issued and installed aggressively under sequential/fixed-gap producers,
causing up to 33.66% more cycles and 53.80% more bytes. P3-lite suppressed all
unsafe sequential/gap-1/gap-2 work and cancelled admitted gap-4/gap-8 work
before issue. Under zero-bubble timing profiles it remained neutral or
slightly slower and never installed a prefetched line.

## Vivado result

Vivado 2024.2.1 targeted `xc7a35tcpg236-1` with a 10 ns clock. The evidence
manifest validated 15 XSim logs, eight OOC synthesis configurations, four
independent post-route implementations, SAIF activity, all required reports,
and 121 downloaded log/report files with zero findings.

| Gate metric | Optimized PF0 | P3-lite | Delta / result | Gate |
| --- | ---: | ---: | ---: | --- |
| OOC slice LUTs | 6,048 | 10,055 | +66.253% | fail (`<=15%`) |
| OOC registers | 2,047 | 3,095 | +51.197% | fail (`<=15%`) |
| OOC WNS | +0.363 ns | -5.896 ns | -6.259 ns | fail (`>=0`) |
| post-route WNS | -0.407 ns | -4.169 ns | -3.762 ns | fail (`>=0`) |
| post-route WHS | +0.118 ns | +0.065 ns | hold clean | pass |
| activity dynamic power | 0.008 W | 0.015 W | +87.5% | fail (`<=10%`) |
| achieved-Fmax time proxy | — | — | -36.154% | fail (`>0%`) |

All four post-route implementations have non-negative hold slack and no
unconstrained paths. Setup closure fails even for PF0 and legacy, while P3 and
P3-lite are materially worse. The stream detector dominates the added logic
and critical paths; removing adaptive and shadow logic is insufficient to meet
the deployment gates without an interface- or architecture-level redesign.

## Files

- [`aggregate.csv`](aggregate.csv): five main replay variants.
- [`pairs.csv`](pairs.csv) and [`classification.csv`](classification.csv):
  exact P3-lite off/on windows and helpful/neutral/harmful labels.
- [`sweep.csv`](sweep.csv): P3-lite controller parameter sweep.
- [`sensitivity.csv`](sensitivity.csv): legacy and P3-lite producer/timing
  sensitivity matrix.
- [`vivado-ppa.csv`](vivado-ppa.csv): OOC and post-route area, timing, and
  vectorless/activity power metrics.
- [`gate-result.json`](gate-result.json): redacted machine-readable gate
  decision.
- [`provenance.json`](provenance.json): public artifact and private-source
  hashes, without licensed traces, addresses, credentials, or private paths.
- [`validation.md`](validation.md): validation commands and outcomes.

Licensed traces, raw sidecars, simulator logs, checkpoints, VCD/SAIF files,
and the private Vivado manifest remain under ignored build directories. The
CSV and JSON files here contain no replay addresses or workstation/remote-host
paths.
