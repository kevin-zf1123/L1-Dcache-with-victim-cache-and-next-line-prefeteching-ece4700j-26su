# L1 Data Cache, Victim Cache, and Prefetching Literature Review

## Purpose

This document records the research basis used to review the baseline RTL.
English is authoritative. Downloaded public copies and implementation
snapshots are indexed in the ignored `ref/README.md`.

## Sources Reviewed

### Baseline L1 data-cache implementation

- The Rocket Chip `DCache.scala` implementation was reviewed as an
  implementation reference for staged synchronous-array access, metadata,
  write-back paths, request replay, and separation of cache storage from
  control. Rocket is substantially more capable than this project baseline,
  including coherence and non-blocking integration concerns that are
  intentionally out of scope.
- The GS464E paper and Intel/Qualcomm architecture decks confirm that practical
  high-performance L1 data caches use greater associativity, multiple access
  paths, and additional hierarchy structures. They are scale references, not
  direct RTL templates.

Conclusion: using synchronous SRAM wrappers and a multi-cycle control FSM is a
reasonable FPGA-oriented baseline. It does not claim a commercial single-cycle
L1 hit latency. The current blocking interface must be measured as a baseline
before adding MSHRs, replay queues, store buffers, or hit-under-miss.

### Victim cache

Jouppi's ISCA 1990 work introduced the small fully associative victim cache in
the refill path of a direct-mapped cache. The essential behavior is:

- retain recently evicted L1 lines;
- probe the victim structure on an L1 miss; and
- on a victim hit, swap the victim line with the conflicting L1 line.

The implemented RTL follows these semantics. It stores complete line address,
data, valid, dirty, and prefetched metadata, performs fully associative lookup,
and swaps on a hit. Dirty victim replacement is written back before overwrite.

The implementation extends the original direct-mapped use case to 2-way L1.
That extension is structurally valid but its benefit must be measured: as L1
associativity rises, fewer conflict misses remain for a small victim cache to
capture. The workload plan therefore compares direct-mapped and 2-way designs
instead of assuming equal benefit.

Current deliberate simplifications:

- victim replacement is round-robin rather than LRU;
- victim lookup adds an FSM cycle rather than a timing-optimized parallel
  single-cycle rescue path; and
- there is no zero-entry bypass configuration yet.

### Next-line and stream prefetching

Jouppi's work also studied prefetch buffers and stream buffers. A key design
choice is where prefetched data is placed:

- a separate prefetch/stream buffer reduces direct L1 pollution but requires a
  second lookup and promotion path;
- direct L1 insertion gives a fast hit when correct but can evict useful demand
  data.

The current RTL is a one-block-lookahead next-line baseline that inserts into
L1. This is intentionally simple and matches the candidate behavior in
ChampSim's `next_line` reference: generate block `N+1` from an observed block
`N`. It is more pollution-prone than Jouppi-style stream buffering, so the
design marks prefetched lines and counts useful, useless, and displacement
events.

Chen and Baer's hardware prefetching work and later surveys distinguish
accuracy, coverage, timeliness, and bandwidth cost. A useful-prefetch count
alone is insufficient. Final evaluation must calculate:

- accuracy = useful prefetches / issued or filled prefetches;
- coverage = demand misses removed by prefetching / baseline demand misses;
- timeliness = whether the prefetch completes before the demand;
- pollution = additional demand misses caused by prefetch displacement; and
- bandwidth overhead = extra lower-memory traffic.

The current `stat_prefetch_pollution` counter is only a pressure proxy because
an L1 line displaced by prefetch may remain in the victim cache. Trace-based
comparison against a prefetch-disabled run is required to identify true
additional misses.

### Adaptive and feedback-directed prefetching

Feedback-directed prefetching research and Pythia show that a prefetcher should
consume system feedback rather than remain hardwired to one policy. Gaze
further demonstrates that spatial-pattern recognition and explicit
over-prefetch mitigation can improve on a simple next-line policy.

The RTL therefore exposes:

- runtime master enable `cfg_prefetch_enable`;
- runtime built-in policy enable `cfg_next_line_enable`;
- `ext_prefetch_valid/ready/addr` for an external stride, region, Gaze-like, or
  adaptive candidate generator;
- one-cycle hit, miss, victim-hit, write-back, prefetch fill/useful/useless/
  pollution/drop events; and
- cumulative counters for offline and hardware control-loop evaluation.

This interface keeps prediction policy outside the core miss/eviction FSM.
Future prefetchers can be evaluated without changing CPU or lower-memory
protocols.

## Review of the Current RTL

### Supported by the literature

- Fully associative victim lookup with swap on victim hit.
- Deferred dirty write-back when a victim entry must be overwritten.
- Write-back plus write-allocate for temporal store locality.
- Synchronous SRAM arrays separated from control metadata.
- Demand priority over best-effort prefetch traffic.
- Explicit prefetched-line metadata and feedback events.
- Replaceable prefetch candidate interface.

### Areas requiring further work

- Add a separate prefetch-buffer placement option to compare against direct L1
  insertion.
- Add true pollution measurement by tracking whether a displaced demand line
  is requested before it would otherwise have been evicted.
- Add prefetch timeliness and lower-memory request counters.
- Add backpressure-aware prefetch scheduling and cancellation.
- Add 0/4/8 victim-entry configurations; zero entries currently require a
  bypass implementation.
- Compare round-robin and LRU victim replacement.
- Add assertions that a line cannot be simultaneously valid in L1 and victim
  cache, except transiently inside a swap edge.
- Add randomized reference-model checking and formal properties for dirty-data
  preservation.
- Add MSHRs or a refill buffer only after the blocking baseline is stable.

## Proposal Reference Audit

The proposal has a useful architectural direction, but its references vary in
strength:

- Jouppi, GS464E, Gaze, and the XiangShan work are relevant technical sources.
- Intel and Qualcomm decks are useful primary industry disclosures but are not
  peer-reviewed papers.
- DeviceBeast is a secondary specification site and should not be the primary
  evidence for Apple cache organization.
- The Loongson manual citation needs an exact edition and stable official URL.
- The textbook is suitable background but should be obtained through a legal
  library copy.

Before the proposal bibliography is finalized, replace weak web references
with official vendor documents or peer-reviewed measurements where possible,
and add access dates for mutable web pages.

## Primary Links

- [Jouppi victim cache, ISCA 1990](https://doi.org/10.1109/ISCA.1990.134547)
- [Chen and Baer hardware prefetching, IEEE TC 1995](https://doi.org/10.1109/12.381947)
- [Feedback Directed Prefetching, HPCA 2007](https://doi.org/10.1109/HPCA.2007.346185)
- [When Prefetching Works, TACO 2012](https://doi.org/10.1145/2133382.2133384)
- [Pythia, MICRO 2021](https://arxiv.org/abs/2109.12021)
- [Gaze, HPCA 2025](https://arxiv.org/abs/2412.05211)
- [Rocket Chip DCache](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/DCache.scala)
- [ChampSim next-line prefetcher](https://github.com/ChampSim/ChampSim/tree/master/prefetcher/next_line)
