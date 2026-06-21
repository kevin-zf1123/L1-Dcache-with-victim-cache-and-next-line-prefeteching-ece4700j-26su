# Design Review I Team Report

## 1. Thesis Title

**Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching**

## 2. Design Top Diagrams and Interfaces

### 2.1 Top-level block diagram

```text
                +----------------------------------------------+
                |                  CPU Core                    |
                |   req_valid/ready, addr, write, wdata, wstrb |
                |   rsp_valid/ready, rdata                     |
                +------------------------+---------------------+
                                         |
                                         v
                +----------------------------------------------+
                |                 L1D Cache Top                |
                |                                              |
                |  +-------------+    +---------------------+  |
                |  | Control FSM  |<-->| Prefetch Control    | |
                |  | IDLE/LOOKUP/ |    | next-line + ext I/F | |
                |  | FILL/WB/RESP |    +---------------------+ |
                |  +------+------+                              |
                |         |                                     |
                |  +------+-------------------------------+      |
                |  | Tag/Data Arrays (1-way or 2-way)     |      |
                |  | valid/dirty/prefetched metadata      |      |
                |  +------+-------------------------------+      |
                |         |                                     |
                |  +------+-------------------------------+      |
                |  | Fully Associative Victim Cache       |      |
                |  | line addr + data + dirty/prefetched  |      |
                |  +------+-------------------------------+      |
                |         |                                     |
                |  +------+-------------------------------+      |
                |  | Stats + event outputs                |      |
                |  +--------------------------------------+      |
                +------------------------+---------------------+
                                         |
                                         v
                +----------------------------------------------+
                |           Lower Line Memory Interface        |
                | req_valid/ready, req_write, req_addr, wdata  |
                | rsp_valid, rdata                             |
                +----------------------------------------------+
```

### 2.2 Module interconnections

| Module | File | Role |
| --- | --- | --- |
| `l1d_cache` | `src/l1d_cache.sv` | Top-level cache datapath and controller |
| `l1d_sram` | `src/l1d_sram.sv` | Synchronous inferred SRAM wrapper for tag/data arrays |
| `l1d_next_line_prefetch` | `src/l1d_next_line_prefetch.sv` | One-entry next-line candidate generator |
| `tb_l1d_cache` | `src/tb_l1d_cache.sv` | Self-checking testbench, backing memory model, workload driver |

### 2.3 Interface summary

**CPU-side interface**

- Blocking ready/valid request channel
- One outstanding request at a time
- Supports aligned 32-bit reads and byte-enable writes
- Returns a completion response for both loads and stores

**Lower-memory interface**

- Cache-line reads and write-backs
- Request handshake uses `mem_req_valid/mem_req_ready`
- Line fill returns later through `mem_rsp_valid/mem_rsp_rdata`
- No lower-memory error or explicit write acknowledgment in this baseline

**Prefetch/adaptation interface**

- Runtime control through `cfg_prefetch_enable` and `cfg_next_line_enable`
- External candidate injection through `ext_prefetch_valid/ready/addr`
- Event outputs and cumulative counters for future adaptive policies

## 3. Summary of the Project Progress

We have completed the baseline RTL implementation of a blocking L1 data cache with configurable direct-mapped or 2-way organization, write-back/write-allocate behavior, a fully associative victim cache, and a next-line prefetch mechanism. The top-level controller is implemented as a multi-state FSM that covers idle lookup, L1 hit processing, victim-cache swap, dirty write-back, line fill, installation, and response hold under backpressure.

On the storage side, synchronous SRAM wrappers are used for both tag and data arrays so the design remains FPGA-oriented and compatible with Vivado inference. Valid, dirty, and prefetched metadata are tracked separately per line. The victim cache stores full line address, data, and metadata, and performs fully associative comparison on L1 misses. On a victim hit, the design swaps the victim entry with the selected L1 way instead of forcing an immediate lower-memory read.

The prefetch path is also implemented. After each demand fill, the next-line generator can enqueue one candidate. Prefetch requests only issue when the cache is idle, so demand traffic always has priority. The design also exposes a clean external prefetch interface so later research can plug in stride or feedback-directed policies without rewriting the main miss FSM.

Verification infrastructure is in place. The Icarus Verilog flow compiles and runs directed tests, randomized scoreboard checks, backpressure checks, synthetic workload tests, and a replay path for text-format traces. Vivado batch scripts and synthesis constraints have been prepared and run.

## 4. Summary of the Experiment Setup Preparation

The project already includes a practical experiment framework for functional validation and workload-oriented evaluation.

**Tools prepared**

- Icarus Verilog for fast RTL compilation and self-checking simulation
- `vvp` execution flow for regression logs
- Vivado batch script for later behavioral simulation and synthesis
- Shell scripts for workload regression and CSV summarization

**Prepared test cases**

- Cold miss and hit behavior
- Write-allocate and byte-enable store update
- Victim-cache rescue after conflict eviction
- Dirty victim replacement write-back to backing memory
- CPU response backpressure stability
- Lower-memory request stability under backpressure
- Randomized golden-memory scoreboard test
- Prefetch usefulness, uselessness, pollution proxy, and external injection

**Prepared benchmark/workload methods**

- Five deterministic synthetic workload profiles:
  - sequential stream
  - stride of two lines
  - localized two-line loop
  - same-set conflict thrash
  - irregular pointer chase
- Text trace replay driver for future SPEC CPU 2017/2026 derived traces
- CSV aggregation flow for workload results

This setup is sufficient for preliminary design review because it tests both correctness and the expected behavioral boundaries of victim caching and next-line prefetching.

## 5. Interim Results of the Project

### 5.1 Functional verification status

The preliminary Icarus regression matrix passes for:

- direct-mapped, 4-entry victim cache, prefetch off
- 2-way, 4-entry victim cache, prefetch off
- 2-way, 8-entry victim cache, prefetch off
- 2-way, 4-entry victim cache, prefetch on
- synthetic workload boundary tests
- trace replay smoke test

### 5.2 Key observations from interim workload data

For the 2-way, 4-entry victim-cache configuration, preliminary synthetic results show:

| Profile | Prefetch | Hits | Misses | Victim hits | Memory reads | Useful | Useless | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Sequential stream | Off | 0 | 12 | 0 | 12 | 0 | 0 | 128 |
| Sequential stream | On | 6 | 6 | 0 | 12 | 6 | 0 | 129 |
| Two-line stride | Off | 0 | 12 | 0 | 12 | 0 | 0 | 133 |
| Two-line stride | On | 0 | 12 | 0 | 24 | 0 | 6 | 227 |
| Localized loop | Off | 10 | 2 | 0 | 2 | 0 | 0 | 63 |
| Localized loop | On | 11 | 1 | 0 | 2 | 1 | 0 | 63 |
| Same-set conflict | Off | 0 | 12 | 9 | 3 | 0 | 0 | 79 |
| Irregular pointer chase | Off | 0 | 12 | 0 | 12 | 0 | 0 | 133 |
| Irregular pointer chase | On | 0 | 12 | 0 | 24 | 0 | 6 | 227 |

### 5.3 Interim interpretation

- The victim cache clearly helps conflict-heavy access patterns. In the same-set thrash case, only the first three accesses go to lower memory and later accesses are mostly recovered through victim hits.
- The next-line prefetcher helps simple sequential streaming and slightly helps a two-line temporal loop.
- The same prefetcher hurts non-adjacent stride and irregular pointer-chasing patterns by increasing lower-memory reads and total cycles.
- Because the current cache is blocking, prefetch improves hit count in favorable cases but does not always reduce total memory traffic or latency.

These results are consistent with the literature and support the project's motivation for combining a small victim cache with a simple prefetch baseline plus adaptation hooks.

## 6. Compare Current Progress with Proposal Timeline

Current implementation is ahead on core RTL completion and basic verification, but behind on final FPGA-oriented evaluation.

**Completed relative to proposal goals**

- Baseline cache organization implemented
- Victim cache implemented and verified
- Next-line prefetch baseline implemented
- Runtime control and external policy hook implemented
- Event counters and monitoring interface implemented
- Directed, randomized, and workload-oriented simulation prepared
- Trace replay infrastructure prepared

**Not yet completed**

- Vivado behavioral simulation on the final toolchain
- Synthesis, timing, utilization, and power collection
- Licensed SPEC trace extraction and classification
- Advanced comparison points such as zero-entry victim-cache bypass or alternate prefetch placement

Overall, the implementation and verification foundation is strong, but the project still needs hardware-tool results and larger workload evidence before the final evaluation phase.

## 7. Any Changes in Team Task Assignment?

No explicit team-role reassignment is documented in the repository at this time. Based on the current artifact structure, the work appears naturally divided into:

- RTL implementation and microarchitecture
- verification and workload regression
- documentation and literature review
- Vivado/PPA evaluation

If the team wants clearer management for the next phase, assigning one owner for Vivado/PPA closure and one owner for trace extraction would reduce schedule risk.

## 8. Existing Problems and Solutions

### Existing problems

- Vivado is not installed on the current development machine, so final synthesis/timing/power data is still missing.
- The cache is blocking and supports only one outstanding CPU request.
- There is no zero-entry victim-cache bypass configuration yet, so a true "no victim cache" comparison is not available from the same RTL path.
- The current prefetch pollution counter is only a pressure proxy, not a true extra-miss measurement.
- Prefetch insertion goes directly into L1, which may create avoidable pollution on irregular workloads.

### Current or proposed solutions

- Use the existing `scripts/run_vivado.tcl` flow on a machine with Vivado in `PATH`.
- Keep the current blocking cache as the validated baseline before considering non-blocking features such as MSHRs or replay buffers.
- Add a victim-cache bypass option for cleaner ablation studies.
- Extend counters and trace comparison to measure true pollution, timeliness, and memory-bandwidth overhead.
- Compare direct-L1 insertion with a small prefetch buffer in a later project stage.

## 9. Next Stage Work Plan and Research Content

### Near-term engineering plan

1. Run Vivado behavioral simulations for the main configurations.
2. Inspect waveforms for hit, miss, swap, fill, and write-back paths.
3. Run synthesis and collect LUT, FF, memory, timing, and power reports.
4. Summarize PPA differences across baseline, victim-cache, prefetch, and combined designs.

### Near-term research plan

1. Extract bounded memory traces from licensed SPEC CPU 2017/2026 workloads.
2. Replay anonymized traces through the cache testbench.
3. Compare direct-mapped vs. 2-way, victim entries, and prefetch on/off.
4. Measure accuracy, usefulness, bandwidth overhead, and AMAT-related trends.

### Stretch goals

1. Add zero-entry victim-cache bypass mode.
2. Add alternate victim replacement policy such as LRU.
3. Add separate prefetch-buffer placement option.
4. Explore adaptive external prefetch policies using the existing event interface.

## 10. Project Management Links

- GitHub / repository root: local project workspace
- Main baseline documentation: `docs/l1d_baseline.md`
- Literature review: `docs/literature_review.md`
- Task tracker: `docs/tasks.md`
- RTL source: `src/`
- Simulation scripts: `scripts/`
- Trace examples: `traces/`

No Feishu or external collaboration folder is documented in the repository.

## 11. References

- `docs/l1d_baseline.md`
- `docs/literature_review.md`
- `docs/tasks.md`
- `src/l1d_cache.sv`
- `src/tb_l1d_cache.sv`
- Jouppi, N. P., "Improving Direct-Mapped Cache Performance by the Addition of a Small Fully-Associative Cache and Prefetch Buffers," ISCA 1990.
- Chen, T.-F. and Baer, J.-L., "Effective Hardware-Based Data Prefetching for High-Performance Processors," IEEE TC 1995.
- Srinath et al., "Feedback Directed Prefetching," HPCA 2007.
- Ferdman et al., "When Prefetching Works, When It Doesn't, and Why," ACM TACO 2012.
- Peled et al., "Pythia: A Customizable Hardware Prefetching Framework Using Online Reinforcement Learning," MICRO 2021.
- Gaze, HPCA 2025 spatial prefetching work as cited in `docs/literature_review.md`.
