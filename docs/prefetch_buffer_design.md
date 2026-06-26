# Prefetch Buffer Design

## Overview

A prefetch buffer (also called a stream buffer or demand/prefetch queue) has been added to the L1 data cache to decouple prefetch issuance from L1 occupancy.

## Architecture

The prefetch buffer sits between the prefetch candidate generator and the L1 cache data path:

```
CPU Request --> [L1 Tag/Data Arrays] <-- Victim Cache
                    ^
                    |
            [Prefetch Buffer] <-- Next-Line Prefetcher
                    |
                    v
            [Lower Memory Interface]
```

## Key Design Decisions

### 1. Placement
The prefetch buffer is a separate FIFO queue that holds prefetched line addresses waiting to be filled. It decouples prefetch issuance from L1 occupancy, avoiding direct L1 pollution from speculative data.

### 2. Configuration Parameters
- `PREFETCH_BUFFER_SIZE`: Number of PB entries (default 4, must be power of two)
- `PB_ENABLED`: Automatically enabled when `ENABLE_PREFETCH != 0` and `PREFETCH_BUFFER_SIZE > 0`

### 3. Fill Handling (Option B - Mark-Filled)
PB entries track whether data has been fetched from memory. A `filled` flag indicates the line is ready for promotion to L1. This aligns with the existing FSM (the L1 fill path expects `fill_line` to be available in `ST_MEM_READ_WAIT`).

## FSM Modifications

### New States
- `ST_PB_ALLOC`: Allocate a PB entry for a prefetch miss
- `ST_PB_FILL_WAIT`: Wait for memory response for a PB-tracked line

### State Transitions
1. **ST_IDLE**: External prefetch and next-line candidates are routed through PB when `!pb_full`
2. **ST_LOOKUP**: On L1 miss + victim miss, check `pb_lookup_hit` first
   - PB hit -> wait for memory (`ST_MEM_READ_WAIT`)
   - No PB hit + not full -> allocate PB entry (`ST_PB_ALLOC`)
   - PB full -> direct demand miss
3. **ST_PB_ALLOC**: Allocate PB entry, then send memory request
4. **ST_MEM_READ_WAIT**: Mark PB entry as filled on memory response
5. **ST_INSTALL**: Free PB entry for prefetch fills

## Statistics

New counters:
- `stat_prefetch_buffer_allocated`: PB entries created
- `stat_prefetch_buffer_promoted`: Prefetched lines promoted to L1
- `stat_prefetch_buffer_evicted`: PB entries evicted
- `stat_prefetch_buffer_full_drops`: Prefetch candidates dropped due to full PB

New event pulses:
- `event_pb_allocated`, `event_pb_promoted`, `event_pb_evicted`, `event_pb_full_drop`

## Files Modified

- `src/l1d_prefetch_buffer.sv` (NEW): Prefetch buffer module
- `src/l1d_cache.sv`: FSM integration, PB signals, statistics
- `src/tb_l1d_cache.sv`: Testbench updates, PB test task

## Verification

The PB module compiles successfully with Icarus Verilog. Integration testing with the full cache and testbench requires further verification once the simulation environment is stabilized.

## Future Work

- Tune PB_SIZE for different workloads
- Add PB eviction policy (LRU, FIFO)
- Add PB occupancy monitoring
- Compare PB vs direct-L1-insertion performance

