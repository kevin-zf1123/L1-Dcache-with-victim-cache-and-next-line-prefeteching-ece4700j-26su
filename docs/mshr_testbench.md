# MSHR Non-Blocking Cache ? Testbench and Verification Plan

## Change Log

| Date       | Version | Change Description                              | Authors |
|------------|---------|-------------------------------------------------|---------|
| 2026-06-30 | v0.1    | Initial MSHR verification testbench design spec | TBD     |

---

## 1. Overview

### 1.1 Purpose

This document specifies the verification strategy for the MSHR non-blocking L1 data cache. It extends the existing self-checking testbench (`src/tb_l1d_cache.sv`) with:

- **Out-of-order scoreboard**: tracks requests and responses independently since they may arrive in different order
- **Non-blocking request tasks**: fire-and-forget CPU request tasks that do not wait for response
- **Protocol monitors**: runtime invariant checks specific to MSHR behavior
- **8 new directed tests**: covering hit-under-miss, miss-under-miss, MSHR merge, MSHR full, victim+MSHR interaction, and prefetch+MSHR
- **Extended randomized test**: OoO-aware version of the existing randomized scoreboard
- **Trace replay adaptation**: non-blocking variant of the existing trace replay driver

### 1.2 Existing Testbench Architecture

The current testbench (`src/tb_l1d_cache.sv`) uses:

| Component | Description |
|-----------|-------------|
| `cpu_request()` | Blocking task: sends request, waits for response |
| `cpu_load()` / `cpu_store()` | Blocking wrappers with golden-memory checking |
| `expect_load()` / `expect_read()` | Blocking wrappers with PASS/FAIL reporting |
| `initialize_memory()` | Fills backing memory and golden memory with deterministic data |
| `update_golden_store()` | Updates golden memory after a store |
| `golden_load()` | Computes expected load result from golden memory |
| Memory response model | 2-cycle fixed-latency memory with mem_ready_phase control |
| `test_baseline()` | Directed test: cold misses, hits, access sizes, sign extension |
| `test_rv64_alignment_faults()` | Misaligned load/store fault detection |
| `test_victim_hit()` | Victim cache swap and rescue |
| `test_dirty_victim_writeback()` | Dirty victim line writeback to memory |
| `test_zero_entry_victim_bypass()` | VICTIM_ENTRIES=0 bypass mode |
| `test_response_backpressure()` | CPU response stability under backpressure |
| `test_randomized_scoreboard()` | 36-access deterministic randomized test |
| `test_prefetch()` | Prefetch trigger, useful/useless accounting, external injection |
| `replay_trace()` | File-based trace replay driver |
| `test_workload_boundaries()` | Synthetic workloads with CSV output |
| Protocol monitors | stalled_mem_req and stalled_cpu_rsp stability checks |

---

## 2. New Testbench Parameters

### 2.1 Parameters Added to `tb_l1d_cache`

```systemverilog
module tb_l1d_cache #(
    parameter integer NUM_WAYS               = 1,
    parameter integer ENABLE_PREFETCH        = 0,
    parameter integer VICTIM_ENTRIES         = 4,
    parameter integer PREFETCH_BUFFER_SIZE   = 4,
    parameter integer L1_REPL_POLICY_LRU     = 1,
    parameter integer VICTIM_REPL_POLICY_LRU = 1,
    // NEW:
    parameter integer MSHR_ENTRIES           = 4,
    parameter integer ENABLE_NONBLOCKING     = 1
);
```

### 2.2 Derived Local Parameters

```systemverilog
localparam integer SCOREBOARD_DEPTH = 128;  // Max in-flight requests
```

---

## 3. Out-of-Order Scoreboard

### 3.1 Problem Statement

The existing `cpu_request()` task is **blocking**:

```systemverilog
task automatic cpu_request(...);
    // Send request
    while (!cpu_req_ready) @(posedge clk);
    // ... send ...

    // WAIT for response (blocking!)
    while (!cpu_rsp_valid) @(posedge clk);
    rsp_data = cpu_rsp_rdata;
endtask
```

With non-blocking cache, responses may arrive **out of order** relative to requests. A request sent later may get a hit and respond before an earlier miss. The testbench must track which responses correspond to which requests.

### 3.2 Scoreboard Entry Structure

```systemverilog
typedef struct packed {
    logic                valid;           // Entry is allocated
    logic                done;            // Response received
    logic                is_write;        // Load (0) or store (1)
    logic [63:0]         addr;            // Request address
    logic [1:0]          size;            // Access size
    logic                unsigned_load;   // Sign/zero extension
    logic [63:0]         wdata;           // Store data (for stores)
    logic [63:0]         expected_data;   // Expected load result
    integer              request_cycle;   // Cycle when request was sent
    integer              response_cycle;  // Cycle when response arrived
} scoreboard_entry_t;
```

### 3.3 Scoreboard Array and Pointers

```systemverilog
scoreboard_entry_t scoreboard [0:SCOREBOARD_DEPTH-1];
integer scoreboard_head;       // Next free slot for allocation
integer scoreboard_drain;      // Next slot to check during drain

// Counters
integer scoreboard_allocated;  // Total entries allocated (lifetime)
integer scoreboard_completed;  // Total entries completed (lifetime)
integer scoreboard_pending;    // Currently pending entries
```

### 3.4 Non-Blocking Request Tasks

#### Fire-and-Forget CPU Request

```systemverilog
task automatic cpu_request_nonblocking(
    input  logic [63:0] addr,
    input  logic        write,
    input  logic [1:0]  size,
    input  logic        unsigned_load,
    input  logic [63:0] data,
    output integer      request_id
);
    integer timeout;
    begin
        // Wait for ready
        @(negedge clk);
        timeout = 0;
        while (!cpu_req_ready) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 200) begin
                $fatal(1, "Non-blocking CPU request timeout at addr=%016x", addr);
            end
        end

        // Fire request
        cpu_req_valid   = 1;
        cpu_req_addr    = addr;
        cpu_req_write   = write;
        cpu_req_size    = size;
        cpu_req_unsigned = unsigned_load;
        cpu_req_wdata   = data;
        @(posedge clk);
        @(negedge clk);
        cpu_req_valid   = 0;

        // Allocate scoreboard entry
        request_id = scoreboard_head;
        scoreboard[scoreboard_head].valid         = 1;
        scoreboard[scoreboard_head].done          = 0;
        scoreboard[scoreboard_head].is_write      = write;
        scoreboard[scoreboard_head].addr          = addr;
        scoreboard[scoreboard_head].size          = size;
        scoreboard[scoreboard_head].unsigned_load = unsigned_load;
        scoreboard[scoreboard_head].wdata         = data;
        scoreboard[scoreboard_head].expected_data = write ? 0 :
            golden_load(addr, size, unsigned_load);
        scoreboard[scoreboard_head].request_cycle = cycles_since_reset;

        scoreboard_head = (scoreboard_head + 1) % SCOREBOARD_DEPTH;
        scoreboard_allocated++;
        scoreboard_pending++;
    end
endtask
```

#### Non-Blocking Load

```systemverilog
task automatic cpu_load_nonblocking(
    input  logic [63:0] addr,
    input  logic [1:0]  size,
    input  logic        unsigned_load,
    output integer      request_id
);
    begin
        cpu_request_nonblocking(addr, 0, size, unsigned_load, 0, request_id);
    end
endtask
```

#### Non-Blocking Store

```systemverilog
task automatic cpu_store_nonblocking(
    input  logic [63:0] addr,
    input  logic [1:0]  size,
    input  logic [63:0] data
);
    integer ignored_id;
    begin
        cpu_request_nonblocking(addr, 1, size, 0, data, ignored_id);
        update_golden_store(addr, data, size);
    end
endtask
```

### 3.5 Response Collector (Continuous Monitor)

This runs in an `always` block, continuously matching CPU responses to scoreboard entries:

```systemverilog
always @(posedge clk) begin
    if (rst_n && cpu_rsp_valid && cpu_rsp_ready) begin
        // Walk scoreboard to find first pending load
        for (int i = 0; i < SCOREBOARD_DEPTH; i++) begin
            int idx = (scoreboard_drain + i) % SCOREBOARD_DEPTH;
            if (scoreboard[idx].valid && !scoreboard[idx].done &&
                !scoreboard[idx].is_write) begin
                // Found pending load
                scoreboard[idx].done = 1;
                scoreboard[idx].response_cycle = cycles_since_reset;
                scoreboard_completed++;
                scoreboard_pending--;

                // Verify data
                if (cpu_rsp_error) begin
                    $display("FAIL load raised unexpected error addr=%016x",
                             scoreboard[idx].addr);
                    errors++;
                end else if (cpu_rsp_rdata !== scoreboard[idx].expected_data) begin
                    $display("FAIL load data mismatch addr=%016x expected=%016x actual=%016x",
                             scoreboard[idx].addr,
                             scoreboard[idx].expected_data,
                             cpu_rsp_rdata);
                    errors++;
                end
                break;
            end
        end

        // For stores: the response_valid pulse confirms completion
        for (int i = 0; i < SCOREBOARD_DEPTH; i++) begin
            int idx = (scoreboard_drain + i) % SCOREBOARD_DEPTH;
            if (scoreboard[idx].valid && !scoreboard[idx].done &&
                scoreboard[idx].is_write) begin
                scoreboard[idx].done = 1;
                scoreboard[idx].response_cycle = cycles_since_reset;
                scoreboard_completed++;
                scoreboard_pending--;
                break;
            end
        end
    end
end
```

### 3.6 Scoreboard Drain Tasks

```systemverilog
// Drain all pending scoreboard entries
task automatic drain_scoreboard_all;
    integer timeout;
    begin
        timeout = 0;
        while (scoreboard_pending > 0) begin
            @(posedge clk);
            timeout = timeout + 1;
            if (timeout > 2000) begin
                $display("FAIL scoreboard drain timeout: %0d entries pending",
                         scoreboard_pending);
                for (int i = 0; i < SCOREBOARD_DEPTH; i++) begin
                    if (scoreboard[i].valid && !scoreboard[i].done) begin
                        $display("  PENDING: id=%0d addr=%016x write=%0d",
                                 i, scoreboard[i].addr, scoreboard[i].is_write);
                    end
                end
                errors++;
                break;
            end
        end
    end
endtask

// Drain at least N entries
task automatic drain_scoreboard_n(input integer n);
    integer drained, start_pending;
    begin
        start_pending = scoreboard_pending;
        drained = 0;
        while (drained < n && scoreboard_pending > 0) begin
            @(posedge clk);
            drained = start_pending - scoreboard_pending;
        end
    end
endtask
```

---

## 4. Directed MSHR Tests

### 4.1 Test: `test_mshr_hit_under_miss`

**Objective**: Verify that L1 hits complete while a miss is outstanding.

**Procedure:**
1. Send a demand read to line A (set 0) ? miss ? MSHR allocated
2. Warm up line B (set 4) in the cache first
3. Immediately send a read to line B ? must hit
4. Verify B's response arrives (before A's)
5. Verify stat_hit_under_miss counter increments
6. Wait for A's response and verify data correctness

### 4.2 Test: `test_mshr_miss_under_miss`

**Objective**: Verify two misses to different lines can be outstanding simultaneously.

**Procedure:**
1. Send read to line A (set 0) ? miss ? MSHR[0]
2. Send read to line B (set 2, different set) ? miss ? MSHR[1]
3. Verify both complete with correct data
4. Verify only 2 memory reads issued (no redundant reads)
5. Verify stat_miss_under_miss increments

### 4.3 Test: `test_mshr_merge_same_line`

**Objective**: Verify two stores to the same cache line merge into one MSHR entry and one memory transaction.

**Procedure:**
1. Send store to line A offset 0 ? miss ? MSHR[0]
2. Send store to line A offset 8 (same line) ? merge into MSHR[0]
3. Verify only 1 memory read issued
4. After fill, read both offsets: verify both store values present
5. Verify stat_mshr_merges increments

### 4.4 Test: `test_mshr_full_backpressure`

**Objective**: Verify CPU stalls when all MSHR entries are full.

**Procedure:**
1. Fill all MSHR entries (send MSHR_ENTRIES misses to different lines)
2. Attempt one more request ? verify cpu_req_ready goes low
3. Drain one response ? verify cpu_req_ready reasserts
4. Verify all requests complete with correct data

### 4.5 Test: `test_mshr_victim_swap_during_miss`

**Objective**: Verify that a victim cache swap triggered by a miss does not corrupt another outstanding miss.

**Procedure:**
1. Fill L1 set 0 to capacity (NUM_WAYS lines)
2. Send miss to new line in set 0 ? triggers victim swap, MSHR[0]
3. While MSHR[0] is being processed, send read to a line in set 2 ? MSHR[1]
4. Verify both complete correctly

### 4.6 Test: `test_mshr_prefetch_coexistence`

**Objective**: Verify prefetch and demand misses can coexist in MSHR.

**Procedure:**
1. Send demand read to trigger next-line prefetch
2. Verify prefetch allocates MSHR entry
3. Send additional demand read to different line
4. Verify both demand and prefetch complete
5. Verify demand completes before prefetch (priority)

### 4.7 Test: `test_mshr_response_backpressure`

**Objective**: Verify CPU response stability under backpressure with MSHR active.

**Procedure:**
1. Send a miss
2. Set cpu_rsp_ready = 0
3. Wait for response to become valid
4. Hold cpu_rsp_ready = 0 for several cycles
5. Verify response data stable (protocol check)
6. Assert cpu_rsp_ready = 1, verify data correct

### 4.8 Test: `test_mshr_store_load_merge`

**Objective**: Verify that a load to the same line as a pending store miss gets the merged data.

**Procedure:**
1. Store miss to line A offset 8 ? MSHR[0]
2. Load from line A offset 0 (same line) ? merge into MSHR[0]
3. After fill, verify load returns correct data from the filled+merged line

---

## 5. Randomized Out-of-Order Test

### 5.1 Test: `test_mshr_randomized`

Extends the existing `test_randomized_scoreboard()` with MSHR-aware features.

**Parameters:**
- RAND_ACCESSES = 200 (configurable)
- Deterministic PRNG seed for reproducibility

**Procedure:**
1. Initialize memory with deterministic pattern
2. For each access:
   a. Generate random address (32-bit low bits, aligned to 8B)
   b. Randomly choose load or store (50/50)
   c. Randomly choose access size (byte/half/word/double)
   d. Issue non-blocking request
   e. Periodically apply backpressure on cpu_rsp_ready
   f. Periodically drain scoreboard to prevent overflow
3. Final drain of all pending responses
4. Verify all scoreboard entries completed
5. Verify golden memory == physical memory
6. Verify cache statistics are self-consistent

---

## 6. Protocol Monitors for MSHR

### 6.1 New Invariants

The following checks run every cycle in an `always` block:

| # | Invariant | Check |
|---|-----------|-------|
| 1 | MSHR count <= MSHR_ENTRIES | `dut.mshr_count <= MSHR_ENTRIES` |
| 2 | No duplicate MSHR entries | No two entries have same addr and !mem_done |
| 3 | cpu_req_ready low when MSHR full | `!cpu_req_ready \|\| !mshr_full` |
| 4 | CPU response stability | Response data unchanged while stalled (existing) |
| 5 | Memory request stability | Mem req unchanged while stalled (existing) |
| 6 | Hit/miss accounting consistency | sum(hits, misses) == accesses completed |

### 6.2 Internal Signal Probing

To enable protocol monitors, expose key internal signals from the DUT:

```systemverilog
// In l1d_cache.sv (add for simulation only):
`ifndef SYNTHESIS
    output logic [MSHR_COUNT_BITS-1:0] dbg_mshr_count,
    output logic                        dbg_mshr_full,
    output logic [MSHR_ENTRIES-1:0]     dbg_mshr_valid
`endif
```

---

## 7. Trace Replay Adaptation

### 7.1 Non-Blocking Trace Replay

The existing `replay_trace()` is extended with a non-blocking variant `replay_trace_nonblocking()`:

- Uses `cpu_load_nonblocking()` and `cpu_store_nonblocking()` instead of blocking variants
- Periodically drains scoreboard to prevent overflow
- Final drain and workload report as before

### 7.2 PlusArgs for Mode Selection

```systemverilog
if ($value$plusargs("TRACE=%s", trace_path)) begin
    initialize_memory();
    reset_cache();
    if ($test$plusargs("TRACE_NONBLOCKING"))
        replay_trace_nonblocking(trace_path);
    else
        replay_trace(trace_path);  // original blocking
end
```

---

## 8. Verification Test Matrix

| Test | Blocking | NB MSHR=1 | NB MSHR=2 | NB MSHR=4 |
|------|:--------:|:---------:|:---------:|:---------:|
| Baseline (hits, sizes, sign-ext) | Yes | Yes | Yes | Yes |
| Misaligned faults | Yes | Yes | Yes | Yes |
| Victim hit swap | Yes | Yes | Yes | Yes |
| Dirty victim writeback | Yes | Yes | Yes | Yes |
| Zero-entry victim bypass | Yes | Yes | Yes | Yes |
| Response backpressure | Yes | Yes | Yes | Yes |
| Randomized scoreboard (existing) | Yes | Yes | Yes | Yes |
| **Hit-under-miss** | N/A | Yes | Yes | Yes |
| **Miss-under-miss** | N/A | N/A | Yes | Yes |
| **MSHR merge same line** | N/A | Yes | Yes | Yes |
| **MSHR store-load merge** | N/A | Yes | Yes | Yes |
| **MSHR full backpressure** | N/A | Yes | Yes | Yes |
| **Victim swap + MSHR** | N/A | Yes | Yes | Yes |
| **Prefetch + MSHR** | N/A | Yes | Yes | Yes |
| **MSHR OoO randomized** | N/A | Yes | Yes | Yes |
| Trace replay (smoke) | Yes | Yes | Yes | Yes |
| Trace replay (SPEC) | Yes | Yes | Yes | Yes |
| Synthetic workloads | Yes | Yes | Yes | Yes |

---

## 9. Test Entry Point Modifications

### 9.1 Updated `initial` Block

```systemverilog
initial begin
    string trace_path;
    // ... init ...

    if ($value$plusargs("TRACE=%s", trace_path)) begin
        initialize_memory(); reset_cache();
        if (ENABLE_NONBLOCKING && $test$plusargs("TRACE_NONBLOCKING"))
            replay_trace_nonblocking(trace_path);
        else
            replay_trace(trace_path);
    end else if ($test$plusargs("WORKLOADS_ONLY")) begin
        test_workload_boundaries();
    end else if (ENABLE_PREFETCH != 0) begin
        test_prefetch();
        if (ENABLE_NONBLOCKING)
            test_mshr_prefetch_coexistence();
    end else begin
        // Existing baseline tests
        test_baseline();
        test_rv64_alignment_faults();
        if (VICTIM_ENTRIES == 0)
            test_zero_entry_victim_bypass();
        else begin
            test_victim_hit();
            test_dirty_victim_writeback();
        end
        test_response_backpressure();
        test_randomized_scoreboard();

        // NEW MSHR tests (only when non-blocking enabled)
        if (ENABLE_NONBLOCKING) begin
            test_mshr_hit_under_miss();
            if (MSHR_ENTRIES >= 2)
                test_mshr_miss_under_miss();
            test_mshr_merge_same_line();
            test_mshr_store_load_merge();
            test_mshr_full_backpressure();
            test_mshr_victim_swap_during_miss();
            test_mshr_response_backpressure();
            test_mshr_randomized();
        end
    end

    if (errors == 0 && protocol_errors == 0) begin
        $display("ALL TESTS PASSED ways=%0d prefetch=%0d nonblocking=%0d mshr=%0d",
                 NUM_WAYS, ENABLE_PREFETCH, ENABLE_NONBLOCKING, MSHR_ENTRIES);
        $finish;
    end else begin
        $fatal(1, "%0d functional and %0d protocol failures",
               errors, protocol_errors);
    end
end
```

---

## 10. Regression Script Additions

### 10.1 Icarus Verilog Commands

```bash
# Non-blocking, direct-mapped, MSHR=4
iverilog -g2012 -o sim/mshr_dm_vc4.vvp \
    -DNUM_WAYS=1 -DENABLE_PREFETCH=0 -DVICTIM_ENTRIES=4 \
    -DMSHR_ENTRIES=4 -DENABLE_NONBLOCKING=1 \
    src/l1d_sram.sv src/l1d_next_line_prefetch.sv \
    src/l1d_prefetch_buffer.sv src/l1d_mshr.sv \
    src/l1d_cache.sv src/tb_l1d_cache.sv

# Non-blocking, 2-way, MSHR=4
iverilog -g2012 -o sim/mshr_2w_vc4.vvp \
    -DNUM_WAYS=2 -DENABLE_PREFETCH=0 -DVICTIM_ENTRIES=4 \
    -DMSHR_ENTRIES=4 -DENABLE_NONBLOCKING=1 \
    src/l1d_sram.sv src/l1d_next_line_prefetch.sv \
    src/l1d_prefetch_buffer.sv src/l1d_mshr.sv \
    src/l1d_cache.sv src/tb_l1d_cache.sv

# Non-blocking with prefetch, MSHR=4
iverilog -g2012 -o sim/mshr_prefetch_vc4.vvp \
    -DNUM_WAYS=2 -DENABLE_PREFETCH=1 -DVICTIM_ENTRIES=4 \
    -DMSHR_ENTRIES=4 -DENABLE_NONBLOCKING=1 \
    src/l1d_sram.sv src/l1d_next_line_prefetch.sv \
    src/l1d_prefetch_buffer.sv src/l1d_mshr.sv \
    src/l1d_cache.sv src/tb_l1d_cache.sv
```

### 10.2 Vivado Simulation Commands

```tcl
# Set generics for non-blocking configuration
set_property generic {
    NUM_WAYS=2 VICTIM_ENTRIES=4 ENABLE_PREFETCH=0
    MSHR_ENTRIES=4 ENABLE_NONBLOCKING=1
} [get_filesets sim_1]
```

---

## 11. Test Execution Flow

```
                    +--------------------------+
                    | Parse plusargs           |
                    | (TRACE, WORKLOADS_ONLY,  |
                    |  VCD, ACCESS_LOG, etc.)  |
                    +-----------+--------------+
                                |
            +-------------------+-------------------+
            |                   |                   |
            v                   v                   v
    +-----------+       +-----------+       +-----------------+
    | TRACE     |       | WORKLOADS |       | Directed Tests  |
    | replay    |       | ONLY      |       | (baseline,      |
    | (blocking |       |           |       |  victim,        |
    |  or NB)   |       | test_work-|       |  prefetch,      |
    +-----+-----+       | load_     |       |  MSHR tests)    |
          |             | boundaries|       +--------+--------+
          v             +-----+-----+                |
    +-----------+             |                      |
    | workload  |             v                      |
    | results   |       +-----------+                |
    +-----------+       | WORKLOAD  |                |
                        | _RESULT   |                |
                        +-----------+                |
                                                     v
                                            +-----------------+
                                            | PASS or FAIL    |
                                            | (errors,        |
                                            |  protocol_errors)|
                                            +-----------------+
```

---

## 12. References

- Existing testbench: `src/tb_l1d_cache.sv`
- MSHR design spec: `docs/mshr_design.md`
- Baseline microarchitecture spec: `docs/Microarchitecture Specification.md`
- [Kroft, D., Lockup-Free Instruction Fetch/Prefetch Cache Organization, ISCA 1981]
- [Farkas, K.I. and Jouppi, N.P., Complexity/Performance Tradeoffs with Non-Blocking Loads, ISCA 1994]
