`timescale 1ns/1ps

module tb_l1d_cache #(
    parameter integer NUM_WAYS = 1,
    parameter integer ENABLE_PREFETCH = 0,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer NUM_SETS = 8,
    parameter integer LINE_BYTES = 16,
    parameter integer PREFETCH_POLICY = 1,
    parameter integer PF_OPT_LEVEL = 3,
    // 0: always ready, 1: historical periodic ready, 2: deterministic random.
    parameter integer MEM_LATENCY = 2,
    parameter integer MEM_READY_MODE = 1,
    // 0: historical sequential driver, 1: zero-bubble driver,
    // 2: response-to-next-request fixed gap.
    parameter integer PRODUCER_PROFILE = 0,
    parameter integer PRODUCER_GAP = 1
);
    localparam integer ADDR_WIDTH = 64;
    localparam integer DATA_WIDTH = 64;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer MEM_BYTES = 4096;
    localparam integer TRACE_LINE_BYTES = 4096;
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

    byte unsigned memory [0:MEM_BYTES-1];
    byte unsigned golden_memory [0:MEM_BYTES-1];
    logic read_pending;
    logic [ADDR_WIDTH-1:0] read_addr;
    integer read_countdown;
    logic [2:0] mem_ready_phase;
    logic [31:0] mem_ready_lfsr;
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
    integer accepted_demand_mem_reads;
    integer accepted_prefetch_mem_reads;
    integer accepted_mem_writes;
    integer cycles_since_reset;
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
    integer access_sidecar_fd;
    integer access_sidecar_schema;
    integer producer_profile;
    integer producer_gap;
    logic measurement_active;
    logic sidecar_request_active;
    integer sidecar_request_seq;
    integer sidecar_hit_before;
    integer sidecar_victim_before;
    integer last_cpu_present_cycle;
    integer last_cpu_accept_cycle;
    integer last_cpu_response_cycle;
    integer last_cpu_latency;
    integer zero_bubble_overlap_observed;
    logic sidecar_measurement_was_active;
    logic [ADDR_WIDTH-1:0] sidecar_pf_addr;
    logic sidecar_pf_addr_valid;
    logic [31:0] sidecar_prev_pf_returned;
    logic [31:0] sidecar_prev_pf_installed;
    logic [31:0] sidecar_prev_pf_merged;
    logic [31:0] sidecar_prev_pf_discarded;
    logic [31:0] sidecar_prev_pf_candidates;
    logic [31:0] sidecar_prev_pf_admitted;
    logic [31:0] sidecar_prev_pf_useful;
    logic [31:0] sidecar_prev_pf_unused_evicted;
    logic [31:0] sidecar_prev_pf_cancelled;
    logic [31:0] sidecar_prev_pf_suppressed_quota;
    logic [31:0] sidecar_prev_pf_suppressed_unsafe;
    logic [31:0] sidecar_prev_pf_caused_writebacks;
    logic [1:0] sidecar_prev_controller_state;
    integer sidecar_delta_i;
    reg [8*64-1:0] config_id;
    reg [8*256-1:0] trace_id;
    integer k;

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
        .event_prefetch_dropped(event_prefetch_dropped),
        .debug_state(debug_state),
        .debug_req_is_prefetch(debug_req_is_prefetch),
        .stat_pf_candidates(stat_pf_candidates),
        .stat_pf_admitted(stat_pf_admitted),
        .stat_pf_issued(stat_pf_issued),
        .stat_pf_returned(stat_pf_returned),
        .stat_pf_installed(stat_pf_installed),
        .stat_pf_merged(stat_pf_merged),
        .stat_pf_discarded(stat_pf_discarded),
        .stat_pf_cancelled(stat_pf_cancelled),
        .stat_pf_unused_evicted(stat_pf_unused_evicted),
        .stat_pf_vc_bypass(stat_pf_vc_bypass),
        .stat_pf_caused_writebacks(stat_pf_caused_writebacks),
        .stat_pf_demand_block_cycles(stat_pf_demand_block_cycles),
        .stat_pf_true_help(stat_pf_true_help),
        .stat_pf_true_pollution(stat_pf_true_pollution),
        .stat_pf_suppressed_quota(stat_pf_suppressed_quota),
        .stat_pf_suppressed_unsafe(stat_pf_suppressed_unsafe),
        .stat_pf_same_line_coalesced(stat_pf_same_line_coalesced),
        .debug_pf_controller_state(debug_pf_controller_state),
        .debug_pf_mshr_valid(debug_pf_mshr_valid),
        .debug_pf_mshr_addr(debug_pf_mshr_addr),
        .debug_pf_mshr_confidence(debug_pf_mshr_confidence)
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

    task automatic snapshot_measurement_counters;
        begin
            metric_hits_base = stat_cpu_hits;
            metric_misses_base = stat_cpu_misses;
            metric_victim_hits_base = stat_victim_hits;
            metric_writebacks_base = stat_writebacks;
            metric_fills_base = stat_prefetch_fills;
            metric_useful_base = stat_prefetch_useful;
            metric_useless_base = stat_prefetch_useless;
            metric_pollution_base = stat_prefetch_pollution;
            metric_dropped_base = stat_prefetch_dropped;
            metric_demand_reads_base = accepted_demand_mem_reads;
            metric_prefetch_reads_base = accepted_prefetch_mem_reads;
            metric_writes_base = accepted_mem_writes;
            metric_cycles_base = cycles_since_reset;
            metric_pf_candidates_base = stat_pf_candidates;
            metric_pf_admitted_base = stat_pf_admitted;
            metric_pf_issued_base = stat_pf_issued;
            metric_pf_returned_base = stat_pf_returned;
            metric_pf_installed_base = stat_pf_installed;
            metric_pf_merged_base = stat_pf_merged;
            metric_pf_discarded_base = stat_pf_discarded;
            metric_pf_cancelled_base = stat_pf_cancelled;
            metric_pf_unused_evicted_base = stat_pf_unused_evicted;
            metric_pf_vc_bypass_base = stat_pf_vc_bypass;
            metric_pf_caused_writebacks_base = stat_pf_caused_writebacks;
            metric_pf_demand_block_cycles_base =
                stat_pf_demand_block_cycles;
            metric_pf_true_help_base = stat_pf_true_help;
            metric_pf_true_pollution_base = stat_pf_true_pollution;
            metric_pf_suppressed_quota_base = stat_pf_suppressed_quota;
            metric_pf_suppressed_unsafe_base = stat_pf_suppressed_unsafe;
            metric_pf_same_line_coalesced_base =
                stat_pf_same_line_coalesced;
        end
    endtask

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
            measurement_active = 1'b0;
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
            snapshot_measurement_counters();
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
        string request_op;
        string response_outcome;
        begin
            request_op = write ? "store" : "load";
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = addr;
            cpu_req_write = write;
            cpu_req_size = size;
            cpu_req_unsigned = unsigned_load;
            cpu_req_wdata = data;
            last_cpu_present_cycle = cycles_since_reset -
                                     metric_cycles_base + 1;
            if (sidecar_request_active && access_sidecar_fd != 0 &&
                access_sidecar_schema == 3) begin
                $fdisplay(access_sidecar_fd,
                          "schema=3 event=demand_present seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=pending latency=-1 details=-",
                          sidecar_request_seq, last_cpu_present_cycle, addr,
                          request_op, size);
            end
            timeout = 0;
            while (!cpu_req_ready) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 200) $fatal(1, "CPU request timeout");
            end
            @(posedge clk);
            last_cpu_accept_cycle = cycles_since_reset -
                                    metric_cycles_base + 1;
            if (sidecar_request_active && access_sidecar_fd != 0 &&
                access_sidecar_schema == 3) begin
                $fdisplay(access_sidecar_fd,
                          "schema=3 event=demand_accept seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=pending latency=0 details=-",
                          sidecar_request_seq, last_cpu_accept_cycle, addr,
                          request_op, size);
            end
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
            // cpu_rsp_valid is observed on the response-transfer edge.  The
            // legacy driver deliberately leaves one additional full idle
            // opportunity after it; the zero-bubble driver returns now so
            // the next request can be presented before the first ready edge.
            last_cpu_response_cycle = cycles_since_reset -
                                      metric_cycles_base + 1;
            last_cpu_latency = last_cpu_response_cycle -
                               last_cpu_accept_cycle;
            if (sidecar_request_active && access_sidecar_fd != 0 &&
                access_sidecar_schema == 3) begin
                if (stat_cpu_hits != sidecar_hit_before) begin
                    response_outcome = "l1_hit";
                end else if (stat_victim_hits != sidecar_victim_before) begin
                    response_outcome = "victim_hit";
                end else begin
                    response_outcome = "lower_memory";
                end
                $fdisplay(access_sidecar_fd,
                          "schema=3 event=demand_response seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=%s latency=%0d details=-",
                          sidecar_request_seq, last_cpu_response_cycle, addr,
                          request_op, size, response_outcome,
                          last_cpu_latency);
            end
            if (producer_profile == 0) begin
                @(posedge clk);
            end else if (producer_profile == 2) begin
                repeat (producer_gap) @(posedge clk);
            end
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

    task automatic test_prefetch_arbitration;
        logic [ADDR_WIDTH-1:0] base;
        logic ext_accepted;
        logic [31:0] fills_before;
        integer timeout;
        begin
            $display("TEST prefetch arbitration, ways=%0d", NUM_WAYS);

            // A misaligned CPU request still owns the CPU acceptance slot.  An
            // external producer is allowed to retire its request only when the
            // cache can actually latch it.
            initialize_memory();
            reset_cache();
            cfg_next_line_enable = 1'b0;
            base = 64'h0000_0000_0000_0200;
            fills_before = stat_prefetch_fills;
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = base + 1;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_HALF;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;
            ext_prefetch_valid = 1'b1;
            ext_prefetch_addr = base + 4*LINE_BYTES;
            #1;
            ext_accepted = ext_prefetch_ready;
            if (ext_prefetch_ready) begin
                $display("FAIL external prefetch accepted with misaligned CPU demand");
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
            cpu_req_size = SIZE_DOUBLE;
            if (ext_accepted) begin
                ext_prefetch_valid = 1'b0;
            end

            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 40) $fatal(1, "misaligned arbitration response timeout");
            end
            if (!cpu_rsp_error || cpu_rsp_error_cause != RSP_LOAD_MISALIGNED) begin
                $display("FAIL arbitration CPU request did not report misalignment");
                errors = errors + 1;
            end
            @(posedge clk);

            if (ext_prefetch_valid) begin
                timeout = 0;
                while (!ext_prefetch_ready) begin
                    @(negedge clk);
                    timeout = timeout + 1;
                    if (timeout > 40) $fatal(1, "deferred external prefetch timeout");
                end
                @(posedge clk);
                @(negedge clk);
                ext_prefetch_valid = 1'b0;
            end
            timeout = 0;
            while (stat_prefetch_fills == fills_before && timeout <= 80) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (stat_prefetch_fills == fills_before) begin
                $display("FAIL external prefetch was acknowledged but never filled");
                errors = errors + 1;
            end

            // A queued next-line candidate must likewise remain pending while
            // a misaligned demand receives its architectural error response.
            initialize_memory();
            reset_cache();
            base = 64'h0000_0000_0000_0400;
            cpu_rsp_ready = 1'b0;
            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
                        "seed pending next-line candidate");
            fills_before = stat_prefetch_fills;
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = base + 3;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_WORD;
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (!dut.next_line_candidate_valid) begin
                $display("FAIL next-line candidate was not pending at arbitration boundary");
                errors = errors + 1;
            end
            if (dut.next_line_candidate_ready) begin
                $display("FAIL next-line candidate accepted with misaligned CPU demand");
                errors = errors + 1;
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
            cpu_req_size = SIZE_DOUBLE;
            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 40) $fatal(1, "pending arbitration response timeout");
            end
            @(posedge clk);
            timeout = 0;
            while (stat_prefetch_fills == fills_before && timeout <= 80) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (stat_prefetch_fills == fills_before) begin
                $display("FAIL pending next-line request was silently lost");
                errors = errors + 1;
            end

            // Three back-to-back cold demand misses keep the single-entry
            // next-line queue occupied: one candidate survives and the two
            // later candidates are explicitly counted as dropped.
            initialize_memory();
            reset_cache();
            base = 64'h0000_0000_0000_0800;
            cpu_rsp_ready = 1'b0;
            expect_read(base, memory_load(base, SIZE_DOUBLE, 1'b0),
                        "continuous demand miss 0");

            // Present miss 1 before retiring miss 0's response.
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = base + 4*LINE_BYTES;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cpu_rsp_ready = 1'b0;
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 80) $fatal(1, "continuous miss 1 response timeout");
            end

            // Present miss 2 before retiring miss 1's response.
            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = base + 8*LINE_BYTES;
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            cpu_rsp_ready = 1'b0;
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(posedge clk);
                timeout = timeout + 1;
                if (timeout > 80) $fatal(1, "continuous miss 2 response timeout");
            end
            @(negedge clk);
            cpu_rsp_ready = 1'b1;
            @(posedge clk);
            timeout = 0;
            while ((stat_prefetch_fills < 1 || stat_prefetch_dropped < 2) &&
                   timeout <= 120) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (stat_prefetch_fills != 1 || stat_prefetch_dropped != 2) begin
                $display("FAIL expected one fill and two drops, got fills=%0d dropped=%0d",
                         stat_prefetch_fills, stat_prefetch_dropped);
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
        integer unused_resident;
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
        integer result_schema;
        reg [8*256-1:0] result_trace_id;
        string status;
        begin
            hits = stat_cpu_hits - metric_hits_base;
            misses = stat_cpu_misses - metric_misses_base;
            victim_hits = stat_victim_hits - metric_victim_hits_base;
            demand_reads = accepted_demand_mem_reads - metric_demand_reads_base;
            prefetch_reads = accepted_prefetch_mem_reads - metric_prefetch_reads_base;
            writes = accepted_mem_writes - metric_writes_base;
            writebacks = stat_writebacks - metric_writebacks_base;
            fills = stat_prefetch_fills - metric_fills_base;
            useful = stat_prefetch_useful - metric_useful_base;
            useless = stat_prefetch_useless - metric_useless_base;
            pollution = stat_prefetch_pollution - metric_pollution_base;
            dropped = stat_prefetch_dropped - metric_dropped_base;
            unused_resident = count_unused_resident();
            service_cycles = cycles_since_reset - metric_cycles_base;
            result_schema = (access_sidecar_schema == 3 ||
                             PREFETCH_POLICY == 1) ? 3 : 2;
            if (PREFETCH_POLICY == 1) begin
                pf_candidates = stat_pf_candidates - metric_pf_candidates_base;
                pf_admitted = stat_pf_admitted - metric_pf_admitted_base;
                pf_issued = stat_pf_issued - metric_pf_issued_base;
                pf_returned = stat_pf_returned - metric_pf_returned_base;
                pf_installed = stat_pf_installed - metric_pf_installed_base;
                pf_merged = stat_pf_merged - metric_pf_merged_base;
                pf_discarded = stat_pf_discarded - metric_pf_discarded_base;
                pf_cancelled = stat_pf_cancelled - metric_pf_cancelled_base;
                pf_unused_evicted = stat_pf_unused_evicted -
                                    metric_pf_unused_evicted_base;
                pf_vc_bypass = stat_pf_vc_bypass - metric_pf_vc_bypass_base;
                pf_caused_writebacks = stat_pf_caused_writebacks -
                                       metric_pf_caused_writebacks_base;
                pf_demand_block_cycles = stat_pf_demand_block_cycles -
                                         metric_pf_demand_block_cycles_base;
                pf_true_help = stat_pf_true_help - metric_pf_true_help_base;
                pf_true_pollution = stat_pf_true_pollution -
                                    metric_pf_true_pollution_base;
                pf_suppressed_quota = stat_pf_suppressed_quota -
                                      metric_pf_suppressed_quota_base;
                pf_suppressed_unsafe = stat_pf_suppressed_unsafe -
                                       metric_pf_suppressed_unsafe_base;
                pf_same_line_coalesced = stat_pf_same_line_coalesced -
                                         metric_pf_same_line_coalesced_base;
            end else begin
                // A schema-3 sidecar can be requested while replaying the
                // frozen legacy policy.  Normalize its historical lifecycle
                // into the same causal vocabulary without changing RTL.
                pf_candidates = prefetch_reads + dropped;
                pf_admitted = prefetch_reads;
                pf_issued = prefetch_reads;
                pf_returned = prefetch_reads;
                pf_installed = fills;
                pf_merged = 0;
                pf_discarded = 0;
                pf_cancelled = 0;
                pf_unused_evicted = useless;
                pf_vc_bypass = 0;
                pf_caused_writebacks = 0;
                pf_demand_block_cycles = 0;
                pf_true_help = 0;
                pf_true_pollution = 0;
                pf_suppressed_quota = 0;
                pf_suppressed_unsafe = 0;
                pf_same_line_coalesced = 0;
            end
            // In schema 3, `useful` is total useful work.  Installed-before-
            // demand uses remain timely; same-line MSHR merges are late uses.
            timely_useful = useful;
            if (result_schema == 3)
                useful = timely_useful + pf_merged;
            if (trace_id == '0) begin
                result_trace_id = "synthetic";
            end else begin
                result_trace_id = trace_id;
            end
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
                         workload_name, demand_reads, misses - victim_hits);
                errors = errors + 1;
            end
            if (PREFETCH_POLICY == 0 && prefetch_reads != fills) begin
                $display("FAIL prefetch read/fill accounting name=%s prefetch_reads=%0d fills=%0d",
                         workload_name, prefetch_reads, fills);
                errors = errors + 1;
            end
            if (PREFETCH_POLICY == 0 &&
                fills != useful + useless + unused_resident) begin
                $display("FAIL prefetch conservation name=%s fills=%0d useful=%0d useless=%0d resident=%0d",
                         workload_name, fills, useful, useless, unused_resident);
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
                if (pf_admitted > pf_issued + pf_cancelled) begin
                    $display("FAIL optimized admission lifecycle name=%s admitted=%0d issued=%0d cancelled=%0d",
                             workload_name, pf_admitted, pf_issued,
                             pf_cancelled);
                    errors = errors + 1;
                end
                if (prefetch_reads != pf_issued) begin
                    $display("FAIL optimized prefetch read/issue accounting name=%s reads=%0d issued=%0d",
                             workload_name, prefetch_reads, pf_issued);
                    errors = errors + 1;
                end
                if (pf_issued != pf_returned) begin
                    $display("FAIL optimized prefetch drain accounting name=%s issued=%0d returned=%0d",
                             workload_name, pf_issued, pf_returned);
                    errors = errors + 1;
                end
                if (pf_returned !=
                    pf_installed + pf_merged + pf_discarded) begin
                    $display("FAIL optimized response accounting name=%s returned=%0d installed=%0d merged=%0d discarded=%0d",
                             workload_name, pf_returned, pf_installed,
                             pf_merged, pf_discarded);
                    errors = errors + 1;
                end
                if (fills != pf_installed) begin
                    $display("FAIL optimized fill/install accounting name=%s fills=%0d installed=%0d",
                             workload_name, fills, pf_installed);
                    errors = errors + 1;
                end
                if (pf_installed !=
                    timely_useful + pf_unused_evicted + unused_resident) begin
                    $display("FAIL optimized install residency accounting name=%s installed=%0d useful=%0d unused_evicted=%0d resident=%0d",
                             workload_name, pf_installed, timely_useful,
                             pf_unused_evicted, unused_resident);
                    errors = errors + 1;
                end
                if (useless != pf_unused_evicted) begin
                    $display("FAIL optimized unused-eviction accounting name=%s legacy=%0d lifecycle=%0d",
                             workload_name, useless, pf_unused_evicted);
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
            status = (errors == 0 && protocol_errors == 0) ? "PASS" : "FAIL";
            if (result_schema == 2) begin
                $display("WORKLOAD_RESULT schema=2 name=%s config_id=%0s trace_id=%0s sets=%0d ways=%0d line_bytes=%0d l1_bytes=%0d victim_entries=%0d victim_bytes=%0d total_bytes=%0d prefetch=%0d accesses=%0d hits=%0d misses=%0d victim_hits=%0d demand_mem_reads=%0d prefetch_mem_reads=%0d mem_reads=%0d mem_writes=%0d read_bytes=%0d write_bytes=%0d writebacks=%0d fills=%0d useful=%0d useless_evicted=%0d unused_resident=%0d pollution_proxy=%0d dropped=%0d timely_useful=%0d late_useful=0 replay_service_cycles=%0d watchdogs=0 protocol=%0d duplicate_lines=0 status=%s",
                         workload_name, config_id, result_trace_id, NUM_SETS,
                         NUM_WAYS, LINE_BYTES, NUM_SETS*NUM_WAYS*LINE_BYTES,
                         VICTIM_ENTRIES, VICTIM_ENTRIES*LINE_BYTES,
                         (NUM_SETS*NUM_WAYS + VICTIM_ENTRIES)*LINE_BYTES,
                         ENABLE_PREFETCH, accesses, hits, misses, victim_hits,
                         demand_reads, prefetch_reads,
                         demand_reads + prefetch_reads, writes,
                         (demand_reads + prefetch_reads)*LINE_BYTES,
                         writes*LINE_BYTES, writebacks, fills, useful, useless,
                         unused_resident, pollution, dropped, useful,
                         service_cycles, protocol_errors, status);
            end else begin
                $display("WORKLOAD_RESULT schema=3 name=%s config_id=%0s trace_id=%0s sets=%0d ways=%0d line_bytes=%0d l1_bytes=%0d victim_entries=%0d victim_bytes=%0d total_bytes=%0d prefetch=%0d accesses=%0d hits=%0d misses=%0d victim_hits=%0d demand_mem_reads=%0d prefetch_mem_reads=%0d mem_reads=%0d mem_writes=%0d read_bytes=%0d write_bytes=%0d writebacks=%0d fills=%0d useful=%0d useless_evicted=%0d unused_resident=%0d pollution_proxy=%0d dropped=%0d timely_useful=%0d late_useful=%0d replay_service_cycles=%0d watchdogs=0 protocol=%0d duplicate_lines=0 status=%s pf_candidates=%0d pf_admitted=%0d pf_issued=%0d pf_returned=%0d pf_installed=%0d pf_merged=%0d pf_discarded=%0d pf_cancelled=%0d pf_unused_evicted=%0d pf_unused_resident=%0d pf_vc_bypass=%0d pf_caused_writebacks=%0d pf_demand_block_cycles=%0d pf_true_help=%0d pf_true_pollution=%0d pf_suppressed_quota=%0d pf_suppressed_unsafe=%0d pf_same_line_coalesced=%0d pf_controller_state=%0d pf_mshr_valid=%0d pf_mshr_addr=%016h pf_mshr_confidence=%0d",
                         workload_name, config_id, result_trace_id, NUM_SETS,
                         NUM_WAYS, LINE_BYTES, NUM_SETS*NUM_WAYS*LINE_BYTES,
                         VICTIM_ENTRIES, VICTIM_ENTRIES*LINE_BYTES,
                         (NUM_SETS*NUM_WAYS + VICTIM_ENTRIES)*LINE_BYTES,
                         ENABLE_PREFETCH, accesses, hits, misses, victim_hits,
                         demand_reads, prefetch_reads,
                         demand_reads + prefetch_reads, writes,
                         (demand_reads + prefetch_reads)*LINE_BYTES,
                         writes*LINE_BYTES, writebacks, fills, useful, useless,
                         unused_resident, pollution, dropped, timely_useful,
                         pf_merged, service_cycles, protocol_errors, status,
                         pf_candidates, pf_admitted, pf_issued, pf_returned,
                         pf_installed, pf_merged, pf_discarded, pf_cancelled,
                         pf_unused_evicted, unused_resident, pf_vc_bypass,
                         pf_caused_writebacks, pf_demand_block_cycles,
                         pf_true_help, pf_true_pollution, pf_suppressed_quota,
                         pf_suppressed_unsafe, pf_same_line_coalesced,
                         debug_pf_controller_state, debug_pf_mshr_valid,
                         debug_pf_mshr_addr, debug_pf_mshr_confidence);
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
            if (ENABLE_PREFETCH != 0 && PREFETCH_POLICY == 0) begin
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
            if (PREFETCH_POLICY == 0 &&
                (stat_cpu_misses != STREAM_ACCESSES ||
                 stat_prefetch_useful != 0)) begin
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
            if (PREFETCH_POLICY == 0 &&
                (stat_cpu_misses != POINTER_ACCESSES ||
                 stat_prefetch_useful != 0)) begin
                $display("FAIL irregular pointer chase unexpectedly used next-line data");
                errors = errors + 1;
            end
        end
    endtask

    // Read the next semantic trace item while skipping blank lines and
    // comments.  Item kinds are 0=EOF, 1=demand, 2=warmup marker, and
    // 3=measure marker.  Keeping phase markers explicit prevents the
    // zero-bubble producer from presenting a request across an ROI boundary.
    task automatic read_next_trace_item(
        input integer trace_fd,
        inout integer trace_line_number,
        output integer item_kind,
        output integer item_operation,
        output integer item_size,
        output integer item_unsigned,
        output logic [ADDR_WIDTH-1:0] item_addr,
        output logic [DATA_WIDTH-1:0] item_data
    );
        integer scan_count;
        integer phase_code;
        reg [8*TRACE_LINE_BYTES-1:0] trace_line;
        begin
            item_kind = -1;
            item_operation = -1;
            item_size = -1;
            item_unsigned = 0;
            item_addr = '0;
            item_data = '0;
            while (item_kind < 0 && !$feof(trace_fd)) begin
                trace_line = '0;
                if ($fgets(trace_line, trace_fd) != 0) begin
                    trace_line_number = trace_line_number + 1;
                    phase_code = trace_phase_code(trace_line);
                    if (phase_code == 1) begin
                        item_kind = 2;
                    end else if (phase_code == 2) begin
                        item_kind = 3;
                    end else if (!trace_is_comment(trace_line)) begin
                        scan_count = $sscanf(trace_line, "%d %d %d %h %h",
                                             item_operation, item_size,
                                             item_unsigned, item_addr,
                                             item_data);
                        if (scan_count >= 1) begin
                            case (item_operation)
                                0: begin
                                    if (scan_count != 4 || item_size < 0 ||
                                        item_size > 3 || item_unsigned < 0 ||
                                        item_unsigned > 1) begin
                                        $fatal(1,
                                               "invalid trace load at line %0d",
                                               trace_line_number);
                                    end
                                end
                                1: begin
                                    if (scan_count != 5 || item_size < 0 ||
                                        item_size > 3) begin
                                        $fatal(1,
                                               "invalid trace store at line %0d",
                                               trace_line_number);
                                    end
                                end
                                default: begin
                                    $fatal(1,
                                           "invalid trace opcode at line %0d",
                                           trace_line_number);
                                end
                            endcase
                            item_kind = 1;
                        end
                    end
                end
            end
            if (item_kind < 0) item_kind = 0;
        end
    endtask

    // Replay one contiguous trace phase with one accepted demand and one
    // presented lookahead demand.  The cache remains single-accept: request
    // i+1 is held valid after request i is accepted, then transfers only after
    // i's response releases ST_RESP.  This is the producer behavior required
    // to exercise background prefetch issue and same-line PF-MSHR merge.
    task automatic replay_zero_bubble_segment(
        input integer trace_fd,
        inout integer trace_line_number,
        inout integer accesses,
        input integer check_load_data,
        input integer first_operation,
        input integer first_size,
        input integer first_unsigned,
        input logic [ADDR_WIDTH-1:0] first_addr,
        input logic [DATA_WIDTH-1:0] first_data,
        output integer boundary_kind,
        output integer boundary_operation,
        output integer boundary_size,
        output integer boundary_unsigned,
        output logic [ADDR_WIDTH-1:0] boundary_addr,
        output logic [DATA_WIDTH-1:0] boundary_data
    );
        integer current_operation;
        integer current_size;
        integer current_unsigned;
        logic [ADDR_WIDTH-1:0] current_addr;
        logic [DATA_WIDTH-1:0] current_data;
        integer current_seq;
        integer current_accept_cycle;
        integer current_hit_before;
        integer current_victim_before;
        integer next_kind;
        integer next_operation;
        integer next_size;
        integer next_unsigned;
        logic [ADDR_WIDTH-1:0] next_addr;
        logic [DATA_WIDTH-1:0] next_data;
        integer next_seq;
        integer timeout;
        integer segment_accepts;
        integer segment_responses;
        integer segment_records;
        integer segment_overlaps;
        logic accepted;
        logic got_response;
        logic [DATA_WIDTH-1:0] response_data;
        logic response_error;
        logic [1:0] response_cause;
        string current_op_name;
        string next_op_name;
        string response_outcome;
        begin
            current_operation = first_operation;
            current_size = first_size;
            current_unsigned = first_unsigned;
            current_addr = first_addr;
            current_data = first_data;
            current_seq = measurement_active ? accesses : -1;
            segment_accepts = 0;
            segment_responses = 0;
            segment_records = 1;
            segment_overlaps = 0;

            @(negedge clk);
            cpu_req_valid = 1'b1;
            cpu_req_addr = current_addr;
            cpu_req_write = (current_operation == 1);
            cpu_req_size = current_size[1:0];
            cpu_req_unsigned = current_unsigned != 0;
            cpu_req_wdata = current_data;
            current_op_name = (current_operation == 1) ? "store" : "load";
            last_cpu_present_cycle = cycles_since_reset -
                                     metric_cycles_base + 1;
            if (measurement_active && access_sidecar_fd != 0 &&
                access_sidecar_schema == 3) begin
                $fdisplay(access_sidecar_fd,
                          "schema=3 event=demand_present seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=pending latency=-1 details=-",
                          current_seq, last_cpu_present_cycle, current_addr,
                          current_op_name, current_size);
            end

            boundary_kind = 0;
            while (segment_responses < segment_records) begin
                accepted = 1'b0;
                timeout = 0;
                while (!accepted) begin
                    @(posedge clk);
                    accepted = cpu_req_valid && cpu_req_ready;
                    timeout = timeout + 1;
                    if (timeout > 400)
                        $fatal(1, "zero-bubble CPU request timeout");
                end
                segment_accepts = segment_accepts + 1;
                current_accept_cycle = cycles_since_reset -
                                       metric_cycles_base + 1;
                current_hit_before = stat_cpu_hits;
                current_victim_before = stat_victim_hits;
                if (measurement_active && access_sidecar_fd != 0 &&
                    access_sidecar_schema == 3) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=demand_accept seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=pending latency=0 details=-",
                              current_seq, current_accept_cycle, current_addr,
                              current_op_name, current_size);
                end

                read_next_trace_item(trace_fd, trace_line_number, next_kind,
                                     next_operation, next_size, next_unsigned,
                                     next_addr, next_data);
                if (next_kind == 1) begin
                    next_seq = measurement_active ? current_seq + 1 : -1;
                    next_op_name = (next_operation == 1) ? "store" : "load";
                    @(negedge clk);
                    // The previous request was accepted, so its payload may
                    // now be replaced.  valid deliberately stays asserted.
                    cpu_req_addr = next_addr;
                    cpu_req_write = (next_operation == 1);
                    cpu_req_size = next_size[1:0];
                    cpu_req_unsigned = next_unsigned != 0;
                    cpu_req_wdata = next_data;
                    last_cpu_present_cycle = cycles_since_reset -
                                             metric_cycles_base + 1;
                    if (measurement_active && access_sidecar_fd != 0 &&
                        access_sidecar_schema == 3) begin
                        $fdisplay(access_sidecar_fd,
                                  "schema=3 event=demand_present seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=pending latency=-1 details=-",
                                  next_seq, last_cpu_present_cycle, next_addr,
                                  next_op_name, next_size);
                    end
                end else begin
                    @(negedge clk);
                    cpu_req_valid = 1'b0;
                    cpu_req_size = SIZE_DOUBLE;
                    cpu_req_unsigned = 1'b0;
                    cpu_req_wdata = '0;
                end

                got_response = 1'b0;
                timeout = 0;
                while (!got_response) begin
                    @(posedge clk);
                    got_response = cpu_rsp_valid && cpu_rsp_ready;
                    timeout = timeout + 1;
                    if (timeout > 800)
                        $fatal(1, "zero-bubble CPU response timeout");
                end
                if (next_kind == 1) begin
                    if (!cpu_req_valid || cpu_req_addr !== next_addr ||
                        cpu_req_write !== (next_operation == 1) ||
                        cpu_req_size !== next_size[1:0]) begin
                        $fatal(1,
                               "next zero-bubble request not held during prior response");
                    end
                    segment_overlaps = segment_overlaps + 1;
                    zero_bubble_overlap_observed =
                        zero_bubble_overlap_observed + 1;
                end

                response_data = cpu_rsp_rdata;
                response_error = cpu_rsp_error;
                response_cause = cpu_rsp_error_cause;
                last_cpu_response_cycle = cycles_since_reset -
                                          metric_cycles_base + 1;
                last_cpu_latency = last_cpu_response_cycle -
                                   current_accept_cycle;
                if (stat_cpu_hits != current_hit_before) begin
                    response_outcome = "l1_hit";
                end else if (stat_victim_hits != current_victim_before) begin
                    response_outcome = "victim_hit";
                end else begin
                    response_outcome = "lower_memory";
                end
                if (measurement_active && access_sidecar_fd != 0 &&
                    access_sidecar_schema == 3) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=demand_response seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=%s latency=%0d details=-",
                              current_seq, last_cpu_response_cycle,
                              current_addr, current_op_name, current_size,
                              response_outcome, last_cpu_latency);
                end

                if (current_operation == 0) begin
                    if (response_error) begin
                        $display("FAIL load raised error addr=%016x size=%0d cause=%0d",
                                 current_addr, current_size, response_cause);
                        errors = errors + 1;
                    end
                    if (check_load_data &&
                        response_data !== golden_load(current_addr,
                                                      current_size[1:0],
                                                      current_unsigned != 0)) begin
                        $display("FAIL trace load line-seq=%0d addr=%016x size=%0d unsigned=%0d expected=%016x actual=%016x",
                                 current_seq, current_addr, current_size,
                                 current_unsigned,
                                 golden_load(current_addr,
                                             current_size[1:0],
                                             current_unsigned != 0),
                                 response_data);
                        errors = errors + 1;
                    end
                end else begin
                    if (response_error) begin
                        $display("FAIL store raised error addr=%016x size=%0d cause=%0d",
                                 current_addr, current_size, response_cause);
                        errors = errors + 1;
                    end
                    update_golden_store(current_addr, current_data,
                                        current_size[1:0]);
                end

                if (measurement_active) begin
                    if (access_sidecar_fd != 0 &&
                        access_sidecar_schema == 2) begin
                        $fdisplay(access_sidecar_fd,
                                  "schema=2 event=demand seq=%0d cycle=%0d addr=%016h op=%s size=%0d outcome=%s details=-",
                                  current_seq, current_accept_cycle,
                                  current_addr, current_op_name, current_size,
                                  response_outcome);
                    end
                    accesses = accesses + 1;
                end
                segment_responses = segment_responses + 1;

                if (next_kind == 1) begin
                    current_operation = next_operation;
                    current_size = next_size;
                    current_unsigned = next_unsigned;
                    current_addr = next_addr;
                    current_data = next_data;
                    current_seq = next_seq;
                    current_op_name = next_op_name;
                    segment_records = segment_records + 1;
                end else begin
                    boundary_kind = next_kind;
                    boundary_operation = next_operation;
                    boundary_size = next_size;
                    boundary_unsigned = next_unsigned;
                    boundary_addr = next_addr;
                    boundary_data = next_data;
                end
            end

            if (segment_accepts != segment_responses) begin
                $fatal(1,
                       "zero-bubble accepted/response mismatch accepts=%0d responses=%0d",
                       segment_accepts, segment_responses);
            end
            if (segment_records > 1 &&
                segment_overlaps != segment_records - 1) begin
                $fatal(1,
                       "zero-bubble overlap mismatch records=%0d overlaps=%0d",
                       segment_records, segment_overlaps);
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
        integer check_load_data;
        integer accesses;
        integer has_phase_markers;
        integer saw_measure_phase;
        integer hit_before;
        integer victim_before;
        integer accept_cycle;
        integer is_phase_line;
        integer phase_code;
        integer item_kind;
        integer item_operation;
        integer item_size;
        integer item_unsigned;
        integer boundary_kind;
        integer boundary_operation;
        integer boundary_size;
        integer boundary_unsigned;
        reg [8*TRACE_LINE_BYTES-1:0] trace_line;
        logic [ADDR_WIDTH-1:0] addr;
        logic [DATA_WIDTH-1:0] data;
        logic [ADDR_WIDTH-1:0] item_addr;
        logic [DATA_WIDTH-1:0] item_data;
        logic [ADDR_WIDTH-1:0] boundary_addr;
        logic [DATA_WIDTH-1:0] boundary_data;
        logic [DATA_WIDTH-1:0] actual;
        logic [1:0] size;
        logic unsigned_load;
        string outcome;
        begin
            trace_fd = $fopen(trace_path, "r");
            if (trace_fd == 0) begin
                $fatal(1, "cannot open trace file: %s", trace_path);
            end

            // Detect phased traces before replay so warmup is guaranteed to
            // execute with every prefetch source disabled.  Legacy traces
            // without markers remain whole-ROI measurement traces.
            has_phase_markers = 0;
            while (!$feof(trace_fd)) begin
                trace_line = '0;
                if ($fgets(trace_line, trace_fd) != 0) begin
                    if (trace_phase_code(trace_line) != 0) begin
                        has_phase_markers = 1;
                    end
                end
            end
            $fclose(trace_fd);
            trace_fd = $fopen(trace_path, "r");
            if (trace_fd == 0) begin
                $fatal(1, "cannot reopen trace file: %s", trace_path);
            end

            $display("TEST trace replay file=%s ways=%0d sets=%0d line_bytes=%0d prefetch=%0d phased=%0d",
                     trace_path, NUM_WAYS, NUM_SETS, LINE_BYTES,
                     ENABLE_PREFETCH, has_phase_markers);
            check_load_data = !$test$plusargs("TRACE_SKIP_LOAD_CHECKS");
            if (!check_load_data) begin
                $display("TRACE load-data checks disabled");
            end
            accesses = 0;
            saw_measure_phase = 0;
            measurement_active = !has_phase_markers;
            cfg_prefetch_enable = (!has_phase_markers) &&
                                  (ENABLE_PREFETCH != 0);
            cfg_next_line_enable = cfg_prefetch_enable;
            snapshot_measurement_counters();
            trace_line_number = 0;
            zero_bubble_overlap_observed = 0;
            if (producer_profile == 1) begin
                read_next_trace_item(trace_fd, trace_line_number, item_kind,
                                     item_operation, item_size, item_unsigned,
                                     item_addr, item_data);
                while (item_kind != 0) begin
                    case (item_kind)
                        2: begin
                            if (saw_measure_phase) begin
                                $fatal(1,
                                       "warmup phase follows measure at line %0d",
                                       trace_line_number);
                            end
                            measurement_active = 1'b0;
                            cfg_prefetch_enable = 1'b0;
                            cfg_next_line_enable = 1'b0;
                            read_next_trace_item(
                                trace_fd, trace_line_number, item_kind,
                                item_operation, item_size, item_unsigned,
                                item_addr, item_data
                            );
                        end
                        3: begin
                            if (saw_measure_phase) begin
                                $fatal(1,
                                       "duplicate measure phase at line %0d",
                                       trace_line_number);
                            end
                            // replay_zero_bubble_segment returns only after
                            // its last response and deasserts request valid,
                            // so no warmup request can cross this drain.
                            wait_for_quiescence();
                            snapshot_measurement_counters();
                            accesses = 0;
                            saw_measure_phase = 1;
                            measurement_active = 1'b1;
                            cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
                            cfg_next_line_enable = (ENABLE_PREFETCH != 0);
                            read_next_trace_item(
                                trace_fd, trace_line_number, item_kind,
                                item_operation, item_size, item_unsigned,
                                item_addr, item_data
                            );
                        end
                        1: begin
                            replay_zero_bubble_segment(
                                trace_fd, trace_line_number, accesses,
                                check_load_data, item_operation, item_size,
                                item_unsigned, item_addr, item_data,
                                boundary_kind, boundary_operation,
                                boundary_size, boundary_unsigned,
                                boundary_addr, boundary_data
                            );
                            item_kind = boundary_kind;
                            item_operation = boundary_operation;
                            item_size = boundary_size;
                            item_unsigned = boundary_unsigned;
                            item_addr = boundary_addr;
                            item_data = boundary_data;
                        end
                        default: begin
                            $fatal(1, "unknown parsed trace item %0d",
                                   item_kind);
                        end
                    endcase
                end
                $display("ZERO_BUBBLE_RESULT overlaps=%0d",
                         zero_bubble_overlap_observed);
            end else begin
            while (!$feof(trace_fd)) begin
                trace_line = '0;
                if ($fgets(trace_line, trace_fd) != 0) begin
                    trace_line_number = trace_line_number + 1;
                    operation = -1;
                    scan_count = 0;
                    trace_size = -1;
                    trace_unsigned = 0;
                    addr = '0;
                    data = '0;
                    is_phase_line = 0;
                    phase_code = trace_phase_code(trace_line);
                    if (phase_code == 1) begin
                        is_phase_line = 1;
                        if (saw_measure_phase) begin
                            $fatal(1, "warmup phase follows measure at line %0d",
                                   trace_line_number);
                        end
                        measurement_active = 1'b0;
                        cfg_prefetch_enable = 1'b0;
                        cfg_next_line_enable = 1'b0;
                    end else if (phase_code == 2) begin
                            is_phase_line = 1;
                            if (saw_measure_phase) begin
                                $fatal(1, "duplicate measure phase at line %0d",
                                       trace_line_number);
                            end
                            wait_for_quiescence();
                            snapshot_measurement_counters();
                            accesses = 0;
                            saw_measure_phase = 1;
                            measurement_active = 1'b1;
                            cfg_prefetch_enable = (ENABLE_PREFETCH != 0);
                            cfg_next_line_enable = (ENABLE_PREFETCH != 0);
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
                                    $fatal(1, "invalid trace load at line %0d",
                                           trace_line_number);
                                end
                                size = trace_size;
                                unsigned_load = trace_unsigned != 0;
                                hit_before = stat_cpu_hits;
                                victim_before = stat_victim_hits;
                                accept_cycle = cycles_since_reset -
                                               metric_cycles_base + 1;
                                sidecar_request_active = measurement_active;
                                sidecar_request_seq = accesses;
                                sidecar_hit_before = hit_before;
                                sidecar_victim_before = victim_before;
                                cpu_load(addr, size, unsigned_load, actual);
                                sidecar_request_active = 1'b0;
                                if (check_load_data &&
                                    actual !== golden_load(addr, size,
                                                           unsigned_load)) begin
                                    $display("FAIL trace load line=%0d addr=%016x size=%0d unsigned=%0d expected=%016x actual=%016x",
                                             trace_line_number, addr, size,
                                             unsigned_load,
                                             golden_load(addr, size,
                                                         unsigned_load),
                                             actual);
                                    errors = errors + 1;
                                end
                                if (measurement_active) begin
                                    accesses = accesses + 1;
                                    if (stat_cpu_hits != hit_before) begin
                                        outcome = "l1_hit";
                                    end else if (stat_victim_hits != victim_before) begin
                                        outcome = "victim_hit";
                                    end else begin
                                        outcome = "lower_memory";
                                    end
                                    if (access_sidecar_fd != 0) begin
                                        if (access_sidecar_schema == 2) begin
                                            $fdisplay(access_sidecar_fd,
                                                      "schema=2 event=demand seq=%0d cycle=%0d addr=%016h op=load size=%0d outcome=%s details=-",
                                                      accesses - 1, accept_cycle,
                                                      addr, size, outcome);
                                        end
                                    end
                                end
                            end
                            1: begin
                                if (scan_count != 5 ||
                                    trace_size < 0 || trace_size > 3) begin
                                    $fatal(1, "invalid trace store at line %0d",
                                           trace_line_number);
                                end
                                size = trace_size;
                                hit_before = stat_cpu_hits;
                                victim_before = stat_victim_hits;
                                accept_cycle = cycles_since_reset -
                                               metric_cycles_base + 1;
                                sidecar_request_active = measurement_active;
                                sidecar_request_seq = accesses;
                                sidecar_hit_before = hit_before;
                                sidecar_victim_before = victim_before;
                                cpu_store(addr, size, data);
                                sidecar_request_active = 1'b0;
                                update_golden_store(addr, data, size);
                                if (measurement_active) begin
                                    accesses = accesses + 1;
                                    if (stat_cpu_hits != hit_before) begin
                                        outcome = "l1_hit";
                                    end else if (stat_victim_hits != victim_before) begin
                                        outcome = "victim_hit";
                                    end else begin
                                        outcome = "lower_memory";
                                    end
                                    if (access_sidecar_fd != 0) begin
                                        if (access_sidecar_schema == 2) begin
                                            $fdisplay(access_sidecar_fd,
                                                      "schema=2 event=demand seq=%0d cycle=%0d addr=%016h op=store size=%0d outcome=%s details=-",
                                                      accesses - 1, accept_cycle,
                                                      addr, size, outcome);
                                        end
                                    end
                                end
                            end
                            default: begin
                                $fatal(1, "invalid trace opcode at line %0d",
                                       trace_line_number);
                            end
                        endcase
                    end
                end
            end
            end
            $fclose(trace_fd);
            if (has_phase_markers && !saw_measure_phase) begin
                $fatal(1, "phased trace does not contain a measure phase");
            end
            wait_for_quiescence();
            report_workload("trace_replay", accesses);
        end
    endtask

    assign mem_req_ready = !read_pending &&
                           ((MEM_READY_MODE == 0) ? 1'b1 :
                            (MEM_READY_MODE == 1) ?
                                (mem_ready_phase != 3'b000) :
                            (MEM_READY_MODE == 2) ?
                                (mem_ready_lfsr[0] || mem_ready_lfsr[3]) :
                                1'b0);

    always_ff @(posedge clk or negedge rst_n) begin
        integer b;
        if (!rst_n) begin
            read_pending <= 1'b0;
            read_addr <= '0;
            read_countdown <= 0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_rdata <= '0;
            mem_ready_phase <= '0;
            mem_ready_lfsr <= 32'h4700_2026;
            accepted_mem_reads <= 0;
            accepted_demand_mem_reads <= 0;
            accepted_prefetch_mem_reads <= 0;
            accepted_mem_writes <= 0;
            cycles_since_reset <= 0;
        end else begin
            mem_rsp_valid <= 1'b0;
            mem_ready_phase <= mem_ready_phase + 1'b1;
            mem_ready_lfsr <= {mem_ready_lfsr[30:0],
                               mem_ready_lfsr[31] ^ mem_ready_lfsr[21] ^
                               mem_ready_lfsr[1] ^ mem_ready_lfsr[0]};
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
                    if (debug_req_is_prefetch) begin
                        accepted_prefetch_mem_reads <=
                            accepted_prefetch_mem_reads + 1;
                    end else begin
                        accepted_demand_mem_reads <=
                            accepted_demand_mem_reads + 1;
                    end
                    read_pending <= 1'b1;
                    read_addr <= mem_req_addr;
                    read_countdown <= MEM_LATENCY;
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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sidecar_measurement_was_active = 1'b0;
            sidecar_pf_addr = '0;
            sidecar_pf_addr_valid = 1'b0;
            sidecar_prev_pf_returned = '0;
            sidecar_prev_pf_installed = '0;
            sidecar_prev_pf_merged = '0;
            sidecar_prev_pf_discarded = '0;
            sidecar_prev_pf_candidates = '0;
            sidecar_prev_pf_admitted = '0;
            sidecar_prev_pf_useful = '0;
            sidecar_prev_pf_unused_evicted = '0;
            sidecar_prev_pf_cancelled = '0;
            sidecar_prev_pf_suppressed_quota = '0;
            sidecar_prev_pf_suppressed_unsafe = '0;
            sidecar_prev_pf_caused_writebacks = '0;
            sidecar_prev_controller_state = '0;
        end else if (!measurement_active) begin
            // Warmup is intentionally absent from the measurement sidecar.
            // Synchronize the edge detector so the first measured cycle does
            // not replay lifecycle transitions that happened during warmup.
            sidecar_measurement_was_active = 1'b0;
            sidecar_pf_addr_valid = 1'b0;
            sidecar_prev_pf_returned = stat_pf_returned;
            sidecar_prev_pf_installed = stat_pf_installed;
            sidecar_prev_pf_merged = stat_pf_merged;
            sidecar_prev_pf_discarded = stat_pf_discarded;
            sidecar_prev_pf_candidates = stat_pf_candidates;
            sidecar_prev_pf_admitted = stat_pf_admitted;
            sidecar_prev_pf_useful = stat_prefetch_useful;
            sidecar_prev_pf_unused_evicted = stat_pf_unused_evicted;
            sidecar_prev_pf_cancelled = stat_pf_cancelled;
            sidecar_prev_pf_suppressed_quota = stat_pf_suppressed_quota;
            sidecar_prev_pf_suppressed_unsafe = stat_pf_suppressed_unsafe;
            sidecar_prev_pf_caused_writebacks = stat_pf_caused_writebacks;
            sidecar_prev_controller_state = debug_pf_controller_state;
        end else begin
            if (!sidecar_measurement_was_active) begin
                sidecar_measurement_was_active = 1'b1;
                sidecar_prev_pf_returned = stat_pf_returned;
                sidecar_prev_pf_installed = stat_pf_installed;
                sidecar_prev_pf_merged = stat_pf_merged;
                sidecar_prev_pf_discarded = stat_pf_discarded;
                sidecar_prev_pf_candidates = stat_pf_candidates;
                sidecar_prev_pf_admitted = stat_pf_admitted;
                sidecar_prev_pf_useful = stat_prefetch_useful;
                sidecar_prev_pf_unused_evicted = stat_pf_unused_evicted;
                sidecar_prev_pf_cancelled = stat_pf_cancelled;
                sidecar_prev_pf_suppressed_quota = stat_pf_suppressed_quota;
                sidecar_prev_pf_suppressed_unsafe = stat_pf_suppressed_unsafe;
                sidecar_prev_pf_caused_writebacks = stat_pf_caused_writebacks;
                sidecar_prev_controller_state = debug_pf_controller_state;
                if (access_sidecar_fd != 0 &&
                    access_sidecar_schema == 3) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=controller_state seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=state_%0d latency=0 details=mshr_valid:%0d,mshr_addr:%016h,mshr_confidence:%0d",
                              cycles_since_reset - metric_cycles_base,
                              {ADDR_WIDTH{1'b0}}, LINE_BYTES,
                              debug_pf_controller_state,
                              debug_pf_mshr_valid, debug_pf_mshr_addr,
                              debug_pf_mshr_confidence);
                end
            end

            if (mem_req_valid && mem_req_ready && !mem_req_write &&
                debug_req_is_prefetch) begin
                sidecar_pf_addr = mem_req_addr;
                sidecar_pf_addr_valid = 1'b1;
                if (access_sidecar_fd != 0 && access_sidecar_schema == 2) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=2 event=prefetch_issue seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=lower_memory details=-",
                              cycles_since_reset - metric_cycles_base,
                              mem_req_addr, LINE_BYTES);
                end else if (access_sidecar_fd != 0) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_issue seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=lower_memory latency=-1 details=controller:%0d,mshr_valid:%0d,mshr_confidence:%0d",
                              cycles_since_reset - metric_cycles_base,
                              mem_req_addr, LINE_BYTES,
                              debug_pf_controller_state,
                              debug_pf_mshr_valid,
                              debug_pf_mshr_confidence);
                end
            end

            if (event_prefetch_fill && access_sidecar_fd != 0 &&
                (access_sidecar_schema == 2 || PREFETCH_POLICY == 0)) begin
                if (access_sidecar_schema == 2) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=2 event=prefetch_fill seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=l1_hit details=-",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES);
                end else begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_fill seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=l1_hit latency=-1 details=-",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES);
                end
            end

            if (access_sidecar_fd != 0 && access_sidecar_schema == 3 &&
                PREFETCH_POLICY == 1) begin
                for (sidecar_delta_i = sidecar_prev_pf_candidates;
                     sidecar_delta_i < stat_pf_candidates;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_candidate seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=queued latency=-1 details=controller:%0d,confidence:%0d",
                              cycles_since_reset - metric_cycles_base,
                              (ext_prefetch_valid && ext_prefetch_ready) ?
                              {ext_prefetch_addr[ADDR_WIDTH-1:OFFSET_BITS],
                               {OFFSET_BITS{1'b0}}} :
                              dut.next_line_candidate_addr,
                              LINE_BYTES, debug_pf_controller_state,
                              (ext_prefetch_valid && ext_prefetch_ready) ?
                              3 : dut.next_line_candidate_confidence);
                end
                for (sidecar_delta_i = sidecar_prev_pf_admitted;
                     sidecar_delta_i < stat_pf_admitted;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_admit seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=admitted latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              sidecar_pf_addr_valid ? sidecar_pf_addr :
                              dut.req_line_addr_comb,
                              LINE_BYTES, debug_pf_controller_state);
                end
                if (stat_pf_returned != sidecar_prev_pf_returned) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_return seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=returned latency=-1 details=controller:%0d,mshr_valid:%0d",
                              cycles_since_reset - metric_cycles_base,
                              sidecar_pf_addr_valid ? sidecar_pf_addr :
                              debug_pf_mshr_addr,
                              LINE_BYTES, debug_pf_controller_state,
                              debug_pf_mshr_valid);
                end
                if (stat_pf_installed != sidecar_prev_pf_installed) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_install seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=l1_hit latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              sidecar_pf_addr_valid ? sidecar_pf_addr :
                              dut.req_line_addr_comb,
                              LINE_BYTES, debug_pf_controller_state);
                    sidecar_pf_addr_valid = 1'b0;
                end
                if (stat_pf_merged != sidecar_prev_pf_merged) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_merge seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=late_merge latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              debug_pf_mshr_valid ? debug_pf_mshr_addr :
                              sidecar_pf_addr,
                              LINE_BYTES, debug_pf_controller_state);
                    sidecar_pf_addr_valid = 1'b0;
                end
                if (stat_pf_discarded != sidecar_prev_pf_discarded) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_discard seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=discarded latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              sidecar_pf_addr_valid ? sidecar_pf_addr :
                              debug_pf_mshr_addr,
                              LINE_BYTES, debug_pf_controller_state);
                    sidecar_pf_addr_valid = 1'b0;
                end
                for (sidecar_delta_i = sidecar_prev_pf_useful;
                     sidecar_delta_i < stat_prefetch_useful;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_use seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=timely_use latency=0 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES,
                              debug_pf_controller_state);
                end
                for (sidecar_delta_i = sidecar_prev_pf_unused_evicted;
                     sidecar_delta_i < stat_pf_unused_evicted;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_evict seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=unused_evict latency=-1 details=vc_bypass:1,controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES,
                              debug_pf_controller_state);
                end
                for (sidecar_delta_i = sidecar_prev_pf_cancelled;
                     sidecar_delta_i < stat_pf_cancelled;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_cancel seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=cancelled latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES,
                              debug_pf_controller_state);
                end
                for (sidecar_delta_i = sidecar_prev_pf_suppressed_quota;
                     sidecar_delta_i < stat_pf_suppressed_quota;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_suppressed seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=quota latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              dut.next_line_candidate_addr, LINE_BYTES,
                              debug_pf_controller_state);
                end
                for (sidecar_delta_i = sidecar_prev_pf_suppressed_unsafe;
                     sidecar_delta_i < stat_pf_suppressed_unsafe;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_suppressed seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=unsafe latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              dut.req_line_addr_comb, LINE_BYTES,
                              debug_pf_controller_state);
                end
                for (sidecar_delta_i = sidecar_prev_pf_caused_writebacks;
                     sidecar_delta_i < stat_pf_caused_writebacks;
                     sidecar_delta_i = sidecar_delta_i + 1) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=prefetch_writeback seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=writeback latency=-1 details=controller:%0d",
                              cycles_since_reset - metric_cycles_base,
                              mem_req_addr, LINE_BYTES,
                              debug_pf_controller_state);
                end
                if (debug_pf_controller_state !=
                    sidecar_prev_controller_state) begin
                    $fdisplay(access_sidecar_fd,
                              "schema=3 event=controller_state seq=-1 cycle=%0d addr=%016h op=prefetch size=%0d outcome=state_%0d latency=0 details=mshr_valid:%0d,mshr_addr:%016h,mshr_confidence:%0d",
                              cycles_since_reset - metric_cycles_base,
                              {ADDR_WIDTH{1'b0}}, LINE_BYTES,
                              debug_pf_controller_state,
                              debug_pf_mshr_valid, debug_pf_mshr_addr,
                              debug_pf_mshr_confidence);
                end
            end

            sidecar_prev_pf_returned = stat_pf_returned;
            sidecar_prev_pf_installed = stat_pf_installed;
            sidecar_prev_pf_merged = stat_pf_merged;
            sidecar_prev_pf_discarded = stat_pf_discarded;
            sidecar_prev_pf_candidates = stat_pf_candidates;
            sidecar_prev_pf_admitted = stat_pf_admitted;
            sidecar_prev_pf_useful = stat_prefetch_useful;
            sidecar_prev_pf_unused_evicted = stat_pf_unused_evicted;
            sidecar_prev_pf_cancelled = stat_pf_cancelled;
            sidecar_prev_pf_suppressed_quota = stat_pf_suppressed_quota;
            sidecar_prev_pf_suppressed_unsafe = stat_pf_suppressed_unsafe;
            sidecar_prev_pf_caused_writebacks = stat_pf_caused_writebacks;
            sidecar_prev_controller_state = debug_pf_controller_state;
        end
    end

    initial begin
        string trace_path;
        string sidecar_path;
        integer command_mem_latency;
        integer command_mem_ready_mode;
        clk = 1'b0;
        rst_n = 1'b0;
        errors = 0;
        protocol_errors = 0;
        access_sidecar_fd = 0;
        access_sidecar_schema = 3;
        producer_profile = PRODUCER_PROFILE;
        producer_gap = PRODUCER_GAP;
        sidecar_request_active = 1'b0;
        sidecar_request_seq = -1;
        sidecar_hit_before = 0;
        sidecar_victim_before = 0;
        measurement_active = 1'b0;
        trace_id = '0;
        void'($value$plusargs("PRODUCER_PROFILE=%d", producer_profile));
        void'($value$plusargs("PRODUCER_GAP=%d", producer_gap));
        command_mem_latency = MEM_LATENCY;
        command_mem_ready_mode = MEM_READY_MODE;
        if ($value$plusargs("MEM_LATENCY=%d", command_mem_latency) &&
            command_mem_latency != MEM_LATENCY) begin
            $fatal(1,
                   "MEM_LATENCY command provenance %0d does not match elaborated value %0d",
                   command_mem_latency, MEM_LATENCY);
        end
        if ($value$plusargs("MEM_READY_MODE=%d", command_mem_ready_mode) &&
            command_mem_ready_mode != MEM_READY_MODE) begin
            $fatal(1,
                   "MEM_READY_MODE command provenance %0d does not match elaborated value %0d",
                   command_mem_ready_mode, MEM_READY_MODE);
        end
        if (MEM_LATENCY < 0) begin
            $fatal(1, "MEM_LATENCY must be non-negative");
        end
        if (MEM_READY_MODE < 0 || MEM_READY_MODE > 2) begin
            $fatal(1, "MEM_READY_MODE must be 0, 1, or 2");
        end
        if (producer_profile < 0 || producer_profile > 2) begin
            $fatal(1, "PRODUCER_PROFILE must be 0, 1, or 2");
        end
        if (producer_gap < 0) begin
            $fatal(1, "PRODUCER_GAP must be non-negative");
        end
        if ($value$plusargs("SIDECAR_SCHEMA=%d", access_sidecar_schema)) begin
            if (access_sidecar_schema != 2 && access_sidecar_schema != 3) begin
                $fatal(1, "SIDECAR_SCHEMA must be 2 or 3");
            end
        end
        if (!$value$plusargs("CONFIG_ID=%s", config_id)) begin
            if (NUM_WAYS == 1 && NUM_SETS == 8 &&
                VICTIM_ENTRIES == 4 && ENABLE_PREFETCH == 0) begin
                config_id = "dm_s8_vc4_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 4 && ENABLE_PREFETCH == 0) begin
                config_id = "2w_s4_vc4_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 8 && ENABLE_PREFETCH == 0) begin
                config_id = "2w_s4_vc8_pf0";
            end else if (NUM_WAYS == 2 && NUM_SETS == 4 &&
                         VICTIM_ENTRIES == 4 && ENABLE_PREFETCH != 0) begin
                config_id = "2w_s4_vc4_pf1";
            end else begin
                config_id = $sformatf("%0dw_s%0d_vc%0d_pf%0d",
                                      NUM_WAYS, NUM_SETS, VICTIM_ENTRIES,
                                      ENABLE_PREFETCH);
            end
        end
        if (!$value$plusargs("TRACE_ID=%s", trace_id)) begin
            trace_id = '0;
        end
        if ($value$plusargs("ACCESS_SIDECAR=%s", sidecar_path)) begin
            access_sidecar_fd = $fopen(sidecar_path, "w");
            if (access_sidecar_fd == 0) begin
                $fatal(1, "cannot open access sidecar: %s", sidecar_path);
            end
        end
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
        end else if (ENABLE_PREFETCH != 0 && PREFETCH_POLICY == 0) begin
            test_prefetch_arbitration();
            test_prefetch();
        end else if (ENABLE_PREFETCH != 0) begin
            // Optimized policy behavior is exercised by the dedicated stream,
            // controller and shadow tests.  Reuse the synthetic workloads here
            // only as an end-to-end data/protocol smoke test.
            test_workload_boundaries();
        end else begin
            test_baseline();
            test_rv64_alignment_faults();
            test_victim_hit();
            test_dirty_victim_writeback();
            test_response_backpressure();
            test_randomized_scoreboard();
        end

        if (access_sidecar_fd != 0) begin
            $fclose(access_sidecar_fd);
            access_sidecar_fd = 0;
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
