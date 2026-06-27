# Prefetch Measurement Plan

## Goal

Add measurement support for three missing evaluation dimensions:

- true pollution;
- prefetch timeliness; and
- memory-bandwidth cost.

The current RTL already records useful, useless, pollution-proxy, and dropped
prefetch events, so the remaining work is to turn those raw counters into
ground-truth comparisons and cycle-based metrics.

## Current Status

The first complete measurement flow is now implemented.

- Hardware-side counters now record prefetch issue count, prefetch fill count,
  useful and useless prefetches, issue-to-fill cycles, fill-to-use cycles,
  demand-memory reads, prefetch-memory reads, and writebacks.
- The workload output now emits these values through `WORKLOAD_RESULT`, and
  `scripts/summarize_workloads.sh` exports them into
  `sim/workload_results.csv`.
- The workload regression now runs with `+ACCESS_LOG`, which adds structured
  `WORKLOAD_BEGIN`, `ACCESS_RESULT`, and `PREFETCH_EVENT` lines to workload
  logs.
- `scripts/analyze_prefetch_metrics.py` computes paired-run true pollution,
  miss reduction, bandwidth overhead, prefetch accuracy, and an offline
  timeliness classification.

## Implemented Procedure

### 1. Hardware-side measurement

- Keep `stat_prefetch_pollution` as a pressure proxy.
- Record:
  - prefetch issue count;
  - prefetch fill count;
  - issue-to-fill cycle accumulation;
  - fill-to-use cycle accumulation;
  - demand-memory read count;
  - prefetch-memory read count; and
  - writeback count.
- Carry prefetch timing metadata with prefetched lines in both L1 and victim
  cache so victim-cache rescue still reports correct use latency.

### 2. Workload-level logging

During workload-mode runs, the testbench emits:

- `WORKLOAD_BEGIN name=<workload>`;
- `ACCESS_RESULT ...` for every completed CPU access; and
- `PREFETCH_EVENT kind=issue|fill|use|useless ...` for prefetch-related
  transitions.

This is the current source of truth for offline late/on-time classification.

### 3. Paired-run offline analysis

`scripts/analyze_prefetch_metrics.py` matches rows by:

- workload name;
- associativity;
- victim-entry count; and
- prefetch-buffer size.

It then derives:

- true pollution = `max(prefetch_misses - baseline_misses, 0)`;
- miss reduction = `max(baseline_misses - prefetch_misses, 0)`;
- bandwidth overhead = `prefetch_mem_total_bytes - baseline_mem_total_bytes`;
- prefetch accuracy = `prefetch_useful / prefetch_fills`;
- `late_prefetch_misses`: misses to lines that already had a prefetch issue but
  were not filled before the demand;
- `prefetched_miss_candidates`: misses to lines with an earlier prefetch issue;
- `filled_before_miss`: lines that had filled before the later miss; and
- `on_time_uses`: demand hits that consumed a prefetched line.

## Remaining Work

- Write the final interpretation into thesis-facing docs such as
  `docs/l1d_baseline.md`.
- Decide whether `late_prefetch_misses` should remain an offline metric or
  later become a dedicated hardware counter.
- If needed, extend the same analysis flow to longer benchmark trace-replay
  regions beyond the current synthetic workload set.

## Expected Outputs

- paired workload logs for prefetch-off and prefetch-on runs;
- updated workload CSV output with the new measurements;
- analyzer output from `scripts/analyze_prefetch_metrics.py`;
- a short interpretation note explaining when prefetching is timely, when it
  is late, and when it raises bandwidth cost; and
- a thesis-ready distinction between proxy pollution and true pollution.
