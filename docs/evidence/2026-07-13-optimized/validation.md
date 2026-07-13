# Optimized Prefetcher Validation Record

English is authoritative. All commands ran from the repository root on
2026-07-13. Licensed traces, logs, sidecars, binaries, and complete manifests
remain in the ignored private build tree.

## Local functional verification

- `scripts/run_iverilog.sh`: ten cache simulations reported `ALL TESTS
  PASSED`; 20/20 workload records passed; its embedded 76-check prefetch-unit
  suite passed.
- `scripts/run_p3_tests.sh`: 62 directed PF-MSHR checks, ten optimized edge
  scenarios, and the true zero-bubble issue/merge replay passed.
- `scripts/run_prefetch_unit_tests.sh`: 76 stream/controller checks passed.
- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`: 82 tests
  passed.
- Shell syntax checks, Python byte-code compilation, and `git diff --check`
  passed.

Icarus emitted only its known constant-select/unpacked-array sensitivity and
testbench `$fatal` synthesis diagnostics. No test emitted a functional
`FAIL`, `FATAL`, protocol, watchdog, duplicate-line, or conservation failure.

## Replay gates

The main P3 profile passed 100/100 runs and 25/25 exact pairs: aggregate cycle
delta -724, byte overhead zero, 25/25 non-degrading windows, maximum slowdown
zero, and zero prefetch-caused write-back. The seven sensitivity profile pairs
passed another 700 runs and 350 exact pairs. P3's aggregate cycle delta was
never positive and its byte overhead was always zero. For the
latency-2/periodic-ready sequential and fixed-gap profiles, legacy added cycles
and 672,032 bytes while P3 added neither, so both metrics strictly improved.
For zero-bubble latency-0/always-ready and latency-8/deterministic-random-ready,
legacy and P3 both had zero byte overhead; P3's 570- and 859-cycle savings are
therefore strict cycle improvements with bandwidth held equal
(Pareto/non-regressing), not strict bandwidth improvements. The only harmful
sensitivity window was +71 cycles (+0.1282%) under latency-8 deterministic
random ready, below the 5% guardrail; that profile saved 859 cycles overall.
Across 650 schema-3 main/sensitivity rows, no run retained an orphan admission,
unreturned issue, unmatched response outcome, or live terminal PF MSHR.

## Remote XSim closed the optimized matrix

The final remote Vivado 2024.2.1 execution produced a `PASS` private manifest
at `2026-07-13T06:58:25.192439Z`, with empty findings, exit status zero, no
download failures, and downloaded-log scanning enabled. The private manifest's
SHA-256 is
`8a603dcff120f15114370e7556dd84d33e8bd9fc4028375d5ddedc97685e10cd`;
the public derivative removes the execution command and absolute launcher
path while retaining relative artifact paths and hashes.

- Eleven simulation logs passed: eight workload configurations plus the
  stream/controller, PF-MSHR, and optimized-edge auxiliary tops.
- The workload logs contained exactly 83 schema-3 `WORKLOAD_RESULT` rows.
  Every expected workload appeared once, every row reported `PASS`, and every
  row passed admission, issue/return, response-outcome, install-residency,
  zero-prefetch-write-back, and terminal-empty-MSHR checks.
- Four synthesis configurations completed with the requested parameter
  bindings and produced 12/12 expected utilization, timing, and power reports.
- The required optimized VCD was present (901,858 bytes). The final scan found
  no functional `FAIL`, `FATAL`, `ERROR`, or `CRITICAL WARNING` marker.

## Synthesis PPA exposes a timing cost

The synthesis target was `xc7a35tcpg236-1` with a 10 ns clock constraint.
Values below come directly from the final report triplets; estimated Fmax is
`1000 / (10 - WNS)` and is provided only for comparison.

| Configuration | LUTs | LUT memory | Registers | BRAM | WNS / TNS (ns) | Estimated Fmax (MHz) | Total / dynamic / static power (W) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | -1.019 / -45.732 | 90.752 | 0.124 / 0.053 / 0.070 |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | -2.130 / -101.115 | 82.440 | 0.125 / 0.055 / 0.070 |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | -2.500 / -139.521 | 80.000 | 0.128 / 0.058 / 0.070 |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | -9.342 / -2,571.288 | 51.701 | 0.139 / 0.068 / 0.070 |

For the matched two-way, four-set, VC4 comparison, enabling P3 adds 3,745
LUTs (+52.473%) and 1,543 registers (+48.009%); LUT memory and BRAM do not
increase. WNS changes by -7.212 ns, TNS by -2,470.173 ns, and estimated Fmax
by -30.739 MHz (-37.287%). Estimated total power increases by 0.014 W (+11.2%)
and dynamic power by 0.013 W (+23.636%); static power is unchanged at 0.070 W.

## Limits on PPA interpretation

All four points fail 100 MHz setup timing; hold timing passes. The reports are
from synthesized, unplaced netlists, not `opt_design`/place/route results, so
the Fmax values are slack-derived estimates rather than achieved frequencies.
The three prefetch-off tops have 265 inputs and 753 outputs without I/O delay;
the prefetch-on top has 328 and 1,141 respectively. Bonded-I/O demand is
1,447/106 for prefetch-off and 1,510/106 for prefetch-on, reflecting a research
measurement top rather than a board-pin-realistic wrapper. The report triplets
contain zero combinational loops and no literal multiple-driver diagnostic,
but those observations alone are not a formal proof of driver uniqueness.
Vivado used no simulation activity file and labels every power estimate `Low`
confidence. These results therefore support relative research comparison, not
100 MHz timing closure, post-route utilization, board feasibility, or measured
power.
