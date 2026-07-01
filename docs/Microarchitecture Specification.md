# Microarchitecture Specification
# L1 Data Cache with Victim Cache and Next-Line Prefetching

---

## 1. Change Log

| Date       | Version | Change Description         | Authors | Reviewers |
|------------|---------|----------------------------|---------|-----------|
| 2026-06-25 | v0.1    | First draft of the spec    | TBD     | TBD       |

---

## 2. Overview

This block is a **blocking L1 data cache** targeting the **RISC-V RV64** architecture. It implements a write-back, write-allocate cache with configurable direct-mapped or 2-way set-associative organization, a fully associative victim cache for conflict-miss recovery, and an optional next-line (spatial) hardware prefetcher with feedback counters for usefulness and pollution monitoring.

### 2.1 Goals

- Provide a cycle-accurate, synthesizable RTL model of an L1 data cache suitable for FPGA prototyping and ASIC evaluation.
- Support the full RV64 load/store ISA: byte, halfword, word, word-unsigned, and doubleword loads/stores with proper sign/zero extension and alignment error reporting.
- Reduce conflict misses through a parameterized fully associative victim cache with full-line swap semantics.
- Improve spatial locality exploitation through a replaceable next-line prefetcher that inserts prefetched lines directly into L1.
- Expose rich event counters and pulse events for offline and online performance analysis.

### 2.2 Non-Goals

- Multi-core coherence (MESI/MOESI protocols).
- Non-blocking operation: no MSHRs, no hit-under-miss, no store buffer.
- MMU/TLB translation, PMP/PMA permission checks, or uncached MMIO passthrough.
- Write-through policy, write-combining buffers, or partial-line write allocation.
- Advanced prefetch policies (stride, pattern-matcher, neural).
- ECC, scrubbing, or other reliability features.
- Back-pressure on the memory response path (the memory model provides a fixed 2-cycle latency).

### 2.3 Integration

The cache sits between a RISC-V CPU core and a lower-level memory system (L2 cache or DRAM controller). It presents:

- A **CPU request/response channel** with ready/valid handshakes carrying addresses, control signals (write, size, unsigned), and write data.
- A **line-memory interface** transferring complete 16-byte cache lines to/from the memory subsystem.
- An **external prefetch injection port** accepting prefetch addresses from an upstream prefetcher.
- A **next-line prefetcher submodule** producing best-effort aligned candidate addresses.
- **Statistics and event outputs** for performance monitoring.

### 2.4 Design Methodology

| Aspect              | Choice                                              |
|---------------------|-----------------------------------------------------|
| Language            | SystemVerilog (IEEE 1800-2012)                       |
| Synthesis target    | Xilinx Vivado (100 MHz clock, XDC constraint)       |
| Simulation          | Icarus Verilog (fast regression), Vivado XSim (signoff) |
| Memory primitives   | Synchronous single-port SRAM inference wrapper (l1d_sram) |
| Verification        | Self-checking testbench with directed tests, randomized scoreboard, synthetic workloads, and trace replay |

### 2.5 Physical Design Assumptions

- Clock: 100 MHz (10 ns period) as constrained in constraints/l1d_baseline.xdc.
- The design infers synchronous SRAM arrays for tags and data; actual SRAM binding depends on the target technology.
- Floorplan: the tag/data SRAM arrays occupy the central region; the FSM control logic and victim cache state sit around the periphery. Pin placement follows standard I/O conventions with clock entering on one side.
- Estimated gate count: approximately 3,000-8,000 equivalent logic cells depending on NUM_WAYS, NUM_SETS, and VICTIM_ENTRIES configuration.

---

## 3. High-Level Requirements

### 3.1 Functional Requirements

1. **RV64 Load/Store Contract.** The CPU interface accepts 64-bit byte addresses and 64-bit data words. Supported operations are byte (1 B), halfword (2 B), word (4 B), word-unsigned (4 B), and doubleword (8 B) accesses. Stores write partial data into the cache line; loads return the requested bytes with sign or zero extension to XLEN.

2. **Write-Back, Write-Allocate.** On a store miss, the cache allocates a line from lower memory, merges the store data into the line, and marks the line dirty. On a store hit, the store data is merged in-place and the dirty bit is set.

3. **Alignment Checking.** Misaligned loads and stores are detected at request time. The cache returns an error response (cpu_rsp_error=1, cpu_rsp_error_cause=RSP_LOAD_MISALIGNED or RSP_STORE_MISALIGNED) without accessing memory.

4. **Victim Cache.** A fully associative structure retaining recently evicted L1 lines. On an L1 miss, the victim cache is probed. On a victim hit, the victim line and the conflicting L1 line (or an invalid L1 slot) are swapped: both data and all metadata (valid, dirty, prefetched) transfer. If the evicted L1 line is dirty, a write-back is issued before the swap. If the victim entry being overwritten is dirty, a write-back is issued first.

5. **Next-Line Prefetching.** When a demand fill completes, the prefetcher computes the address of the next aligned cache line (line_address + LINE_BYTES) and emits a candidate. The candidate is best-effort: if the CPU or an external prefetcher issues a request before the candidate is consumed, the candidate is dropped. Prefetched lines are tracked with a prefetched bit and counted as useful (when later accessed by the CPU), useless (when evicted without CPU access), or pollution (when they displace a non-prefetched demand line).

6. **External Prefetch Injection.** The interface ext_prefetch_valid/ready/addr allows an upstream prefetcher (stride, pattern-matcher, Gaze, etc.) to inject prefetch candidates directly. External prefetches follow the same allocation and eviction path as next-line prefetches.

### 3.2 Performance Requirements

| Metric              | Value / Note                                          |
|---------------------|-------------------------------------------------------|
| Unloaded CPU latency (hit)   | 2 cycles (lookup + response)                    |
| Unloaded CPU latency (miss)  | Variable: depends on write-back chain and memory latency |
| Unloaded CPU latency (prefetch fill) | 1 cycle (if L1 hit on prefetch) or full miss path  |
| Memory interface throughput  | 1 line per request; blocking (no pipelining)     |
| Max concurrent transactions  | 1 CPU request, 1 memory request, 1 prefetch candidate |

### 3.3 Non-Functional Requirements

- **Synthesizability:** The RTL must compile cleanly under Vivado and infer synchronous SRAMs.
- **Reset:** Synchronous active-low reset (
st_n) initializes all state to zero.
- **Scalability:** Parameters allow CONFIGURABLE NUM_SETS (power of two, $\ge$ 2), NUM_WAYS (1 or 2), VICTIM_ENTRIES (0 or power of two), LINE_BYTES (power of two), and DATA_WIDTH (power of two bytes).

---

## 4. Top-Level Block Diagram

The top-level block diagram maps 1:1 to the l1d_cache RTL module. Internally, the design comprises:

- **Request Arbiter / Selector** (combinational logic within l1d_cache): arbitrates between CPU demand requests, external prefetch requests, and next-line prefetch candidates in fixed priority order.
- **Cache Controller FSM** (l1d_cache): a 10-state state machine governing lookup, hit/write, victim swap, write-back, memory read, fill install, and response phases.
- **Tag SRAM Arrays** (l1d_sram instances, generated per way): store tag bits indexed by set address. One read per cycle, one way-specific write per cycle.
- **Data SRAM Arrays** (l1d_sram instances, generated per way): store complete cache lines indexed by set address. One read per cycle, one way-specific write per cycle.
- **Metadata Storage** (registered arrays within l1d_cache): valid bits, dirty bits, prefetched bits, and round-robin replacement pointer per set.
- **Victim Cache** (registered arrays within l1d_cache): fully associative structure with VICTIM_ENTRIES entries, each storing a full address, full data line, valid, dirty, and prefetched metadata.
- **Next-Line Prefetcher** (l1d_next_line_prefetch submodule): single-entry candidate buffer that computes line_address + LINE_BYTES on demand fills.
- **Event Counters & Pulses** (registered counters and self-clearing pulses within l1d_cache): 9 cumulative 32-bit counters and 11 single-cycle event outputs.

---

## 5. Parameters and Typedefs

### 5.1 Module Parameters

| Parameter      | Type    | Default | Constraint                          | Description                           |
|---------------|---------|---------|-------------------------------------|---------------------------------------|
| ADDR_WIDTH  | integer | 64      | Must be 64 (RV64)                   | CPU address width                     |
| DATA_WIDTH  | integer | 64      | Power of 2, $\ge$ 8                 | CPU data width in bits                |
| LINE_BYTES  | integer | 16      | Power of 2, multiple of DATA_WIDTH/8 | Cache line size in bytes              |
| NUM_SETS    | integer | 8       | Power of 2, $\ge$ 2                 | Number of cache sets                  |
| NUM_WAYS    | integer | 2       | 1 or 2                              | Associativity (1 = direct-mapped)     |
| VICTIM_ENTRIES | integer | 4   | 0 or power of 2                     | Victim cache depth                    |
| ENABLE_PREFETCH | integer | 1 | 0 or 1                               | Compile-time prefetcher enable        |

### 5.2 Derived Localparams

| Localparam               | Definition                                      | Description                      |
|-------------------------|-------------------------------------------------|----------------------------------|
| LINE_BITS             | LINE_BYTES * 8                                | Cache line width in bits         |
| WORD_BYTES            | DATA_WIDTH / 8                                | CPU word width in bytes          |
| OFFSET_BITS           | $clog2(LINE_BYTES)                            | Byte offset within a line        |
| SET_BITS              | $clog2(NUM_SETS)                              | Set-index bit width              |
| TAG_BITS              | ADDR_WIDTH - OFFSET_BITS - SET_BITS            | Tag field width                  |
| SRAM_ADDR_WIDTH       | (NUM_SETS > 1) ? (NUM_SETS) : 1          | SRAM address input width         |
| WAY_BITS              | (NUM_WAYS > 1) ? (NUM_WAYS) : 1          | Way-select bit width             |
| VC_BITS               | (VICTIM_ENTRIES > 1) ? (VICTIM_ENTRIES) : 1 | Victim cache index width      |
| VICTIM_ENABLED        | (VICTIM_ENTRIES > 0)                          | Compile-time victim cache flag   |
| VICTIM_STORAGE_ENTRIES| (VICTIM_ENTRIES > 0) ? VICTIM_ENTRIES : 1      | Array dimension for VC storage   |

### 5.3 Access Size Enums

| Name            | Value | Bytes |
|-----------------|-------|-------|
| ACCESS_BYTE   | 2'b00 | 1     |
| ACCESS_HALF   | 2'b01 | 2     |
| ACCESS_WORD   | 2'b10 | 4     |
| ACCESS_DOUBLE | 2'b11 | 8     |

### 5.4 Response Error Codes

| Name               | Value | Meaning              |
|--------------------|-------|----------------------|
| RSP_OK           | 2'b00 | No error             |
| RSP_LOAD_MISALIGNED  | 2'b01 | Load address misaligned |
| RSP_STORE_MISALIGNED | 2'b10 | Store address misaligned |

---

## 6. Interfaces

### 6.1 Clock and Configuration

| Port Direction | Port Type             | Port Name               | Description                                   |
|---------------|-----------------------|-------------------------|-----------------------------------------------|
| Input         | logic               | clk                   | System clock                                  |
| Input         | logic               | 
st_n                 | Active-low synchronous reset                   |
| Input         | logic               | cfg_prefetch_enable   | Runtime master enable for all prefetching      |
| Input         | logic               | cfg_next_line_enable  | Runtime enable for the built-in next-line policy |

### 6.2 External Prefetch Injection

| Port Direction | Port Type             | Port Name               | Description                                   |
|---------------|-----------------------|-------------------------|-----------------------------------------------|
| Input         | logic               | ext_prefetch_valid    | External prefetch candidate is valid           |
| Output        | logic               | ext_prefetch_ready    | Cache accepts external prefetch (idle only)    |
| Input         | [ADDR_WIDTH-1:0]    | ext_prefetch_addr     | Byte address of external prefetch candidate    |

### 6.3 CPU Request Channel

| Port Direction | Port Type             | Port Name               | Description                                   |
|---------------|-----------------------|-------------------------|-----------------------------------------------|
| Input         | logic               | cpu_req_valid         | CPU has a request on the bus                   |
| Output        | logic               | cpu_req_ready         | Cache accepts CPU request (idle only)          |
| Input         | [ADDR_WIDTH-1:0]    | cpu_req_addr          | 64-bit byte address                            |
| Input         | logic               | cpu_req_write         | 1 = store, 0 = load                            |
| Input         | [1:0]               | cpu_req_size          | Access size: byte/half/word/double             |
| Input         | logic               | cpu_req_unsigned      | 1 = zero-extend load, 0 = sign-extend load     |
| Input         | [DATA_WIDTH-1:0]    | cpu_req_wdata         | Write data for stores                          |

### 6.4 CPU Response Channel

| Port Direction | Port Type             | Port Name               | Description                                   |
|---------------|-----------------------|-------------------------|-----------------------------------------------|
| Output        | logic               | cpu_rsp_valid         | Cache has response data (ST_RESP state)        |
| Input         | logic               | cpu_rsp_ready         | CPU accepts response                           |
| Output        | [DATA_WIDTH-1:0]    | cpu_rsp_rdata         | Loaded data for loads                          |
| Output        | logic               | cpu_rsp_error         | Error indicator                                |
| Output        | [1:0]               | cpu_rsp_error_cause   | Error cause: misalignment type                 |

### 6.5 Line Memory Interface

| Port Direction | Port Type             | Port Name               | Description                                   |
|---------------|-----------------------|-------------------------|-----------------------------------------------|
| Output        | logic               | mem_req_valid         | Cache issues a memory request (read fill or write-back) |
| Input         | logic               | mem_req_ready         | Lower memory accepts the request               |
| Output        | logic               | mem_req_write         | 1 = write-back, 0 = read-fill request          |
| Output        | [ADDR_WIDTH-1:0]    | mem_req_addr          | Line-aligned address                           |
| Output        | [(LINE_BYTES*8)-1:0]| mem_req_wdata         | Write-back data (full line)                    |
| Input         | logic               | mem_rsp_valid         | Lower memory has a fill response               |
| Input         | [(LINE_BYTES*8)-1:0]| mem_rsp_rdata         | Filled cache line data                         |

### 6.6 Statistics Outputs (cumulative 32-bit counters)

| Port Direction | Port Type             | Port Name                    | Description                                |
|---------------|-----------------------|------------------------------|--------------------------------------------|
| Output        | [31:0]              | stat_cpu_hits              | Cumulative CPU demand hits                  |
| Output        | [31:0]              | stat_cpu_misses            | Cumulative CPU demand misses                |
| Output        | [31:0]              | stat_victim_hits           | Cumulative victim cache hits                |
| Output        | [31:0]              | stat_writebacks            | Cumulative dirty line write-backs           |
| Output        | [31:0]              | stat_prefetch_fills        | Cumulative prefetch line fills into L1      |
| Output        | [31:0]              | stat_prefetch_useful       | Cumulative prefetches later accessed by CPU |
| Output        | [31:0]              | stat_prefetch_useless      | Cumulative prefetches evicted unused        |
| Output        | [31:0]              | stat_prefetch_pollution    | Cumulative prefetch displacing demand line  |
| Output        | [31:0]              | stat_prefetch_dropped      | Cumulative dropped next-line candidates     |

### 6.7 Event Pulse Outputs (single-cycle)

| Port Direction | Port Type | Port Name                    | Trigger Condition                                         |
|---------------|-----------|------------------------------|-----------------------------------------------------------|
| Output        | logic   | event_cpu_access           | CPU request arrives in ST_IDLE                             |
| Output        | logic   | event_cpu_hit              | L1 tag hit on demand request                               |
| Output        | logic   | event_cpu_miss             | L1 miss on demand request (includes victim-hit misses)     |
| Output        | logic   | event_victim_hit           | Victim cache hit on demand request                         |
| Output        | logic   | event_writeback            | Dirty line written to memory                               |
| Output        | logic   | event_prefetch_fill        | Prefetch candidate fills a new L1 line                      |
| Output        | logic   | event_prefetch_useful      | Prefetched line later accessed by CPU                       |
| Output        | logic   | event_prefetch_useless     | Prefetched line evicted without CPU access                  |
| Output        | logic   | event_prefetch_pollution   | Prefetch displaces a non-prefetched demand line             |
| Output        | logic   | event_prefetch_dropped     | Next-line candidate dropped due to buffer full              |

### 6.8 Status Outputs

| Port Direction | Port Type | Port Name      | Description                          |
|---------------|-----------|----------------|--------------------------------------|
| Output        | logic   | cache_idle   | 1 when FSM is in ST_IDLE             |

---

## 7. Address Decomposition

For a 64-bit address with the default configuration (LINE_BYTES=16, NUM_SETS=8):

`
Address [63:0]:
┌───────────────┬────────────┬──────────────────┐
│ Tag [47:0]    │ Set [6:0]  │ Byte Offset [3:0]│
│ 48 bits       │  7 bits    │   4 bits         │
└───────────────┴────────────┴──────────────────┘
`

General formula:

- **Byte offset:** OFFSET_BITS = (LINE_BYTES) (LSBs)
- **Set index:** SET_BITS = (NUM_SETS) (next field)
- **Tag:** TAG_BITS = ADDR_WIDTH - OFFSET_BITS - SET_BITS (MSBs)

Helper functions in RTL:

| Function           | Implementation                                    |
|--------------------|---------------------------------------------------|
| ddress_set(addr)| ddr >> OFFSET_BITS                             |
| ddress_tag(addr)| ddr[ADDR_WIDTH-1 -: TAG_BITS]                  |
| line_address(addr)| {addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}} |
| compose_line_address(tag, set)| {tag, set_index, {OFFSET_BITS{1'b0}}} |

---

## 8. Submodule: l1d_sram

A synchronous single-port SRAM inference wrapper used for both tag and data arrays.

### 8.1 Ports

| Port Direction | Port Type             | Description               |
|---------------|-----------------------|---------------------------|
| Input         | logic               | clk                     |
| Input         | logic               | en                      |
| Input         | logic               | we                      |
| Input         | [ADDR_WIDTH-1:0]    | ddr                    |
| Input         | [WIDTH-1:0]         | wdata                   |
| Output        | [WIDTH-1:0]         | 
data                   |

### 8.2 Behavior

- On en=1 and we=1: write wdata to mem[addr], read-back wdata to 
data in the same cycle (write-through read).
- On en=1 and we=0: read mem[addr] to 
data.
- On en=0: 
data holds its previous value.

### 8.3 Instantiation

Two parameterized instances per way:

| Instance    | WIDTH       | DEPTH    | Purpose          |
|-------------|-------------|----------|------------------|
| Tag array   | TAG_BITS  | NUM_SETS | Stores tag bits per way/set |
| Data array  | LINE_BITS | NUM_SETS | Stores complete cache line per way/set |

---

## 9. Submodule: l1d_next_line_prefetch

A one-entry candidate queue for spatial prefetching.

### 9.1 Ports

| Port Direction | Port Type             | Description                        |
|---------------|-----------------------|------------------------------------|
| Input         | logic               | clk                              |
| Input         | logic               | st_n                            |
| Input         | logic               | enable                           |
| Input         | logic               | demand_fill_valid                |
| Input         | [ADDR_WIDTH-1:0]    | demand_line_addr                 |
| Output        | logic               | candidate_valid                  |
| Input         | logic               | candidate_ready                  |
| Output        | [ADDR_WIDTH-1:0]    | candidate_addr                   |
| Output        | logic               | dropped                          |

### 9.2 Behavior

- Triggered on a demand fill (demand_fill_valid=1 and enable=1).
- Computes the next-line candidate as {tag, set, 0} + LINE_BYTES.
- If a candidate is already pending and not yet consumed (candidate_valid && !candidate_ready), the new candidate is dropped and dropped pulses high.
- The pending candidate is cleared when consumed (candidate_valid && candidate_ready) or when enable is deasserted.
- The module is stateless beyond its single-entry buffer: no history, no pattern matching.

---

## 10. Cache Controller FSM

The cache controller is implemented as a 10-state finite state machine.

### 10.1 State Enum

`systemverilog
typedef enum logic [3:0] {
    ST_IDLE,        // 4'b0000
    ST_LOOKUP,      // 4'b0001
    ST_HIT_WRITE,   // 4'b0010
    ST_VC_SWAP,     // 4'b0011
    ST_WB_REQ,      // 4'b0100
    ST_VC_INSERT,   // 4'b0101
    ST_MEM_READ_REQ,// 4'b1000
    ST_MEM_READ_WAIT,// 4'b1001
    ST_INSTALL,     // 4'b1010
    ST_RESP         // 4'b1011
} state_t;
`

### 10.2 State Transition Table

| From State      | Condition                                         | To State         |
|-----------------|---------------------------------------------------|------------------|
| ST_IDLE       | CPU req valid, aligned                            | ST_LOOKUP      |
| ST_IDLE       | CPU req valid, misaligned                         | ST_RESP        |
| ST_IDLE       | External prefetch valid                           | ST_LOOKUP      |
| ST_IDLE       | Next-line prefetch valid                          | ST_LOOKUP      |
| ST_LOOKUP     | L1 hit + demand load                              | ST_RESP        |
| ST_LOOKUP     | L1 hit + demand store                             | ST_HIT_WRITE   |
| ST_LOOKUP     | L1 hit + prefetch                                 | ST_IDLE        |
| ST_LOOKUP     | Victim hit + demand                               | ST_VC_SWAP     |
| ST_LOOKUP     | Victim hit + prefetch                             | ST_IDLE        |
| ST_LOOKUP     | Miss + invalid slot available                     | ST_MEM_READ_REQ|
| ST_LOOKUP     | Miss + dirty L1 eviction (no victim)              | ST_WB_REQ      |
| ST_LOOKUP     | Miss + dirty L1 eviction (with victim)            | ST_WB_REQ $\rightarrow$ ST_VC_INSERT |
| ST_LOOKUP     | Miss + clean L1 eviction + victim                 | ST_VC_INSERT   |
| ST_LOOKUP     | Miss + clean L1 eviction, no victim               | ST_MEM_READ_REQ|
| ST_HIT_WRITE  | Always                                            | ST_RESP        |
| ST_VC_SWAP    | Swap complete, need fill (victim hit + miss path) | ST_MEM_READ_REQ|
| ST_VC_SWAP    | Swap complete, no fill needed (victim hit + L1 had data) | ST_RESP |
| ST_WB_REQ     | WB accepted, victim insert pending                | ST_VC_INSERT   |
| ST_WB_REQ     | WB accepted, no victim insert                     | ST_MEM_READ_REQ|
| ST_VC_INSERT  | VC updated                                        | ST_MEM_READ_REQ|
| ST_MEM_READ_REQ | mem_req_ready                                   | ST_MEM_READ_WAIT|
| ST_MEM_READ_WAIT | mem_rsp_valid                                  | ST_INSTALL     |
| ST_INSTALL    | Prefetch fill                                     | ST_IDLE        |
| ST_INSTALL    | Demand fill                                       | ST_RESP        |
| ST_RESP       | cpu_rsp_ready                                     | ST_IDLE        |

### 10.3 State Descriptions

| State           | Cycles | Description                                                        |
|-----------------|--------|--------------------------------------------------------------------|
| ST_IDLE       | 1+     | Waits for a request from CPU, external prefetch, or next-line prefetcher. Asserts cpu_req_ready or ext_prefetch_ready as appropriate. |
| ST_LOOKUP     | 1      | Performs parallel L1 tag lookup (associative over all ways) and victim cache lookup. Determines hit/miss/victim-hit path. |
| ST_HIT_WRITE  | 1      | Updates the dirty bit and clears the prefetched bit for a hit store. Transitions to ST_RESP. |
| ST_VC_SWAP    | 1      | Swaps the victim line into the selected L1 slot (valid, dirty, prefetched, data). If the evicted L1 line was valid, inserts it into the victim cache. |
| ST_WB_REQ     | 1+     | Issues a dirty line write-back on the memory interface. Waits for mem_req_ready. |
| ST_VC_INSERT  | 1      | Inserts the evicted L1 line into the victim cache at the round-robin position. Increments the victim RR pointer. |
| ST_MEM_READ_REQ | 1+   | Issues a read-fill request on the memory interface. Waits for mem_req_ready. |
| ST_MEM_READ_WAIT | 1  | Waits for the memory response (mem_rsp_valid). Loads the fill data and prepares response data. |
| ST_INSTALL    | 1      | Writes the new tag and data into the L1 SRAM at the selected way/set. Sets valid=1, dirty=(store && !prefetch), prefetched bit. |
| ST_RESP       | 1+     | Drives the CPU response channel with loaded data and error status. Waits for cpu_rsp_ready. |

### 10.4 Request Arbitration (ST_IDLE)

Priority order in ST_IDLE:

1. **CPU request** (highest) - if cpu_req_valid and aligned, latched and transitions to ST_LOOKUP. If misaligned, error response queued, transitions to ST_RESP.
2. **External prefetch** - if cfg_prefetch_enable=1 and ext_prefetch_valid=1. Address is line-aligned internally and treated as a prefetch (non-write).
3. **Next-line prefetch** (lowest) - if cfg_prefetch_enable=1 and the next-line candidate is valid. The candidate address is consumed (acknowledged via 
ext_line_candidate_ready) and treated as a prefetch.

Only one request is accepted per idle cycle. Prefetch requests are only accepted when the CPU has no pending request.

### 10.5 Lookup Logic (ST_LOOKUP)

Parallel combinational lookup:

1. **L1 tag lookup:** iterate over all NUM_WAYS ways. A hit requires alid_bits[way][set] == 1 AND 	ag_q[way] == req_tag. The first matching way is recorded as hit_way. Also track the first invalid way (invalid_way) for allocation optimization.
2. **Victim cache lookup:** if VICTIM_ENABLED, iterate over all VICTIM_ENTRIES entries. A hit requires c_valid[entry] == 1 AND c_addr[entry] == req_line_addr.
3. **Mutual exclusion assertion:** the design asserts (in simulation only, gated by ` ifndef SYNTHESIS `) that a line cannot be simultaneously valid in both L1 and the victim cache at the same time. This invariant is maintained by the swap logic in ST_VC_SWAP.

Decision table:

| Condition                          | Action                                             | Next State       |
|------------------------------------|----------------------------------------------------|------------------|
| L1 hit + demand load               | Load data, return to CPU                           | ST_RESP        |
| L1 hit + demand store              | Merge store data, set dirty, return to CPU         | ST_HIT_WRITE $\rightarrow$ ST_RESP |
| L1 hit + prefetch                  | Discard prefetch, return to idle                    | ST_IDLE        |
| Victim hit + demand                | Swap victim into L1, return data to CPU            | ST_VC_SWAP $\rightarrow$ ST_RESP |
| Victim hit + prefetch              | Discard, return to idle                             | ST_IDLE        |
| Miss + invalid slot available      | Skip WB, go directly to memory read                | ST_MEM_READ_REQ|
| Miss + dirty L1 eviction           | Issue WB, then continue                            | ST_WB_REQ      |
| Miss + clean L1 eviction + victim  | Insert evicted into victim, then read memory       | ST_VC_INSERT $\rightarrow$ ST_MEM_READ_REQ |
| Miss + no victim + dirty L1        | Issue WB, then read memory                         | ST_WB_REQ $\rightarrow$ ST_MEM_READ_REQ |

### 10.6 Write-Back Path (ST_WB_REQ)

When a dirty line must be evicted (either from L1 or from the victim cache):

1. Latch the evicted line address (wb_addr) and data (wb_data).
2. Assert mem_req_valid = 1, mem_req_write = 1.
3. On mem_req_ready, increment stat_writebacks and pulse event_writeback.
4. Continue to the next state based on whether a victim cache insertion is pending.

### 10.7 Fill Installation (ST_INSTALL)

On receiving a read-fill response:

1. For a **store miss**, merge the store data into the received line using merge_store_data() before installation.
2. For a **load miss** or **prefetch fill**, install the line as-is.
3. Set alid_bits[selected_way][req_set] = 1, dirty_bits[...] = (store && !prefetch), prefetched_bits[...] = prefetch.
4. Advance the round-robin replacement pointer: 
eplacement_way[set] = (selected_way + 1) % NUM_WAYS.
5. For prefetch fills, return to ST_IDLE immediately (no CPU response needed). For demand fills, proceed to ST_RESP.

### 10.8 Response Generation (ST_RESP)

Drives cpu_rsp_valid with the computed response data:

- **Hit load:** line_load_data(data_q[hit_way], addr, size, unsigned)
- **Hit store:** line_load_data(merged_line, addr, size, unsigned) - returns the data as it would appear after the store.
- **Miss fill:** line_load_data(fill_line, addr, size, unsigned) - the line loaded from memory (merged with store data if applicable).
- **Misaligned error:** cpu_rsp_error = 1, cpu_rsp_error_cause = RSP_LOAD_MISALIGNED or RSP_STORE_MISALIGNED, cpu_rsp_rdata = 0.

---

## 11. Victim Cache

### 11.1 Structure

The victim cache is a fully associative structure with VICTIM_ENTRIES entries. Each entry stores:

| Field              | Width         | Description                              |
|--------------------|---------------|------------------------------------------|
| c_valid         | 1 bit         | Entry is valid                           |
| c_dirty         | 1 bit         | Line is dirty (must be written back)     |
| c_prefetched    | 1 bit         | Line was prefetched (not demand)         |
| c_addr          | ADDR_WIDTH  | Full 64-bit line address (acts as tag)   |
| c_data          | LINE_BITS   | Complete cache line data                 |

### 11.2 Replacement Policy

Round-robin insertion at position c_rr. The pointer increments modulo VICTIM_ENTRIES on each ST_VC_INSERT. No victim lookup priority adjustment - all entries are probed equally.

### 11.3 Swap Semantics

On a victim hit:

1. **Determine the L1 target slot:** if an invalid L1 slot exists in the set, use it (invalid_way). Otherwise, use the round-robin replacement way.
2. **Save evicted L1 state:** if the target slot was valid, capture its valid/dirty/prefetched/tag/data into evicted_* signals.
3. **Transfer victim data:** copy c_data[victim_hit] into working_line, set working_dirty = vc_dirty[victim_hit], compute 
esponse_data.
4. **Transition to ST_VC_SWAP:** in this state, write the victim data into the L1 SRAM and metadata, then insert the evicted L1 line (or invalidate the victim entry if no L1 line was evicted).

### 11.4 Dirty Victim Handling

Before inserting a new line into a victim entry that already holds dirty data:

1. Transition to ST_WB_REQ to write back the dirty victim line.
2. After the write-back completes, proceed to ST_VC_INSERT to store the new evicted line.

---

## 12. Prefetching and Pollution Monitoring

### 12.1 Next-Line Prefetcher

Triggered on every demand fill in ST_INSTALL. Computes the next aligned line address as line_address + LINE_BYTES. The prefetcher has a single-entry buffer:

- If a candidate is already pending and not consumed, the new candidate is **dropped** (dropped pulses high, stat_prefetch_dropped increments).
- If the candidate is consumed (accepted by the arbiter in ST_IDLE), it becomes a prefetch request.
- The candidate is also cleared if cfg_next_line_enable or cfg_prefetch_enable is deasserted.

### 12.2 Prefetch Classification

| Event                  | Counter Incremented          | Trigger Condition                                            |
|------------------------|------------------------------|--------------------------------------------------------------|
| Prefetch fill          | stat_prefetch_fills        | A prefetch candidate successfully installs a new L1 line     |
| Useful prefetch        | stat_prefetch_useful       | CPU accesses a prefetched line (clears prefetched bit)     |
| Useless prefetch       | stat_prefetch_useless      | A prefetched line is evicted from the victim cache without CPU access |
| Pollution              | stat_prefetch_pollution    | A prefetch displaces a non-prefetched demand line in L1      |
| Dropped candidate      | stat_prefetch_dropped      | Next-line buffer was full when a new demand fill occurred    |

### 12.3 Pollution Measurement Caveat

stat_prefetch_pollution counts L1 lines displaced by prefetches that were not themselves prefetched. This is a **lower bound** on true pollution because a displaced demand line may be rescued later by the victim cache. True pollution requires comparing miss rates between prefetch-enabled and prefetch-disabled runs on the same trace.

### 12.4 External Prefetch Interface

The ext_prefetch_valid/ready/addr interface allows an external prefetcher to inject candidates. External prefetches follow the same allocation path as next-line prefetches and are subject to the same classification counters. The cfg_prefetch_enable signal gates all prefetch activity (both internal and external).

---

## 13. Data Path Functions

### 13.1 Load Data Extraction (line_load_data)

Extracts the requested bytes from a cache line and extends to DATA_WIDTH:

1. Compute yte_offset = addr[OFFSET_BITS-1:0].
2. Gather min(WORD_BYTES, access_bytes(size)) bytes starting at the offset.
3. Zero-extend or sign-extend to DATA_WIDTH based on unsigned_load.
4. Unused bytes in the result are zero-filled.

### 13.2 Store Data Merge (merge_store_data)

Merges store data into a cache line:

1. Compute yte_offset = addr[OFFSET_BITS-1:0].
2. For each byte in the access, overwrite the corresponding byte in the line with the matching byte from wdata.
3. Return the modified line for SRAM installation.

### 13.3 Alignment Check (ccess_misaligned)

| Size       | Misaligned if                                  |
|------------|------------------------------------------------|
| Byte       | Never                                         |
| Halfword   | ddr[0] == 1                                |
| Word       | |addr[1:0] == 1                             |
| Double     | |addr[2:0] == 1                             |

### 13.4 Access Size Mapping (ccess_bytes)

| size value | Bytes returned |
|-------------|----------------|
| 2'b00       | 1              |
| 2'b01       | 2              |
| 2'b10       | 4              |
| 2'b11       | 8              |

---

## 14. Metadata Storage

### 14.1 L1 Per-Set/Way Metadata Arrays

| Array                | Dimensions              | Description                          |
|----------------------|-------------------------|--------------------------------------|
| alid_bits         | [NUM_WAYS-1:0][NUM_SETS-1:0] | Line is present in this way/set       |
| dirty_bits         | [NUM_WAYS-1:0][NUM_SETS-1:0] | Line has been modified since load     |
| prefetched_bits    | [NUM_WAYS-1:0][NUM_SETS-1:0] | Line was brought in by prefetch      |
| 
eplacement_way    | [NUM_SETS-1:0]         | Round-robin pointer per set           |

### 14.2 Reset Behavior

On reset (
st_n = 0):

- All valid, dirty, and prefetched bits are cleared to 0.
- All victim cache entries are invalidated.
- All replacement pointers are set to 0.
- All counters are zeroed.
- FSM state returns to ST_IDLE.

---

## 15. Latency Analysis

### 15.1 Unloaded Latency

| Transaction Type                        | Cycles (unloaded) | Path                                         |
|-----------------------------------------|-------------------|----------------------------------------------|
| L1 hit load                             | 2                 | ST_LOOKUP $\rightarrow$ ST_RESP          |
| L1 hit store                            | 3                 | ST_LOOKUP $\rightarrow$ ST_HIT_WRITE $\rightarrow$ ST_RESP |
| Victim hit load/store                   | 4                 | ST_LOOKUP $\rightarrow$ ST_VC_SWAP $\rightarrow$ ST_RESP |
| Miss (invalid slot, no WB)              | 4 + mem latency   | ST_LOOKUP $\rightarrow$ ST_MEM_READ_REQ $\rightarrow$ ST_MEM_READ_WAIT $\rightarrow$ ST_INSTALL $\rightarrow$ ST_RESP |
| Miss (dirty L1 eviction, no victim)     | 5 + mem latency   | ST_LOOKUP $\rightarrow$ ST_WB_REQ $\rightarrow$ ST_MEM_READ_REQ $\rightarrow$ ST_MEM_READ_WAIT $\rightarrow$ ST_INSTALL $\rightarrow$ ST_RESP |
| Miss (clean L1, dirty victim)           | 6 + mem latency   | ST_LOOKUP $\rightarrow$ ST_WB_REQ $\rightarrow$ ST_VC_INSERT $\rightarrow$ ST_MEM_READ_REQ $\rightarrow$ ST_MEM_READ_WAIT $\rightarrow$ ST_INSTALL $\rightarrow$ ST_RESP |
| Miss (clean L1, clean victim)           | 5 + mem latency   | ST_LOOKUP $\rightarrow$ ST_VC_INSERT $\rightarrow$ ST_MEM_READ_REQ $\rightarrow$ ST_MEM_READ_WAIT $\rightarrow$ ST_INSTALL $\rightarrow$ ST_RESP |
| Prefetch fill (L1 hit on prefetch)      | 1                 | ST_LOOKUP $\rightarrow$ ST_IDLE          |
| Prefetch fill (miss, no WB)             | 4                 | ST_LOOKUP $\rightarrow$ ST_MEM_READ_REQ $\rightarrow$ ST_MEM_READ_WAIT $\rightarrow$ ST_INSTALL $\rightarrow$ ST_IDLE |

Note: The testbench memory model uses a fixed 2-cycle read latency. Real memory systems will add additional cycles for mem_req_ready deassertion and mem_rsp_valid assertion.

### 15.2 Loaded Latency

Under sustained traffic, the blocking design serializes all requests through a single memory path. Loaded latency grows unboundedly as queue depth increases, consistent with standard queuing theory for a blocking cache. The design assumes a single outstanding transaction at any time.

---

## 16. Arbitration, Fairness, and QoS

### 16.1 Request Arbitration

The cache uses **fixed-priority arbitration** with the following order:

1. CPU demand requests (highest)
2. External prefetch requests
3. Next-line prefetch requests (lowest)

Prefetch requests are only serviced when the CPU has no pending request. This ensures that prefetch traffic cannot starve demand traffic.

### 16.2 Forward Progress Guarantees

The design guarantees forward progress under the following assumptions:

- The CPU eventually asserts cpu_rsp_ready to accept responses.
- The memory subsystem eventually asserts mem_req_ready and mem_rsp_valid.
- The victim cache has sufficient entries to hold evicted lines (no victim overflow under normal operation).

Deadlock is impossible because:

- The FSM has a single serialized request path; no circular waits exist.
- All state transitions are unconditional on the receiving side's ready signal (the FSM holds state until the response arrives).
- The next-line prefetcher has a single-entry buffer that drains when the arbiter accepts the candidate or when the enable signal is deasserted.

Livelock is prevented by the CPU-request priority: as long as the CPU issues requests, they will eventually be serviced because prefetch requests are only accepted in ST_IDLE and the FSM cannot loop indefinitely without reaching ST_IDLE.

---

## 17. Power

### 17.1 Power Modes

The design has no explicit power management. All state is active whenever clk is running. The cfg_prefetch_enable signal can disable prefetch-related logic, reducing dynamic power from prefetch path toggling.

### 17.2 Self-Clocking Gate Estimation

- SRAM arrays are only enabled (rray_en=1) when a request is being processed, providing natural gating of array read/write activity.
- The victim cache and metadata arrays are registered logic that toggles proportional to miss rate and eviction frequency.
- Estimated self-gating proportion: approximately 30-60% of flops are idle during hit-only traffic, higher during low-utilization periods.

---

## 18. Physical Design

### 18.1 Floorplan Sketch

`
+----------------------------------------------------------+
|                                                          |
|  +---------+  +-------------------------------+  +------+ |
|  |  FSM    |  |   Tag SRAM Arrays             |  | Vict | |
|  | Control |  |   (per way, indexed by set)   |  | im Ca | |
|  |         |  |                               |  | che  | |
|  +----+----+  +--------------+----------------+  +------+ |
|       |                     |                          |
|  +----v----+  +--------------v----------------+        |
|  | Metadata|  |   Data SRAM Arrays            |        |
|  |(valid,  |  |   (per way, indexed by set)   |        |
|  | dirty,  |  +-------------------------------+        |
|  | rr ptr) |                                            |
|  +---------+                                            |
|                                                          |
|  I/O Pins: clk, rst_n (top)                              |
|  CPU Interface: left side                                |
|  Memory Interface: right side                            |
|  Stats/Events: bottom                                    |
+----------------------------------------------------------+
`

### 18.2 SRAM Configuration

| SRAM Instance     | Width        | Depth       | Ports | Type        |
|-------------------|--------------|-------------|-------|-------------|
| Tag array (per way)| TAG_BITS  | NUM_SETS  | 1R/1W | Synchronous |
| Data array (per way)| LINE_BITS| NUM_SETS  | 1R/1W | Synchronous |
| Victim cache      | N/A (registered) | VICTIM_ENTRIES entries | Fully associative lookup |

### 18.3 Estimated Statistics

| Metric             | Estimate (default: 8 sets, 2 ways, 4 victim) |
|--------------------|----------------------------------------------|
| Flop count         | ~1,500-2,500                                 |
| LUT/Logic cells    | ~2,000-5,000                                 |
| Critical path      | L1 tag lookup combinatorial loop (parallel tag comparison across ways) |
| Max frequency      | 100 MHz (constrained); likely achievable at 150-200 MHz on modern FPGA |

---

## 19. Configuration Registers (CSRs)

The design uses top-level input signals rather than a dedicated CSR bus for configuration. The following runtime-configurable signals serve as soft CSRs:

| Signal                   | Width | Reset | Description                              |
|--------------------------|-------|-------|------------------------------------------|
| cfg_prefetch_enable    | 1     | 0     | Master enable for all prefetching        |
| cfg_next_line_enable   | 1     | 0     | Enable the built-in next-line policy     |

All other configuration is compile-time via module parameters. A future extension could wrap these signals in a CSR bus for runtime reconfiguration.

---

## 20. Performance Analysis

### 20.1 Instrumentation

The block provides 9 cumulative 32-bit counters and 11 single-cycle event pulses, all accessible as top-level outputs.

**Counters:**
- stat_cpu_hits: demand hits
- stat_cpu_misses: demand misses
- stat_victim_hits: victim cache hits (sub-category of demand misses)
- stat_writebacks: dirty line write-backs
- stat_prefetch_fills: prefetch line installations
- stat_prefetch_useful: prefetches later accessed
- stat_prefetch_useless: prefetches evicted unused
- stat_prefetch_pollution: prefetches displacing demand lines
- stat_prefetch_dropped: next-line candidates lost to buffer fullness

**Derived Metrics:**
- Hit rate = stat_cpu_hits / (stat_cpu_hits + stat_cpu_misses)
- Victim hit rate = stat_victim_hits / stat_cpu_misses
- Prefetch accuracy = stat_prefetch_useful / stat_prefetch_fills
- Coverage = demand misses eliminated by prefetch / baseline demand misses (requires comparison run)

### 20.2 Event Pulses

Each event pulse (event_*) provides a cycle-accurate trigger suitable for connection to an on-chip logic analyzer or hardware performance counter accumulator. Events self-clear (pulse high for one cycle) and are reset at the beginning of each FSM cycle.

---

## 21. Debugging

### 21.1 Simulation-Only Assertions

Gated by ` ifndef SYNTHESIS `, the following safety checks run every clock cycle during reset:

1. **No simultaneous L1/victim validity:** asserts that a line cannot be valid in both L1 and the victim cache at the same time. Triggers $fatal(1, "A line is simultaneously valid in L1 and victim cache") if violated.
2. **No duplicate victim entries:** asserts that no two victim cache entries hold the same address when both are valid. Triggers $fatal(1, "Duplicate line in victim cache") if violated.

### 21.2 Testbench Diagnostics

The testbench (src/tb_l1d_cache.sv) includes:

- **Protocol violation detection:** checks that stalled memory requests and CPU responses preserve their payload across cycles.
- **Golden memory comparison:** a software model of memory is compared against cache-loaded data in randomized tests.
- **Counter conservation:** asserts that hits + misses = total accesses across all workload runs.
- **Trace replay mode:** +TRACE=<path> replays a text trace file for deterministic verification.
- **Workload boundary mode:** +WORKLOADS_ONLY runs synthetic workloads without trace replay.
- **VCD dump:** +VCD generates a VCD waveform file for visual inspection.

---

## 22. Reliability

The design does not implement hardware reliability features:

- **No ECC** on tag, data, or victim cache storage.
- **No scrubbing** or wear-leveling.
- **No timing monitors** or voltage sensors.
- **No DFT/BIST** circuits.

These features are outside the scope of the baseline L1D cache and would be added at the system or tile level.

---

## 23. Implementation Details

### 23.1 l1d_cache — Top Module

The top module l1d_cache integrates four major components:

1. **Synchronous SRAM arrays** (tag and data, instantiated via l1d_sram in a generate loop over ways).
2. **Metadata registers** (valid, dirty, prefetched bits, and round-robin replacement pointer).
3. **Fully associative victim cache** (registered arrays for address, data, valid, dirty, prefetched, and a round-robin insert pointer).
4. **Cache controller FSM** (10 states, described in Section 10).

Plus two helper submodules:
5. **Next-line prefetcher** (l1d_next_line_prefetch, single-entry candidate buffer).
6. **Arbiter and request selector** (combinational logic within the top module's lways_comb block).

#### 23.1.1 SRAM Array Generation

A generate block instantiates NUM_WAYS pairs of tag and data SRAMs:

`systemverilog
generate
    genvar way;
    for (way = 0; way < NUM_WAYS; way = way + 1) : gen_arrays
        l1d_sram #(TAG_BITS, NUM_SETS) tag_array (...);
        l1d_sram #(LINE_BITS, NUM_SETS) data_array (...);
    endfor
endgenerate
`

All ways share the same rray_en, rray_addr, rray_wtag, and rray_wdata signals. Way-specific write enables (	ag_we[way], data_we[way]) select which way is written in a given cycle. Read data from each way is captured in 	ag_q[way] and data_q[way].

#### 23.1.2 Victim Cache Implementation

The victim cache is implemented as five parallel registered arrays, each indexed by VC_BITS:

- c_valid[VICTIM_STORAGE_ENTRIES]
- c_dirty[VICTIM_STORAGE_ENTRIES]
- c_prefetched[VICTIM_STORAGE_ENTRIES]
- c_addr[VICTIM_STORAGE_ENTRIES] (full 64-bit address)
- c_data[VICTIM_STORAGE_ENTRIES] (full cache line)

Lookup is performed in combinational logic (lways_comb) by iterating over all entries and comparing addresses. Insertion occurs in ST_VC_INSERT at the round-robin position c_rr.

#### 23.1.3 FSM State Encoding

The FSM uses an explicit 4-bit encoding via enum logic [3:0]. The synthesizer may re-encode these for area or timing optimization.

#### 23.1.4 Request Latching

When transitioning from ST_IDLE to ST_LOOKUP, the requesting address, write flag, size, unsigned flag, and write data are latched into 
eq_* signals. This allows the FSM to reference the request throughout the miss/eviction/fill/response path without holding the CPU interface open.

#### 23.1.5 Prefetch Hit Classification

When a prefetched line is later accessed by the CPU (in ST_LOOKUP on an L1 hit or in ST_VC_SWAP on a victim hit):

1. Clear the prefetched bit for that way/set.
2. Increment stat_prefetch_useful.
3. Pulse event_prefetch_useful.

When a prefetched line is inserted into the victim cache (in ST_VC_INSERT):

1. If the evicted L1 line being stored into the victim was prefetched, increment stat_prefetch_useless and pulse event_prefetch_useless.

When a prefetch evicts a non-prefetched demand line (in ST_LOOKUP on a miss path):

1. If the evicted line's prefetched_bits is 0, increment stat_prefetch_pollution and pulse event_prefetch_pollution.

### 23.2 l1d_next_line_prefetch — Next-Line Candidate Generator

A single-entry FIFO with a pending flip-flop storing the candidate address. Triggered by demand_fill_valid from the cache controller. Computes {tag, set, 0} + LINE_BYTES. Clears on consumption or enable deassertion.

### 23.3 l1d_sram — SRAM Wrapper

A simple synchronous single-port RAM with write-through read behavior. Used for tag arrays (width = TAG_BITS, depth = NUM_SETS) and data arrays (width = LINE_BITS, depth = NUM_SETS). The synthesizer maps this to technology-specific SRAM primitives or inferred flip-flop arrays depending on target.

---

## 24. References

- [Jouppi, N.P., Improving Direct-Mapped Cache Performance by the Addition of a Small Fully-Associative Cache and Prefetch Buffers, ISCA 1990.](https://doi.org/10.1109/ISCA.1990.134547)
- [Chen, D.N. and Baer, J.L., Experimental Evaluation of a Hardware Adjacent Block Prefetcher, IEEE TC, 1995.](https://doi.org/10.1109/12.381947)
- [Shoaib et al., Pythia: A Feedback-Directed Prefetcher Using On-Chip Learning, MICRO 2021.](https://arxiv.org/abs/2109.12021)
- [Zhang and Samih, Gaze: Learning to Prefetch for Spatial and Temporal Patterns, HPCA 2025.](https://arxiv.org/abs/2412.05211)
- [Rocket Chip DCache.scala, Chips Alliance.](https://github.com/chipsalliance/rocket-chip/blob/master/src/main/scala/rocket/DCache.scala)
- [ChampSim next_line prefetcher reference.](https://github.com/ChampSim/ChampSim/tree/master/prefetcher/next_line)
- [Repository README.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/README.md)
- [Baseline design document: docs/l1d_baseline.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/l1d_baseline.md)
- [Literature review: docs/literature_review.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/literature_review.md)
- [Design Review II Team Report: docs/Design Review II Team Report.md](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/docs/Design%20Review%20II%20Team%20Report.md)
- [Source: src/l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_cache.sv)
- [Source: src/l1d_next_line_prefetch.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_next_line_prefetch.sv)
- [Source: src/l1d_sram.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/l1d_sram.sv)
- [Source: src/tb_l1d_cache.sv](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/src/tb_l1d_cache.sv)
- [Constraints: constraints/l1d_baseline.xdc](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/constraints/l1d_baseline.xdc)
- [Scripts: scripts/run_iverilog.sh](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_iverilog.sh)
- [Scripts: scripts/run_vivado.tcl](D:/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/scripts/run_vivado.tcl)
