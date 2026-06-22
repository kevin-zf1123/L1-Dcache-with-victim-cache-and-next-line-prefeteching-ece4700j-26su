`timescale 1ns/1ps

module tb_l1d_cache #(
    parameter integer NUM_WAYS = 1,
    parameter integer ENABLE_PREFETCH = 0,
    parameter integer VICTIM_ENTRIES = 4
);
    localparam integer ADDR_WIDTH = 64;
    localparam integer DATA_WIDTH = 64;
    localparam integer LINE_BYTES = 16;
    localparam integer NUM_SETS = 4;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer MEM_BYTES = 4096;
    localparam integer CONFLICT_STRIDE = NUM_SETS * LINE_BYTES;
    localparam logic [1:0] SIZE_BYTE   = 2'b00;
    localparam logic [1:0] SIZE_HALF   = 2'b01;
    localparam logic [1:0] SIZE_WORD   = 2'b10;
    localparam logic [1:0] SIZE_DOUBLE = 2'b11;
    localparam logic [1:0] RSP_OK                = 2'b00;
    localparam logic [1:0] RSP_LOAD_MISALIGNED  = 2'b01;
    localparam logic [1:0] RSP_STORE_MISALIGNED = 2'b10;

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
    logic [1:0] cpu_req_size;
    logic cpu_req_unsigned;
    logic [DATA_WIDTH-1:0] cpu_req_wdata;
    logic cpu_rsp_valid;
    logic cpu_rsp_ready;
    logic [DATA_WIDTH-1:0] cpu_rsp_rdata;
    logic cpu_rsp_error;
    logic [1:0] cpu_rsp_error_cause;

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
    logic stalled_cpu_error;
    logic [1:0] stalled_cpu_error_cause;
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
        .cpu_req_size(cpu_req_size),
        .cpu_req_unsigned(cpu_req_unsigned),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_rdata(cpu_rsp_rdata),
        .cpu_rsp_error(cpu_rsp_error),
        .cpu_rsp_error_cause(cpu_rsp_error_cause),
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

    function automatic integer access_bytes(
        input logic [1:0] size
    );
        begin
            case (size)
                SIZE_BYTE:   access_bytes = 1;
                SIZE_HALF:   access_bytes = 2;
                SIZE_WORD:   access_bytes = 4;
                default:     access_bytes = 8;
            endcase
        end
    endfunction

    function automatic logic access_misaligned(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size
    );
        begin
            case (size)
                SIZE_BYTE:   access_misaligned = 1'b0;
                SIZE_HALF:   access_misaligned = addr[0];
                SIZE_WORD:   access_misaligned = |addr[1:0];
                default:     access_misaligned = |addr[2:0];
            endcase
        end
    endfunction

    function automatic integer mem_index(
        input logic [ADDR_WIDTH-1:0] addr
    );
        begin
            mem_index = addr % MEM_BYTES;
        end
    endfunction

    function automatic [LINE_BITS-1:0] load_line(
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer b;
        logic [LINE_BITS-1:0] result;
        begin
            result = '0;
            for (b = 0; b < LINE_BYTES; b = b + 1) begin
                result[b*8 +: 8] = memory[mem_index(addr + b)];
            end
            load_line = result;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] memory_load(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic unsigned_load
    );
        integer b;
        logic [DATA_WIDTH-1:0] raw;
        begin
            raw = '0;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                if (b < access_bytes(size)) begin
                    raw[b*8 +: 8] = memory[mem_index(addr + b)];
                end
            end
            case (size)
                SIZE_BYTE: begin
                    memory_load = unsigned_load ?
                        {{(DATA_WIDTH-8){1'b0}}, raw[7:0]} :
                        {{(DATA_WIDTH-8){raw[7]}}, raw[7:0]};
                end
                SIZE_HALF: begin
                    memory_load = unsigned_load ?
                        {{(DATA_WIDTH-16){1'b0}}, raw[15:0]} :
                        {{(DATA_WIDTH-16){raw[15]}}, raw[15:0]};
                end
                SIZE_WORD: begin
                    memory_load = unsigned_load ?
                        {{(DATA_WIDTH-32){1'b0}}, raw[31:0]} :
                        {{(DATA_WIDTH-32){raw[31]}}, raw[31:0]};
                end
                default: begin
                    memory_load = raw;
                end
            endcase
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] golden_load(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic unsigned_load
    );
        integer b;
        logic [DATA_WIDTH-1:0] raw;
        begin
            raw = '0;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                if (b < access_bytes(size)) begin
                    raw[b*8 +: 8] = golden_memory[mem_index(addr + b)];
                end
            end
            case (size)
                SIZE_BYTE: begin
                    golden_load = unsigned_load ?
                        {{(DATA_WIDTH-8){1'b0}}, raw[7:0]} :
                        {{(DATA_WIDTH-8){raw[7]}}, raw[7:0]};
                end
                SIZE_HALF: begin
                    golden_load = unsigned_load ?
                        {{(DATA_WIDTH-16){1'b0}}, raw[15:0]} :
                        {{(DATA_WIDTH-16){raw[15]}}, raw[15:0]};
                end
                SIZE_WORD: begin
                    golden_load = unsigned_load ?
                        {{(DATA_WIDTH-32){1'b0}}, raw[31:0]} :
                        {{(DATA_WIDTH-32){raw[31]}}, raw[31:0]};
                end
                default: begin
                    golden_load = raw;
                end
            endcase
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

    task automatic update_golden_store(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] data,
        input logic [1:0] size
    );
        integer b;
        begin
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                if (b < access_bytes(size)) begin
                    golden_memory[mem_index(addr + b)] = data[b*8 +: 8];
                end
            end
        end
    endtask

    task automatic reset_cache;
        begin
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;
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

    task automatic cpu_request(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic write,
        input logic [1:0] size,
        input logic unsigned_load,
        input logic [DATA_WIDTH-1:0] data,
        output logic [DATA_WIDTH-1:0] rsp_data,
        output logic rsp_error,
        output logic [1:0] rsp_error_cause
    );
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = write;
            cpu_req_size = size;
            cpu_req_unsigned = unsigned_load;
            cpu_req_wdata = data;
            timeout = 0;
            while (!cpu_req_ready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "CPU request timeout");
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;

            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 400) $fatal(1, "CPU response timeout");
            end
            rsp_data = cpu_rsp_rdata;
            rsp_error = cpu_rsp_error;
            rsp_error_cause = cpu_rsp_error_cause;
            @(posedge clk);
        end
    endtask

    task automatic cpu_load(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic unsigned_load,
        output logic [DATA_WIDTH-1:0] data
    );
        logic error;
        logic [1:0] cause;
        begin
            cpu_request(addr, 1'b0, size, unsigned_load, '0,
                        data, error, cause);
            if (error) begin
                $display("FAIL load raised error addr=%016x size=%0d cause=%0d",
                         addr, size, cause);
                errors = errors + 1;
            end
        end
    endtask

    task automatic cpu_read(
        input logic [ADDR_WIDTH-1:0] addr,
        output logic [DATA_WIDTH-1:0] data
    );
        begin
            cpu_load(addr, SIZE_DOUBLE, 1'b0, data);
        end
    endtask

    task automatic cpu_store(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic [DATA_WIDTH-1:0] data
    );
        logic ignored_error;
        logic [1:0] ignored_cause;
        logic [DATA_WIDTH-1:0] ignored_data;
        begin
            cpu_request(addr, 1'b1, size, 1'b0, data,
                        ignored_data, ignored_error, ignored_cause);
            if (ignored_error) begin
                $display("FAIL store raised error addr=%016x size=%0d cause=%0d",
                         addr, size, ignored_cause);
                errors = errors + 1;
            end
        end
    endtask

    task automatic expect_load(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic unsigned_load,
        input logic [DATA_WIDTH-1:0] expected,
        input string label_text
    );
        logic [DATA_WIDTH-1:0] actual;
        begin
            cpu_load(addr, size, unsigned_load, actual);
            if (actual !== expected) begin
                $display("FAIL %s addr=%016x size=%0d unsigned=%0d expected=%016x actual=%016x",
                         label_text, addr, size, unsigned_load, expected, actual);
                errors = errors + 1;
            end else begin
                $display("PASS %s addr=%016x size=%0d data=%016x",
                         label_text, addr, size, actual);
            end
        end
    endtask

    task automatic expect_read(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] expected,
        input string label_text
    );
        begin
            expect_load(addr, SIZE_DOUBLE, 1'b0, expected, label_text);
        end
    endtask

    task automatic test_baseline;
        logic [ADDR_WIDTH-1:0] addr_a;
        logic [ADDR_WIDTH-1:0] addr_b;
        logic [ADDR_WIDTH-1:0] addr_high;
        logic [31:0] hits_before;
        begin
            $display("TEST RV64 hits, write-allocate, and access sizes, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            addr_a = 64'h0000_0000_0000_0020;
            addr_b = 64'h0000_0000_0000_0130;
            addr_high = 64'h0000_0001_0000_0210;

            expect_read(addr_a, memory_load(addr_a, SIZE_DOUBLE, 1'b0),
                        "cold 64-bit read miss");
            hits_before = stat_cpu_hits;
            expect_read(addr_a, memory_load(addr_a, SIZE_DOUBLE, 1'b0),
                        "64-bit read hit");
            if (stat_cpu_hits != hits_before + 1) begin
                $display("FAIL hit counter did not increment");
                errors = errors + 1;
            end

            cpu_store(addr_b, SIZE_DOUBLE, 64'hdead_beef_cafe_babe);
            update_golden_store(addr_b, 64'hdead_beef_cafe_babe, SIZE_DOUBLE);
            expect_read(addr_b, 64'hdead_beef_cafe_babe,
                        "SD write-allocate readback");

            cpu_store(addr_b + 3, SIZE_BYTE, 64'h80);
            update_golden_store(addr_b + 3, 64'h80, SIZE_BYTE);
            expect_load(addr_b + 3, SIZE_BYTE, 1'b0,
                        64'hffff_ffff_ffff_ff80, "LB sign extension");
            expect_load(addr_b + 3, SIZE_BYTE, 1'b1,
                        64'h0000_0000_0000_0080, "LBU zero extension");

            cpu_store(addr_b + 4, SIZE_HALF, 64'h8001);
            update_golden_store(addr_b + 4, 64'h8001, SIZE_HALF);
            expect_load(addr_b + 4, SIZE_HALF, 1'b0,
                        64'hffff_ffff_ffff_8001, "LH sign extension");
            expect_load(addr_b + 4, SIZE_HALF, 1'b1,
                        64'h0000_0000_0000_8001, "LHU zero extension");

            cpu_store(addr_b + 8, SIZE_WORD, 64'h8000_0001);
            update_golden_store(addr_b + 8, 64'h8000_0001, SIZE_WORD);
            expect_load(addr_b + 8, SIZE_WORD, 1'b0,
                        64'hffff_ffff_8000_0001, "LW sign extension");
            expect_load(addr_b + 8, SIZE_WORD, 1'b1,
                        64'h0000_0000_8000_0001, "LWU zero extension");

            expect_read(addr_high, memory_load(addr_high, SIZE_DOUBLE, 1'b0),
                        "64-bit high-address tag read");
        end
    endtask

    task automatic expect_misaligned(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic write,
        input logic [1:0] size,
        input logic [1:0] expected_cause,
        input string label_text
    );
        logic [DATA_WIDTH-1:0] rsp_data;
        logic rsp_error;
        logic [1:0] rsp_cause;
        integer reads_before;
        integer writes_before;
        logic [31:0] hits_before;
        logic [31:0] misses_before;
        begin
            reads_before = accepted_mem_reads;
            writes_before = accepted_mem_writes;
            hits_before = stat_cpu_hits;
            misses_before = stat_cpu_misses;
            cpu_request(addr, write, size, 1'b0, 64'hfeed_face_cafe_beef,
                        rsp_data, rsp_error, rsp_cause);
            if (!rsp_error || rsp_cause !== expected_cause) begin
                $display("FAIL %s addr=%016x size=%0d write=%0d error=%0d cause=%0d",
                         label_text, addr, size, write, rsp_error, rsp_cause);
                errors = errors + 1;
            end else begin
                $display("PASS %s addr=%016x size=%0d cause=%0d",
                         label_text, addr, size, rsp_cause);
            end
            if (accepted_mem_reads != reads_before ||
                accepted_mem_writes != writes_before ||
                stat_cpu_hits != hits_before ||
                stat_cpu_misses != misses_before) begin
                $display("FAIL misaligned access changed cache/memory counters");
                errors = errors + 1;
            end
        end
    endtask

    task automatic test_rv64_alignment_faults;
        begin
            $display("TEST RV64 misaligned access faults, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();

            expect_misaligned(64'h0000_0000_0000_0101, 1'b0, SIZE_HALF,
                              RSP_LOAD_MISALIGNED, "misaligned LH");
            expect_misaligned(64'h0000_0000_0000_0102, 1'b0, SIZE_WORD,
                              RSP_LOAD_MISALIGNED, "misaligned LW");
            expect_misaligned(64'h0000_0000_0000_0104, 1'b0, SIZE_DOUBLE,
                              RSP_LOAD_MISALIGNED, "misaligned LD");
            expect_misaligned(64'h0000_0000_0000_0111, 1'b1, SIZE_HALF,
                              RSP_STORE_MISALIGNED, "misaligned SH");
            expect_misaligned(64'h0000_0000_0000_0112, 1'b1, SIZE_WORD,
                              RSP_STORE_MISALIGNED, "misaligned SW");
            expect_misaligned(64'h0000_0000_0000_0114, 1'b1, SIZE_DOUBLE,
                              RSP_STORE_MISALIGNED, "misaligned SD");
        end
    endtask

    task automatic test_victim_hit;
        logic [ADDR_WIDTH-1:0] base;
        logic [31:0] victim_before;
        begin
            $display("TEST victim-cache swap, ways=%0d", NUM_WAYS);
            initialize_memory();
            reset_cache();
            base = 64'h0000_0000_0000_0000;

            for (k = 0; k <= NUM_WAYS; k = k + 1) begin
                expect_read(base + k*CONFLICT_STRIDE,
                            memory_load(base + k*CONFLICT_STRIDE,
                                        SIZE_DOUBLE, 1'b0),
                            "conflict fill");
            end
            victim_before = stat_victim_hits;
            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
                        "victim rescue");
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
            base = 64'h0000_0000_0000_0080;
            writebacks_before = stat_writebacks;

            cpu_store(base, SIZE_DOUBLE, 64'h1234_5678_9abc_def0);
            update_golden_store(base, 64'h1234_5678_9abc_def0, SIZE_DOUBLE);
            for (k = 1; k <= NUM_WAYS + VICTIM_ENTRIES; k = k + 1) begin
                expect_read(base + k*CONFLICT_STRIDE,
                            memory_load(base + k*CONFLICT_STRIDE,
                                        SIZE_DOUBLE, 1'b0),
                            "dirty eviction pressure");
            end
            repeat (3) @(posedge clk);
            if (stat_writebacks <= writebacks_before) begin
                $display("FAIL dirty victim line was not written back");
                errors = errors + 1;
            end
            if (memory_load(base, SIZE_DOUBLE, 1'b0) !==
                64'h1234_5678_9abc_def0) begin
                $display("FAIL backing memory did not receive dirty line");
                errors = errors + 1;
            end else begin
                $display("PASS dirty victim write-back data=%016x",
                         memory_load(base, SIZE_DOUBLE, 1'b0));
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
            addr = 64'h0000_0000_0000_01c0;

            @(negedge clk);
            cpu_rsp_ready = 1'b0;
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;
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
                if (!cpu_rsp_valid || cpu_rsp_rdata !== held_data ||
                    cpu_rsp_error || cpu_rsp_error_cause != RSP_OK) begin
                    $display("FAIL CPU response changed while stalled");
                    errors = errors + 1;
                end
            end
            if (held_data !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                $display("FAIL backpressured response data expected=%016x actual=%016x",
                         golden_load(addr, SIZE_DOUBLE, 1'b0), held_data);
                errors = errors + 1;
            end
            @(negedge clk);
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic test_randomized_scoreboard;
        logic [63:0] random_state;
        integer operation;
        integer byte_index;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [DATA_WIDTH-1:0] actual;
        logic [1:0] size;
        logic unsigned_load;
        begin
            $display("TEST randomized golden-memory scoreboard, ways=%0d",
                     NUM_WAYS);
            initialize_memory();
            reset_cache();
            random_state = 64'h4700_2026_0000_0001 ^ NUM_WAYS;

            for (operation = 0; operation < 160;
                 operation = operation + 1) begin
                random_state = random_state ^
                               (random_state << 13);
                random_state = random_state ^
                               (random_state >> 17);
                random_state = random_state ^
                               (random_state << 5);
                size = random_state[2:1];
                unsigned_load = random_state[3];
                addr = ((random_state >> 4) % 1024);
                addr = (addr / access_bytes(size)) * access_bytes(size);

                if (random_state[0]) begin
                    data = {random_state[31:0], random_state[63:32]} ^
                           (operation * 64'h0101_0101_0101_0101);
                    cpu_store(addr, size, data);
                    update_golden_store(addr, data, size);
                end else begin
                    cpu_load(addr, size, unsigned_load, actual);
                    if (actual !== golden_load(addr, size, unsigned_load)) begin
                        $display("FAIL randomized load op=%0d addr=%016x size=%0d unsigned=%0d expected=%016x actual=%016x",
                                 operation, addr, size, unsigned_load,
                                 golden_load(addr, size, unsigned_load),
                                 actual);
                        errors = errors + 1;
                    end
                end
            end

            // Force every randomized dirty line through L1 and victim cache.
            for (byte_index = 0; byte_index < NUM_SETS; byte_index = byte_index + 1) begin
                for (operation = 0;
                     operation < NUM_WAYS + VICTIM_ENTRIES + 2;
                     operation = operation + 1) begin
                    addr = 64'h0000_0000_0000_0800 +
                           operation*CONFLICT_STRIDE +
                           byte_index*LINE_BYTES;
                    cpu_read(addr, actual);
                    if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                        $display("FAIL flush-pressure read addr=%016x", addr);
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
            base = 64'h0000_0000_0000_0100;
            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
                        "runtime-disabled prefetch demand");
            repeat (20) @(posedge clk);
            if (stat_prefetch_fills != 0) begin
                $display("FAIL prefetch issued while runtime-disabled");
                errors = errors + 1;
            end

            reset_cache();
            base = 64'h0000_0000_0000_0200;

            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
                        "prefetch trigger miss");
            timeout = 0;
            while (stat_prefetch_fills == 0) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "prefetch fill timeout");
            end
            useful_before = stat_prefetch_useful;
            expect_read(base + LINE_BYTES,
                        memory_load(base + LINE_BYTES, SIZE_DOUBLE, 1'b0),
                        "prefetched next line");
            if (stat_prefetch_useful != useful_before + 1) begin
                $display("FAIL useful prefetch counter did not increment");
                errors = errors + 1;
            end

            // A prefetched line moved into the victim cache remains useful.
            base = 64'h0000_0000_0000_0300;
            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
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
                            memory_load(prefetched + k*CONFLICT_STRIDE,
                                        SIZE_DOUBLE, 1'b0),
                            "prefetch victim pressure");
            end
            if (stat_prefetch_useless != useless_before) begin
                $display("FAIL prefetch counted useless while retained by victim cache");
                errors = errors + 1;
            end
            useful_before = stat_prefetch_useful;
            victim_before = stat_victim_hits;
            expect_read(prefetched, memory_load(prefetched, SIZE_DOUBLE, 1'b0),
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
            expect_read(injected, memory_load(injected, SIZE_DOUBLE, 1'b0),
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
            base = 64'h0000_0000_0000_0400;
            for (access_index = 0; access_index < STREAM_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + access_index*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                    $display("FAIL sequential stream data addr=%016x", addr);
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
            base = 64'h0000_0000_0000_0600;
            for (access_index = 0; access_index < STREAM_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + access_index*(2*LINE_BYTES);
                cpu_read(addr, actual);
                if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                    $display("FAIL fixed-stride data addr=%016x", addr);
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
            base = 64'h0000_0000_0000_0800;
            for (access_index = 0; access_index < LOOP_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + (access_index % 2)*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                    $display("FAIL localized loop data addr=%016x", addr);
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
            base = 64'h0000_0000_0000_0a00;
            active_lines = NUM_WAYS + 1;
            repetitions = 4;
            total_accesses = active_lines * repetitions;
            for (access_index = 0; access_index < total_accesses;
                 access_index = access_index + 1) begin
                addr = base + (access_index % active_lines)*CONFLICT_STRIDE;
                cpu_read(addr, actual);
                if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                    $display("FAIL conflict-thrash data addr=%016x", addr);
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
            base = 64'h0000_0000_0000_0c00;
            for (access_index = 0; access_index < POINTER_ACCESSES;
                 access_index = access_index + 1) begin
                addr = base + pointer_line[access_index]*LINE_BYTES;
                cpu_read(addr, actual);
                if (actual !== golden_load(addr, SIZE_DOUBLE, 1'b0)) begin
                    $display("FAIL pointer-chase data addr=%016x", addr);
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
        integer trace_size;
        integer trace_unsigned;
        integer accesses;
        reg [8*256-1:0] trace_line;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [DATA_WIDTH-1:0] actual;
        logic [1:0] size;
        logic unsigned_load;
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
                    trace_size = -1;
                    trace_unsigned = 0;
                    addr = '0;
                    data = '0;
                    scan_count = $sscanf(trace_line, "%d %d %d %h %h",
                                         operation, trace_size,
                                         trace_unsigned, addr, data);
                    if (scan_count >= 1) begin
                        case (operation)
                            0: begin
                                if (scan_count != 4 ||
                                    trace_size < 0 || trace_size > 3 ||
                                    trace_unsigned < 0 || trace_unsigned > 1) begin
                                    $fatal(1, "invalid trace load at line %0d",
                                           trace_line_number);
                                end
                                size = trace_size;
                                unsigned_load = trace_unsigned != 0;
                                cpu_load(addr, size, unsigned_load, actual);
                                if (actual !== golden_load(addr, size,
                                                           unsigned_load)) begin
                                    $display("FAIL trace load line=%0d addr=%016x size=%0d unsigned=%0d expected=%016x actual=%016x",
                                             trace_line_number, addr, size,
                                             unsigned_load,
                                             golden_load(addr, size,
                                                         unsigned_load),
                                             actual);
                                    errors = errors + 1;
                                end
                                accesses = accesses + 1;
                            end
                            1: begin
                                if (scan_count != 5 ||
                                    trace_size < 0 || trace_size > 3) begin
                                    $fatal(1, "invalid trace store at line %0d",
                                           trace_line_number);
                                end
                                size = trace_size;
                                cpu_store(addr, size, data);
                                update_golden_store(addr, data, size);
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
                        memory[mem_index(mem_req_addr + b)] <=
                            mem_req_wdata[b*8 +: 8];
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
            stalled_cpu_error <= 1'b0;
            stalled_cpu_error_cause <= RSP_OK;
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
                if (!cpu_rsp_valid ||
                    cpu_rsp_rdata !== stalled_cpu_rdata ||
                    cpu_rsp_error !== stalled_cpu_error ||
                    cpu_rsp_error_cause !== stalled_cpu_error_cause) begin
                    $display("FAIL CPU response payload changed while stalled");
                    protocol_errors = protocol_errors + 1;
                end
            end
            stalled_cpu_rsp <= cpu_rsp_valid && !cpu_rsp_ready;
            if (cpu_rsp_valid && !cpu_rsp_ready) begin
                stalled_cpu_rdata <= cpu_rsp_rdata;
                stalled_cpu_error <= cpu_rsp_error;
                stalled_cpu_error_cause <= cpu_rsp_error_cause;
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
        cpu_req_size = SIZE_DOUBLE;
        cpu_req_unsigned = 1'b0;
        cpu_req_wdata = '0;
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
            test_rv64_alignment_faults();
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
