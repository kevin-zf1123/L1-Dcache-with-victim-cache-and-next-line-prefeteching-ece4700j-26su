# Adaptive Direct-L1 Prefetch Evidence (2026-07-13)

English is authoritative. This directory publishes address-free results from
the final 25-window, 125,511-demand, zero-bubble campaign. Licensed traces,
per-demand sidecars, simulation logs, binaries, and private manifests remain
under ignored `build/spec2026/` paths.

All four campaigns validated 100 runs, 25 exact off/on pairs, and 50 standalone
capacity controls. Geometry was 2 ways, 4 sets, 16-byte lines, and a four-entry
victim cache for each paired comparison. Lower-memory read latency was 2 with
periodic ready backpressure.

| Policy | Cycle delta | Byte overhead | Harmful / neutral / helpful | PF issues | Merges | Installs | PF-caused WB |
| --- | ---: | ---: | --- | ---: | ---: | ---: | ---: |
| Frozen legacy (`0/0`) | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Safe next-line P1 (`1/1`) | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Adaptive stream P2 (`1/2`) | 0 | 0 | 0 / 25 / 0 | 0 | 0 | 0 | 0 |
| Shadow + PF MSHR P3 (`1/3`) | **-724** | **0** | **0 / 7 / 18** | 544 | 544 | 0 | 0 |

P3 reduced demand-owned reads from 59,275 to 58,731 while issuing 544
same-line prefetch reads. Consequently total read and write bytes remained
identical to optimized-off. All 25 windows were non-degrading; the best window
saved 80 cycles and the worst delta was zero. The result passes the primary
cycle, bandwidth, per-window, slowdown, dirty-write-back, and legacy-comparison
gates for this timing profile.

`aggregate.csv` is a compact public roll-up. `classification.csv` publishes
each P3 window's cycle classification without addresses. `provenance.json`
binds these public records to the private validated campaign and analyzer
artifacts by SHA-256.

`sensitivity.csv` publishes the fourteen legacy/P3 sensitivity aggregates.
All seven profile pairs passed. Under latency-2/periodic-ready, P3 was neutral
for sequential and fixed-gap 1/2/4/8 while legacy added both cycles and
672,032 bytes, so P3 strictly improved both metrics. Under zero-bubble
latency-0/always-ready and latency-8/deterministic-random-ready, P3 saved 570
and 859 cycles respectively, but both legacy and P3 had zero byte overhead.
Those two timing results are therefore cycle-improving and bandwidth-neutral
(Pareto/non-regressing), not strict bandwidth reductions. The latency-8 result
contained one +71-cycle (+0.1282%) harmful window but saved 859 cycles overall.
See `validation.md` for the complete local test and gate record.

All 650 schema-3 main/sensitivity run rows closed the admission lifecycle:
every admission issued or cancelled before reporting, and every issue returned
to exactly one install, merge, or discard outcome.

## Remote XSim and synthesis evidence

The final Vivado 2024.2.1 run completed with a `PASS` manifest and no
findings. Its 11 simulation logs comprise eight workload configurations and
three directed auxiliary tops. All 83 workload rows were schema 3, reported
`PASS`, and satisfied the drained optimized-prefetch lifecycle checks. Four
synthesis configurations produced all 12 expected utilization, timing, and
power reports. The redacted public manifest is
[`../vivado-2026-07-13-optimized.json`](../vivado-2026-07-13-optimized.json),
and the extracted metrics are in [`vivado-ppa.csv`](vivado-ppa.csv).

| Configuration | LUTs | LUT memory | Registers | BRAM | WNS (ns) | Estimated Fmax (MHz) | Power (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | -1.019 | 90.752 | 0.124 |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | -2.130 | 82.440 | 0.125 |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | -2.500 | 80.000 | 0.128 |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | -9.342 | 51.701 | 0.139 |

Against the matching optimized-off `2w_s4_vc4_pf0` point, P3 adds 3,745
LUTs (+52.473%) and 1,543 registers (+48.009%), with no additional LUT memory
or BRAM. WNS worsens by 7.212 ns, estimated Fmax falls by 30.739 MHz
(-37.287%), and estimated total power rises by 0.014 W (+11.2%). These costs
show that the functionally successful P3 policy still needs datapath and
control optimization before a 100 MHz implementation claim is supportable.

## PPA limitations

These are synthesis-only, unplaced estimates for `xc7a35tcpg236-1` under a
10 ns clock. All four configurations fail 100 MHz setup timing, although hold
timing passes. `Estimated Fmax` is only the slack-derived approximation
`1000 / (10 - WNS)`; it is not a post-route achieved frequency. The research
top also has incomplete I/O delays and more bonded-I/O demand than the target
device, so its timing reports are not board sign-off evidence. Power uses no
simulation activity file and Vivado labels every estimate `Low` confidence.
Accordingly, the PPA table is a comparative research snapshot; it does not
override the local cycle/bandwidth gates or establish timing closure, routed
resource use, or measured power.
