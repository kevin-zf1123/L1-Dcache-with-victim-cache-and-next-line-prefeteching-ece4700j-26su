# Design Review III (Mid-Term Review) Team Report

## 1. Thesis Title

Design and Evaluation of an L1 Data Cache with Victim Cache and Next-Line Prefetching

## 2. Summary of Project Progress (<500 words)

Since Design Review II, the project has moved from a validated functional baseline to a broader comparative platform for cache-policy evaluation. The core RTL remains a blocking RV64 L1 data cache, but it now supports a wider design space: direct-mapped or 2-way L1 organization, write-back and write-allocate behavior, 0/4/8-entry fully associative victim-cache configurations, optional next-line prefetching, optional prefetch-buffer placement, and configurable LRU or round-robin replacement behavior.

The main implementation progress is concentrated in three areas. First, the RTL now includes the zero-entry victim-cache bypass path, which gives the project a true no-victim baseline instead of treating a small victim cache as the minimum configuration. Second, the replacement and prefetch structures have been extended through LRU policy parameters and a separate prefetch buffer module. Third, the measurement infrastructure has matured from basic hit/miss counting into a workload-level analysis flow that separates demand memory reads, prefetch memory reads, writebacks, prefetch usefulness, useless prefetches, proxy pollution, true paired-run pollution, bandwidth overhead, and timing-related prefetch metrics.

The verification environment has also expanded. The self-checking SystemVerilog testbench now exercises RV64 load and store sizes, sign and zero extension, misalignment errors, dirty write-back behavior, victim-cache swaps, zero-entry victim bypass, randomized golden-memory checking, synthetic workload microbenchmarks, and trace replay through the `+TRACE=<path>` option. The current Icarus regression matrix produces structured `WORKLOAD_RESULT` records and a consolidated CSV file for later plotting and thesis analysis.

Benchmark preparation has progressed beyond the earlier smoke tests. The repository now contains QEMU/gem5-oriented trace-capture and conversion scripts, replay-ready trace artifacts, and validated SPEC CPU 2026 `782.lbm_r` trace replay evidence. In addition, a complete non-blocking MSHR design specification and corresponding verification plan have been written. This MSHR work is currently a specification-level extension, not yet an implemented RTL feature, but it provides a clear architectural path for future hit-under-miss and miss-under-miss support.

Overall, the mid-term status is strong: the functional baseline, advanced options, regression scripts, measurement counters, replay flow, and preliminary evaluation results are all in place. The remaining work is mainly FPGA/Vivado physical evidence, broader benchmark coverage, final interpretation of the measurements, and thesis integration.

## 3. Summary of the Experiment Setup Preparation at This Stage (Tools, Test Cases, Benchmarks) (<500 words)

The current experiment setup is organized as a simulation-first flow with prepared FPGA-oriented follow-up.

**Functional simulation and regression.** The main fast-turnaround tool is Icarus Verilog, driven by `scripts/run_iverilog.sh`. The script builds multiple configurations covering direct-mapped and 2-way caches, 0/4/8 victim entries, prefetch-enabled and prefetch-disabled modes, and prefetch-buffer size variants. The main testbench is `src/tb_l1d_cache.sv`.

**Directed and randomized tests.** The testbench checks cold misses, hits, fills, write-back paths, victim-cache rescue behavior, dirty victim replacement, RV64 byte/halfword/word/doubleword accesses, sign and zero extension, misaligned access errors, response backpressure, memory request stability, randomized golden-memory behavior, and line uniqueness assertions.

**Synthetic workload evaluation.** Five deterministic workload profiles are included: `sequential_stream`, `stride_two_lines`, `localized_two_line_loop`, `same_set_conflict_thrash`, and `irregular_pointer_chase`. These are designed to expose the boundary behavior of the two target techniques: victim caches should help conflict-thrashing patterns, while next-line prefetching should help adjacent-line access but may waste bandwidth on non-adjacent patterns.

**Trace replay.** The testbench supports text trace replay through `+TRACE=<path>`. The repository includes small smoke traces, SPEC 2017/2026 replay artifacts, and a SPEC CPU 2026 `782.lbm_r` aligned trace. `sim/spec2026_test_trace.log` and `sim/spec2026_testprefetch_trace.log` record clean replay validation for prefetch-disabled and prefetch-enabled configurations.

**Measurement and analysis.** `scripts/summarize_workloads.sh` consolidates `WORKLOAD_RESULT` lines into `sim/workload_results.csv`. `scripts/analyze_prefetch_metrics.py` performs paired-run comparison between prefetch-off and prefetch-on results, deriving true pollution, miss reduction, bandwidth overhead, cycle delta, prefetch accuracy, and offline timeliness metrics from workload logs.

**FPGA-oriented preparation.** Vivado integration is prepared through `scripts/run_vivado.tcl` and the 100 MHz clock constraint in `constraints/l1d_baseline.xdc`. Vivado synthesis, timing, utilization, waveform inspection, and power analysis remain the main experiment setup items still to be completed for final sign-off.

## 4. Interim Results of the Project

### 4.1 Functional RTL Status

The current RTL is functional across the available Icarus regression configurations. Implemented features include:

- RV64 load/store support for byte, halfword, word, and doubleword operations;
- sign-extension and zero-extension handling for loads;
- misaligned load/store error reporting;
- configurable direct-mapped or 2-way L1 organization;
- write-back, write-allocate miss handling;
- fully associative victim cache with 0/4/8-entry configurations;
- victim-cache swap and dirty-line preservation;
- LRU or round-robin replacement policy parameters;
- optional next-line prefetching;
- optional prefetch buffer with allocation/fill tracking;
- external prefetch injection support; and
- cumulative statistics counters plus event-style workload logging.

This is a stronger implementation state than Design Review II, where zero-entry victim bypass, LRU options, prefetch-buffer placement, and true paired-run prefetch analysis were still future or partial items.

### 4.2 Synthetic Workload Results

The current consolidated workload table is `sim/workload_results.csv`. The results show the expected qualitative behavior.

**Victim-cache benefit.** For `same_set_conflict_thrash`, the victim cache substantially reduces lower-memory traffic. In a direct-mapped, 4-entry victim-cache configuration, the workload records 8 misses, 6 victim hits, and only 2 lower-memory reads. In the 2-way, 4-entry victim-cache configuration, it records 12 misses, 9 victim hits, and only 3 lower-memory reads. This confirms that the victim cache is rescuing lines that would otherwise repeatedly miss due to set conflicts.

**Next-line prefetch benefit.** For `sequential_stream`, the 2-way, 4-entry victim-cache, prefetch-enabled configuration improves from 0 hits / 12 misses to 6 hits / 6 misses. It records 6 useful prefetches out of 6 prefetch fills, corresponding to 100% prefetch accuracy on this pattern. This is the intended best case for a next-line prefetcher.

**Next-line prefetch limitation.** For `stride_two_lines` and `irregular_pointer_chase`, prefetching does not reduce demand misses. In the 2-way, 4-entry victim-cache case, each workload remains at 12 misses but lower-memory reads increase from 12 to 24. The paired-run analyzer reports 0 miss reduction, 192 bytes of bandwidth overhead, and 0.0000 prefetch accuracy. This demonstrates that next-line prefetching is workload-dependent and can waste bandwidth on non-adjacent access streams.

**Localized reuse.** For `localized_two_line_loop`, prefetching slightly improves demand behavior from 10 hits / 2 misses to 11 hits / 1 miss without increasing total memory bytes. The analyzer reports 1 miss reduction and 100% prefetch accuracy for this small loop.

### 4.3 SPEC CPU 2026 Trace Replay Validation

The project now has validated SPEC CPU 2026 `782.lbm_r` replay evidence.

The short regression trace in `sim/spec2026_test_trace.log` passed with prefetch disabled:

- accesses: 1,772
- hits: 925
- misses: 847
- victim hits: 209
- memory reads: 638
- writebacks: 313
- total memory bytes: 15,216
- cycles: 12,604
- final status: `ALL TESTS PASSED`

The corresponding prefetch-enabled run in `sim/spec2026_testprefetch_trace.log` also passed:

- accesses: 1,772
- hits: 920
- misses: 852
- victim hits: 131
- demand memory reads: 721
- prefetch memory reads: 504
- prefetch issued: 1,425
- prefetch fills: 504
- useful prefetches: 112
- useless prefetches: 388
- proxy pollution events: 370
- total memory bytes: 25,616
- cycles: 17,885
- final status: `ALL TESTS PASSED`

This result is important because it shows the design remains functionally stable under a benchmark-derived replay trace, but it also shows the cost of simple next-line prefetching in the current blocking cache. Prefetching increased lower-memory traffic and cycle count on this trace, while producing only 112 useful prefetches out of 504 fills, or about 22.2% accuracy.

The baseline documentation also records a larger aligned `782.lbm_r` replay run with 999,992 accesses and prefetch disabled. That run produced 327,155 hits, 672,837 misses, 23,347 victim hits, 649,490 memory reads, 380,607 writebacks, and 9,175,526 cycles. This larger run provides the main benchmark-scale baseline for the next evaluation stage.

### 4.4 Measurement Framework

The measurement framework is now one of the strongest parts of the project. It records both raw hardware-style counters and derived paired-run metrics:

- hits, misses, victim hits, memory reads, memory writes, and cycles;
- demand memory reads versus prefetch memory reads;
- prefetch issued, filled, useful, useless, dropped, and proxy pollution counts;
- average issue-to-fill and fill-to-use timing;
- prefetch-buffer allocation, promotion, eviction, and full-drop counts;
- true pollution from paired prefetch-off/prefetch-on demand-miss deltas;
- bandwidth overhead and cycle delta; and
- offline timeliness classifications from `ACCESS_RESULT` and `PREFETCH_EVENT` logs.

This distinction between proxy pollution and true pollution is especially important for the final thesis. A prefetched line can create displacement pressure without necessarily increasing total demand misses, and the paired-run analyzer now provides a defensible way to report that difference.

### 4.5 MSHR Non-Blocking Design Progress

A detailed MSHR non-blocking cache design has been completed in `docs/mshr_design.md`, with a matching verification plan in `docs/mshr_testbench.md`. The design covers hit-under-miss, miss-under-miss, MSHR merging, waiter response fan-out, frontend/backend FSM separation, victim-cache integration, prefetch integration, and new performance counters.

This MSHR extension is not yet implemented in RTL. At mid-term, it should be treated as a specification-complete optional extension and a thesis discussion point. It is also a direct answer to one limitation observed in the current results: because the present cache is blocking, extra prefetch memory traffic competes with demand misses instead of overlapping with them.

## 5. Progress in Writing the Thesis

The thesis writing has progressed from proposal-level motivation to evidence-backed technical documentation. The repository now contains:

- a literature review in `docs/literature_review.md`;
- a baseline architecture and usage document in `docs/l1d_baseline.md`;
- a formal microarchitecture specification in `docs/Microarchitecture Specification.md`;
- task tracking in `docs/tasks.md`;
- prefetch measurement planning in `docs/prefetch_measurement_plan.md`;
- prefetch buffer design notes in `docs/prefetch_buffer_design.md`;
- MSHR design and verification documents in `docs/mshr_design.md` and `docs/mshr_testbench.md`;
- Design Review II team and individual reports; and
- this Design Review III mid-term report.

The thesis now has enough technical material for its architecture, implementation, verification, and preliminary evaluation chapters. The main writing work remaining is synthesis and interpretation: converting the CSV/log results into tables and figures, explaining why each workload behaves as it does, relating the observations back to the literature, documenting the SPEC replay methodology clearly, and adding Vivado synthesis/timing/power results when they are available.

The final thesis should also explicitly separate implemented contributions from design-level future work. Victim cache, next-line prefetching, prefetch buffer, LRU options, zero-entry bypass, and measurement counters are implemented. MSHR non-blocking support is currently specified but not yet implemented.

## 6. Comparison of Current Progress with the Proposal Timeline

The project is broadly on schedule and is ahead of the original timeline in measurement infrastructure, but behind the ideal timeline in FPGA physical evaluation.

| Milestone | Proposal Target | Current Status |
|---|---|---|
| Literature review and architecture study | Design Review I | Complete |
| Blocking L1D baseline RTL | Design Review II | Complete |
| Victim cache implementation | Design Review II | Complete |
| Next-line prefetch implementation | Design Review II | Complete |
| Self-checking testbench | Design Review II | Complete |
| Synthetic workload regression | Design Review II | Complete |
| Zero-entry victim-cache baseline | Post-Review II | Complete |
| LRU replacement option | Post-Review II | Complete |
| Prefetch-buffer option | Post-Review II | Complete |
| True pollution and bandwidth analysis | Post-Review II | Complete |
| SPEC CPU 2026 replay validation | Design Review III | Complete for initial regions |
| MSHR non-blocking design | Design Review III | Specification complete |
| Vivado synthesis/timing/utilization | Design Review III | Pending |
| FPGA power analysis | Design Review III / Final | Pending |
| Expanded benchmark evaluation | Final stage | In progress |
| Thesis evaluation chapter | Final stage | In progress |

Compared with the proposal, the implementation and verification work are strong. The most important schedule risk is that the final report still needs physical implementation evidence from Vivado and a broader benchmark set. The design-space exploration framework is ready, so the remaining work is not blocked by RTL functionality; it is mainly execution, analysis, and documentation.

## 7. Changes in Team Task Assignment

No major structural change in team task assignment is required. The current task distribution remains organized around:

- RTL cache datapath and FSM maintenance;
- verification, regression, and trace replay;
- prefetcher, prefetch buffer, and measurement analysis;
- Vivado synthesis/PPA work; and
- documentation, report writing, and thesis integration.

One practical adjustment is recommended for the final stage: assign a clear owner for Vivado synthesis/timing/power collection, because this is the largest unfinished category. A second clear owner should consolidate the workload results into final thesis tables and plots. The MSHR work should remain optional unless the core evaluation and Vivado evidence are already complete.

## 8. Existing Problems and Solutions

**Problem 1: Vivado physical evidence is still incomplete.**  
The current project is strong in Icarus functional simulation but still lacks final Vivado synthesis, timing, utilization, and power results.  
**Solution:** Use the existing `scripts/run_vivado.tcl` and `constraints/l1d_baseline.xdc` flow first on the baseline configurations, then repeat for victim-cache and prefetch-enabled configurations. Record LUTs, FFs, inferred memories, timing slack/Fmax, and estimated power.

**Problem 2: Next-line prefetching is not universally beneficial.**  
Synthetic stride and pointer-chase workloads show no demand-miss reduction but a large increase in memory reads. The SPEC CPU 2026 replay also shows increased memory traffic and cycle count with low prefetch accuracy.  
**Solution:** Treat this as an expected research result rather than a bug. Keep prefetching optional, report workload-dependent tradeoffs, and use the paired-run analyzer to quantify accuracy, bandwidth overhead, and true pollution.

**Problem 3: Blocking cache structure limits prefetch benefit.**  
The current cache serializes demand misses and prefetch fills through one lower-memory path. Extra prefetch traffic therefore increases stalls instead of being overlapped.  
**Solution:** Use the MSHR non-blocking design as a future-work or optional final extension. If time allows, implement it behind an `ENABLE_NONBLOCKING` parameter; otherwise, use the specification to explain how hit-under-miss could reduce the observed prefetch penalty.

**Problem 4: Documentation must stay synchronized with RTL.**  
Some earlier documents describe planned or idealized block structures, while the live source tree has evolved.  
**Solution:** Treat `src/l1d_cache.sv`, `src/tb_l1d_cache.sv`, and generated logs as authoritative. During thesis writing, update architecture diagrams and descriptions to match the current module hierarchy and implemented parameters.

**Problem 5: Benchmark coverage is still narrow.**  
The project has validated SPEC CPU 2026 `782.lbm_r` trace replay, but broader benchmark-class evaluation remains incomplete.  
**Solution:** Use the existing trace capture/conversion flow to add more trace regions. At minimum, select regions that represent sequential, stride, conflict-heavy, pointer-chasing, and mixed load/store behavior.

## 9. Next Stage Work Plan and Research Content

The next stage should focus on turning the working platform into final thesis evidence.

1. **Run Vivado synthesis and timing.** Generate utilization, timing, and power reports for at least four configurations: baseline without victim cache or prefetching, victim-cache-only, prefetch-only, and combined victim-cache/prefetch design.

2. **Inspect key waveforms.** Use VCD/XSim waveforms to document hit, miss, victim swap, dirty write-back, fill install, prefetch issue/fill, and prefetch-buffer paths.

3. **Expand trace-driven evaluation.** Replay additional benchmark trace regions and run paired prefetch-off/prefetch-on comparisons. Keep the same CSV format so all results can be plotted consistently.

4. **Prepare final evaluation tables and plots.** Report hit rate, victim hit rate, memory reads, writebacks, total bytes, cycles, prefetch accuracy, true pollution, bandwidth overhead, and PPA cost.

5. **Reconcile documentation.** Update `docs/l1d_baseline.md`, the microarchitecture specification, and thesis diagrams so that the written design matches the implemented RTL.

6. **Decide MSHR scope.** If Vivado and evaluation work finish early, implement the MSHR extension as an optional feature. If not, keep it as a design-specification contribution and future-work chapter.

7. **Write final thesis chapters.** Complete the implementation, verification, evaluation, physical design, and conclusion chapters using the current reports and logs as source material.

## 10. References

- [README.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/README.md)
- [docs/Design Review II Team Report.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/Design%20Review%20II%20Team%20Report.md)
- [docs/Design Review II Individual Report.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/Design%20Review%20II%20Individual%20Report.md)
- [docs/l1d_baseline.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/l1d_baseline.md)
- [docs/literature_review.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/literature_review.md)
- [docs/Microarchitecture Specification.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/Microarchitecture%20Specification.md)
- [docs/tasks.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/tasks.md)
- [docs/prefetch_measurement_plan.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/prefetch_measurement_plan.md)
- [docs/prefetch_buffer_design.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/prefetch_buffer_design.md)
- [docs/mshr_design.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/mshr_design.md)
- [docs/mshr_testbench.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/mshr_testbench.md)
- [src/l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_cache.sv)
- [src/l1d_next_line_prefetch.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_next_line_prefetch.sv)
- [src/l1d_prefetch_buffer.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_prefetch_buffer.sv)
- [src/l1d_sram.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_sram.sv)
- [src/tb_l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/tb_l1d_cache.sv)
- [scripts/run_iverilog.sh](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_iverilog.sh)
- [scripts/summarize_workloads.sh](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/summarize_workloads.sh)
- [scripts/analyze_prefetch_metrics.py](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/analyze_prefetch_metrics.py)
- [scripts/run_vivado.tcl](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_vivado.tcl)
- [constraints/l1d_baseline.xdc](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/constraints/l1d_baseline.xdc)
- [sim/workload_results.csv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/workload_results.csv)
- [sim/spec2026_test_trace.log](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/spec2026_test_trace.log)
- [sim/spec2026_testprefetch_trace.log](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/spec2026_testprefetch_trace.log)
- [traces/spec2026_782_lbm_r_test_1m_aligned.trace](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/traces/spec2026_782_lbm_r_test_1m_aligned.trace)
- [traces/spec2017_replay.trace](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/traces/spec2017_replay.trace)
