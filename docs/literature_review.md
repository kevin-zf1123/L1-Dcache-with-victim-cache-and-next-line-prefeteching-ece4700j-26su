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

The frozen policy-0 RTL is the original one-block-lookahead next-line baseline:
it matches ChampSim's `next_line` candidate behavior by generating block `N+1`
from observed block `N`. The optimized default instead uses a four-entry
Gaze-lite adjacent-stream detector, adaptive admission, safe cold direct-L1
insertion, shadow feedback, and one PF MSHR. Both retain direct-L1 data
placement, so prefetched-line metadata and useful/useless/displacement events
remain necessary to control and measure pollution.

Chen and Baer's hardware prefetching work and later surveys distinguish
accuracy, coverage, timeliness, and bandwidth cost. A useful-prefetch count
alone is insufficient. The strict paired replay calculates the following
metrics. Historical schema 2 used structural timely/late proxies; schema 3
records independent demand present/accept/response and PF lifecycle events:

- accuracy = useful prefetches / filled prefetches;
- L1 coverage = (baseline L1 misses - prefetch-on L1 misses) /
  baseline L1 misses;
- legacy `lower_coverage` = (baseline demand-owned reads - prefetch-on
  demand-owned reads) / baseline demand-owned reads. With an MSHR merge, add
  merged PF-owned reads back before interpreting required physical reads;
- timeliness = timely useful / (timely useful + late useful), where a late
  prefetch is still in flight when the demand first presents valid;
- true L1 pollution = a demand that is an L1 hit in the baseline run and an
  L1 miss in the paired prefetch-on run;
- true lower-memory pollution = a demand that avoids lower memory in the
  baseline run but reads lower memory in the paired prefetch-on run; and
- bandwidth overhead = (prefetch-on bytes - baseline bytes) / baseline bytes.

A ratio with a zero denominator is reported as N/A rather than zero.
For the same reason, `useful / fills` is specifically fill accuracy. A
merge-only P3 run can have N/A fill accuracy while `useful / issued` is 100%.

The current `stat_prefetch_pollution` counter is only a pressure proxy because
an L1 line displaced by prefetch may remain in the victim cache. Trace-based
per-demand comparison against a prefetch-disabled run is required to identify
true additional misses. Aggregate miss deltas show net benefit or harm but
cannot identify pollution and help events that cancel out.

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

This interface now feeds an implemented Gaze-lite adjacent-stream detector and
a lightweight feedback controller. Candidate generation remains metadata-only
and the CPU and lower-memory protocols are unchanged.

### Implemented adaptive direct-L1 policy

The optimized policy translates the literature into bounded mechanisms rather
than reproducing a large learning table:

- a four-entry stream table confirms only adjacent `+1/-1` streams, uses a
  two-entry candidate FIFO, preserves stream-generation attribution, expires
  candidates after 16 demand accesses, and never crosses a 4 KiB page;
- an OFF/PROBE/ON controller applies a two-token bucket, 1/16 probe and weak-ON
  rates, a 1/8 normal-ON rate, two-epoch negative hysteresis, and a 512-demand
  OFF cooldown;
- direct-L1 insertion is cold and constrained by clean-victim safety, one
  unused speculative line per set, response-time revalidation, and unused-line
  victim-cache bypass;
- a demand-only tag/dirty shadow L1/VC provides online causal help/pollution
  classification without storing a second copy of line data; and
- one metadata-only PF MSHR permits hit-under-prefetch, same-line load/store
  merge, immediate response capture, and bounded discard while preserving the
  one-outstanding lower-memory protocol.

The controller evaluates cycle-like `saved` and `cost` values. Its penalties
start at eight cycles and use 1/8 EWMA calibration. Level 2 uses raw
useful/pollution proxies through the same feedback interface; level 3 switches
that interface to shadow causal events and adds late-merge credit, blocked
demand cycles, speculative-issue cost, and attributed write-back cost.

The implementation deliberately retains direct-L1 data placement. The stream
table, candidate queues, shadow model, and PF MSHR contain only addresses,
tags, dirty bits, confidence, generations, and control metadata. Returned data
exists only in the normal transient refill register.

## Review of the Current RTL

### Supported by the literature

- Fully associative victim lookup with swap on victim hit.
- Deferred dirty write-back when a victim entry must be overwritten.
- Write-back plus write-allocate for temporal store locality.
- Synchronous SRAM arrays separated from control metadata.
- Demand priority over best-effort prefetch traffic.
- Explicit prefetched-line metadata and feedback events.
- Replaceable prefetch candidate interface.

### Current implementation status and remaining work

The implementation now includes separate demand/prefetch lower-memory
counters, complete schema-3 lifecycle attribution, paired per-demand
true-pollution attribution, online shadow causal feedback, line-uniqueness
assertions, and a randomized golden-memory reference model. Remaining work is:

- add a separate prefetch-buffer placement option to compare against direct L1
  insertion;
- extend lifecycle timing into full percentile distributions across more CPU
  timing models;
- add 0/4/8 victim-entry configurations; zero entries currently require a
  bypass implementation;
- compare round-robin and LRU victim replacement;
- extend simulation assertions with formal dirty-data-preservation properties;
  and
- evaluate whether multiple demand MSHRs are justified; the implemented single
  PF MSHR intentionally does not make the demand cache fully non-blocking.

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
- [XiangShan, MICRO 2022](https://talks-pubs.xiangshan.cc/publications/micro2022-xiangshan.pdf)
- [Rocket Chip DCache](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/DCache.scala)
- [ChampSim next-line prefetcher](https://github.com/ChampSim/ChampSim/tree/master/prefetcher/next_line)
