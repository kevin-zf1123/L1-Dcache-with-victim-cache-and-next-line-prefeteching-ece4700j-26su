`timescale 1ns/1ps

interface l1d_tb_if #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer DATA_WIDTH = 64,
    parameter integer LINE_BYTES = 16
) (
    input logic clk
);
    localparam integer LINE_BITS = LINE_BYTES * 8;

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
    integer duplicate_line_errors;

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
    logic [3:0] debug_state;
    logic debug_req_is_prefetch;
    logic [31:0] stat_pf_candidates;
    logic [31:0] stat_pf_admitted;
    logic [31:0] stat_pf_issued;
    logic [31:0] stat_pf_returned;
    logic [31:0] stat_pf_installed;
    logic [31:0] stat_pf_merged;
    logic [31:0] stat_pf_discarded;
    logic [31:0] stat_pf_cancelled;
    logic [31:0] stat_pf_unused_evicted;
    logic [31:0] stat_pf_vc_bypass;
    logic [31:0] stat_pf_caused_writebacks;
    logic [31:0] stat_pf_demand_block_cycles;
    logic [31:0] stat_pf_true_help;
    logic [31:0] stat_pf_true_pollution;
    logic [31:0] stat_pf_suppressed_quota;
    logic [31:0] stat_pf_suppressed_unsafe;
    logic [31:0] stat_pf_same_line_coalesced;
    logic [1:0] debug_pf_controller_state;
    logic debug_pf_mshr_valid;
    logic [ADDR_WIDTH-1:0] debug_pf_mshr_addr;
    logic [1:0] debug_pf_mshr_confidence;
endinterface

module tb_l1d_cache_oop #(
    parameter integer NUM_WAYS = 1,
    parameter integer ENABLE_PREFETCH = 0,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer NUM_SETS = 8,
    parameter integer LINE_BYTES = 16,
    parameter integer MEM_LATENCY = 2,
    parameter integer MEM_BACKPRESSURE_MODE = 1,
    parameter integer CPU_BACKPRESSURE_MODE = 0,
    parameter integer PREFETCH_POLICY = 1,
    parameter integer PF_OPT_LEVEL = 3,
    // Keep the historical producer as the default for regression identity.
    parameter integer PRODUCER_PROFILE = 0,
    parameter integer PRODUCER_GAP = 1
);
    localparam integer ADDR_WIDTH = 64;
    localparam integer DATA_WIDTH = 64;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(NUM_SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - OFFSET_BITS - SET_BITS;
    localparam integer MEM_BYTES = 16384;
    localparam integer TRACE_LINE_BYTES = 4096;
    localparam integer CONFLICT_STRIDE = NUM_SETS * LINE_BYTES;
    localparam logic [1:0] SIZE_BYTE   = 2'b00;
    localparam logic [1:0] SIZE_HALF   = 2'b01;
    localparam logic [1:0] SIZE_WORD   = 2'b10;
    localparam logic [1:0] SIZE_DOUBLE = 2'b11;
    localparam logic [1:0] RSP_OK                = 2'b00;
    localparam logic [1:0] RSP_LOAD_MISALIGNED  = 2'b01;
    localparam logic [1:0] RSP_STORE_MISALIGNED = 2'b10;
    localparam logic [3:0] ST_VC_SWAP = 4'd3;

    logic clk;
    integer producer_profile;
    integer producer_gap;
    integer trace_plusarg_status;
    integer producer_plusarg_status;
    string run_config_id;
    string run_trace_id;
    l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) bus(clk);

    l1d_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .ENABLE_PREFETCH(ENABLE_PREFETCH),
        .PREFETCH_POLICY(PREFETCH_POLICY),
        .PF_OPT_LEVEL(PF_OPT_LEVEL)
    ) dut (
        .clk(clk),
        .rst_n(bus.rst_n),
        .cfg_prefetch_enable(bus.cfg_prefetch_enable),
        .cfg_next_line_enable(bus.cfg_next_line_enable),
        .ext_prefetch_valid(bus.ext_prefetch_valid),
        .ext_prefetch_ready(bus.ext_prefetch_ready),
        .ext_prefetch_addr(bus.ext_prefetch_addr),
        .cpu_req_valid(bus.cpu_req_valid),
        .cpu_req_ready(bus.cpu_req_ready),
        .cpu_req_addr(bus.cpu_req_addr),
        .cpu_req_write(bus.cpu_req_write),
        .cpu_req_size(bus.cpu_req_size),
        .cpu_req_unsigned(bus.cpu_req_unsigned),
        .cpu_req_wdata(bus.cpu_req_wdata),
        .cpu_rsp_valid(bus.cpu_rsp_valid),
        .cpu_rsp_ready(bus.cpu_rsp_ready),
        .cpu_rsp_rdata(bus.cpu_rsp_rdata),
        .cpu_rsp_error(bus.cpu_rsp_error),
        .cpu_rsp_error_cause(bus.cpu_rsp_error_cause),
        .mem_req_valid(bus.mem_req_valid),
        .mem_req_ready(bus.mem_req_ready),
        .mem_req_write(bus.mem_req_write),
        .mem_req_addr(bus.mem_req_addr),
        .mem_req_wdata(bus.mem_req_wdata),
        .mem_rsp_valid(bus.mem_rsp_valid),
        .mem_rsp_rdata(bus.mem_rsp_rdata),
        .stat_cpu_hits(bus.stat_cpu_hits),
        .stat_cpu_misses(bus.stat_cpu_misses),
        .stat_victim_hits(bus.stat_victim_hits),
        .stat_writebacks(bus.stat_writebacks),
        .stat_prefetch_fills(bus.stat_prefetch_fills),
        .stat_prefetch_useful(bus.stat_prefetch_useful),
        .stat_prefetch_useless(bus.stat_prefetch_useless),
        .stat_prefetch_pollution(bus.stat_prefetch_pollution),
        .stat_prefetch_dropped(bus.stat_prefetch_dropped),
        .cache_idle(bus.cache_idle),
        .event_cpu_access(bus.event_cpu_access),
        .event_cpu_hit(bus.event_cpu_hit),
        .event_cpu_miss(bus.event_cpu_miss),
        .event_victim_hit(bus.event_victim_hit),
        .event_writeback(bus.event_writeback),
        .event_prefetch_fill(bus.event_prefetch_fill),
        .event_prefetch_useful(bus.event_prefetch_useful),
        .event_prefetch_useless(bus.event_prefetch_useless),
        .event_prefetch_pollution(bus.event_prefetch_pollution),
        .event_prefetch_dropped(bus.event_prefetch_dropped),
        .debug_state(bus.debug_state),
        .debug_req_is_prefetch(bus.debug_req_is_prefetch),
        .stat_pf_candidates(bus.stat_pf_candidates),
        .stat_pf_admitted(bus.stat_pf_admitted),
        .stat_pf_issued(bus.stat_pf_issued),
        .stat_pf_returned(bus.stat_pf_returned),
        .stat_pf_installed(bus.stat_pf_installed),
        .stat_pf_merged(bus.stat_pf_merged),
        .stat_pf_discarded(bus.stat_pf_discarded),
        .stat_pf_cancelled(bus.stat_pf_cancelled),
        .stat_pf_unused_evicted(bus.stat_pf_unused_evicted),
        .stat_pf_vc_bypass(bus.stat_pf_vc_bypass),
        .stat_pf_caused_writebacks(bus.stat_pf_caused_writebacks),
        .stat_pf_demand_block_cycles(bus.stat_pf_demand_block_cycles),
        .stat_pf_true_help(bus.stat_pf_true_help),
        .stat_pf_true_pollution(bus.stat_pf_true_pollution),
        .stat_pf_suppressed_quota(bus.stat_pf_suppressed_quota),
        .stat_pf_suppressed_unsafe(bus.stat_pf_suppressed_unsafe),
        .stat_pf_same_line_coalesced(bus.stat_pf_same_line_coalesced),
        .debug_pf_controller_state(bus.debug_pf_controller_state),
        .debug_pf_mshr_valid(bus.debug_pf_mshr_valid),
        .debug_pf_mshr_addr(bus.debug_pf_mshr_addr),
        .debug_pf_mshr_confidence(bus.debug_pf_mshr_confidence)
    );

    string dump_vcd_path;
    initial begin
        run_trace_id = "synthetic";
        if (!$value$plusargs("CONFIG_ID=%s", run_config_id)) begin
            if (NUM_WAYS == 1 && NUM_SETS == 8 &&
                VICTIM_ENTRIES == 4 && ENABLE_PREFETCH == 0) begin
                run_config_id = "dm_s8_vc4_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 4 && ENABLE_PREFETCH == 0) begin
                run_config_id = "2w_s4_vc4_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 8 && ENABLE_PREFETCH == 0) begin
                run_config_id = "2w_s4_vc8_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 4 && ENABLE_PREFETCH != 0) begin
                run_config_id = "2w_s4_vc4_pf1";
            end else begin
                run_config_id = $sformatf("%0dw_s%0d_vc%0d_pf%0d",
                                          NUM_WAYS, NUM_SETS,
                                          VICTIM_ENTRIES, ENABLE_PREFETCH);
            end
        end
        trace_plusarg_status = $value$plusargs("TRACE_ID=%s", run_trace_id);
        if ($value$plusargs("DUMP_VCD=%s", dump_vcd_path)) begin
            $dumpfile(dump_vcd_path);
            $dumpvars(0, clk);
            $dumpvars(0, dut);
        end
    end

    always #5 clk = ~clk;

    function automatic logic [ADDR_WIDTH-1:0] compose_debug_line_address(
        input logic [TAG_BITS-1:0] tag,
        input integer set_index
    );
        logic [SET_BITS-1:0] set_bits;
        begin
            set_bits = set_index[SET_BITS-1:0];
            compose_debug_line_address =
                {tag, set_bits, {OFFSET_BITS{1'b0}}};
        end
    endfunction

    function automatic integer count_unused_resident;
        integer way_index;
        integer set_index;
        integer victim_index;
        begin
            count_unused_resident = 0;
            for (way_index = 0; way_index < NUM_WAYS;
                 way_index = way_index + 1) begin
                for (set_index = 0; set_index < NUM_SETS;
                     set_index = set_index + 1) begin
                    if (dut.valid_bits[way_index][set_index] &&
                        dut.prefetched_bits[way_index][set_index]) begin
                        count_unused_resident = count_unused_resident + 1;
                    end
                end
            end
            for (victim_index = 0; victim_index < VICTIM_ENTRIES;
                 victim_index = victim_index + 1) begin
                if (dut.vc_valid[victim_index] &&
                    dut.vc_prefetched[victim_index]) begin
                    count_unused_resident = count_unused_resident + 1;
                end
            end
        end
    endfunction

    function automatic integer trace_phase_code(
        input reg [8*TRACE_LINE_BYTES-1:0] line
    );
        integer c0;
        integer c1;
        integer c2;
        integer c3;
        integer c4;
        integer c5;
        integer c6;
        integer c7;
        integer c8;
        integer c9;
        integer c10;
        integer c11;
        integer c12;
        integer c13;
        integer c14;
        integer count;
        begin
            count = $sscanf(line,
                            "%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c",
                            c0, c1, c2, c3, c4, c5, c6, c7,
                            c8, c9, c10, c11, c12, c13, c14);
            trace_phase_code = 0;
            if (count >= 14 &&
                c0 == 8'h23 && c1 == 8'h20 &&
                c2 == 8'h50 && c3 == 8'h48 && c4 == 8'h41 &&
                c5 == 8'h53 && c6 == 8'h45 && c7 == 8'h20 &&
                c8 == 8'h77 && c9 == 8'h61 && c10 == 8'h72 &&
                c11 == 8'h6d && c12 == 8'h75 && c13 == 8'h70) begin
                trace_phase_code = 1;
            end else if (count >= 15 &&
                         c0 == 8'h23 && c1 == 8'h20 &&
                         c2 == 8'h50 && c3 == 8'h48 && c4 == 8'h41 &&
                         c5 == 8'h53 && c6 == 8'h45 && c7 == 8'h20 &&
                         c8 == 8'h6d && c9 == 8'h65 && c10 == 8'h61 &&
                         c11 == 8'h73 && c12 == 8'h75 && c13 == 8'h72 &&
                         c14 == 8'h65) begin
                trace_phase_code = 2;
            end
        end
    endfunction

    function automatic integer trace_is_comment(
        input reg [8*TRACE_LINE_BYTES-1:0] line
    );
        integer first_character;
        integer count;
        begin
            count = $sscanf(line, "%c", first_character);
            trace_is_comment = (count == 1 && first_character == 8'h23);
        end
    endfunction

    generate
        genvar dbg_way_a;
        genvar dbg_way_b;
        genvar dbg_set;
        genvar dbg_vc_a;
        genvar dbg_vc_b;

        for (dbg_set = 0; dbg_set < NUM_SETS; dbg_set = dbg_set + 1) begin : gen_l1_l1_dup_set
            for (dbg_way_a = 0; dbg_way_a < NUM_WAYS; dbg_way_a = dbg_way_a + 1) begin : gen_l1_l1_dup_a
                for (dbg_way_b = dbg_way_a + 1; dbg_way_b < NUM_WAYS; dbg_way_b = dbg_way_b + 1) begin : gen_l1_l1_dup_b
                    always @(posedge clk) begin
                        if (bus.rst_n &&
                            bus.debug_state != ST_VC_SWAP &&
                            dut.valid_bits[dbg_way_a][dbg_set] &&
                            dut.valid_bits[dbg_way_b][dbg_set] &&
                            dut.debug_tag[dbg_way_a][dbg_set] ==
                            dut.debug_tag[dbg_way_b][dbg_set]) begin
                            $display("FAIL duplicate L1 line set=%0d way_a=%0d way_b=%0d addr=%016x state=%0d",
                                     dbg_set, dbg_way_a, dbg_way_b,
                                     compose_debug_line_address(
                                         dut.debug_tag[dbg_way_a][dbg_set],
                                         dbg_set),
                                     bus.debug_state);
                            bus.duplicate_line_errors = bus.duplicate_line_errors + 1;
                        end
                    end
                end
            end
        end

        for (dbg_set = 0; dbg_set < NUM_SETS; dbg_set = dbg_set + 1) begin : gen_l1_vc_dup_set
            for (dbg_way_a = 0; dbg_way_a < NUM_WAYS; dbg_way_a = dbg_way_a + 1) begin : gen_l1_vc_dup_way
                for (dbg_vc_a = 0; dbg_vc_a < VICTIM_ENTRIES; dbg_vc_a = dbg_vc_a + 1) begin : gen_l1_vc_dup_entry
                    always @(posedge clk) begin
                        if (bus.rst_n &&
                            bus.debug_state != ST_VC_SWAP &&
                            dut.valid_bits[dbg_way_a][dbg_set] &&
                            dut.vc_valid[dbg_vc_a] &&
                            compose_debug_line_address(
                                dut.debug_tag[dbg_way_a][dbg_set],
                                dbg_set) == dut.vc_addr[dbg_vc_a]) begin
                            $display("FAIL duplicate L1/victim line set=%0d way=%0d victim=%0d addr=%016x state=%0d",
                                     dbg_set, dbg_way_a, dbg_vc_a,
                                     dut.vc_addr[dbg_vc_a], bus.debug_state);
                            bus.duplicate_line_errors = bus.duplicate_line_errors + 1;
                        end
                    end
                end
            end
        end

        for (dbg_vc_a = 0; dbg_vc_a < VICTIM_ENTRIES; dbg_vc_a = dbg_vc_a + 1) begin : gen_vc_vc_dup_a
            for (dbg_vc_b = dbg_vc_a + 1; dbg_vc_b < VICTIM_ENTRIES; dbg_vc_b = dbg_vc_b + 1) begin : gen_vc_vc_dup_b
                always @(posedge clk) begin
                    if (bus.rst_n &&
                        bus.debug_state != ST_VC_SWAP &&
                        dut.vc_valid[dbg_vc_a] &&
                        dut.vc_valid[dbg_vc_b] &&
                        dut.vc_addr[dbg_vc_a] == dut.vc_addr[dbg_vc_b]) begin
                        $display("FAIL duplicate victim line victim_a=%0d victim_b=%0d addr=%016x state=%0d",
                                 dbg_vc_a, dbg_vc_b,
                                 dut.vc_addr[dbg_vc_a], bus.debug_state);
                        bus.duplicate_line_errors = bus.duplicate_line_errors + 1;
                    end
                end
            end
        end
    endgenerate

    class l1d_transaction;
        string name;
        logic [ADDR_WIDTH-1:0] addr;
        logic write;
        logic [1:0] size;
        logic unsigned_load;
        logic [DATA_WIDTH-1:0] data;

        function new(
            input string name_i = "",
            input logic [ADDR_WIDTH-1:0] addr_i = '0,
            input logic write_i = 1'b0,
            input logic [1:0] size_i = SIZE_DOUBLE,
            input logic unsigned_i = 1'b0,
            input logic [DATA_WIDTH-1:0] data_i = '0
        );
            name = name_i;
            addr = addr_i;
            write = write_i;
            size = size_i;
            unsigned_load = unsigned_i;
            data = data_i;
        endfunction
    endclass

    class l1d_scoreboard;
        byte unsigned memory [0:MEM_BYTES-1];
        byte unsigned golden_memory [0:MEM_BYTES-1];

        function integer access_bytes(input logic [1:0] size);
            case (size)
                SIZE_BYTE:   access_bytes = 1;
                SIZE_HALF:   access_bytes = 2;
                SIZE_WORD:   access_bytes = 4;
                default:     access_bytes = 8;
            endcase
        endfunction

        function integer mem_index(input logic [ADDR_WIDTH-1:0] addr);
            mem_index = addr % MEM_BYTES;
        endfunction

        function void initialize();
            integer b;
            for (b = 0; b < MEM_BYTES; b = b + 1) begin
                memory[b] = (b * 13 + 7) & 8'hff;
                golden_memory[b] = memory[b];
            end
        endfunction

        function logic [LINE_BITS-1:0] load_line(input logic [ADDR_WIDTH-1:0] addr);
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

        function logic [DATA_WIDTH-1:0] load_data(
            input logic use_golden,
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
                        if (use_golden) begin
                            raw[b*8 +: 8] = golden_memory[mem_index(addr + b)];
                        end else begin
                            raw[b*8 +: 8] = memory[mem_index(addr + b)];
                        end
                    end
                end
                case (size)
                    SIZE_BYTE: begin
                        load_data = unsigned_load ?
                            {{(DATA_WIDTH-8){1'b0}}, raw[7:0]} :
                            {{(DATA_WIDTH-8){raw[7]}}, raw[7:0]};
                    end
                    SIZE_HALF: begin
                        load_data = unsigned_load ?
                            {{(DATA_WIDTH-16){1'b0}}, raw[15:0]} :
                            {{(DATA_WIDTH-16){raw[15]}}, raw[15:0]};
                    end
                    SIZE_WORD: begin
                        load_data = unsigned_load ?
                            {{(DATA_WIDTH-32){1'b0}}, raw[31:0]} :
                            {{(DATA_WIDTH-32){raw[31]}}, raw[31:0]};
                    end
                    default: begin
                        load_data = raw;
                    end
                endcase
            end
        endfunction

        function logic [DATA_WIDTH-1:0] golden_load(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [1:0] size,
            input logic unsigned_load
        );
            golden_load = load_data(1'b1, addr, size, unsigned_load);
        endfunction

        function logic [DATA_WIDTH-1:0] backing_load(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [1:0] size,
            input logic unsigned_load
        );
            backing_load = load_data(1'b0, addr, size, unsigned_load);
        endfunction

        function void update_golden_store(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [DATA_WIDTH-1:0] data,
            input logic [1:0] size
        );
            integer b;
            for (b = 0; b < DATA_WIDTH/8; b = b + 1) begin
                if (b < access_bytes(size)) begin
                    golden_memory[mem_index(addr + b)] = data[b*8 +: 8];
                end
            end
        endfunction

        function void write_back_line(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [LINE_BITS-1:0] data
        );
            integer b;
            for (b = 0; b < LINE_BYTES; b = b + 1) begin
                memory[mem_index(addr + b)] = data[b*8 +: 8];
            end
        endfunction
    endclass

    class l1d_line_mem_model;
        virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif;
        l1d_scoreboard sb;
        integer accepted_reads;
        integer accepted_demand_reads;
        integer accepted_prefetch_reads;
        integer accepted_writes;
        integer cycles;
        integer latency;
        integer backpressure_mode;
        integer ready_phase;
        integer lfsr;
        logic read_pending;
        logic [ADDR_WIDTH-1:0] read_addr;
        integer read_countdown;

        function new(
            virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif_i,
            l1d_scoreboard sb_i
        );
            vif = vif_i;
            sb = sb_i;
            latency = MEM_LATENCY;
            backpressure_mode = MEM_BACKPRESSURE_MODE;
            reset_state();
        endfunction

        function void reset_state();
            accepted_reads = 0;
            accepted_demand_reads = 0;
            accepted_prefetch_reads = 0;
            accepted_writes = 0;
            cycles = 0;
            ready_phase = 0;
            lfsr = 32'h4700_2026;
            read_pending = 1'b0;
            read_addr = '0;
            read_countdown = 0;
        endfunction

        function logic ready_allowed();
            begin
                case (backpressure_mode)
                    0: ready_allowed = 1'b1;
                    1: ready_allowed = (ready_phase[1:0] != 2'b00);
                    default: ready_allowed = lfsr[0] || lfsr[3];
                endcase
            end
        endfunction

        task run();
            integer countdown_next;
            begin
                vif.mem_rsp_valid = 1'b0;
                vif.mem_rsp_rdata = '0;
                vif.mem_req_ready = 1'b0;
                forever begin
                    @(negedge vif.clk);
                    if (!vif.rst_n) begin
                        vif.mem_req_ready = 1'b0;
                    end else begin
                        vif.mem_req_ready = (!read_pending) && ready_allowed();
                    end

                    @(posedge vif.clk);
                    if (!vif.rst_n) begin
                        reset_state();
                        vif.mem_rsp_valid <= 1'b0;
                        vif.mem_rsp_rdata <= '0;
                    end else begin
                        vif.mem_rsp_valid <= 1'b0;
                        cycles = cycles + 1;
                        ready_phase = ready_phase + 1;
                        lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

                        if (read_pending) begin
                            if (read_countdown == 0) begin
                                vif.mem_rsp_valid <= 1'b1;
                                vif.mem_rsp_rdata <= sb.load_line(read_addr);
                                read_pending = 1'b0;
                            end else begin
                                countdown_next = read_countdown - 1;
                                read_countdown = countdown_next;
                            end
                        end

                        if (vif.mem_req_valid && vif.mem_req_ready) begin
                            if (vif.mem_req_write) begin
                                accepted_writes = accepted_writes + 1;
                                sb.write_back_line(vif.mem_req_addr,
                                                   vif.mem_req_wdata);
                            end else begin
                                accepted_reads = accepted_reads + 1;
                                if (vif.debug_req_is_prefetch) begin
                                    accepted_prefetch_reads =
                                        accepted_prefetch_reads + 1;
                                end else begin
                                    accepted_demand_reads =
                                        accepted_demand_reads + 1;
                                end
                                read_pending = 1'b1;
                                read_addr = vif.mem_req_addr;
                                read_countdown = (latency < 0) ? 0 : latency;
                            end
                        end
                    end
                end
            end
        endtask
    endclass

    class l1d_cpu_driver;
        virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif;
        l1d_scoreboard sb;
        integer profile;
        integer gap;

        function new(
            virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif_i,
            l1d_scoreboard sb_i,
            integer profile_i,
            integer gap_i
        );
            vif = vif_i;
            sb = sb_i;
            profile = profile_i;
            gap = gap_i;
        endfunction

        task drive_defaults();
            begin
                vif.cpu_req_valid = 1'b0;
                vif.cpu_req_addr = '0;
                vif.cpu_req_write = 1'b0;
                vif.cpu_req_size = SIZE_DOUBLE;
                vif.cpu_req_unsigned = 1'b0;
                vif.cpu_req_wdata = '0;
                vif.cpu_rsp_ready = 1'b1;
                vif.cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
                vif.cfg_next_line_enable = (ENABLE_PREFETCH != 0);
                vif.ext_prefetch_valid = 1'b0;
                vif.ext_prefetch_addr = '0;
            end
        endtask

        task reset_cache(input logic enable_prefetch, input logic next_line_enable);
            begin
                drive_defaults();
                vif.cfg_prefetch_enable = enable_prefetch;
                vif.cfg_next_line_enable = next_line_enable;
                vif.rst_n = 1'b0;
                repeat (3) @(posedge vif.clk);
                @(negedge vif.clk);
                vif.rst_n = 1'b1;
                repeat (2) @(posedge vif.clk);
            end
        endtask

        task cpu_request(
            input l1d_transaction tr,
            output logic [DATA_WIDTH-1:0] rsp_data,
            output logic rsp_error,
            output logic [1:0] rsp_error_cause
        );
            integer timeout;
            begin
                @(negedge vif.clk);
                vif.cpu_req_valid = 1'b1;
                vif.cpu_req_addr = tr.addr;
                vif.cpu_req_write = tr.write;
                vif.cpu_req_size = tr.size;
                vif.cpu_req_unsigned = tr.unsigned_load;
                vif.cpu_req_wdata = tr.data;
                timeout = 0;
                while (!vif.cpu_req_ready) begin
                    @(posedge vif.clk);
                    timeout = timeout + 1;
                    if (timeout > 500) $fatal(1, "CPU request timeout: %s", tr.name);
                end
                @(posedge vif.clk);
                @(negedge vif.clk);
                vif.cpu_req_valid = 1'b0;
                vif.cpu_req_addr = '0;
                vif.cpu_req_write = 1'b0;
                vif.cpu_req_size = SIZE_DOUBLE;
                vif.cpu_req_unsigned = 1'b0;
                vif.cpu_req_wdata = '0;

                timeout = 0;
                while (!vif.cpu_rsp_valid) begin
                    @(posedge vif.clk);
                    timeout = timeout + 1;
                    if (timeout > 1000) $fatal(1, "CPU response timeout: %s", tr.name);
                end
                rsp_data = vif.cpu_rsp_rdata;
                rsp_error = vif.cpu_rsp_error;
                rsp_error_cause = vif.cpu_rsp_error_cause;
                if (profile == 0) begin
                    @(posedge vif.clk);
                end else if (profile == 2) begin
                    repeat (gap) @(posedge vif.clk);
                end
            end
        endtask

        task external_prefetch(input logic [ADDR_WIDTH-1:0] addr);
            integer timeout;
            begin
                if (ENABLE_PREFETCH == 0 || !vif.cfg_prefetch_enable) begin
                    return;
                end
                @(negedge vif.clk);
                vif.ext_prefetch_valid = 1'b1;
                vif.ext_prefetch_addr = addr;
                timeout = 0;
                while (!vif.ext_prefetch_ready) begin
                    @(posedge vif.clk);
                    timeout = timeout + 1;
                    if (timeout > 300) $fatal(1, "external prefetch timeout");
                end
                @(posedge vif.clk);
                @(negedge vif.clk);
                vif.ext_prefetch_valid = 1'b0;
                vif.ext_prefetch_addr = '0;
            end
        endtask
    endclass

    class l1d_monitor;
        virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif;
        integer protocol_errors;
        integer watchdog_errors;
        integer latency_min;
        integer latency_max;
        integer latency_sum;
        integer latency_count;
        integer current_latency;
        logic response_active;
        logic stalled_mem_req;
        logic stalled_mem_write;
        logic [ADDR_WIDTH-1:0] stalled_mem_addr;
        logic [LINE_BITS-1:0] stalled_mem_wdata;
        logic stalled_cpu_rsp;
        logic [DATA_WIDTH-1:0] stalled_cpu_rdata;
        logic stalled_cpu_error;
        logic [1:0] stalled_cpu_error_cause;
        logic watchdog_active;
        integer watchdog_age;
        logic [3:0] last_state;

        function new(virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif_i);
            vif = vif_i;
            protocol_errors = 0;
            watchdog_errors = 0;
            reset_metrics();
        endfunction

        function void reset_metrics();
            latency_min = 32'h7fff_ffff;
            latency_max = 0;
            latency_sum = 0;
            latency_count = 0;
            current_latency = 0;
            response_active = 1'b0;
            stalled_mem_req = 1'b0;
            stalled_cpu_rsp = 1'b0;
            watchdog_active = 1'b0;
            watchdog_age = 0;
            last_state = '0;
        endfunction

        function string state_name(input logic [3:0] state);
            case (state)
                4'd0: state_name = "idle";
                4'd1: state_name = "lookup";
                4'd2: state_name = "hit_write";
                4'd3: state_name = "victim_swap";
                4'd4: state_name = "dirty_writeback_request";
                4'd5: state_name = "victim_insert";
                4'd6: state_name = "memory_read_request";
                4'd7: state_name = "memory_wait";
                4'd8: state_name = "install";
                4'd9: state_name = "response_hold";
                default: state_name = "unknown";
            endcase
        endfunction

        task run();
            begin
                forever begin
                    @(posedge vif.clk);
                    if (!vif.rst_n) begin
                        reset_metrics();
                    end else begin
                        // cache_idle is a quiescence signal, so a queued
                        // external candidate intentionally deasserts it even
                        // though demand-priority arbitration may still accept
                        // a CPU request from ST_IDLE.  Check the acceptance
                        // state directly instead of conflating ready with
                        // whole-cache quiescence.
                        if (vif.cpu_req_valid && vif.cpu_req_ready &&
                            vif.debug_state != 4'd0) begin
                            $display("FAIL CPU request accepted outside idle state=%s",
                                     state_name(vif.debug_state));
                            protocol_errors = protocol_errors + 1;
                        end

                        if (stalled_mem_req) begin
                            if (!vif.mem_req_valid ||
                                vif.mem_req_write !== stalled_mem_write ||
                                vif.mem_req_addr !== stalled_mem_addr ||
                                vif.mem_req_wdata !== stalled_mem_wdata) begin
                                $display("FAIL memory request changed while stalled state=%s",
                                         state_name(vif.debug_state));
                                protocol_errors = protocol_errors + 1;
                            end
                        end
                        stalled_mem_req = vif.mem_req_valid && !vif.mem_req_ready;
                        if (vif.mem_req_valid && !vif.mem_req_ready) begin
                            stalled_mem_write = vif.mem_req_write;
                            stalled_mem_addr = vif.mem_req_addr;
                            stalled_mem_wdata = vif.mem_req_wdata;
                        end

                        if (stalled_cpu_rsp) begin
                            if (!vif.cpu_rsp_valid ||
                                vif.cpu_rsp_rdata !== stalled_cpu_rdata ||
                                vif.cpu_rsp_error !== stalled_cpu_error ||
                                vif.cpu_rsp_error_cause !== stalled_cpu_error_cause) begin
                                $display("FAIL CPU response payload changed while stalled state=%s",
                                         state_name(vif.debug_state));
                                protocol_errors = protocol_errors + 1;
                            end
                        end
                        stalled_cpu_rsp = vif.cpu_rsp_valid && !vif.cpu_rsp_ready;
                        if (vif.cpu_rsp_valid && !vif.cpu_rsp_ready) begin
                            stalled_cpu_rdata = vif.cpu_rsp_rdata;
                            stalled_cpu_error = vif.cpu_rsp_error;
                            stalled_cpu_error_cause = vif.cpu_rsp_error_cause;
                        end

                        if (vif.cpu_req_valid && vif.cpu_req_ready) begin
                            response_active = 1'b1;
                            current_latency = 0;
                            watchdog_active = 1'b1;
                            watchdog_age = 0;
                        end else if (response_active) begin
                            current_latency = current_latency + 1;
                        end

                        if (response_active &&
                            vif.cpu_rsp_valid && vif.cpu_rsp_ready) begin
                            response_active = 1'b0;
                            latency_count = latency_count + 1;
                            latency_sum = latency_sum + current_latency;
                            if (current_latency < latency_min) latency_min = current_latency;
                            if (current_latency > latency_max) latency_max = current_latency;
                        end

                        if (vif.mem_req_valid && vif.mem_req_ready) begin
                            watchdog_active = 1'b1;
                            watchdog_age = 0;
                        end
                        if (watchdog_active) begin
                            if (vif.debug_state != last_state ||
                                vif.mem_rsp_valid ||
                                (vif.cpu_rsp_valid && vif.cpu_rsp_ready) ||
                                vif.event_cpu_hit || vif.event_cpu_miss ||
                                vif.event_victim_hit || vif.event_writeback ||
                                vif.event_prefetch_fill || vif.event_prefetch_useful ||
                                vif.event_prefetch_useless || vif.event_prefetch_pollution ||
                                vif.event_prefetch_dropped) begin
                                watchdog_age = 0;
                            end else begin
                                watchdog_age = watchdog_age + 1;
                            end
                            if (vif.cache_idle && !vif.mem_req_valid && !vif.mem_rsp_valid) begin
                                watchdog_active = 1'b0;
                            end else if (watchdog_age > 600) begin
                                $display("FAIL watchdog timeout state=%s req_is_prefetch=%0d",
                                         state_name(vif.debug_state),
                                         vif.debug_req_is_prefetch);
                                watchdog_errors = watchdog_errors + 1;
                                watchdog_age = 0;
                            end
                        end
                        last_state = vif.debug_state;
                    end
                end
            end
        endtask

        function integer latency_avg_x100();
            if (latency_count == 0) begin
                latency_avg_x100 = 0;
            end else begin
                latency_avg_x100 = (latency_sum * 100) / latency_count;
            end
        endfunction
    endclass

    class l1d_sequence;
        virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif;
        l1d_scoreboard sb;
        l1d_line_mem_model mem;
        l1d_cpu_driver driver;
        l1d_monitor monitor;
        integer errors;
        integer protocol_base;
        integer watchdog_base;
        integer duplicate_base;
        integer errors_base;
        logic case_prefetch_enable;
        logic case_next_line_enable;
        integer metric_hits_base;
        integer metric_misses_base;
        integer metric_victim_hits_base;
        integer metric_writebacks_base;
        integer metric_fills_base;
        integer metric_useful_base;
        integer metric_useless_base;
        integer metric_pollution_base;
        integer metric_dropped_base;
        integer metric_demand_reads_base;
        integer metric_prefetch_reads_base;
        integer metric_writes_base;
        integer metric_cycles_base;
        integer metric_pf_candidates_base;
        integer metric_pf_admitted_base;
        integer metric_pf_issued_base;
        integer metric_pf_returned_base;
        integer metric_pf_installed_base;
        integer metric_pf_merged_base;
        integer metric_pf_discarded_base;
        integer metric_pf_cancelled_base;
        integer metric_pf_unused_evicted_base;
        integer metric_pf_vc_bypass_base;
        integer metric_pf_caused_writebacks_base;
        integer metric_pf_demand_block_cycles_base;
        integer metric_pf_true_help_base;
        integer metric_pf_true_pollution_base;
        integer metric_pf_suppressed_quota_base;
        integer metric_pf_suppressed_unsafe_base;
        integer metric_pf_same_line_coalesced_base;

        function new(
            virtual l1d_tb_if #(ADDR_WIDTH, DATA_WIDTH, LINE_BYTES) vif_i,
            l1d_scoreboard sb_i,
            l1d_line_mem_model mem_i,
            l1d_cpu_driver driver_i,
            l1d_monitor monitor_i
        );
            vif = vif_i;
            sb = sb_i;
            mem = mem_i;
            driver = driver_i;
            monitor = monitor_i;
            errors = 0;
        endfunction

        task start_case(
            input string name,
            input logic enable_prefetch,
            input logic next_line_enable
        );
            begin
                $display("TEST_PHASE3 name=%s ways=%0d vc=%0d prefetch=%0d next_line=%0d mem_latency=%0d mem_bp=%0d cpu_bp=%0d",
                         name, NUM_WAYS, VICTIM_ENTRIES, enable_prefetch,
                         next_line_enable, MEM_LATENCY, MEM_BACKPRESSURE_MODE,
                         CPU_BACKPRESSURE_MODE);
                sb.initialize();
                protocol_base = monitor.protocol_errors;
                watchdog_base = monitor.watchdog_errors;
                duplicate_base = vif.duplicate_line_errors;
                errors_base = errors;
                case_prefetch_enable = enable_prefetch;
                case_next_line_enable = next_line_enable;
                monitor.reset_metrics();
                driver.reset_cache(enable_prefetch, next_line_enable);
                snapshot_measurement_counters();
            end
        endtask

        task snapshot_measurement_counters();
            begin
                metric_hits_base = vif.stat_cpu_hits;
                metric_misses_base = vif.stat_cpu_misses;
                metric_victim_hits_base = vif.stat_victim_hits;
                metric_writebacks_base = vif.stat_writebacks;
                metric_fills_base = vif.stat_prefetch_fills;
                metric_useful_base = vif.stat_prefetch_useful;
                metric_useless_base = vif.stat_prefetch_useless;
                metric_pollution_base = vif.stat_prefetch_pollution;
                metric_dropped_base = vif.stat_prefetch_dropped;
                metric_demand_reads_base = mem.accepted_demand_reads;
                metric_prefetch_reads_base = mem.accepted_prefetch_reads;
                metric_writes_base = mem.accepted_writes;
                metric_cycles_base = mem.cycles;
                metric_pf_candidates_base = vif.stat_pf_candidates;
                metric_pf_admitted_base = vif.stat_pf_admitted;
                metric_pf_issued_base = vif.stat_pf_issued;
                metric_pf_returned_base = vif.stat_pf_returned;
                metric_pf_installed_base = vif.stat_pf_installed;
                metric_pf_merged_base = vif.stat_pf_merged;
                metric_pf_discarded_base = vif.stat_pf_discarded;
                metric_pf_cancelled_base = vif.stat_pf_cancelled;
                metric_pf_unused_evicted_base = vif.stat_pf_unused_evicted;
                metric_pf_vc_bypass_base = vif.stat_pf_vc_bypass;
                metric_pf_caused_writebacks_base =
                    vif.stat_pf_caused_writebacks;
                metric_pf_demand_block_cycles_base =
                    vif.stat_pf_demand_block_cycles;
                metric_pf_true_help_base = vif.stat_pf_true_help;
                metric_pf_true_pollution_base = vif.stat_pf_true_pollution;
                metric_pf_suppressed_quota_base =
                    vif.stat_pf_suppressed_quota;
                metric_pf_suppressed_unsafe_base =
                    vif.stat_pf_suppressed_unsafe;
                metric_pf_same_line_coalesced_base =
                    vif.stat_pf_same_line_coalesced;
            end
        endtask

        task wait_for_quiescence();
            integer timeout;
            begin
                @(negedge vif.clk);
                vif.cfg_next_line_enable = 1'b0;
                timeout = 0;
                while (!vif.cache_idle || mem.read_pending || vif.mem_req_valid) begin
                    @(posedge vif.clk);
                    timeout = timeout + 1;
                    if (timeout > 1200) $fatal(1, "cache quiescence timeout");
                end
                repeat (2) @(posedge vif.clk);
            end
        endtask

        task report_workload(input string workload_name, input integer accesses);
            string status;
            integer failed;
            integer unused_resident;
            integer hits;
            integer misses;
            integer victim_hits;
            integer demand_reads;
            integer prefetch_reads;
            integer writes;
            integer writebacks;
            integer fills;
            integer useful;
            integer useless;
            integer pollution;
            integer dropped;
            integer service_cycles;
            integer pf_candidates;
            integer pf_admitted;
            integer pf_issued;
            integer pf_returned;
            integer pf_installed;
            integer pf_merged;
            integer pf_discarded;
            integer pf_cancelled;
            integer pf_unused_evicted;
            integer pf_vc_bypass;
            integer pf_caused_writebacks;
            integer pf_demand_block_cycles;
            integer pf_true_help;
            integer pf_true_pollution;
            integer pf_suppressed_quota;
            integer pf_suppressed_unsafe;
            integer pf_same_line_coalesced;
            integer timely_useful;
            begin
                wait_for_quiescence();
                hits = vif.stat_cpu_hits - metric_hits_base;
                misses = vif.stat_cpu_misses - metric_misses_base;
                victim_hits = vif.stat_victim_hits - metric_victim_hits_base;
                demand_reads = mem.accepted_demand_reads -
                               metric_demand_reads_base;
                prefetch_reads = mem.accepted_prefetch_reads -
                                 metric_prefetch_reads_base;
                writes = mem.accepted_writes - metric_writes_base;
                writebacks = vif.stat_writebacks - metric_writebacks_base;
                fills = vif.stat_prefetch_fills - metric_fills_base;
                useful = vif.stat_prefetch_useful - metric_useful_base;
                useless = vif.stat_prefetch_useless - metric_useless_base;
                pollution = vif.stat_prefetch_pollution - metric_pollution_base;
                dropped = vif.stat_prefetch_dropped - metric_dropped_base;
                service_cycles = mem.cycles - metric_cycles_base;
                pf_candidates = vif.stat_pf_candidates -
                                metric_pf_candidates_base;
                pf_admitted = vif.stat_pf_admitted - metric_pf_admitted_base;
                pf_issued = vif.stat_pf_issued - metric_pf_issued_base;
                pf_returned = vif.stat_pf_returned - metric_pf_returned_base;
                pf_installed = vif.stat_pf_installed -
                               metric_pf_installed_base;
                pf_merged = vif.stat_pf_merged - metric_pf_merged_base;
                pf_discarded = vif.stat_pf_discarded -
                               metric_pf_discarded_base;
                pf_cancelled = vif.stat_pf_cancelled -
                               metric_pf_cancelled_base;
                pf_unused_evicted = vif.stat_pf_unused_evicted -
                                    metric_pf_unused_evicted_base;
                pf_vc_bypass = vif.stat_pf_vc_bypass -
                               metric_pf_vc_bypass_base;
                pf_caused_writebacks = vif.stat_pf_caused_writebacks -
                                       metric_pf_caused_writebacks_base;
                pf_demand_block_cycles = vif.stat_pf_demand_block_cycles -
                                         metric_pf_demand_block_cycles_base;
                pf_true_help = vif.stat_pf_true_help -
                               metric_pf_true_help_base;
                pf_true_pollution = vif.stat_pf_true_pollution -
                                    metric_pf_true_pollution_base;
                pf_suppressed_quota = vif.stat_pf_suppressed_quota -
                                      metric_pf_suppressed_quota_base;
                pf_suppressed_unsafe = vif.stat_pf_suppressed_unsafe -
                                       metric_pf_suppressed_unsafe_base;
                pf_same_line_coalesced = vif.stat_pf_same_line_coalesced -
                                         metric_pf_same_line_coalesced_base;
                timely_useful = useful;
                if (PREFETCH_POLICY == 1)
                    useful = timely_useful + pf_merged;
                if (hits + misses != accesses) begin
                    $display("FAIL workload accounting name=%s accesses=%0d hits_plus_misses=%0d",
                             workload_name, accesses, hits + misses);
                    errors = errors + 1;
                end
                if ((PREFETCH_POLICY == 0 &&
                     demand_reads != misses - victim_hits) ||
                    (PREFETCH_POLICY == 1 &&
                     demand_reads + pf_merged != misses - victim_hits)) begin
                    $display("FAIL demand read accounting name=%s demand_reads=%0d misses_minus_victim=%0d",
                             workload_name, demand_reads,
                             misses - victim_hits);
                    errors = errors + 1;
                end
                if (PREFETCH_POLICY == 0 && prefetch_reads != fills) begin
                    $display("FAIL prefetch read/fill accounting name=%s prefetch_reads=%0d fills=%0d",
                             workload_name, prefetch_reads, fills);
                    errors = errors + 1;
                end
                unused_resident = count_unused_resident();
                if (PREFETCH_POLICY == 0 &&
                    fills != useful + useless + unused_resident) begin
                    $display("FAIL prefetch conservation name=%s fills=%0d useful=%0d useless=%0d resident=%0d",
                             workload_name, fills, useful, useless,
                             unused_resident);
                    errors = errors + 1;
                end
                if (PREFETCH_POLICY == 1) begin
                    if (pf_issued > pf_admitted ||
                        pf_admitted > pf_candidates) begin
                        $display("FAIL optimized candidate accounting name=%s candidates=%0d admitted=%0d issued=%0d",
                                 workload_name, pf_candidates, pf_admitted,
                                 pf_issued);
                        errors = errors + 1;
                    end
                    if (prefetch_reads != pf_issued ||
                        pf_issued != pf_returned) begin
                        $display("FAIL optimized prefetch issue/drain accounting name=%s reads=%0d issued=%0d returned=%0d",
                                 workload_name, prefetch_reads, pf_issued,
                                 pf_returned);
                        errors = errors + 1;
                    end
                    if (pf_returned !=
                        pf_installed + pf_merged + pf_discarded) begin
                        $display("FAIL optimized response accounting name=%s returned=%0d installed=%0d merged=%0d discarded=%0d",
                                 workload_name, pf_returned, pf_installed,
                                 pf_merged, pf_discarded);
                        errors = errors + 1;
                    end
                    if (fills != pf_installed ||
                        pf_installed != timely_useful + pf_unused_evicted +
                            unused_resident ||
                        useless != pf_unused_evicted) begin
                        $display("FAIL optimized install accounting name=%s fills=%0d installed=%0d useful=%0d unused_evicted=%0d resident=%0d merged=%0d",
                                 workload_name, fills, pf_installed, timely_useful,
                                 pf_unused_evicted, unused_resident, pf_merged);
                        errors = errors + 1;
                    end
                    if (pf_caused_writebacks != 0) begin
                        $display("FAIL optimized prefetch caused writeback name=%s count=%0d",
                                 workload_name, pf_caused_writebacks);
                        errors = errors + 1;
                    end
                end
                if (writes != writebacks) begin
                    $display("FAIL writeback accounting name=%s mem_writes=%0d writebacks=%0d",
                             workload_name, writes, writebacks);
                    errors = errors + 1;
                end
                failed = (errors != errors_base) ||
                         (monitor.protocol_errors != protocol_base) ||
                         (monitor.watchdog_errors != watchdog_base) ||
                         (vif.duplicate_line_errors != duplicate_base);
                status = failed ? "FAIL" : "PASS";
                if (PREFETCH_POLICY == 0) begin
                    $display("WORKLOAD_RESULT schema=2 name=%s config_id=%s trace_id=%s sets=%0d ways=%0d line_bytes=%0d l1_bytes=%0d victim_entries=%0d victim_bytes=%0d total_bytes=%0d prefetch=%0d accesses=%0d hits=%0d misses=%0d victim_hits=%0d demand_mem_reads=%0d prefetch_mem_reads=%0d mem_reads=%0d mem_writes=%0d read_bytes=%0d write_bytes=%0d writebacks=%0d fills=%0d useful=%0d useless_evicted=%0d unused_resident=%0d pollution_proxy=%0d dropped=%0d timely_useful=%0d late_useful=0 replay_service_cycles=%0d watchdogs=%0d protocol=%0d duplicate_lines=%0d status=%s next_line=%0d mem_latency=%0d mem_bp=%0d cpu_bp=%0d latency_min=%0d latency_max=%0d latency_avg_x100=%0d",
                             workload_name, run_config_id, run_trace_id,
                             NUM_SETS, NUM_WAYS, LINE_BYTES,
                             NUM_SETS*NUM_WAYS*LINE_BYTES, VICTIM_ENTRIES,
                             VICTIM_ENTRIES*LINE_BYTES,
                             (NUM_SETS*NUM_WAYS + VICTIM_ENTRIES)*LINE_BYTES,
                             case_prefetch_enable, accesses, hits, misses,
                             victim_hits, demand_reads, prefetch_reads,
                             demand_reads + prefetch_reads, writes,
                             (demand_reads + prefetch_reads) * LINE_BYTES,
                             writes * LINE_BYTES, writebacks, fills, useful,
                             useless, unused_resident, pollution, dropped,
                             useful, service_cycles,
                             monitor.watchdog_errors - watchdog_base,
                             monitor.protocol_errors - protocol_base,
                             vif.duplicate_line_errors - duplicate_base,
                             status, case_next_line_enable, MEM_LATENCY,
                             MEM_BACKPRESSURE_MODE, CPU_BACKPRESSURE_MODE,
                             (monitor.latency_count == 0) ? 0 :
                                 monitor.latency_min,
                             monitor.latency_max,
                             monitor.latency_avg_x100());
                end else begin
                    $display("WORKLOAD_RESULT schema=3 name=%s config_id=%s trace_id=%s sets=%0d ways=%0d line_bytes=%0d l1_bytes=%0d victim_entries=%0d victim_bytes=%0d total_bytes=%0d prefetch=%0d accesses=%0d hits=%0d misses=%0d victim_hits=%0d demand_mem_reads=%0d prefetch_mem_reads=%0d mem_reads=%0d mem_writes=%0d read_bytes=%0d write_bytes=%0d writebacks=%0d fills=%0d useful=%0d useless_evicted=%0d unused_resident=%0d pollution_proxy=%0d dropped=%0d timely_useful=%0d late_useful=%0d replay_service_cycles=%0d watchdogs=%0d protocol=%0d duplicate_lines=%0d status=%s pf_candidates=%0d pf_admitted=%0d pf_issued=%0d pf_returned=%0d pf_installed=%0d pf_merged=%0d pf_discarded=%0d pf_cancelled=%0d pf_unused_evicted=%0d pf_unused_resident=%0d pf_vc_bypass=%0d pf_caused_writebacks=%0d pf_demand_block_cycles=%0d pf_true_help=%0d pf_true_pollution=%0d pf_suppressed_quota=%0d pf_suppressed_unsafe=%0d pf_same_line_coalesced=%0d pf_controller_state=%0d pf_mshr_valid=%0d pf_mshr_addr=%016h pf_mshr_confidence=%0d next_line=%0d mem_latency=%0d mem_bp=%0d cpu_bp=%0d latency_min=%0d latency_max=%0d latency_avg_x100=%0d",
                             workload_name, run_config_id, run_trace_id,
                             NUM_SETS, NUM_WAYS, LINE_BYTES,
                             NUM_SETS*NUM_WAYS*LINE_BYTES, VICTIM_ENTRIES,
                             VICTIM_ENTRIES*LINE_BYTES,
                             (NUM_SETS*NUM_WAYS + VICTIM_ENTRIES)*LINE_BYTES,
                             case_prefetch_enable, accesses, hits, misses,
                             victim_hits, demand_reads, prefetch_reads,
                             demand_reads + prefetch_reads, writes,
                             (demand_reads + prefetch_reads) * LINE_BYTES,
                             writes * LINE_BYTES, writebacks, fills, useful,
                             useless, unused_resident, pollution, dropped,
                             timely_useful, pf_merged, service_cycles,
                             monitor.watchdog_errors - watchdog_base,
                             monitor.protocol_errors - protocol_base,
                             vif.duplicate_line_errors - duplicate_base,
                             status, pf_candidates, pf_admitted, pf_issued,
                             pf_returned, pf_installed, pf_merged,
                             pf_discarded, pf_cancelled, pf_unused_evicted,
                             unused_resident, pf_vc_bypass,
                             pf_caused_writebacks, pf_demand_block_cycles,
                             pf_true_help, pf_true_pollution,
                             pf_suppressed_quota, pf_suppressed_unsafe,
                             pf_same_line_coalesced,
                             vif.debug_pf_controller_state,
                             vif.debug_pf_mshr_valid,
                             vif.debug_pf_mshr_addr,
                             vif.debug_pf_mshr_confidence,
                             case_next_line_enable, MEM_LATENCY,
                             MEM_BACKPRESSURE_MODE, CPU_BACKPRESSURE_MODE,
                             (monitor.latency_count == 0) ? 0 :
                                 monitor.latency_min,
                             monitor.latency_max,
                             monitor.latency_avg_x100());
                end
            end
        endtask

        task load_expect(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [1:0] size,
            input logic unsigned_load,
            input string label_text
        );
            l1d_transaction tr;
            logic [DATA_WIDTH-1:0] actual;
            logic error;
            logic [1:0] cause;
            logic [DATA_WIDTH-1:0] expected;
            begin
                tr = new(label_text, addr, 1'b0, size, unsigned_load, '0);
                expected = sb.golden_load(addr, size, unsigned_load);
                driver.cpu_request(tr, actual, error, cause);
                if (error || actual !== expected) begin
                    $display("FAIL load %s addr=%016x size=%0d error=%0d cause=%0d expected=%016x actual=%016x",
                             label_text, addr, size, error, cause,
                             expected, actual);
                    errors = errors + 1;
                end
            end
        endtask

        task store_expect(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic [1:0] size,
            input logic [DATA_WIDTH-1:0] data,
            input string label_text
        );
            l1d_transaction tr;
            logic [DATA_WIDTH-1:0] actual;
            logic error;
            logic [1:0] cause;
            begin
                tr = new(label_text, addr, 1'b1, size, 1'b0, data);
                driver.cpu_request(tr, actual, error, cause);
                if (error) begin
                    $display("FAIL store %s addr=%016x size=%0d cause=%0d",
                             label_text, addr, size, cause);
                    errors = errors + 1;
                end else begin
                    sb.update_golden_store(addr, data, size);
                end
            end
        endtask

        task expect_misaligned(
            input logic [ADDR_WIDTH-1:0] addr,
            input logic write,
            input logic [1:0] size,
            input logic [1:0] expected_cause,
            input string label_text
        );
            l1d_transaction tr;
            logic [DATA_WIDTH-1:0] actual;
            logic error;
            logic [1:0] cause;
            begin
                tr = new(label_text, addr, write, size, 1'b0,
                         64'hfeed_face_cafe_beef);
                driver.cpu_request(tr, actual, error, cause);
                if (!error || cause !== expected_cause) begin
                    $display("FAIL misaligned %s addr=%016x write=%0d size=%0d error=%0d cause=%0d",
                             label_text, addr, write, size, error, cause);
                    errors = errors + 1;
                end
            end
        endtask

        task test_cpu_response_backpressure();
            logic [ADDR_WIDTH-1:0] addr;
            logic [DATA_WIDTH-1:0] held;
            integer timeout;
            begin
                start_case("cpu_response_backpressure", 1'b0, 1'b0);
                addr = 64'h0000_0000_0000_0120;
                @(negedge vif.clk);
                vif.cpu_rsp_ready = 1'b0;
                vif.cpu_req_valid = 1'b1;
                vif.cpu_req_addr = addr;
                vif.cpu_req_write = 1'b0;
                vif.cpu_req_size = SIZE_DOUBLE;
                vif.cpu_req_unsigned = 1'b0;
                vif.cpu_req_wdata = '0;
                @(posedge vif.clk);
                @(negedge vif.clk);
                vif.cpu_req_valid = 1'b0;
                timeout = 0;
                while (!vif.cpu_rsp_valid) begin
                    @(posedge vif.clk);
                    timeout = timeout + 1;
                    if (timeout > 1000) $fatal(1, "response backpressure timeout");
                end
                held = vif.cpu_rsp_rdata;
                repeat (5) begin
                    @(posedge vif.clk);
                    if (!vif.cpu_rsp_valid || vif.cpu_rsp_rdata !== held) begin
                        $display("FAIL response backpressure payload changed");
                        errors = errors + 1;
                    end
                end
                @(negedge vif.clk);
                vif.cpu_rsp_ready = 1'b1;
                @(posedge vif.clk);
                report_workload("cpu_response_backpressure", 1);
            end
        endtask

        task run_directed_regression();
            integer k;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("directed_rv64", 1'b0, 1'b0);
                load_expect(64'h20, SIZE_DOUBLE, 1'b0, "cold_double");
                load_expect(64'h20, SIZE_DOUBLE, 1'b0, "hit_double");
                store_expect(64'h130, SIZE_DOUBLE, 64'hdead_beef_cafe_babe,
                             "sd_readback");
                load_expect(64'h130, SIZE_DOUBLE, 1'b0, "sd_readback");
                store_expect(64'h133, SIZE_BYTE, 64'h80, "sb");
                load_expect(64'h133, SIZE_BYTE, 1'b0, "lb");
                load_expect(64'h133, SIZE_BYTE, 1'b1, "lbu");
                store_expect(64'h138, SIZE_WORD, 64'h8000_0001, "sw");
                load_expect(64'h138, SIZE_WORD, 1'b0, "lw");
                load_expect(64'h0000_0001_0000_0210, SIZE_DOUBLE, 1'b0,
                            "high_tag");
                expect_misaligned(64'h101, 1'b0, SIZE_HALF,
                                  RSP_LOAD_MISALIGNED, "lh");
                expect_misaligned(64'h114, 1'b1, SIZE_DOUBLE,
                                  RSP_STORE_MISALIGNED, "sd");
                report_workload("directed_rv64", 10);

                start_case("victim_dirty_regression", 1'b0, 1'b0);
                base = 64'h0000_0000_0000_0800;
                store_expect(base, SIZE_DOUBLE, 64'h1234_5678_9abc_def0,
                             "dirty_seed");
                for (k = 1; k <= NUM_WAYS + VICTIM_ENTRIES; k = k + 1) begin
                    load_expect(base + k*CONFLICT_STRIDE, SIZE_DOUBLE, 1'b0,
                                "dirty_pressure");
                end
                load_expect(base, SIZE_DOUBLE, 1'b0, "dirty_recovery");
                report_workload("victim_dirty_regression",
                                NUM_WAYS + VICTIM_ENTRIES + 2);

                test_cpu_response_backpressure();
            end
        endtask

        task matrix_row_major();
            integer r;
            integer c;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("matrix_row_major", ENABLE_PREFETCH != 0,
                           ENABLE_PREFETCH != 0);
                base = 64'h0000_0000_0000_1000;
                accesses = 0;
                for (r = 0; r < 4; r = r + 1) begin
                    for (c = 0; c < 4; c = c + 1) begin
                        load_expect(base + (r*4 + c)*LINE_BYTES,
                                    SIZE_DOUBLE, 1'b0, "row_major");
                        accesses = accesses + 1;
                    end
                end
                report_workload("matrix_row_major", accesses);
            end
        endtask

        task matrix_column_major();
            integer r;
            integer c;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("matrix_column_major", ENABLE_PREFETCH != 0,
                           ENABLE_PREFETCH != 0);
                base = 64'h0000_0000_0000_1400;
                accesses = 0;
                for (c = 0; c < 4; c = c + 1) begin
                    for (r = 0; r < 4; r = r + 1) begin
                        load_expect(base + (r*4 + c)*LINE_BYTES,
                                    SIZE_DOUBLE, 1'b0, "column_major");
                        accesses = accesses + 1;
                    end
                end
                report_workload("matrix_column_major", accesses);
            end
        endtask

        task matrix_blocked();
            integer br;
            integer bc;
            integer r;
            integer c;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("matrix_blocked_tiled", ENABLE_PREFETCH != 0,
                           ENABLE_PREFETCH != 0);
                base = 64'h0000_0000_0000_1800;
                accesses = 0;
                for (br = 0; br < 4; br = br + 2) begin
                    for (bc = 0; bc < 4; bc = bc + 2) begin
                        for (r = br; r < br + 2; r = r + 1) begin
                            for (c = bc; c < bc + 2; c = c + 1) begin
                                load_expect(base + (r*4 + c)*LINE_BYTES,
                                            SIZE_DOUBLE, 1'b0, "blocked");
                                accesses = accesses + 1;
                            end
                        end
                    end
                end
                report_workload("matrix_blocked_tiled", accesses);
            end
        endtask

        task same_set_matrix_pressure(input integer extra_victim);
            integer i;
            integer rep;
            integer active_lines;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            string workload;
            begin
                active_lines = NUM_WAYS + (extra_victim ? VICTIM_ENTRIES + 1 : 1);
                workload = extra_victim ?
                    "matrix_same_set_exceeds_l1_plus_victim" :
                    "matrix_same_set_exceeds_l1";
                start_case(workload, 1'b0, 1'b0);
                base = extra_victim ? 64'h0000_0000_0000_2000 :
                                      64'h0000_0000_0000_1c00;
                accesses = 0;
                for (rep = 0; rep < 4; rep = rep + 1) begin
                    for (i = 0; i < active_lines; i = i + 1) begin
                        load_expect(base + i*CONFLICT_STRIDE,
                                    SIZE_DOUBLE, 1'b0, workload);
                        accesses = accesses + 1;
                    end
                end
                report_workload(workload, accesses);
            end
        endtask

        task store_heavy_matrix();
            integer i;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("matrix_store_heavy_dirty", 1'b0, 1'b0);
                base = 64'h0000_0000_0000_2400;
                accesses = 0;
                for (i = 0; i < NUM_WAYS + VICTIM_ENTRIES + 4; i = i + 1) begin
                    store_expect(base + i*CONFLICT_STRIDE, SIZE_DOUBLE,
                                 64'h4700_0000_0000_0000 + i,
                                 "store_heavy");
                    accesses = accesses + 1;
                end
                for (i = 0; i < NUM_WAYS + VICTIM_ENTRIES + 4; i = i + 1) begin
                    load_expect(base + i*CONFLICT_STRIDE, SIZE_DOUBLE, 1'b0,
                                "store_heavy_readback");
                    accesses = accesses + 1;
                end
                report_workload("matrix_store_heavy_dirty", accesses);
            end
        endtask

        task pointer_permutation();
            integer i;
            integer line_id [0:15];
            logic [ADDR_WIDTH-1:0] base;
            begin
                line_id[0] = 0;  line_id[1] = 11; line_id[2] = 3;  line_id[3] = 14;
                line_id[4] = 6;  line_id[5] = 1;  line_id[6] = 12; line_id[7] = 5;
                line_id[8] = 15; line_id[9] = 8;  line_id[10] = 2; line_id[11] = 10;
                line_id[12] = 4; line_id[13] = 13; line_id[14] = 7; line_id[15] = 9;
                start_case("pointer_random_permutation", ENABLE_PREFETCH != 0,
                           ENABLE_PREFETCH != 0);
                base = 64'h0000_0000_0000_3000;
                for (i = 0; i < 16; i = i + 1) begin
                    load_expect(base + line_id[i]*LINE_BYTES,
                                SIZE_DOUBLE, 1'b0, "pointer_perm");
                end
                report_workload("pointer_random_permutation", 16);
            end
        endtask

        task pointer_conflict_chain();
            integer i;
            integer active_lines;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("pointer_conflict_chain", 1'b0, 1'b0);
                base = 64'h0000_0000_0000_3400;
                active_lines = NUM_WAYS + ((VICTIM_ENTRIES > 2) ? 2 : 1);
                for (i = 0; i < active_lines * 5; i = i + 1) begin
                    load_expect(base + (i % active_lines)*CONFLICT_STRIDE,
                                SIZE_DOUBLE, 1'b0, "pointer_conflict");
                end
                report_workload("pointer_conflict_chain", active_lines * 5);
            end
        endtask

        task pointer_irregular_long();
            integer i;
            integer idx;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("pointer_irregular_defeats_next_line",
                           ENABLE_PREFETCH != 0, ENABLE_PREFETCH != 0);
                base = 64'h0000_0000_0000_3800;
                idx = 7;
                for (i = 0; i < 24; i = i + 1) begin
                    idx = (idx + 7) % 31;
                    load_expect(base + idx*LINE_BYTES,
                                SIZE_DOUBLE, 1'b0, "pointer_irregular");
                end
                report_workload("pointer_irregular_defeats_next_line", 24);
            end
        endtask

        task pointer_mixed_update();
            integer i;
            integer idx;
            integer accesses;
            logic [ADDR_WIDTH-1:0] base;
            begin
                start_case("pointer_mixed_load_store_update", 1'b0, 1'b0);
                base = 64'h0000_0000_0000_3c00;
                accesses = 0;
                idx = 2;
                for (i = 0; i < 20; i = i + 1) begin
                    idx = (idx * 9 + 5) % 23;
                    if ((i % 3) == 0) begin
                        store_expect(base + idx*LINE_BYTES, SIZE_DOUBLE,
                                     64'h7000_0000_0000_0000 + i,
                                     "pointer_update_store");
                    end else begin
                        load_expect(base + idx*LINE_BYTES, SIZE_DOUBLE, 1'b0,
                                    "pointer_update_load");
                    end
                    accesses = accesses + 1;
                end
                report_workload("pointer_mixed_load_store_update", accesses);
            end
        endtask

        task external_prefetch_candidates();
            integer i;
            integer demand;
            logic [ADDR_WIDTH-1:0] base;
            begin
                if (ENABLE_PREFETCH == 0) begin
                    return;
                end
                start_case("external_prefetch_matrix_candidates", 1'b1, 1'b0);
                base = 64'h0000_0000_0000_4400;
                for (i = 0; i < 8; i = i + 1) begin
                    driver.external_prefetch(base + i*LINE_BYTES);
                    repeat (6) @(posedge vif.clk);
                    // PROBE refills one token per 16 demand accesses.  Keep
                    // demand traffic moving while a one-entry external skid
                    // applies legitimate backpressure; otherwise a serial
                    // producer would wait for ready while also withholding
                    // the accesses needed to replenish the token bucket.
                    for (demand = 0; demand < 16; demand = demand + 1) begin
                        load_expect(base + i*LINE_BYTES, SIZE_DOUBLE, 1'b0,
                                    "external_prefetch_load");
                    end
                end
                report_workload("external_prefetch_matrix_candidates", 128);
            end
        endtask

        task replay_trace(input string trace_path);
            integer trace_fd;
            integer trace_line_number;
            integer scan_count;
            integer operation;
            integer trace_size;
            integer trace_unsigned;
            integer accesses;
            integer check_load_data;
            integer has_phase_markers;
            integer saw_measure_phase;
            integer phase_code;
            integer is_phase_line;
            integer measurement_active;
            reg [8*TRACE_LINE_BYTES-1:0] trace_line;
            logic [ADDR_WIDTH-1:0] addr;
            logic [DATA_WIDTH-1:0] data;
            logic [DATA_WIDTH-1:0] actual;
            logic [DATA_WIDTH-1:0] expected;
            logic error;
            logic [1:0] cause;
            logic [1:0] size;
            logic unsigned_load;
            l1d_transaction tr;
            begin
                trace_fd = $fopen(trace_path, "r");
                if (trace_fd == 0) begin
                    $fatal(1, "cannot open trace file: %s", trace_path);
                end
                has_phase_markers = 0;
                while (!$feof(trace_fd)) begin
                    trace_line = '0;
                    if ($fgets(trace_line, trace_fd) != 0 &&
                        trace_phase_code(trace_line) != 0) begin
                        has_phase_markers = 1;
                    end
                end
                $fclose(trace_fd);

                start_case("trace_replay",
                           (!has_phase_markers) && (ENABLE_PREFETCH != 0),
                           (!has_phase_markers) && (ENABLE_PREFETCH != 0));
                trace_fd = $fopen(trace_path, "r");
                if (trace_fd == 0) begin
                    $fatal(1, "cannot reopen trace file: %s", trace_path);
                end
                check_load_data = !$test$plusargs("TRACE_SKIP_LOAD_CHECKS");
                accesses = 0;
                saw_measure_phase = 0;
                measurement_active = !has_phase_markers;
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
                        scan_count = 0;
                        is_phase_line = 0;
                        phase_code = trace_phase_code(trace_line);
                        if (phase_code == 1) begin
                            is_phase_line = 1;
                            if (saw_measure_phase) begin
                                $fatal(1, "warmup phase follows measure at line %0d",
                                       trace_line_number);
                            end
                            measurement_active = 0;
                            vif.cfg_prefetch_enable = 1'b0;
                            vif.cfg_next_line_enable = 1'b0;
                        end else if (phase_code == 2) begin
                            is_phase_line = 1;
                            if (saw_measure_phase) begin
                                $fatal(1, "duplicate measure phase at line %0d",
                                       trace_line_number);
                            end
                            wait_for_quiescence();
                            snapshot_measurement_counters();
                            monitor.reset_metrics();
                            accesses = 0;
                            saw_measure_phase = 1;
                            measurement_active = 1;
                            case_prefetch_enable = (ENABLE_PREFETCH != 0);
                            case_next_line_enable = (ENABLE_PREFETCH != 0);
                            vif.cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
                            vif.cfg_next_line_enable = (ENABLE_PREFETCH != 0);
                        end else if (trace_is_comment(trace_line)) begin
                            is_phase_line = 1;
                        end else begin
                            scan_count = $sscanf(trace_line, "%d %d %d %h %h",
                                                 operation, trace_size,
                                                 trace_unsigned, addr, data);
                        end
                        if (!is_phase_line && scan_count >= 1) begin
                            case (operation)
                                0: begin
                                    if (scan_count != 4 ||
                                        trace_size < 0 || trace_size > 3 ||
                                        trace_unsigned < 0 || trace_unsigned > 1) begin
                                        $fatal(1, "invalid trace load line=%0d",
                                               trace_line_number);
                                    end
                                    size = trace_size[1:0];
                                    unsigned_load = trace_unsigned != 0;
                                    tr = new("trace_load", addr, 1'b0, size,
                                             unsigned_load, '0);
                                    expected = sb.golden_load(addr, size,
                                                              unsigned_load);
                                    driver.cpu_request(tr, actual, error, cause);
                                    if (error ||
                                        (check_load_data && actual !== expected)) begin
                                        $display("FAIL trace load line=%0d addr=%016x error=%0d cause=%0d expected=%016x actual=%016x",
                                                 trace_line_number, addr, error,
                                                 cause, expected, actual);
                                        errors = errors + 1;
                                    end
                                    if (measurement_active) begin
                                        accesses = accesses + 1;
                                    end
                                end
                                1: begin
                                    if (scan_count != 5 ||
                                        trace_size < 0 || trace_size > 3) begin
                                        $fatal(1, "invalid trace store line=%0d",
                                               trace_line_number);
                                    end
                                    size = trace_size[1:0];
                                    tr = new("trace_store", addr, 1'b1, size,
                                             1'b0, data);
                                    driver.cpu_request(tr, actual, error, cause);
                                    if (error) begin
                                        $display("FAIL trace store line=%0d addr=%016x cause=%0d",
                                                 trace_line_number, addr, cause);
                                        errors = errors + 1;
                                    end else begin
                                        sb.update_golden_store(addr, data, size);
                                    end
                                    if (measurement_active) begin
                                        accesses = accesses + 1;
                                    end
                                end
                                default: begin
                                    $fatal(1, "invalid trace opcode line=%0d",
                                           trace_line_number);
                                end
                            endcase
                        end
                    end
                end
                $fclose(trace_fd);
                if (has_phase_markers && !saw_measure_phase) begin
                    $fatal(1, "phased trace does not contain a measure phase");
                end
                report_workload("trace_replay", accesses);
            end
        endtask

        task run_phase3_workloads();
            begin
                run_directed_regression();
                matrix_row_major();
                matrix_column_major();
                matrix_blocked();
                same_set_matrix_pressure(0);
                same_set_matrix_pressure(1);
                store_heavy_matrix();
                pointer_permutation();
                pointer_conflict_chain();
                pointer_irregular_long();
                pointer_mixed_update();
                external_prefetch_candidates();
            end
        endtask
    endclass

    initial begin
        l1d_scoreboard sb;
        l1d_line_mem_model mem;
        l1d_cpu_driver driver;
        l1d_monitor monitor;
        l1d_sequence seq;
        string trace_path;

        clk = 1'b0;
        producer_profile = PRODUCER_PROFILE;
        producer_gap = PRODUCER_GAP;
        producer_plusarg_status =
            $value$plusargs("PRODUCER_PROFILE=%d", producer_profile);
        producer_plusarg_status =
            $value$plusargs("PRODUCER_GAP=%d", producer_gap);
        sb = new();
        mem = new(bus, sb);
        driver = new(bus, sb, producer_profile, producer_gap);
        monitor = new(bus);
        seq = new(bus, sb, mem, driver, monitor);
        driver.drive_defaults();
        bus.rst_n = 1'b0;
        bus.duplicate_line_errors = 0;

        if (producer_profile < 0 || producer_profile > 2) begin
            $fatal(1, "PRODUCER_PROFILE must be 0, 1, or 2");
        end
        if (producer_gap < 0) begin
            $fatal(1, "PRODUCER_GAP must be non-negative");
        end

        if ($test$plusargs("VCD")) begin
            $dumpfile("sim/l1d_cache_oop.vcd");
            $dumpvars(0, tb_l1d_cache_oop);
        end

        fork
            mem.run();
            monitor.run();
        join_none

        if ($test$plusargs("NOOP_PROBE")) begin
            repeat (2) @(posedge clk);
            $display("NOOP_PROBE PASS Vivado OOP harness elaborated");
        end else if ($value$plusargs("TRACE=%s", trace_path)) begin
            seq.replay_trace(trace_path);
        end else begin
            seq.run_phase3_workloads();
        end

        repeat (5) @(posedge clk);
        if (seq.errors == 0 &&
            monitor.protocol_errors == 0 &&
            monitor.watchdog_errors == 0 &&
            bus.duplicate_line_errors == 0) begin
            $display("ALL OOP TESTS PASSED ways=%0d vc=%0d prefetch=%0d",
                     NUM_WAYS, VICTIM_ENTRIES, ENABLE_PREFETCH);
            $finish;
        end else begin
            $fatal(1, "%0d functional, %0d protocol, %0d watchdog, %0d duplicate-line failures",
                   seq.errors, monitor.protocol_errors,
                   monitor.watchdog_errors, bus.duplicate_line_errors);
        end
    end
endmodule
