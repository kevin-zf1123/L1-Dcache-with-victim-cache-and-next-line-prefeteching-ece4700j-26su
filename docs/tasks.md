# Project Tasks

## Baseline

- [x] Define blocking ready/valid CPU and line-memory interfaces.
- [x] Implement RV64 load/store request fields, 64-bit addresses, and XLEN data.
- [x] Implement configurable direct-mapped / 2-way L1D.
- [x] Implement synchronous tag and data SRAM wrappers.
- [x] Implement write-back / write-allocate FSM.
- [x] Implement fully associative victim cache and swap path.
- [x] Verify dirty victim replacement write-back.
- [x] Implement next-line prefetch baseline.
- [x] Add runtime and external prefetch adaptation interfaces.
- [x] Add hardware event pulses and cumulative counters.
- [x] Run direct-mapped, 2-way, and prefetch Icarus regressions.
- [x] Document architecture, use, workload plan, and literature review.

## Verification and Advanced Features

### Adaptive direct-L1 prefetcher (P0–P3)

- [x] Preserve the original blocking next-line engine behind
  `PREFETCH_POLICY=0` and make optimized policy level 3 the wrapper default.
- [x] Add true zero-bubble, sequential, and fixed-gap 1/2/4/8 producers.
- [x] Upgrade replay sidecars and conservation checks to schema 3 while
  retaining schema-2 input compatibility.
- [x] Add candidate/admit/issue/return/install/use/evict/cancel/discard/merge,
  suppression, controller, shadow, write-back attribution, and blocked-cycle
  observability.
- [x] Implement P1 safe cold insertion, one-unused-line-per-set quota, dirty
  guards, response revalidation, VC bypass, TTL, independent external skid,
  idle guard, and token admission.
- [x] Implement P2 four-entry Gaze-lite adjacent-stream detection and the
  hysteretic OFF/PROBE/ON controller.
- [x] Implement P3 demand-only tag/dirty shadow L1/VC and one metadata-only PF
  MSHR with hit-under-prefetch, load/store merge, and bounded discard.
- [x] Add directed and randomized Icarus regressions for stream/controller,
  safe insertion, shadow attribution, zero-bubble merge, TTL, EWMA, response
  backpressure, runtime disable, and discard/revalidation paths.
- [x] Complete and publish the final 25-window legacy/P1/P2/P3 zero-bubble
  campaign against all stated performance and bandwidth gates.
- [x] Complete the sequential, fixed-gap 1/2/4/8, latency-0/always-ready, and
  latency-8/random-backpressure paired sensitivity campaigns.
- [x] Run the optimized P3 XSim matrix (11 logs / 83 schema-3 rows) and the
  four-configuration Vivado synthesis/PPA campaign (12 reports).

- [x] Add deterministic randomized golden-memory scoreboard.
- [x] Verify RV64 load/store sizes, sign/zero extension, and misaligned errors.
- [x] Verify mutually exclusive CPU/external/next-line handshakes under overlap.
- [x] Verify 64-bit high-address tags and RV64 trace replay format.
- [x] Check CPU-response and lower-memory request stability under backpressure.
- [x] Add simulation checks for handshake stability and line uniqueness.
- [x] Verify 4-entry and 8-entry victim-cache configurations.
- [x] Add deterministic synthetic workload-boundary regression and CSV output.
- [x] Add class-based Vivado OOP harness for Phase 3 workloads.
- [x] Add deterministic generated Phase 3 matrix and pointer traces.
- [x] Add Phase 3 workload records with read/write bytes and latency summaries.
- [x] Add watchdog, protocol, and duplicate-line failure reporting to Vivado workloads.
- [ ] Add a zero-entry victim-cache bypass configuration.
- [ ] Add LRU victim replacement option.
- [ ] Add separate prefetch-buffer placement option.
- [x] Add paired true-pollution analysis and separate demand/prefetch
  memory-bandwidth measurements; retain the RTL displacement counter as a proxy.
- [x] Add independent candidate/accept/issue/return/install/merge/discard
  prefetch lifecycle counters and event records.
- [ ] Add per-prefetch transaction identity and candidate-to-issue-to-return
  latency distributions.
- [x] Add reusable trace replay driver for SPEC CPU 2017/2026 regions.
- [x] Run the historical `782.lbm_r` extraction/replay plumbing check
  (non-authoritative benchmark evidence).
- [x] Capture and replay the legacy 20-window/four-configuration SPEC matrix
  (historical full-system mixed traces; not benchmark-attributable).
- [x] Validate target-process, vCPU, privilege, and address-space attribution on a
  dynamic RV64 smoke workload.
- [x] Emit the canonical workload schema and strict paired-run analysis.
- [x] Add per-demand true-pollution attribution through paired replay sidecars.
- [x] Add per-demand present/accept/response latency and prefetch lifecycle
  sidecar analysis.
- [x] Capture and replay licensed SPEC regions with the validated process-scoped
  flow.
- [x] Classify validated windows and publish paired metrics and plots under
  `docs/evidence/2026-07-13/`.

## Vivado and PPA

- [x] Run RV64 Vivado simulation for direct-mapped and 2-way configurations.
- [x] Run Vivado OOP workload matrix for VC4, VC8, next-line prefetch, and trace replay.
- [ ] Inspect waveforms for all hit, miss, swap, fill, and write-back paths.
- [x] Capture a representative passing prefetch-on VCD artifact.
- [x] Run RV64 synthesis and record LUT, FF, inferred memory, and timing reports.
- [x] Add a baseline 10 ns clock constraint.
- [x] Calculate an approximate RV64 post-synthesis Fmax from Vivado STA reports.
- [x] Run RV64 vectorless FPGA power estimation and document its assumptions.
- [ ] Run implementation/post-route timing and activity-based power analysis.
- [x] Compare baseline, victim-cache, prefetch, and combined configurations.
- [x] Re-run the comparison with equal L1 capacity and identical simulation/PPA
  geometry.

## Release Scope

The repository remains public. Further Git-history, cached-ref, LFS-object, or
fork cleanup is explicitly outside this remediation plan; licensed capture
artifacts remain private under ignored build directories.
