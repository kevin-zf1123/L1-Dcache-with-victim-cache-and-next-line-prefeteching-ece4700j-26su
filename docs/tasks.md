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

- [x] Add deterministic randomized golden-memory scoreboard.
- [x] Verify RV64 load/store sizes, sign/zero extension, and misaligned errors.
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
- [ ] Add true pollution, timeliness, and memory-bandwidth measurements.
- [x] Add reusable trace replay driver for SPEC CPU 2017/2026 regions.
- [x] Run initial licensed SPEC CPU 2026 782.lbm_r trace extraction and replay validation.
- [x] Classify additional licensed SPEC workload regions.

## Vivado and PPA

- [x] Run RV64 Vivado simulation for direct-mapped and 2-way configurations.
- [x] Run Vivado OOP workload matrix for VC4, VC8, next-line prefetch, and trace replay.
- [ ] Inspect waveforms for all hit, miss, swap, fill, and write-back paths.
- [x] Capture a representative passing next-line prefetch VCD artifact.
- [x] Run RV64 synthesis and record LUT, FF, inferred memory, and timing reports.
- [x] Add a baseline 10 ns clock constraint.
- [x] Calculate an approximate RV64 post-synthesis Fmax from Vivado STA reports.
- [x] Run RV64 vectorless FPGA power estimation and document its assumptions.
- [ ] Run implementation/post-route timing and activity-based power analysis.
- [x] Compare baseline, victim-cache, prefetch, and combined configurations.
