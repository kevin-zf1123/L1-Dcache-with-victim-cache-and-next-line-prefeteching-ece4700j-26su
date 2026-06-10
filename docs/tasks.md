# Project Tasks

## Baseline

- [x] Define blocking ready/valid CPU and line-memory interfaces.
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
- [x] Check CPU-response and lower-memory request stability under backpressure.
- [x] Add simulation checks for handshake stability and line uniqueness.
- [x] Verify 4-entry and 8-entry victim-cache configurations.
- [x] Add deterministic synthetic workload-boundary regression and CSV output.
- [ ] Add a zero-entry victim-cache bypass configuration.
- [ ] Add LRU victim replacement option.
- [ ] Add separate prefetch-buffer placement option.
- [ ] Add true pollution, timeliness, and memory-bandwidth measurements.
- [x] Add reusable trace replay driver for SPEC CPU 2017/2026 regions.
- [ ] Run licensed SPEC trace extraction and workload classification.

## Vivado and PPA

- [ ] Run Vivado simulation for direct-mapped and 2-way configurations.
- [ ] Inspect waveforms for all hit, miss, swap, fill, and write-back paths.
- [ ] Run synthesis and record LUT, FF, inferred memory, and timing reports.
- [x] Add a baseline 10 ns clock constraint.
- [ ] Calculate Fmax from an actual Vivado STA report.
- [ ] Run FPGA power estimation with documented activity assumptions.
- [ ] Compare baseline, victim-cache, prefetch, and combined configurations.
