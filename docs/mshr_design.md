# MSHR Non-Blocking L1 Data Cache — Design Specification

## Change Log

| Date       | Version | Change Description                           | Authors |
|------------|---------|----------------------------------------------|---------|
| 2026-06-30 | v0.1    | Initial MSHR non-blocking design spec        | TBD     |

---

## 1. Overview

### 1.1 Purpose

This document specifies the **Miss Status Holding Register (MSHR)** extension that transforms the current **blocking** L1 Data Cache into a **non-blocking** cache capable of:

- **Hit-under-miss**: servicing L1 hits while a prior miss is outstanding
- **Miss-under-miss**: supporting multiple concurrent outstanding misses
- **MSHR merging**: coalescing multiple CPU requests to the same cache line into a single memory transaction

### 1.2 Current Baseline

The existing L1D cache (src/l1d_cache.sv) is a **fully blocking** design:

`systemverilog
// Current behavior — CPU is blocked during entire miss pipeline
cpu_req_ready = (state == ST_IDLE);
`

The CPU must wait through the entire miss-handling sequence:
ST_LOOKUP → ST_VC_SWAP → ST_WB_REQ → ST_VC_INSERT → ST_MEM_READ_REQ → ST_MEM_READ_WAIT → ST_INSTALL → ST_RESP → ST_IDLE

This can stall the CPU for **tens of cycles** per miss. The Microarchitecture Specification (docs/Microarchitecture Specification.md) explicitly lists non-blocking operation as a **non-goal** for the baseline design.

### 1.3 Goals

| Goal | Description |
|------|-------------|
| Hit-under-miss | CPU continues issuing requests that hit in L1 while a miss is in progress |
| Miss-under-miss | Up to MSHR_ENTRIES misses can be outstanding simultaneously |
| MSHR merging | Multiple requests to the same line merge into one memory transaction |
| Backward compatibility | ENABLE_NONBLOCKING=0 falls back to original blocking behavior |
| Synthesizable | Same technology target (Xilinx Vivado, 100 MHz) |
| Verified | Full directed + randomized + trace-replay regression |

### 1.4 Non-Goals

- Store buffer / write-combining buffer
- Out-of-order store retirement
- Multi-core coherence extensions
- Speculative prefetch issuing during MSHR-full conditions

---

## 2. MSHR Module — l1d_mshr.sv

### 2.1 Module Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| MSHR_ENTRIES | 4 | Number of MSHR entries |
| ADDR_WIDTH | 64 | Address width (RV64) |
| DATA_WIDTH | 64 | CPU data word width |
| LINE_BITS | 128 | Cache line width in bits (16B x 8) |
| MAX_WAITERS | 4 | Maximum pending CPU requests per MSHR entry |

Derived locals:
- MSHR_BITS = clog2(MSHR_ENTRIES) (or 1 if MSHR_ENTRIES == 1)
- MSHR_COUNT_BITS = clog2(MSHR_ENTRIES + 1)

### 2.2 MSHR Entry Fields

Each MSHR entry tracks one outstanding cache miss and all CPU requests waiting on that line.

| Field | Width | Description |
|-------|-------|-------------|
| valid | 1 | Entry is allocated |
| addr | 64 | Full line address of the miss |
| is_write | 1 | At least one waiter is a store |
| wdata | 128 | Merged store data for the line |
| wmask | 16 | Byte-enable mask (1 = byte written) |
| size | 2 | Access size of primary request |
| unsign | 1 | Sign/zero extension for primary load |
| prefetch | 1 | This miss originates from prefetcher |
| issue_cycle | 32 | Timestamp when miss was detected |
| mem_sent | 1 | Memory read request has been issued |
| mem_done | 1 | Memory response has been received |
| wb_needed | 1 | Victim writeback required |
| evict_addr | 64 | Address of evicted (victim) line |
| evict_data | 128 | Data of evicted line |
| evict_dirty | 1 | Evicted line was dirty |
| n_waiters | 2 | Count of pending CPU sub-requests |
| waiter_valid | 4x1 | Valid bits for each waiter slot |
| waiter_addr | 4x64 | Address for each waiter |
| waiter_write | 4x1 | Load (0) or store (1) |
| waiter_size | 4x2 | Access size for each waiter |
| waiter_unsign | 4x1 | Sign/zero extension for each waiter |
| waiter_wdata | 4x64 | Store data for each waiter |
| waiter_wmask | 4x16 | Byte mask for each waiter store |

**Memory estimate** (MSHR_ENTRIES=4, MAX_WAITERS=4): ~2800 flip-flops, ~700 slices (approximate).

### 2.3 Port Interface

#### Allocation Interface (from Frontend FSM)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| alloc_valid | in | 1 | Allocate or merge request |
| alloc_addr | in | 64 | Full line address |
| alloc_write | in | 1 | Load (0) or store (1) |
| alloc_size | in | 2 | Access size |
| alloc_unsigned | in | 1 | Sign/zero extension |
| alloc_wdata | in | 64 | Store data (ignored for loads) |
| alloc_ready | out | 1 | MSHR can accept this request |
| alloc_entry_id | out | MSHR_BITS | Entry index allocated/merged |
| alloc_merged | out | 1 | Request was merged (not new entry) |

#### Lookup Interface (Combinational)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| lookup_addr | in | 64 | Line address to probe |
| lookup_hit | out | 1 | Address matches valid, !mem_done entry |
| lookup_id | out | MSHR_BITS | Matching entry index |

#### Backend Interface (to Backend FSM)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| backend_valid | out | 1 | At least one entry needs processing |
| backend_id | out | MSHR_BITS | Next entry to process (priority order) |
| backend_accept | in | 1 | Backend latched this entry |
| backend_mem_issued | in | 1 | Memory request sent for this entry |
| backend_mem_done | in | 1 | Memory response received |
| backend_fill_data | in | 128 | Filled cache line data |

#### Deallocation Interface

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| dealloc_valid | in | 1 | Free this MSHR entry |
| dealloc_id | in | MSHR_BITS | Entry to free |

#### Waiter Response Interface (to Frontend)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| waiter_rsp_valid | out | 1 | Response data for a waiter is ready |
| waiter_rsp_ready | in | 1 | Frontend accepts the response |
| waiter_rsp_data | out | 64 | Response data |
| waiter_rsp_error | out | 1 | Error flag |

#### Status

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| full | out | 1 | All MSHR entries allocated |
| empty | out | 1 | No MSHR entries allocated |
| count | out | MSHR_COUNT_BITS | Number of active entries |

---

## 3. Decoupled Frontend/Backend Architecture

### 3.1 Architectural Overview

`
                          +----------------------------------+
  cpu_req_valid --------->|                                  |
  cpu_req_ready <---------|        FRONTEND FSM              |
                          |   (1-2 cycles per request)       |--> cpu_rsp_valid (HIT PATH)
                          |                                  |
                          |   - Tag lookup                   |
                          |   - Hit detection                |
                          |   - Miss -> MSHR alloc/merge     |
                          |   - Misaligned -> error response |
                          +---------------+------------------+
                                          | miss
                                          v
                          +----------------------------------+
                          |           MSHR                    |
                          |   (4 entries x N waiters)        |--> waiter_rsp_valid (MISS PATH)
                          +---------------+------------------+
                                          | pending
                                          v
                          +----------------------------------+
  mem_req_valid <---------|                                  |
  mem_req_ready --------->|        BACKEND FSM               |
                          |   (sequential miss processor)    |--> mem_rsp_valid
                          |                                  |
                          |   - Victim eviction              |
                          |   - Memory read/write            |
                          |   - Line fill / install          |
                          +----------------------------------+
`

### 3.2 Frontend FSM

The frontend is a **2-state machine** that runs every cycle, independently of the backend.

**States**: FRONT_IDLE, FRONT_LOOKUP

**Key properties:**
- cpu_req_ready = !mshr_full && (state == FRONT_IDLE)
- Frontend always returns to FRONT_IDLE in 1-2 cycles
- Hit responses go directly to CPU (bypass backend)
- Miss responses come later via MSHR waiter fan-out

**Transitions:**

`
FRONT_IDLE:
  if (cpu_req_valid && cpu_req_ready):
    latch request into fr_req_* registers
    issue tag SRAM read
    -> FRONT_LOOKUP

FRONT_LOOKUP:
  if (access_misaligned):
    cpu_rsp_valid = 1, cpu_rsp_error = 1
    -> FRONT_IDLE
  else if (l1_hit):
    extract data from SRAM
    cpu_rsp_valid = 1 (direct to CPU)
    if (write): update SRAM with merged data
    -> FRONT_IDLE
  else if (victim_hit):
    allocate MSHR entry (or merge)
    -> FRONT_IDLE
  else:  // L1 miss, no victim hit
    allocate MSHR entry (or merge)
    -> FRONT_IDLE
`

### 3.3 Backend FSM

The backend is a **sequential miss processor** that handles one MSHR entry at a time.

**States:**

| State | Description |
|-------|-------------|
| ST_BACKEND_IDLE | Poll MSHR for next pending entry |
| ST_BACKEND_LOOKUP | Re-check tags (may now hit) |
| ST_BACKEND_VC_SWAP | Evict L1 line, swap with victim cache |
| ST_BACKEND_WB_REQ | Issue victim writeback to memory |
| ST_BACKEND_VC_INSERT | Store evicted line into victim cache |
| ST_BACKEND_MEM_REQ | Issue memory read for miss line |
| ST_BACKEND_MEM_WAIT | Wait for memory response |
| ST_BACKEND_INSTALL | Fill line into L1, update tags |
| ST_BACKEND_SERVE_WAITERS | Fan out responses to waiting CPU requests |

**Transitions:**

`
ST_BACKEND_IDLE:
  if (mshr_backend_valid):
    latch current_entry = mshr_backend_id
    mshr_backend_accept = 1
    -> ST_BACKEND_LOOKUP

ST_BACKEND_LOOKUP:
  // Re-check tags: another miss may have filled this line already
  if (l1_hit_now):
    -> ST_BACKEND_INSTALL (direct, no memory read needed)
  else if (victim_hit):
    -> ST_BACKEND_VC_SWAP
  else:
    -> ST_BACKEND_MEM_REQ

ST_BACKEND_VC_SWAP:
  // Same logic as current ST_VC_SWAP
  // Select eviction way, swap with victim cache
  // Track evicted victim data in MSHR evict_* fields
  if (evicted victim entry dirty):
    mshr_wb_needed[current] = 1
    -> ST_BACKEND_WB_REQ
  else:
    -> ST_BACKEND_MEM_REQ

ST_BACKEND_WB_REQ:
  mem_req_valid = 1, mem_req_write = 1
  mem_req_addr = mshr_evict_addr[current]
  mem_req_wdata = mshr_evict_data[current]
  wait for mem_req_ready
  -> ST_BACKEND_MEM_REQ

ST_BACKEND_MEM_REQ:
  mem_req_valid = 1, mem_req_write = 0
  mem_req_addr = mshr_addr[current]
  mshr_mem_sent[current] = 1
  wait for mem_req_ready
  -> ST_BACKEND_MEM_WAIT

ST_BACKEND_MEM_WAIT:
  wait for mem_rsp_valid
  mshr_mem_done[current] = 1
  mshr_fill_data[current] = mem_rsp_rdata
  -> ST_BACKEND_INSTALL

ST_BACKEND_INSTALL:
  // Write fill_data into L1 data SRAM
  // Update tag, valid, dirty, lru
  // Signal MSHR backend_mem_done
  -> ST_BACKEND_SERVE_WAITERS

ST_BACKEND_SERVE_WAITERS:
  // Iterate over waiter slots in MSHR entry
  // For each valid waiter:
  //   Extract data from fill_data
  //   Assert waiter_rsp_valid with extracted data
  //   Wait for waiter_rsp_ready
  // On completion: deallocate MSHR entry
  -> ST_BACKEND_IDLE
`

### 3.4 SRAM Access Arbitration

The frontend and backend share the tag/data SRAM arrays:

- **Read-read conflicts**: Frontend reads tags during FRONT_LOOKUP; Backend reads during BACKEND_LOOKUP. Fixed priority gives frontend precedence (only 1 cycle).
- **Read-write conflicts**: Backend writes tags during BACKEND_INSTALL; Frontend reads during FRONT_LOOKUP. If both occur same cycle: stall frontend 1 cycle.

`systemverilog
// SRAM arbitration
frontend_sram_grant = (state != ST_BACKEND_INSTALL);
if (!frontend_sram_grant) begin
    frontend_stall = 1;
end
`

---

## 4. MSHR Allocation and Merge Logic

### 4.1 Allocation Flow

`
CPU Request -> Frontend FSM -> Tag Lookup -> MISS detected
                                              |
                                    +---------+---------+
                                    | mshr_lookup_hit?  |
                                    +----+---------+----+
                                       YES         NO
                                        |           |
                                        v           v
                                +-----------+ +-----------+
                                | MERGE     | | ALLOCATE  |
                                | into      | | new entry |
                                | existing  | |           |
                                | entry     | | if !full  |
                                +-----+-----+ +-----+-----+
                                      |             |
                                      v             v
                                Return to FRONT_IDLE
                                (CPU can send next request)
`

### 4.2 Merge Logic (Same-Line Coalescing)

`systemverilog
// Combinational merge detection
always_comb begin
    mshr_lookup_hit = 0;
    mshr_lookup_id  = 0;
    for (int i = 0; i < MSHR_ENTRIES; i++) begin
        if (mshr_valid[i] &&
            mshr_addr[i] == alloc_addr &&
            !mshr_mem_done[i]) begin
            mshr_lookup_hit = 1;
            mshr_lookup_id  = i;
            break;
        end
    end
end
`

When merging a store: update byte-enable mask and merge store data into the MSHR line buffer.

### 4.3 Allocation Priority

New entries use priority encoder (lowest-index free entry). Demand misses take priority over prefetch misses.

### 4.4 Backend Priority

Backend processes entries in FIFO order (oldest miss first). Demand entries processed before prefetch entries.

---

## 5. Waiter Response Fan-Out

### 5.1 Response Sequencing

When backend reaches ST_BACKEND_SERVE_WAITERS for MSHR entry e:

`
For waiter_index = 0 to MAX_WAITERS-1:
    if (mshr_waiter_valid[e][waiter_index]):
        // Extract data from filled line
        response_data = line_load_data(fill_data, waiter_addr, waiter_size, waiter_unsign);
        // If waiter is a store: merge store data into line first
        if (mshr_waiter_write[e][waiter_index]):
            merged_line = merge_store_data(fill_data, waiter_addr, waiter_wdata, waiter_size);
            response_data = line_load_data(merged_line, ...);
        
        // Assert response, wait for ready
        waiter_rsp_valid = 1;
        waiter_rsp_data  = response_data;
        wait (waiter_rsp_ready);
        waiter_rsp_valid = 0;

// All waiters served -> deallocate MSHR entry
mshr_valid[e] = 0;
`

### 5.2 CPU Response Multiplexing

`systemverilog
// CPU response multiplexing
always_comb begin
    if (frontend_rsp_pending) begin
        cpu_rsp_valid = 1;
        cpu_rsp_rdata = frontend_rsp_data;
    end else if (mshr_waiter_rsp_valid) begin
        cpu_rsp_valid = 1;
        cpu_rsp_rdata = mshr_waiter_rsp_data;
    end else begin
        cpu_rsp_valid = 0;
        cpu_rsp_rdata = 'x;
    end
end
`

---

## 6. Victim Cache Integration with MSHR

### 6.1 MSHR-Aware Victim Flow

`
ST_BACKEND_VC_SWAP:
  - selected_way = evict_way_comb (as before)
  - Swap: L1[selected_way][set] <-> VC[victim_hit_idx]
  - If VC entry was dirty:
      Store evicted VC addr/data into MSHR evict_* fields
      mshr_wb_needed[current] = 1
  - -> ST_BACKEND_WB_REQ (if wb_needed) else ST_BACKEND_MEM_REQ

ST_BACKEND_VC_INSERT:
  - Insert evicted L1 line into VC at round-robin position
  - If that VC slot was dirty -> writeback needed first
  - -> ST_BACKEND_WB_REQ or ST_BACKEND_MEM_REQ
`

### 6.2 Writeback Sequencing

Writebacks must complete **before** the memory read for the same MSHR entry. The backend serializes: writeback -> memory read -> fill for each MSHR entry.

---

## 7. Prefetch Integration with MSHR

### 7.1 Next-Line Prefetch Trigger

`
Before:  next_line_trigger = (state == ST_INSTALL) && !req_is_prefetch;
After:   next_line_trigger = (backend_state == ST_BACKEND_INSTALL)
                             && !mshr_prefetch[current_entry];
`

### 7.2 Prefetch MSHR Allocation

- Prefetch candidates allocated as MSHR entries with prefetch=1
- Backend processes prefetch entries only when no demand entries pending
- If MSHR full, prefetch candidates are dropped (same as current)

### 7.3 External Prefetch

External prefetches (ext_prefetch_valid) routed through frontend as MSHR entries with prefetch=1.

### 7.4 Prefetch Buffer Path

PB alloc/fill handled by backend asynchronously; PB promotion handled by frontend on CPU hit in PB.

---

## 8. Parameterization

### 8.1 New Parameters in l1d_cache

`systemverilog
module l1d_cache #(
    // ... existing parameters ...
    parameter integer MSHR_ENTRIES        = 4,
    parameter integer ENABLE_NONBLOCKING  = 1
) ( /* ... */ );
`

### 8.2 Backward Compatibility

When ENABLE_NONBLOCKING == 0:
- cpu_req_ready = (state == ST_IDLE) — original blocking behavior
- MSHR module not instantiated (using generate if)
- Backend FSM = original FSM (same state names and transitions)
- No new ports required on l1d_cache

This enables A/B comparison between blocking and non-blocking configurations using the same testbench.

---

## 9. New Statistics and Events

### 9.1 Output Ports

`systemverilog
output logic [31:0] stat_mshr_allocations,
output logic [31:0] stat_mshr_merges,
output logic [31:0] stat_mshr_full_stalls,
output logic [31:0] stat_hit_under_miss,
output logic [31:0] stat_miss_under_miss,
output logic [31:0] stat_mshr_cycles
`

### 9.2 Event Pulses

`systemverilog
output logic event_mshr_full
`

### 9.3 Counter Semantics

| Counter | Increments When |
|---------|----------------|
| stat_mshr_allocations | A new MSHR entry is allocated (not a merge) |
| stat_mshr_merges | A CPU request merges into an existing MSHR entry |
| stat_mshr_full_stalls | cpu_req_valid && !cpu_req_ready due to MSHR full |
| stat_hit_under_miss | A CPU hit occurs while mshr_count > 0 |
| stat_miss_under_miss | A miss is allocated while mshr_count >= 1 |
| stat_mshr_cycles | Every cycle where mshr_count > 0 |

---

## 10. Implementation Order

| Step | Description | Estimated Effort |
|------|-------------|-----------------|
| 1 | Create src/l1d_mshr.sv — standalone module | Medium |
| 2 | Unit-test MSHR with minimal testbench | Small |
| 3 | Instantiate MSHR in l1d_cache.sv (behind generate if) | Small |
| 4 | Implement frontend FSM decoupling | Large |
| 5 | Implement hit-under-miss for reads | Medium |
| 6 | Implement backend FSM (sequential miss processor) | Large |
| 7 | Integrate victim cache path with MSHR tracking | Medium |
| 8 | Implement hit-under-miss for stores | Medium |
| 9 | Implement MSHR merge logic | Medium |
| 10 | Implement waiter response fan-out | Medium |
| 11 | Integrate prefetch and PB paths | Medium |
| 12 | Add statistics and events | Small |
| 13 | Write all directed tests (see testbench doc) | Medium |
| 14 | Write randomized OoO scoreboard test | Medium |
| 15 | Add protocol monitors | Small |
| 16 | Adapt trace replay | Small |
| 17 | Run full regression matrix | Large |
| 18 | Synthesize and compare PPA | Medium |

---

## 11. References

- [Jouppi, N.P., Improving Direct-Mapped Cache Performance by the Addition of a Small Fully-Associative Cache and Prefetch Buffers, ISCA 1990](https://doi.org/10.1109/ISCA.1990.134547)
- [Kroft, D., Lockup-Free Instruction Fetch/Prefetch Cache Organization, ISCA 1981](https://doi.org/10.1145/285930.285981)
- [Farkas, K.I. and Jouppi, N.P., Complexity/Performance Tradeoffs with Non-Blocking Loads, ISCA 1994](https://doi.org/10.1109/ISCA.1994.288147)
- [Tuck, N. et al., Scalable Cache Miss Handling for High Memory-Level Parallelism, MICRO 2006](https://doi.org/10.1109/MICRO.2006.44)
- Repository: src/l1d_cache.sv, src/l1d_next_line_prefetch.sv, src/l1d_prefetch_buffer.sv, src/l1d_sram.sv, src/tb_l1d_cache.sv
- Specification: docs/Microarchitecture Specification.md
