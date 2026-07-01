# Design Review II Team Report

## 1. Thesis Title

Design and Evaluation of an L1 Data Cache with Victim Cache and Next-Line Prefetching

## 2. Summary of Project Progress (<500 words)

At the current stage, the project has completed a working RTL baseline for a blocking L1 data cache and has moved from architecture planning into repeatable implementation and evaluation. The implemented cache supports RV64-style load/store requests with 64-bit addresses and 64-bit data, write-back and write-allocate behavior, configurable direct-mapped or 2-way organization, a fully associative victim cache, and an optional next-line prefetcher. The current source tree keeps the active RTL in a compact structure centered on `src/l1d_cache.sv`, with reusable SRAM and prefetch helper modules in separate files.

Progress is strongest in three areas. First, the cache datapath and control path are already functional enough to support both directed tests and longer replay workloads. Second, the verification environment is no longer limited to simple unit checks. The self-checking testbench exercises RV64-sized loads and stores, sign and zero extension, misaligned access error handling, dirty eviction behavior, victim-cache rescue behavior, randomized memory checking, synthetic workload profiles, and external trace replay. Third, the project now has an end-to-end workload path: traces can be captured or converted into the replay format expected by the testbench, then evaluated through the RTL and summarized with cache statistics.

The current repository also includes initial workload evidence rather than only planned experiments. Synthetic workloads already show the intended qualitative behavior of the design. Sequential access benefits from next-line prefetching, conflict-heavy access patterns benefit from the victim cache, and irregular or non-adjacent patterns show the expected risk of unnecessary prefetch traffic. In addition, a benchmark-derived replay file has been run successfully through the cache testbench, confirming that the design can remain stable under long mixed read/write traces rather than only small directed cases.

Overall, the project is beyond the proposal stage and beyond a purely conceptual Design Review I state. The baseline hardware, regression scripts, workload replay flow, and preliminary measurements are all in place. The remaining work is mainly comparative evaluation, cleanup of documentation to match the live implementation, and FPGA-oriented timing, power, and post-route analysis.

## 3. Summary of the Experiment Setup Preparation at This Stage (<500 words)

The current experiment setup uses a simulation-first workflow. Icarus Verilog is the main fast-turnaround environment for functional regression, while Vivado batch scripts are prepared for later FPGA-oriented simulation, synthesis, timing, utilization, and power analysis. The main regression entry is `scripts/run_iverilog.sh`, and the corresponding FPGA tool script is `scripts/run_vivado.tcl`.

The testbench in `src/tb_l1d_cache.sv` is self-checking and supports several categories of experiments:

- directed functional tests for cache hits, misses, fills, and write-backs;
- RV64 load/store verification across byte, halfword, word, and doubleword operations;
- sign-extension and zero-extension checking for loads;
- misaligned load/store error checking;
- randomized golden-memory checking;
- victim-cache swap and dirty-line preservation tests;
- response and lower-memory backpressure checks;
- synthetic workload microbenchmarks; and
- text-trace replay using a `+TRACE=<path>` runtime option.

The synthetic workloads currently included in the regression are sequential streaming, two-line stride, localized two-line reuse, same-set conflict thrashing, and irregular pointer-chase style access. These workloads are useful because they expose the expected boundary conditions for victim caching and next-line prefetching before larger benchmark studies are complete.

For benchmark preparation, the repository includes scripts and trace artifacts for replay-based evaluation. The available scripts support trace capture and conversion, including `scripts/gem5_trace_capture.py`, `scripts/convert_gem5_packet_trace.py`, and `scripts/convert_gem5_write_trace.py`. The workspace also contains replay-ready traces such as `traces/smoke.trace` and `traces/spec2017_replay.trace`, along with larger SPEC CPU 2026 derived trace artifacts for later study. This means the current setup is already capable of running both small redistributable checks and larger benchmark-derived workloads through the RTL model.

## 4. Interim Results of the Project

The present RTL passes the available Icarus regression cases for direct-mapped, 2-way, victim-cache-depth, and prefetch-enabled configurations. This is the main result at the implementation level: the cache is stable enough to support controlled comparison rather than only debugging.

The synthetic workload results already show clear behavioral trends. From `sim/workload_results.csv`:

- in the 2-way, 4-entry victim-cache, prefetch-enabled configuration, `sequential_stream` improved from 0 hits / 12 misses to 6 hits / 6 misses;
- in the same prefetch-enabled configuration, `stride_two_lines` and `irregular_pointer_chase` produced no demand-hit improvement but doubled memory reads from 12 to 24;
- `localized_two_line_loop` improved slightly with prefetching, from 10 hits / 2 misses to 11 hits / 1 miss; and
- `same_set_conflict_thrash` in the 2-way, 4-entry victim-cache configuration achieved 9 victim hits with only 3 lower-memory reads, showing the intended benefit of the victim cache under conflict pressure.

The project also has a successful benchmark-derived replay result. Running the 2-way, 8-entry victim-cache configuration on `traces/spec2017_replay.trace` produced the following result in `sim/spec_trace.log`:

- accesses: 167118
- hits: 146787
- misses: 20331
- victim hits: 9919
- memory reads: 10412
- memory writes: 3017
- cycles: 818648
- final status: `ALL TESTS PASSED`

An additional prefetch-enabled replay log is also present in `sim/spec_trace_prefetch.log`. In that run, the cache recorded 147595 hits, 19523 misses, 12186 victim hits, 13975 memory reads, 3242 memory writes, 3821 useful prefetches, 2813 useless prefetches, and 523 pollution events over 848947 cycles. This suggests that prefetching can reduce demand misses on this trace, but it also increases lower-memory traffic and total cycles in the current blocking design, so the final thesis should treat prefetching as a workload-dependent tradeoff rather than an unconditional improvement.

These results are sufficient for Design Review II because they demonstrate implemented functionality, repeatable regression, and the beginning of workload-driven analysis.

## 5. Progress in Writing the Thesis

The writing work has progressed from proposal-level framing to technical documentation that can directly support the final thesis. The repository already contains an architecture and usage document (`docs/l1d_baseline.md`), a literature review (`docs/literature_review.md`), project task tracking (`docs/tasks.md`), and Design Review presentation materials. The Design Review II report can therefore be written as an evidence-based update rather than as a plan only.

The main writing task that remains is consolidation. Some repository documents reflect earlier design states or future-looking descriptions, so the thesis and review documents need to consistently follow the live implementation and measured results in the current source tree and simulation logs.

## 6. Comparison of Current Progress with the Proposal Timeline

Current progress is generally aligned with the proposal and is ahead of schedule in functional validation. The project already has a working RTL baseline, a reusable replay framework, automated regression, and initial benchmark-derived measurements. These are substantial milestones for the second review stage.

The main gap relative to the full proposal is not implementation completeness but evaluation depth. Comparative experiments across more workload classes, more trace regions, and more configuration combinations still need to be completed. Vivado-based RV64 synthesis, waveform inspection for all important controller paths, and post-route or activity-based power analysis also remain unfinished.

In short, the project is on track technically, with remaining work concentrated in measurement breadth, FPGA implementation evidence, and final thesis integration.

## 7. Changes in Team Task Assignment

No formal change in team task assignment is documented in the repository. Based on the current artifacts, work appears to remain distributed across RTL implementation, verification, workload-trace preparation, and report/presentation writing.

## 8. Existing Problems and Solutions

Several practical issues remain.

First, the documentation is not perfectly synchronized with the active source tree. Some files describe a more heavily refactored RTL organization than the current `src/` directory actually contains. The immediate solution is to treat the live source files and generated logs as authoritative and to revise the remaining documents accordingly.

Second, the next-line prefetcher is beneficial only for some access patterns. The current results already show that it helps sequential or highly localized access but can add unnecessary lower-memory traffic for stride and irregular patterns. The project addresses this by keeping the prefetcher optional and by recording useful, useless, dropped, and pollution-related statistics for later comparison.

Third, the cache is still a blocking design with one serialized lower-memory path. This simplifies control and is appropriate for a baseline, but it limits throughput and can reduce the observed benefit of prefetching because extra prefetch traffic competes with demand misses. The solution at this project stage is not to redesign the cache immediately, but to evaluate the blocking baseline carefully and use that evidence to motivate any later extension such as buffering or non-blocking support.

Fourth, some proposed advanced comparisons are still incomplete. Zero-entry victim-cache bypass, alternate replacement policies such as LRU, and broader true-pollution or timeliness analysis remain future work items.

## 9. Next Stage Work Plan and Research Content

The next stage should focus on turning the existing baseline into a stronger comparative study.

1. Expand trace-driven experiments using additional benchmark regions and replay files.
2. Compare baseline, victim-cache-only, prefetch-only, and combined configurations under the same workloads.
3. Use the existing counters and logs to relate hit rate, victim hits, memory traffic, and cycle count rather than relying on hit rate alone.
4. Reconcile the architecture and implementation documents so that all report text matches the active RTL and scripts.
5. Run or refresh the Vivado-based RV64 flow for simulation, synthesis, timing, utilization, and power evidence.
6. Inspect key FSM waveform paths, especially fill, swap, write-back, and prefetch interactions.
7. Decide whether one optional extension, such as a zero-entry victim-cache bypass mode or a prefetch-buffer variant, is feasible within the remaining thesis schedule.

This plan keeps the current momentum: the hardware baseline is already functional, so the highest-value next work is disciplined evaluation and thesis-quality analysis.

## 10. References

- [README.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/README.md)
- [docs/l1d_baseline.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/l1d_baseline.md)
- [docs/literature_review.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/literature_review.md)
- [docs/tasks.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/tasks.md)
- [scripts/run_iverilog.sh](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_iverilog.sh)
- [scripts/run_vivado.tcl](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_vivado.tcl)
- [scripts/gem5_trace_capture.py](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/gem5_trace_capture.py)
- [scripts/convert_gem5_packet_trace.py](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/convert_gem5_packet_trace.py)
- [scripts/convert_gem5_write_trace.py](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/convert_gem5_write_trace.py)
- [src/l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_cache.sv)
- [src/l1d_next_line_prefetch.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_next_line_prefetch.sv)
- [src/l1d_sram.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_sram.sv)
- [src/tb_l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/tb_l1d_cache.sv)
- [sim/workload_results.csv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/workload_results.csv)
- [sim/spec_trace.log](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/spec_trace.log)
- [sim/spec_trace_prefetch.log](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/sim/spec_trace_prefetch.log)
- [traces/spec2017_replay.trace](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/traces/spec2017_replay.trace)
- [traces/smoke.trace](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/traces/smoke.trace)
