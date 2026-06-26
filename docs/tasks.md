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
- [x] Add a zero-entry victim-cache bypass configuration.
  - [x] Make `VICTIM_ENTRIES=0` legal in the RTL and testbench parameter checks.
  - [x] Bypass all victim-cache lookup, swap, insert, and replacement logic when the victim cache is disabled.
  - [x] Keep the same L1 miss/fill/write-back behavior so the zero-entry mode is a true baseline comparison.
  - [x] Add directed tests for conflict misses, dirty evictions, and prefetch pollution with victim cache disabled.
  - [x] Update workload CSV output so zero-entry runs are easy to compare against 4-entry and 8-entry runs.
  - [x] Confirm synthesis/simulation still pass for both `VICTIM_ENTRIES=0` and enabled configurations.
- [ ] Add LRU victim replacement option.
- [x] Add separate prefetch-buffer placement option.
- [ ] Add true pollution, timeliness, and memory-bandwidth measurements.
- [x] Add reusable trace replay driver for SPEC CPU 2017/2026 regions.
- [x] Run initial licensed SPEC CPU 2026 782.lbm_r trace extraction and replay validation.
- [ ] Classify additional licensed SPEC workload regions.

## Vivado and PPA

- [ ] Run RV64 Vivado simulation for direct-mapped and 2-way configurations.
- [ ] Inspect waveforms for all hit, miss, swap, fill, and write-back paths.
- [ ] Run RV64 synthesis and record LUT, FF, inferred memory, and timing reports.
- [x] Add a baseline 10 ns clock constraint.
- [ ] Calculate an approximate RV64 post-synthesis Fmax from Vivado STA reports.
- [ ] Run RV64 vectorless FPGA power estimation and document its assumptions.
- [ ] Run implementation/post-route timing and activity-based power analysis.
- [ ] Compare baseline, victim-cache, prefetch, and combined configurations.
