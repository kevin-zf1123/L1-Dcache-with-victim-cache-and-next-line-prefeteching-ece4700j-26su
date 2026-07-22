# Validation Record (2026-07-22)

All commands were run from the repository root. Replay and local regressions
were run serially to avoid oversubscribing the workstation. Licensed traces,
raw sidecars, simulator logs, remote connection details, and Vivado work
products remain in ignored private build directories.

## Replay and gate validation

```bash
./scripts/run_feedback_replay_matrix.sh
```

The orchestrator executed all 26 campaigns afresh and ended with
`MATRIX_ALL_PASS`. Every campaign
closed its exact off/on pairing, workload-schema, lifecycle-conservation,
watchdog, protocol, duplicate-line, and source-hash checks.

A focused fixed-gap-4 sidecar audit covered 5,028 demands. It observed 1,425
candidates, all admitted and then cancelled before issue; 1,033 were suppressed
as unsafe and 392 were same-line coalesces. Candidate identity remained stable
through sidecar parsing and the audit passed.

The total evaluator was then run over the five main profiles, the P3-lite
parameter sweep, all sensitivity profiles, and the validated Vivado manifest:

```bash
python3 scripts/evaluate_prefetch_evidence.py \
  --replay legacy=build/spec2026/current-2026-07-22/main/legacy \
  --replay p1=build/spec2026/current-2026-07-22/main/p1 \
  --replay p2=build/spec2026/current-2026-07-22/main/p2 \
  --replay p3=build/spec2026/current-2026-07-22/main/p3 \
  --replay p3-lite=build/spec2026/current-2026-07-22/main/p3-lite \
  --main-replay p3-lite \
  --vivado-manifest build/vivado/evidence_manifest.json \
  --out-dir build/spec2026/current-2026-07-22/gate
```

The command completed successfully and produced a structurally valid total
decision. `combined_gate_pass=false` is the measured design result, not an
evaluator error: the decision is
`DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`. The deployment wrapper consequently
keeps prefetch disabled by default.

## Vivado validation

The remote runner used Vivado 2024.2.1 and the repository's 10 ns constraint.
The connection secret was supplied only to the current process and was not
written to a repository file, command line, log, manifest, or public artifact.

The batch execution exited with status zero. The collector downloaded and
scanned 121 log/report files comprising 15 XSim logs, eight OOC synthesis
configurations, four independent implementation runs, and vectorless plus
SAIF-backed power reports. The final `l1d-vivado-evidence-v3` manifest reports
`PASS`, zero findings, zero download failures, and remote exit status zero.
The exact Vivado 2024.2 `[Timing 38-282]` setup-gate message is permitted only
because numerical timing reports are evaluated separately; any other critical
warning remains fatal.

## Final local regression

| Command | Outcome |
| --- | --- |
| `./scripts/run_iverilog.sh` | PASS: baseline geometries, workload rows, randomized scoreboard, and 81 prefetch-unit checks |
| `./scripts/run_p3_tests.sh` | PASS: 62 PF-MSHR checks, explicit lower-port arbitration, zero-bubble merge, and optimized edge/backpressure scenarios |
| `./scripts/run_deploy_tests.sh` | PASS: six deployment/feature-ablation configurations |
| `./scripts/run_vc_formatter_ab.sh` | PASS: VC-lookup and swap-stage formatter modes |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | PASS: 97 tests |
| `bash -n scripts/run_feedback_replay_matrix.sh scripts/run_spec_trace_replay.sh scripts/run_deploy_tests.sh scripts/run_vc_formatter_ab.sh` | PASS |
| `python3 -m py_compile scripts/evaluate_prefetch_evidence.py scripts/publish_prefetch_evidence.py scripts/run_remote_vivado.py scripts/summarize_spec_replay.py` | PASS |

The recurring Icarus messages about constant selects in `always_*` blocks are
known simulator limitations. All self-checking simulations completed with exit
status zero.
