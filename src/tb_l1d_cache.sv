`timescale 1ns/1ps

module tb_l1d_cache #(
    parameter integer NUM_WAYS = 1,
    parameter integer ENABLE_PREFETCH = 0,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer MEM_BYTES = 1048576
);
    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 32;
    localparam integer LINE_BYTES = 16;
    localparam integer NUM_SETS = 4;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam logic [ADDR_WIDTH-1:0] ADDR_MASK = MEM_BYTES - 1;
    localparam integer CONFLICT_STRIDE = NUM_SETS * LINE_BYTES;

    logic clk;
    logic rst_n;

    logic cfg_prefetch_enable;
    logic cfg_next_line_enable;
    logic ext_prefetch_valid;
    logic ext_prefetch_ready;
    logic [ADDR_WIDTH-1:0] ext_prefetch_addr;

    logic cpu_req_valid;
    logic cpu_req_ready;
    logic [ADDR_WIDTH-1:0] cpu_req_addr;
    logic cpu_req_write;
    logic [DATA_WIDTH-1:0] cpu_req_wdata;
    logic [(DATA_WIDTH/8)-1:0] cpu_req_wstrb;
    logic cpu_rsp_valid;
    logic cpu_rsp_ready;
    logic [DATA_WIDTH-1:0] cpu_rsp_rdata;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDR_WIDTH-1:0] mem_req_addr;
    logic [LINE_BITS-1:0] mem_req_wdata;
    logic mem_rsp_valid;
    logic [LINE_BITS-1:0] mem_rsp_rdata;

    logic [31:0] stat_cpu_hits;
    logic [31:0] stat_cpu_misses;
    logic [31:0] stat_victim_hits;
    logic [31:0] stat_writebacks;
    logic [31:0] stat_prefetch_fills;
    logic [31:0] stat_prefetch_useful;
    logic [31:0] stat_prefetch_useless;
    logic [31:0] stat_prefetch_pollution;
    logic [31:0] stat_prefetch_dropped;
    logic cache_idle;
    logic event_cpu_access;
    logic event_cpu_hit;
    logic event_cpu_miss;
    logic event_victim_hit;
    logic event_writeback;
    logic event_prefetch_fill;
    logic event_prefetch_useful;
    logic event_prefetch_useless;
    logic event_prefetch_pollution;
    logic event_prefetch_dropped;

    byte unsigned memory [0:MEM_BYTES-1];
    byte unsigned golden_memory [0:MEM_BYTES-1];
    logic read_pending;
    logic [ADDR_WIDTH-1:0] read_addr;
    integer read_countdown;
    logic [2:0] mem_ready_phase;
    logic stalled_mem_req;
    logic stalled_mem_write;
    logic [ADDR_WIDTH-1:0] stalled_mem_addr;
    logic [LINE_BITS-1:0] stalled_mem_wdata;
    logic stalled_cpu_rsp;
    logic [DATA_WIDTH-1:0] stalled_cpu_rdata;
    integer errors;
    integer protocol_errors;
    integer accepted_mem_reads;
    integer accepted_mem_writes;
    integer cycles_since_reset;
    integer k;

    l1d_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .ENABLE_PREFETCH(ENABLE_PREFETCH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_prefetch_enable(cfg_prefetch_enable),
        .cfg_next_line_enable(cfg_next_line_enable),
        .ext_prefetch_valid(ext_prefetch_valid),
        .ext_prefetch_ready(ext_prefetch_ready),
        .ext_prefetch_addr(ext_prefetch_addr),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_write(cpu_req_write),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_req_wstrb(cpu_req_wstrb),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_rdata(cpu_rsp_rdata),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_addr(mem_req_addr),
        .mem_req_wdata(mem_req_wdata),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata),
        .stat_cpu_hits(stat_cpu_hits),
        .stat_cpu_misses(stat_cpu_misses),
        .stat_victim_hits(stat_victim_hits),
        .stat_writebacks(stat_writebacks),
        .stat_prefetch_fills(stat_prefetch_fills),
        .stat_prefetch_useful(stat_prefetch_useful),
        .stat_prefetch_useless(stat_prefetch_useless),
        .stat_prefetch_pollution(stat_prefetch_pollution),
        .stat_prefetch_dropped(stat_prefetch_dropped),
        .cache_idle(cache_idle),
        .event_cpu_access(event_cpu_access),
        .event_cpu_hit(event_cpu_hit),
        .event_cpu_miss(event_cpu_miss),
        .event_victim_hit(event_victim_hit),
        .event_writeback(event_writeback),
        .event_prefetch_fill(event_prefetch_fill),
        .event_prefetch_useful(event_prefetch_useful),
        .event_prefetch_useless(event_prefetch_useless),
        .event_prefetch_pollution(event_prefetch_pollution),
        .event_prefetch_dropped(event_prefetch_dropped)
    );

    always #5 clk = ~clk;

    function automatic [LINE_BITS-1:0] load_line(
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer b;
        logic [LINE_BITS-1:0] result;
        begin
            addr = addr & ADDR_MASK;
            result = '0;
            for (b = 0; b < LINE_BYTES; b = b + 1) begin
                result[b*8 +: 8] = memory[addr + b];
            end
            load_line = result;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] memory_word(
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer b;
        logic [DATA_WIDTH-1:0] result;
        begin
            addr = addr & ADDR_MASK;
            result = '0;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                result[b*8 +: 8] = memory[addr + b];
            end
            memory_word = result;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] golden_word(
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer b;
        logic [DATA_WIDTH-1:0] result;
        begin
            addr = addr & ADDR_MASK;
            result = '0;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                result[b*8 +: 8] = golden_memory[addr + b];
            end
            golden_word = result;
        end
    endfunction

    task automatic initialize_memory;
        integer b;
        begin
            for (b = 0; b < MEM_BYTES; b = b + 1) begin
                memory[b] = (b * 13 + 7) & 8'hff;
                golden_memory[b] = (b * 13 + 7) & 8'hff;
            end
        end
    endtask

    task automatic update_golden_word(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data,
        input logic [(DATA_WIDTH/8)-1:0] wstrb
    );
        integer b;
        begin
            addr = addr & ADDR_MASK;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                if (wstrb[b]) begin
                    golden_memory[addr + b] = data[b*8 +: 8];
                end
            end
        end
    endtask

    task automatic reset_cache;
        begin
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
            cpu_req_write = 1'b0;
            cpu_req_wdata = '0;
            cpu_req_wstrb = '0;
            cpu_rsp_ready = 1'b1;
            cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
            cfg_next_line_enable = (ENABLE_PREFETCH != 0);
            ext_prefetch_valid = 1'b0;
            ext_prefetch_addr = '0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic cpu_read(
        input logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data
    );
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = 1'b0;
            cpu_req_wdata = '0;
            cpu_req_wstrb = '0;
            timeout = 0;
            while (!cpu_req_ready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "CPU read request timeout");
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;

            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 400) $fatal(1, "CPU read response timeout");
            end
            data = cpu_rsp_rdata;
            @(posedge clk);
        end
    endtask

    task automatic cpu_write(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data,
        input logic [(DATA_WIDTH/8)-1:0] wstrb
    );
        logic [DATA_WIDTH-1:0] ignored;
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = 1'b1;
            cpu_req_wdata = data;
            cpu_req_wstrb = wstrb;
            timeout = 0;
            while (!cpu_req_ready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "CPU write request timeout");
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;

            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 400) $fatal(1, "CPU write response timeout");
            end
            ignored = cpu_rsp_rdata;
            @(posedge clk);
        end
    endtask

    task automatic expect_read(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] expected,
        input string label_text
    );
        logic [DATA_WIDTH-1:0] actual;
        begin
            cpu_read(addr, actual);
            if (actual !== expected) begin
                $display("FAIL %s addr=%08x expected=%08x actual=%08x",
                         label_text, addr, expected, actual);
                errors = errors + 1;
            end else begin
                $display("PASS %s addr=%08x data=%08x",
                         label_text, addr, actual);
            end
        end
    endtask

    task automatic test_baseline;
        logic [ADDR_WIDTH-1:0] addr_a;
        logic [ADDR_WIDTH-1:0] addr_b;
        logic [31:0] hits_before;
        begin
            $display("TEST baseline hits and write-allocate, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            addr_a = 32'h0000_0020;
            addr_b = 32'h0000_0134;

            expect_read(addr_a, memory_word(addr_a), "cold read miss");
            hits_before = stat_cpu_hits;
            expect_read(addr_a, memory_word(addr_a), "read hit");
            if (stat_cpu_hits != hits_before + 1) begin
                $display("FAIL hit counter did not increment");
                errors = errors + 1;
            end

            cpu_write(addr_b, 32'hdeadc0de, 4'hf);
            expect_read(addr_b, 32'hdeadc0de, "write-allocate readback");
            cpu_write(addr_b, 32'h0000_aa00, 4'b0010);
            expect_read(addr_b, 32'hdead_aade, "byte-enable write hit");
        end
    endtask

    task automatic test_victim_hit;
        logic [ADDR_WIDTH-1:0] base;
        logic [31:0] victim_before;
        begin
            $display("TEST victim-cache swap, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            base = 32'h0000_0000;

            for (k = 0; k <= NUM_WAYS; k = k + 1) begin
                expect_read(base + k*CONFLICT_STRIDE,
                            memory_word(base + k*CONFLICT_STRIDE),
                            "conflict fill");
            end
            victim_before = stat_victim_hits;
            expect_read(base, memory_word(base), "victim rescue");
            if (stat_victim_hits != victim_before + 1) begin
                $display("FAIL victim hit counter did not increment");
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_dirty_victim_writeback;
        logic [ADDR_WIDTH-1:0] base;
        logic [31:0] writebacks_before;
        begin
            $display("TEST dirty victim write-back, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            base = 32'h0000_0080;
            writebacks_before = stat_writebacks;

            cpu_write(base, 32'h1234_5678, 4'hf);
            update_golden_word(base, 32'h1234_5678, 4'hf);
            for (k = 1; k <= NUM_WAYS + VICTIM_ENTRIES; k = k + 1) begin
                expect_read(base + k*CONFLICT_STRIDE,
                            memory_word(base + k*CONFLICT_STRIDE),
                            "dirty eviction pressure");
            end
            repeat (3) @(posedge clk);
            if (stat_writebacks <= writebacks_before) begin
                $display("FAIL dirty victim line was not written back");
                errors = errors + 1;
            end
            if (memory_word(base) !== 32'h1234_5678) begin
                $display("FAIL backing memory did not receive dirty line");
                errors = errors + 1;
            end else begin
                $display("PASS dirty victim write-back data=%08x",
                         memory_word(base));
            end
        end
    endtask

    task automatic test_response_backpressure;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] held_data;
        integer timeout;
        begin
            $display("TEST CPU response backpressure, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            addr = 32'h0000_01c0;

            @(negedge clk);
            cpu_rsp_ready = 1'b0;
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = 1'b0;
            cpu_req_wdata = '0;
            cpu_req_wstrb = '0;
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;

            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 400) $fatal(1, "Backpressure response timeout");
            end
            held_data = cpu_rsp_rdata;
            repeat (4) begin
                @(posedge clk);
                if (!cpu_rsp_valid || cpu_rsp_rdata !== held_data) begin
                    $display("FAIL CPU response changed while stalled");
                    errors = errors + 1;
                end
            end
            if (held_data !== golden_word(addr)) begin
                $display("FAIL backpressured response data expected=%08x actual=%08x",
                         golden_word(addr), held_data);
                errors = errors + 1;
            end
            @(negedge clk);
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic test_randomized_scoreboard;
        integer unsigned random_state;
        integer operation;
        integer byte_index;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [DATA_WIDTH-1:0] actual;
        logic [(DATA_WIDTH/8)-1:0] wstrb;
        begin
            $display("TEST randomized golden-memory scoreboard, ways=%0d",
                     NUM_WAYS);
            initialize_memory();
            reset_cache();
            random_state = 32'h4700_2026 ^ NUM_WAYS;

            for (operation = 0; operation < 160;
                 operation = operation + 1) begin
                random_state = random_state ^
                               (random_state << 13);
                random_state = random_state ^
                               (random_state >> 17);
                random_state = random_state ^
                               (random_state << 5);
                addr = ((random_state >> 3) % 256) * (DATA_WIDTH/8);

                if (random_state[0]) begin
                    data = random_state ^ (operation * 32'h0101_0101);
                    wstrb = random_state[7:4];
                    if (wstrb == '0) begin
                        wstrb = 4'b0001;
                    end
                    cpu_write(addr, data, wstrb);
                    update_golden_word(addr, data, wstrb);
                end else begin
                    cpu_read(addr, actual);
                    if (actual !== golden_word(addr)) begin
                        $display("FAIL randomized read op=%0d addr=%08x expected=%08x actual=%08x",
                                 operation, addr, golden_word(addr), actual);
                        errors = errors + 1;
                    end
                end
            end

            // Force every randomized dirty line through L1 and victim cache.
            for (byte_index = 0; byte_index < NUM_SETS; byte_index = byte_index + 1) begin
                for (operation = 0;
                     operation < NUM_WAYS + VICTIM_ENTRIES + 2;
                     operation = operation + 1) begin
                    addr = 32'h0000_0800 +
                           operation*CONFLICT_STRIDE +
                           byte_index*LINE_BYTES;
                    cpu_read(addr, actual);
                    if (actual !== golden_word(addr)) begin
                        $display("FAIL flush-pressure read addr=%08x", addr);
                        errors = errors + 1;
                    end
                end
            end
            repeat (5) @(posedge clk);

            for (byte_index = 0; byte_index < 1024;
                 byte_index = byte_index + 1) begin
                if (memory[byte_index] !== golden_memory[byte_index]) begin
                    $display("FAIL dirty preservation byte=%0d expected=%02x actual=%02x",
                             byte_index, golden_memory[byte_index],
                             memory[byte_index]);
                    errors = errors + 1;
                end
            end
            if (errors == 0) begin
                $display("PASS randomized scoreboard and dirty preservation");
            end
        end
    endtask

    task automatic test_prefetch;
        logic [ADDR_WIDTH-1:0] base;
        logic [ADDR_WIDTH-1:0] prefetched;
        logic [ADDR_WIDTH-1:0] injected;
        logic [31:0] useful_before;
        logic [31:0] useless_before;
        logic [31:0] victim_before;
        logic [31:0] fills_before;
        integer timeout;
        begin
            $display("TEST next-line prefetch, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            cfg_prefetch_enable = 1'b0;
            base = 32'h0000_0100;
            expect_read(base, memory_word(base),
                        "runtime-disabled prefetch demand");
            repeat (20) @(posedge clk);
            if (stat_prefetch_fills != 0) begin
                $display("FAIL prefetch issued while runtime-disabled");
                errors = errors + 1;
            end

            reset_cache();
            base = 32'h0000_0200;

            expect_read(base, memory_word(base), "prefetch trigger miss");
            timeout = 0;
            while (stat_prefetch_fills == 0) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "prefetch fill timeout");
            end
            useful_before = stat_prefetch_useful;
            expect_read(base + LINE_BYTES, memory_word(base + LINE_BYTES),
                        "prefetched next line");
            if (stat_prefetch_useful != useful_before + 1) begin
                $display("FAIL useful prefetch counter did not increment");
                errors = errors + 1;
            end

            // A prefetched line moved into the victim cache remains useful.
            base = 32'h0000_0300;
            expect_read(base, memory_word(base),
                        "victim-prefetch trigger miss");
            timeout = 0;
            while (stat_prefetch_fills < 2) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "second prefetch fill timeout");
            end
            cfg_next_line_enable = 1'b0;
            prefetched = base + LINE_BYTES;
            useless_before = stat_prefetch_useless;
            for (k = 1; k <= NUM_WAYS; k = k + 1) begin
                expect_read(prefetched + k*CONFLICT_STRIDE,
                            memory_word(prefetched + k*CONFLICT_STRIDE),
                            "prefetch victim pressure");
            end
            if (stat_prefetch_useless != useless_before) begin
                $display("FAIL prefetch counted useless while retained by victim cache");
                errors = errors + 1;
            end
            useful_before = stat_prefetch_useful;
            victim_before = stat_victim_hits;
            expect_read(prefetched, memory_word(prefetched),
                        "prefetch rescued from victim");
            if (stat_prefetch_useful != useful_before + 1 ||
                stat_victim_hits != victim_before + 1) begin
                $display("FAIL victim-rescued prefetch accounting");
                errors = errors + 1;
            end

            injected = base + 8*LINE_BYTES;
            fills_before = stat_prefetch_fills;
            @(negedge clk);
            ext_prefetch_valid = 1'b1;
            ext_prefetch_addr = injected;
            timeout = 0;
            while (!ext_prefetch_ready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "external prefetch timeout");
            end
            @(posedge clk);
            @(negedge clk);
            ext_prefetch_valid = 1'b0;

            timeout = 0;
            while (stat_prefetch_fills == fills_before) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "external prefetch fill timeout");
            end
            useful_before = stat_prefetch_useful;
            expect_read(injected, memory_word(injected),
                        "externally injected prefetch");
            if (stat_prefetch_useful != useful_before + 1) begin
                $display("FAIL external prefetch was not marked useful");
                errors = errors + 1;
            end
        end
    endtask

    task automatic wait_for_quiescence;
        integer timeout;
        begin
            @(negedge clk);
            cfg_next_line_enable = 1'b0;
            timeout = 0;
            while (!cache_idle || read_pending || mem_req_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 400) $fatal(1, "cache quiescence timeout");
            end
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic report_workload(
        input string workload_name,
        input integer accesses
    );
        begin
            $display("WORKLOAD_RESULT name=%s ways=%0d vc=%0d prefetch=%0d accesses=%0d hits=%0d misses=%0d victim_hits=%0d mem_reads=%0d mem_writes=%0d useful=%0d useless=%0d pollution=%0d dropped=%0d cycles=%0d",
                     workload_name, NUM_WAYS, VICTIM_ENTRIES,
                     cfg_prefetch_enable, accesses, stat_cpu_hits,
                     stat_cpu_misses, stat_victim_hits, accepted_mem_reads,
                     accepted_mem_writes, stat_prefetch_useful,
                     stat_prefetch_useless, stat_prefetch_pollution,
                     stat_prefetch_dropped, cycles_since_reset);
            if (stat_cpu_hits + stat_cpu_misses != accesses) begin
                $display("FAIL workload accounting name=%s accesses=%0d hits_plus_misses=%0d",
                         workload_name, accesses,
                         stat_cpu_hits + stat_cpu_misses);
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_workload_boundaries;
        localparam integer STREAM_ACCESSES = 12;
        localparam integer LOOP_ACCESSES = 12;
        localparam integer POINTER_ACCESSES = 12;
        integer access_index;
        integer active_lines;
        integer repetitions;
        integer total_accesses;
        integer pointer_line [0:POINTER_ACCESSES-1];
        logic [ADDR_WIDTH-1:0] base;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] actual;
        begin
            $display("TEST workload-driven boundary profiles, ways=%0d prefetch=%0d",
                     NUM_WAYS, ENABLE_PREFETCH);

            initialize_memory();
            reset_cache();
            base = 32'h0000_0400;
            for (access_index = 0; access_index < STREAM_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + access_index*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_word(addr)) begin
                    $display("FAIL sequential stream data addr=%08x", addr);
                    errors = errors + 1;
                end
            end
            wait_for_quiescence();
            report_workload("sequential_stream", STREAM_ACCESSES);
            if (ENABLE_PREFETCH != 0) begin
                if (stat_prefetch_useful == 0 ||
                    stat_cpu_misses >= STREAM_ACCESSES) begin
                    $display("FAIL sequential stream did not benefit from next-line prefetch");
                    errors = errors + 1;
                end
            end else if (stat_cpu_misses != STREAM_ACCESSES) begin
                $display("FAIL cold sequential baseline should miss once per line");
                errors = errors + 1;
            end

            initialize_memory();
            reset_cache();
            base = 32'h0000_0600;
            for (access_index = 0; access_index < STREAM_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + access_index*(2*LINE_BYTES);
                cpu_read(addr, actual);
                if (actual !== golden_word(addr)) begin
                    $display("FAIL fixed-stride data addr=%08x", addr);
                    errors = errors + 1;
                end
            end
            wait_for_quiescence();
            report_workload("stride_two_lines", STREAM_ACCESSES);
            if (stat_cpu_misses != STREAM_ACCESSES ||
                stat_prefetch_useful != 0) begin
                $display("FAIL two-line stride should not use next-line candidates");
                errors = errors + 1;
            end

            initialize_memory();
            reset_cache();
            base = 32'h0000_0800;
            for (access_index = 0; access_index < LOOP_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + (access_index % 2)*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_word(addr)) begin
                    $display("FAIL localized loop data addr=%08x", addr);
                    errors = errors + 1;
                end
            end
            wait_for_quiescence();
            report_workload("localized_two_line_loop", LOOP_ACCESSES);
            if (stat_cpu_hits < LOOP_ACCESSES - 2) begin
                $display("FAIL localized loop did not reach stable cache hits");
                errors = errors + 1;
            end

            initialize_memory();
            reset_cache();
            cfg_prefetch_enable = 1'b0;
            cfg_next_line_enable = 1'b0;
            base = 32'h0000_0a00;
            active_lines = NUM_WAYS + 1;
            repetitions = 4;
            total_accesses = active_lines * repetitions;
            for (access_index = 0; access_index < total_accesses;
                 access_index = access_index + 1) begin
                addr = base + (access_index % active_lines)*CONFLICT_STRIDE;
                cpu_read(addr, actual);
                if (actual !== golden_word(addr)) begin
                    $display("FAIL conflict-thrash data addr=%08x", addr);
                    errors = errors + 1;
                end
            end
            wait_for_quiescence();
            report_workload("same_set_conflict_thrash", total_accesses);
            if (accepted_mem_reads != active_lines ||
                stat_victim_hits < total_accesses - active_lines) begin
                $display("FAIL victim cache did not retain the conflict working set");
                errors = errors + 1;
            end

            pointer_line[0] = 0;
            pointer_line[1] = 10;
            pointer_line[2] = 4;
            pointer_line[3] = 18;
            pointer_line[4] = 8;
            pointer_line[5] = 22;
            pointer_line[6] = 2;
            pointer_line[7] = 16;
            pointer_line[8] = 6;
            pointer_line[9] = 20;
            pointer_line[10] = 12;
            pointer_line[11] = 14;
            initialize_memory();
            reset_cache();
            base = 32'h0000_0c00;
            for (access_index = 0; access_index < POINTER_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + pointer_line[access_index]*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_word(addr)) begin
                    $display("FAIL pointer-chase data addr=%08x", addr);
                    errors = errors + 1;
                end
            end
            wait_for_quiescence();
            report_workload("irregular_pointer_chase", POINTER_ACCESSES);
            if (stat_cpu_misses != POINTER_ACCESSES ||
                stat_prefetch_useful != 0) begin
                $display("FAIL irregular pointer chase unexpectedly used next-line data");
                errors = errors + 1;
            end
        end
    endtask

    task automatic replay_trace(
        input string trace_path
    );
        integer trace_fd;
        integer trace_line_number;
        integer scan_count;
        integer operation;
        integer accesses;
        reg [8*256-1:0] trace_line;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [DATA_WIDTH-1:0] actual;
        logic [(DATA_WIDTH/8)-1:0] wstrb;
        begin
            trace_fd = $fopen(trace_path, "r");
            if (trace_fd == 0) begin
                $fatal(1, "cannot open trace file: %s", trace_path);
            end

            $display("TEST trace replay file=%s ways=%0d prefetch=%0d",
                     trace_path, NUM_WAYS, ENABLE_PREFETCH);
            accesses = 0;
            trace_line_number = 0;
            while (!$feof(trace_fd)) begin
                trace_line = '0;
                if ($fgets(trace_line, trace_fd) != 0) begin
                    trace_line_number = trace_line_number + 1;
                    operation = -1;
                    addr = '0;
                    data = '0;
                    wstrb = '0;
                    scan_count = $sscanf(trace_line, "%d %h %h %h",
                                         operation, addr, data, wstrb);
                    if (scan_count >= 2) begin
                        case (operation)
                            0: begin
                                cpu_read(addr, actual);
                                if (actual !== golden_word(addr)) begin
                                    $display("FAIL trace read line=%0d addr=%08x expected=%08x actual=%08x",
                                             trace_line_number, addr,
                                             golden_word(addr), actual);
                                    errors = errors + 1;
                                end
                                accesses = accesses + 1;
                            end
                            1: begin
                                if (scan_count != 4 || wstrb == '0) begin
                                    $fatal(1, "invalid trace write at line %0d",
                                           trace_line_number);
                                end
                                cpu_write(addr, data, wstrb);
                                update_golden_word(addr, data, wstrb);
                                accesses = accesses + 1;
                            end
                            default: begin
                                $fatal(1, "invalid trace opcode at line %0d",
                                       trace_line_number);
                            end
                        endcase
                    end
                end
            end
            $fclose(trace_fd);
            wait_for_quiescence();
            report_workload("trace_replay", accesses);
        end
    endtask

    assign mem_req_ready = !read_pending && (mem_ready_phase != 3'b000);

    always_ff @(posedge clk or negedge rst_n) begin
        integer b;
        if (!rst_n) begin
            read_pending <= 1'b0;
            read_addr <= '0;
            read_countdown <= 0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_rdata <= '0;
            mem_ready_phase <= '0;
            accepted_mem_reads <= 0;
            accepted_mem_writes <= 0;
            cycles_since_reset <= 0;
        end else begin
            mem_rsp_valid <= 1'b0;
            mem_ready_phase <= mem_ready_phase + 1'b1;
            cycles_since_reset <= cycles_since_reset + 1;

            if (read_pending) begin
                if (read_countdown == 0) begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_rdata <= load_line(read_addr);
                    read_pending <= 1'b0;
                end else begin
                    read_countdown <= read_countdown - 1;
                end
            end

            if (mem_req_valid && mem_req_ready) begin
                if (mem_req_write) begin
                    accepted_mem_writes <= accepted_mem_writes + 1;
                    for (b = 0; b < LINE_BYTES; b = b + 1) begin
                        memory[(mem_req_addr & ADDR_MASK) + b] <= mem_req_wdata[b*8 +: 8];
                    end
                end else begin
                    accepted_mem_reads <= accepted_mem_reads + 1;
                    read_pending <= 1'b1;
                    read_addr <= mem_req_addr;
                    read_countdown <= 2;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stalled_mem_req <= 1'b0;
            stalled_mem_write <= 1'b0;
            stalled_mem_addr <= '0;
            stalled_mem_wdata <= '0;
            stalled_cpu_rsp <= 1'b0;
            stalled_cpu_rdata <= '0;
        end else begin
            if (stalled_mem_req) begin
                if (!mem_req_valid ||
                    mem_req_write !== stalled_mem_write ||
                    mem_req_addr !== stalled_mem_addr ||
                    mem_req_wdata !== stalled_mem_wdata) begin
                    $display("FAIL memory request changed while stalled");
                    protocol_errors = protocol_errors + 1;
                end
            end
            stalled_mem_req <= mem_req_valid && !mem_req_ready;
            if (mem_req_valid && !mem_req_ready) begin
                stalled_mem_write <= mem_req_write;
                stalled_mem_addr <= mem_req_addr;
                stalled_mem_wdata <= mem_req_wdata;
            end

            if (stalled_cpu_rsp) begin
                if (!cpu_rsp_valid || cpu_rsp_rdata !== stalled_cpu_rdata) begin
                    $display("FAIL CPU response payload changed while stalled");
                    protocol_errors = protocol_errors + 1;
                end
            end
            stalled_cpu_rsp <= cpu_rsp_valid && !cpu_rsp_ready;
            if (cpu_rsp_valid && !cpu_rsp_ready) begin
                stalled_cpu_rdata <= cpu_rsp_rdata;
            end
        end
    end

    initial begin
        string trace_path;
        clk = 1'b0;
        rst_n = 1'b0;
        errors = 0;
        protocol_errors = 0;
        cpu_req_valid = 1'b0;
        cpu_req_addr = '0;
        cpu_req_write = 1'b0;
        cpu_req_wdata = '0;
        cpu_req_wstrb = '0;
        cpu_rsp_ready = 1'b1;
        cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
        cfg_next_line_enable = (ENABLE_PREFETCH != 0);
        ext_prefetch_valid = 1'b0;
        ext_prefetch_addr = '0;

        if ($test$plusargs("VCD")) begin
            $dumpfile("sim/l1d_cache.vcd");
            $dumpvars(0, tb_l1d_cache);
        end

        if ($value$plusargs("TRACE=%s", trace_path)) begin
            initialize_memory();
            reset_cache();
            replay_trace(trace_path);
        end else if ($test$plusargs("WORKLOADS_ONLY")) begin
            test_workload_boundaries();
        end else if (ENABLE_PREFETCH != 0) begin
            test_prefetch();
        end else begin
            test_baseline();
            test_victim_hit();
            test_dirty_victim_writeback();
            test_response_backpressure();
            test_randomized_scoreboard();
        end

        if (errors == 0 && protocol_errors == 0) begin
            $display("ALL TESTS PASSED ways=%0d prefetch=%0d",
                     NUM_WAYS, ENABLE_PREFETCH);
            $finish;
        end else begin
            $fatal(1, "%0d functional and %0d protocol failures",
                   errors, protocol_errors);
        end
    end
endmodule
