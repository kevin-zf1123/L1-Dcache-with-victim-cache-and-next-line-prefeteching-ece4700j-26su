# Design Review I Presentation

## Deck Positioning

- Audience: course design review / technical milestone presentation
- Duration: about 15 minutes
- Goal: show implemented architecture, verification readiness, interim evidence, and next-stage plan
- Tone: formal, technical, concise, evidence-driven

## Slide 1. Title

**Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching**

- Design Review I
- ECE 4700J course project
- Focus of this review:
  - implemented RTL baseline
  - verification progress
  - interim workload results
  - remaining risks and next steps

Visual idea:
- Clean cover with chip/cache abstract background
- One highlight line: "Conflict-miss reduction + simple prefetch evaluation"

Speaker note:
Open by framing this as an implementation and measurement milestone. The key message is that the baseline architecture is already built and the next phase is focused on evidence collection and comparison.

## Slide 2. Motivation and Research Question

**Why this project matters**

- L1 data-cache misses directly increase pipeline stall time
- Small low-latency caches remain vulnerable to conflict misses
- Simple prefetchers can improve streaming access, but may waste bandwidth or pollute L1

**Research question**

- Can a small victim cache and a simple next-line prefetcher improve L1D behavior under representative workload boundaries?
- Under what access patterns do they help, and when do they hurt?

Visual idea:
- Two-column comparison: conflict miss problem on the left, prefetch tradeoff on the right

Speaker note:
Keep this slide conceptual. We are not claiming universal improvement; we are studying the boundary conditions of two classic cache techniques.

## Slide 3. Project Scope and Contributions

**Implemented scope**

- Blocking L1 data cache with ready/valid CPU and lower-memory interfaces
- Configurable direct-mapped or 2-way organization
- Write-back and write-allocate policy
- Fully associative victim cache with swap path
- Idle-cycle next-line prefetch baseline
- Runtime control, external prefetch hook, and hardware statistics

**Contribution of current milestone**

- A working RTL research platform for comparing:
  - baseline cache behavior
  - victim-cache benefit
  - prefetch usefulness and overhead

Visual idea:
- One central architecture block with four labeled feature callouts

Speaker note:
This slide tells the reviewers exactly what has been implemented already, so the rest of the talk has a clear technical boundary.

## Slide 4. Top-Level Architecture

**System organization**

```text
CPU <-> L1D cache controller <-> lower line memory
          |        | 
          |        +-> next-line / external prefetch path
          |
          +-> tag/data SRAM arrays + victim cache + counters
```

**Key modules**

- `l1d_cache.sv`: datapath, FSM, victim-cache control, counters
- `l1d_sram.sv`: synchronous SRAM wrapper
- `l1d_next_line_prefetch.sv`: one-entry next-line generator
- `tb_l1d_cache.sv`: self-checking testbench and memory model

Visual idea:
- Structured architecture diagram with three layers:
  - CPU interface
  - cache core
  - lower memory interface

Speaker note:
Emphasize that this is an FPGA-oriented, synchronous-array design rather than an aggressive commercial L1 implementation.

## Slide 5. Data Path and Control Flow

**Main FSM states**

- `ST_IDLE`: accept CPU request or issue idle-time prefetch
- `ST_LOOKUP`: read arrays and compare L1 ways / victim entries
- `ST_HIT_WRITE`: commit store hit and mark dirty
- `ST_VC_SWAP`: swap victim-hit line into L1
- `ST_WB_REQ` and `ST_VC_INSERT`: preserve dirty evictions
- `ST_MEM_READ_REQ`, `ST_MEM_READ_WAIT`, `ST_INSTALL`: fetch and install line
- `ST_RESP`: hold response under backpressure

**Key behavior**

- Demand traffic has priority over prefetch traffic
- Victim hits avoid unnecessary lower-memory reads
- Dirty data is preserved through deferred write-back

Visual idea:
- Simple left-to-right miss path flowchart with victim-hit branch

Speaker note:
Walk through one miss example: L1 miss, victim check, possible rescue, otherwise eviction/write-back/fill/install/response.

## Slide 6. Victim Cache and Prefetch Design Choices

**Victim cache**

- Fully associative structure storing line address, data, valid, dirty, and prefetched metadata
- Swap-based rescue on victim hit
- Round-robin replacement in current baseline

**Next-line prefetch**

- Triggered after demand fills
- One-entry candidate queue
- Executes only when cache is idle
- Directly inserts prefetched lines into L1

**Monitoring support**

- Useful, useless, pollution, fill, drop, hit, miss, and write-back counters
- External candidate injection for future adaptive policies

Visual idea:
- Two feature cards: victim cache on left, prefetch path on right

Speaker note:
This slide connects the RTL to the research question. The design is intentionally simple enough to verify, but rich enough to expose meaningful tradeoffs.

## Slide 7. Verification and Experiment Setup

**Verification environment**

- Icarus Verilog for fast functional regression
- Self-checking testbench with backing-memory model
- Vivado batch flow prepared for later simulation and synthesis

**Test coverage already implemented**

- cold misses and hit behavior
- write-allocate and byte-enable stores
- victim rescue under conflict pressure
- dirty victim replacement write-back
- CPU response and memory-request backpressure stability
- randomized golden-memory scoreboard
- synthetic workload boundary tests
- text trace replay support

Visual idea:
- Verification stack diagram: directed tests, randomized tests, workloads, trace replay

Speaker note:
Stress that the project already has a real verification harness, not only manual waveform inspection.

## Slide 8. Regression Status and Current Readiness

**Current pass status**

- Direct-mapped, VC4, prefetch off: PASS
- 2-way, VC4, prefetch off: PASS
- 2-way, VC8, prefetch off: PASS
- 2-way, VC4, prefetch on: PASS
- Workload-boundary regression suite: PASS
- Trace replay smoke test: PASS

**Current readiness assessment**

- Functional baseline is stable enough for design review
- Measurement infrastructure is in place
- Final FPGA-tool evidence is not yet complete

Visual idea:
- Green regression matrix with one yellow box for "Vivado/PPA pending"

Speaker note:
This is the handoff point between implementation and evaluation. The RTL is ready for broader workload and PPA analysis.

## Slide 9. Interim Workload Evidence

**Synthetic workload observations for 2-way + VC4**

| Profile | Main observation |
| --- | --- |
| Sequential stream | Prefetch converts 6 of 12 accesses into hits |
| Two-line stride | Prefetch provides no benefit and doubles memory reads |
| Localized two-line loop | Slight improvement from one useful prefetch |
| Same-set conflict thrash | Victim cache rescues most repeated conflicts |
| Irregular pointer chase | Prefetch adds traffic without reducing misses |

**Key interpretation**

- Victim cache is effective for conflict-dominated patterns
- Next-line prefetch is highly workload-sensitive

Visual idea:
- One summary table plus two callout boxes: "helps" and "hurts"

Speaker note:
This is the strongest evidence slide. It shows that the current platform can already distinguish favorable and unfavorable workload classes.

## Slide 10. Technical Takeaways

**What we learned so far**

- Victim cache improves resilience to set conflicts with limited hardware complexity
- Next-line prefetch is beneficial for adjacency-heavy access streams
- Increased hit count does not necessarily reduce total lower-memory traffic
- Direct L1 insertion is simple, but can introduce pollution on irregular access patterns
- The exposed event/counter interface is useful for future adaptive experiments

**Most important takeaway**

- The design already demonstrates the intended tradeoff boundary rather than a one-sided improvement claim

Visual idea:
- Five concise takeaways with one highlighted final conclusion

Speaker note:
Frame this as a research milestone: the platform is already producing interpretable architectural evidence.

## Slide 11. Current Limitations and Risks

**Architectural limitations**

- Blocking cache with one outstanding CPU request
- No MSHRs, hit-under-miss, coherence, ECC, or zero-entry victim-cache bypass
- Replacement policy is round-robin, not LRU

**Evaluation risks**

- No final Vivado timing, area, or power reports yet
- No licensed SPEC-derived trace results yet
- Current pollution metric is a proxy, not a full true-pollution measurement

Visual idea:
- Risk slide with two sections: architecture limits and evaluation gaps

Speaker note:
Be explicit here. This strengthens credibility and makes the next-stage plan feel well scoped.

## Slide 12. Next Stage Plan

**Engineering tasks**

1. Run Vivado behavioral simulation for key configurations
2. Inspect waveforms for hit, miss, swap, fill, and write-back paths
3. Run synthesis and collect LUT, FF, memory, timing, and power reports

**Research tasks**

1. Extract and replay bounded SPEC CPU 2017/2026 traces
2. Compare direct-mapped vs. 2-way, victim-cache size, and prefetch on/off
3. Measure usefulness, bandwidth overhead, and AMAT-related trends

**Stretch goals**

- add zero-entry victim-cache bypass
- compare alternate replacement policies
- evaluate separate prefetch-buffer placement

Visual idea:
- Roadmap timeline from "validated RTL" to "final comparison and PPA"

Speaker note:
Show that the remaining work is focused and executable because the infrastructure is already in place.

## Slide 13. Closing

**Conclusion**

- The baseline RTL platform has been implemented and functionally verified
- Victim cache and next-line prefetch both show meaningful, measurable boundary behavior
- The project is ready to move from implementation-heavy work to tool-based evaluation and workload-driven comparison

**Closing message**

- Design Review I outcome: architecture complete, verification strong, evaluation phase next

Visual idea:
- Minimal closing slide with one strong summary statement

Speaker note:
End confidently: the project is not blocked on first implementation anymore; it is entering the evidence and comparison phase.

## Slide 14. Q&A

**Questions and Discussion**

- Architecture decisions
- verification methodology
- workload plan
- evaluation metrics

Visual idea:
- Clean Q&A page with subtle cache/block diagram background

Speaker note:
Use this as a buffer slide if the talk runs slightly short or if reviewers want to go deeper into methodology.

## Suggested Timing

- Slides 1-3: 3 minutes
- Slides 4-6: 4 minutes
- Slides 7-10: 4 minutes
- Slides 11-13: 3 minutes
- Slide 14 / Q&A transition: 1 minute

Total: about 15 minutes
