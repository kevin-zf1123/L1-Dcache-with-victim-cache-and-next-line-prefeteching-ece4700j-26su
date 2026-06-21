`timescale 1ns/1ps

module l1d_cache #(
    parameter integer ADDR_WIDTH       = 32,
    parameter integer DATA_WIDTH       = 32,
    parameter integer LINE_BYTES       = 16,
    parameter integer NUM_SETS         = 8,
    parameter integer NUM_WAYS         = 2,
    parameter integer VICTIM_ENTRIES   = 4,
    parameter integer ENABLE_PREFETCH  = 1
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         cfg_prefetch_enable,
    input  logic                         cfg_next_line_enable,
    input  logic                         ext_prefetch_valid,
    output logic                         ext_prefetch_ready,
    input  logic [ADDR_WIDTH-1:0]        ext_prefetch_addr,

    input  logic                         cpu_req_valid,
    output logic                         cpu_req_ready,
    input  logic [ADDR_WIDTH-1:0]        cpu_req_addr,
    input  logic                         cpu_req_write,
    input  logic [DATA_WIDTH-1:0]        cpu_req_wdata,
    input  logic [(DATA_WIDTH/8)-1:0]    cpu_req_wstrb,

    output logic                         cpu_rsp_valid,
    input  logic                         cpu_rsp_ready,
    output logic [DATA_WIDTH-1:0]        cpu_rsp_rdata,

    output logic                         mem_req_valid,
    input  logic                         mem_req_ready,
    output logic                         mem_req_write,
    output logic [ADDR_WIDTH-1:0]        mem_req_addr,
    output logic [(LINE_BYTES*8)-1:0]    mem_req_wdata,
    input  logic                         mem_rsp_valid,
    input  logic [(LINE_BYTES*8)-1:0]    mem_rsp_rdata,

    output logic [31:0]                  stat_cpu_hits,
    output logic [31:0]                  stat_cpu_misses,
    output logic [31:0]                  stat_victim_hits,
    output logic [31:0]                  stat_writebacks,
    output logic [31:0]                  stat_prefetch_fills,
    output logic [31:0]                  stat_prefetch_useful,
    output logic [31:0]                  stat_prefetch_useless,
    output logic [31:0]                  stat_prefetch_pollution,
    output logic [31:0]                  stat_prefetch_dropped,

    output logic                         cache_idle,
    output logic                         event_cpu_access,
    output logic                         event_cpu_hit,
    output logic                         event_cpu_miss,
    output logic                         event_victim_hit,
    output logic                         event_writeback,
    output logic                         event_prefetch_fill,
    output logic                         event_prefetch_useful,
    output logic                         event_prefetch_useless,
    output logic                         event_prefetch_pollution,
    output logic                         event_prefetch_dropped
);
    import l1d_cache_pkg::*;

    localparam integer LINE_BITS       = LINE_BYTES * 8;
    localparam integer WORD_BYTES      = DATA_WIDTH / 8;
    localparam integer OFFSET_BITS     = $clog2(LINE_BYTES);
    localparam integer SET_BITS        = $clog2(NUM_SETS);
    localparam integer TAG_BITS        = ADDR_WIDTH - OFFSET_BITS - SET_BITS;
    localparam integer SRAM_ADDR_WIDTH = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer WAY_BITS        = (NUM_WAYS > 1) ? $clog2(NUM_WAYS) : 1;
    localparam integer VC_BITS         = (VICTIM_ENTRIES > 1) ? $clog2(VICTIM_ENTRIES) : 1;

    state_t state;

    logic array_en;
    logic [NUM_WAYS-1:0] tag_we;
    logic [NUM_WAYS-1:0] data_we;
    logic [SRAM_ADDR_WIDTH-1:0] array_addr;
    logic [TAG_BITS-1:0] array_wtag;
    logic [LINE_BITS-1:0] array_wdata;
    logic [NUM_WAYS*TAG_BITS-1:0] tag_q_flat;
    logic [NUM_WAYS*LINE_BITS-1:0] data_q_flat;
    logic [TAG_BITS-1:0] tag_q [0:NUM_WAYS-1];
    logic [LINE_BITS-1:0] data_q [0:NUM_WAYS-1];

    logic valid_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic dirty_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic prefetched_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [WAY_BITS-1:0] replacement_way [0:NUM_SETS-1];

    logic vc_valid [0:VICTIM_ENTRIES-1];
    logic vc_dirty [0:VICTIM_ENTRIES-1];
    logic vc_prefetched [0:VICTIM_ENTRIES-1];
    logic [ADDR_WIDTH-1:0] vc_addr [0:VICTIM_ENTRIES-1];
    logic [LINE_BITS-1:0] vc_data [0:VICTIM_ENTRIES-1];
    logic [VC_BITS-1:0] vc_rr;
    logic [VICTIM_ENTRIES-1:0] vc_valid_flat;
    logic [VICTIM_ENTRIES-1:0] vc_dirty_flat;
    logic [VICTIM_ENTRIES-1:0] vc_prefetched_flat;
    logic [VICTIM_ENTRIES*ADDR_WIDTH-1:0] vc_addr_flat;
    logic [VICTIM_ENTRIES*LINE_BITS-1:0] vc_data_flat;

    logic [ADDR_WIDTH-1:0] req_addr;
    logic req_write;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic [WORD_BYTES-1:0] req_wstrb;
    logic req_is_prefetch;

    logic [WAY_BITS-1:0] selected_way;
    logic [VC_BITS-1:0] selected_vc;
    logic [LINE_BITS-1:0] working_line;
    logic working_dirty;
    logic [LINE_BITS-1:0] fill_line;

    logic evicted_valid;
    logic evicted_dirty;
    logic evicted_prefetched;
    logic [ADDR_WIDTH-1:0] evicted_addr;
    logic [LINE_BITS-1:0] evicted_data;

    logic [ADDR_WIDTH-1:0] wb_addr;
    logic [LINE_BITS-1:0] wb_data;

    logic [DATA_WIDTH-1:0] response_data;
    logic next_line_trigger;
    logic next_line_candidate_valid;
    logic next_line_candidate_ready;
    logic [ADDR_WIDTH-1:0] next_line_candidate_addr;
    logic next_line_dropped;
    logic state_is_idle;
    logic [WAY_BITS-1:0] replacement_way_current;
    logic [LINE_BITS-1:0] hit_line_data_current;
    logic [ADDR_WIDTH-1:0] replacement_line_addr_current;
    logic [LINE_BITS-1:0] replacement_line_data_current;
    logic replacement_line_dirty_current;
    logic replacement_line_prefetched_current;
    logic [LINE_BITS-1:0] victim_line_data_current;
    logic victim_line_dirty_current;
    logic victim_rr_valid_current;
    logic victim_rr_dirty_current;
    logic [ADDR_WIDTH-1:0] victim_rr_addr_current;
    logic [LINE_BITS-1:0] victim_rr_data_current;
    logic arb_cpu_req_ready;
    logic arb_ext_prefetch_ready;
    logic arb_next_line_candidate_ready;
    logic arb_idle_array_en;
    logic [SRAM_ADDR_WIDTH-1:0] arb_idle_array_addr;
    logic arb_launch_req_valid;
    logic [ADDR_WIDTH-1:0] arb_launch_req_addr;
    logic arb_launch_req_write;
    logic [DATA_WIDTH-1:0] arb_launch_req_wdata;
    logic [WORD_BYTES-1:0] arb_launch_req_wstrb;
    logic arb_launch_req_is_prefetch;

    integer reset_i;
    integer reset_j;
    integer assert_i;
    integer assert_j;
    logic l1_hit_comb;
    logic victim_hit_valid_comb;
    logic invalid_way_valid_comb;
    logic [NUM_WAYS-1:0] way_match_comb;
    logic [WAY_BITS-1:0] hit_way_comb;
    logic [WAY_BITS-1:0] invalid_way_comb;
    logic [VC_BITS-1:0] victim_hit_comb;
    logic [SET_BITS-1:0] req_set_comb;
    logic [TAG_BITS-1:0] req_tag_comb;
    logic [ADDR_WIDTH-1:0] req_line_addr_comb;

    function automatic [SET_BITS-1:0] address_set(
        input logic [ADDR_WIDTH-1:0] addr
    );
        address_set = (addr >> OFFSET_BITS);
    endfunction

    function automatic [TAG_BITS-1:0] address_tag(
        input logic [ADDR_WIDTH-1:0] addr
    );
        address_tag = addr[ADDR_WIDTH-1 -: TAG_BITS];
    endfunction

    function automatic [ADDR_WIDTH-1:0] line_address(
        input logic [ADDR_WIDTH-1:0] addr
    );
        line_address = {addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
    endfunction

    function automatic [ADDR_WIDTH-1:0] compose_line_address(
        input logic [TAG_BITS-1:0] tag,
        input logic [SET_BITS-1:0] set_index
    );
        compose_line_address = {tag, set_index, {OFFSET_BITS{1'b0}}};
    endfunction

    function automatic [DATA_WIDTH-1:0] line_word(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer word_index;
        begin
            word_index = (addr >> $clog2(WORD_BYTES)) %
                         (LINE_BYTES / WORD_BYTES);
            line_word = line[word_index*DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    function automatic [LINE_BITS-1:0] merge_word(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] wdata,
        input logic [WORD_BYTES-1:0] wstrb
    );
        integer word_index;
        integer byte_index;
        logic [LINE_BITS-1:0] result;
        begin
            result = line;
            word_index = (addr >> $clog2(WORD_BYTES)) %
                         (LINE_BYTES / WORD_BYTES);
            for (byte_index = 0; byte_index < WORD_BYTES; byte_index = byte_index + 1) begin
                if (wstrb[byte_index]) begin
                    result[(word_index*DATA_WIDTH)+(byte_index*8) +: 8] =
                        wdata[(byte_index*8) +: 8];
                end
            end
            merge_word = result;
        end
    endfunction

    l1d_array_bank #(
        .NUM_WAYS(NUM_WAYS),
        .NUM_SETS(NUM_SETS),
        .TAG_BITS(TAG_BITS),
        .LINE_BITS(LINE_BITS),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH)
    ) array_bank (
        .clk(clk),
        .array_en(array_en),
        .tag_we(tag_we),
        .data_we(data_we),
        .array_addr(array_addr),
        .array_wtag(array_wtag),
        .array_wdata(array_wdata),
        .tag_q_flat(tag_q_flat),
        .data_q_flat(data_q_flat)
    );

    generate
        genvar way;
        for (way = 0; way < NUM_WAYS; way = way + 1) begin : gen_array_unpack
            assign tag_q[way] = tag_q_flat[way*TAG_BITS +: TAG_BITS];
            assign data_q[way] = data_q_flat[way*LINE_BITS +: LINE_BITS];
        end
        for (way = 0; way < NUM_WAYS; way = way + 1) begin : gen_way_match
            assign way_match_comb[way] =
                (tag_q[way] == req_tag_comb);
        end
    endgenerate

    generate
        genvar vc_entry;
        for (vc_entry = 0; vc_entry < VICTIM_ENTRIES; vc_entry = vc_entry + 1) begin : gen_victim_unpack
            assign vc_valid[vc_entry] = vc_valid_flat[vc_entry];
            assign vc_dirty[vc_entry] = vc_dirty_flat[vc_entry];
            assign vc_prefetched[vc_entry] = vc_prefetched_flat[vc_entry];
            assign vc_addr[vc_entry] = vc_addr_flat[vc_entry*ADDR_WIDTH +: ADDR_WIDTH];
            assign vc_data[vc_entry] = vc_data_flat[vc_entry*LINE_BITS +: LINE_BITS];
        end
    endgenerate

    l1d_next_line_prefetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES)
    ) next_line_prefetch (
        .clk(clk),
        .rst_n(rst_n),
        .enable((ENABLE_PREFETCH != 0) &&
                cfg_prefetch_enable && cfg_next_line_enable),
        .demand_fill_valid(next_line_trigger),
        .demand_line_addr(req_line_addr_comb),
        .candidate_valid(next_line_candidate_valid),
        .candidate_ready(next_line_candidate_ready),
        .candidate_addr(next_line_candidate_addr),
        .dropped(next_line_dropped)
    );

    l1d_lookup #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .TAG_BITS(TAG_BITS),
        .SET_BITS(SET_BITS),
        .WAY_BITS(WAY_BITS),
        .VC_BITS(VC_BITS)
    ) lookup (
        .req_addr(req_addr),
        .way_match(way_match_comb),
        .valid_bits(valid_bits),
        .vc_valid(vc_valid),
        .vc_addr(vc_addr),
        .l1_hit(l1_hit_comb),
        .hit_way(hit_way_comb),
        .invalid_way_valid(invalid_way_valid_comb),
        .invalid_way(invalid_way_comb),
        .victim_hit_valid(victim_hit_valid_comb),
        .victim_hit(victim_hit_comb),
        .req_set(req_set_comb),
        .req_tag(req_tag_comb),
        .req_line_addr(req_line_addr_comb)
    );

    assign state_is_idle = (state == ST_IDLE);

    always_comb begin
        replacement_way_current = replacement_way[req_set_comb];
        hit_line_data_current = data_q[hit_way_comb];
        replacement_line_addr_current =
            compose_line_address(tag_q[replacement_way_current], req_set_comb);
        replacement_line_data_current = data_q[replacement_way_current];
        replacement_line_dirty_current =
            dirty_bits[replacement_way_current][req_set_comb];
        replacement_line_prefetched_current =
            prefetched_bits[replacement_way_current][req_set_comb];
        victim_line_data_current = vc_data[victim_hit_comb];
        victim_line_dirty_current = vc_dirty[victim_hit_comb];
        victim_rr_valid_current = vc_valid[vc_rr];
        victim_rr_dirty_current = vc_dirty[vc_rr];
        victim_rr_addr_current = vc_addr[vc_rr];
        victim_rr_data_current = vc_data[vc_rr];
    end

    l1d_request_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .SRAM_ADDR_WIDTH(SRAM_ADDR_WIDTH)
    ) request_arbiter (
        .state_idle(state_is_idle),
        .prefetch_feature_en((ENABLE_PREFETCH != 0) && cfg_prefetch_enable),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_write(cpu_req_write),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_req_wstrb(cpu_req_wstrb),
        .ext_prefetch_valid(ext_prefetch_valid),
        .ext_prefetch_addr(ext_prefetch_addr),
        .next_line_candidate_valid(next_line_candidate_valid),
        .next_line_candidate_addr(next_line_candidate_addr),
        .cpu_req_ready(arb_cpu_req_ready),
        .ext_prefetch_ready(arb_ext_prefetch_ready),
        .next_line_candidate_ready(arb_next_line_candidate_ready),
        .idle_array_en(arb_idle_array_en),
        .idle_array_addr(arb_idle_array_addr),
        .launch_req_valid(arb_launch_req_valid),
        .launch_req_addr(arb_launch_req_addr),
        .launch_req_write(arb_launch_req_write),
        .launch_req_wdata(arb_launch_req_wdata),
        .launch_req_wstrb(arb_launch_req_wstrb),
        .launch_req_is_prefetch(arb_launch_req_is_prefetch)
    );

    l1d_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .LINE_BITS(LINE_BITS),
        .WAY_BITS(WAY_BITS),
        .VC_BITS(VC_BITS)
    ) controller (
        .clk(clk),
        .rst_n(rst_n),
        .arb_launch_req_valid(arb_launch_req_valid),
        .arb_launch_req_addr(arb_launch_req_addr),
        .arb_launch_req_write(arb_launch_req_write),
        .arb_launch_req_wdata(arb_launch_req_wdata),
        .arb_launch_req_wstrb(arb_launch_req_wstrb),
        .arb_launch_req_is_prefetch(arb_launch_req_is_prefetch),
        .l1_hit_comb(l1_hit_comb),
        .hit_way_comb(hit_way_comb),
        .victim_hit_valid_comb(victim_hit_valid_comb),
        .victim_hit_comb(victim_hit_comb),
        .invalid_way_valid_comb(invalid_way_valid_comb),
        .invalid_way_comb(invalid_way_comb),
        .replacement_way_current(replacement_way_current),
        .victim_rr_index_current(vc_rr),
        .replacement_line_addr_current(replacement_line_addr_current),
        .replacement_line_data_current(replacement_line_data_current),
        .replacement_line_dirty_current(replacement_line_dirty_current),
        .replacement_line_prefetched_current(replacement_line_prefetched_current),
        .hit_line_data_current(hit_line_data_current),
        .victim_line_data_current(victim_line_data_current),
        .victim_line_dirty_current(victim_line_dirty_current),
        .victim_rr_valid_current(victim_rr_valid_current),
        .victim_rr_dirty_current(victim_rr_dirty_current),
        .victim_rr_addr_current(victim_rr_addr_current),
        .victim_rr_data_current(victim_rr_data_current),
        .mem_req_ready(mem_req_ready),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata),
        .cpu_rsp_ready(cpu_rsp_ready),
        .state(state),
        .req_addr(req_addr),
        .req_write(req_write),
        .req_wdata(req_wdata),
        .req_wstrb(req_wstrb),
        .req_is_prefetch(req_is_prefetch),
        .selected_way(selected_way),
        .selected_vc(selected_vc),
        .working_line(working_line),
        .working_dirty(working_dirty),
        .fill_line(fill_line),
        .evicted_valid(evicted_valid),
        .evicted_dirty(evicted_dirty),
        .evicted_prefetched(evicted_prefetched),
        .evicted_addr(evicted_addr),
        .evicted_data(evicted_data),
        .wb_addr(wb_addr),
        .wb_data(wb_data),
        .response_data(response_data)
    );

    l1d_victim_cache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BITS(LINE_BITS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .VC_BITS(VC_BITS)
    ) victim_cache (
        .clk(clk),
        .rst_n(rst_n),
        .state(state),
        .selected_vc(selected_vc),
        .evicted_valid(evicted_valid),
        .evicted_dirty(evicted_dirty),
        .evicted_prefetched(evicted_prefetched),
        .evicted_addr(evicted_addr),
        .evicted_data(evicted_data),
        .vc_rr(vc_rr),
        .vc_valid_flat(vc_valid_flat),
        .vc_dirty_flat(vc_dirty_flat),
        .vc_prefetched_flat(vc_prefetched_flat),
        .vc_addr_flat(vc_addr_flat),
        .vc_data_flat(vc_data_flat)
    );

    always_comb begin
        cpu_req_ready = arb_cpu_req_ready;
        cpu_rsp_valid = (state == ST_RESP);
        cpu_rsp_rdata = response_data;
        cache_idle = (state == ST_IDLE);
        ext_prefetch_ready = arb_ext_prefetch_ready;
        next_line_candidate_ready = arb_next_line_candidate_ready;
        next_line_trigger =
            (state == ST_INSTALL) && !req_is_prefetch;
        event_prefetch_dropped = next_line_dropped;

        mem_req_valid = 1'b0;
        mem_req_write = 1'b0;
        mem_req_addr = '0;
        mem_req_wdata = '0;

        array_en = 1'b0;
        tag_we = '0;
        data_we = '0;
        array_addr = '0;
        array_wtag = req_tag_comb;
        array_wdata = working_line;

        if (state == ST_IDLE) begin
            array_en = arb_idle_array_en;
            array_addr = arb_idle_array_addr;
        end

        if (state == ST_HIT_WRITE || state == ST_VC_SWAP ||
            state == ST_INSTALL) begin
            array_en = 1'b1;
            array_addr = req_set_comb;
            tag_we[selected_way] = 1'b1;
            data_we[selected_way] = 1'b1;
            array_wtag = req_tag_comb;
            if (state == ST_INSTALL) begin
                array_wdata = fill_line;
            end
        end

        if (state == ST_WB_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_addr = wb_addr;
            mem_req_wdata = wb_data;
        end

        if (state == ST_MEM_READ_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_addr = req_line_addr_comb;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (reset_i = 0; reset_i < NUM_SETS;
                 reset_i = reset_i + 1) begin
                replacement_way[reset_i] <= '0;
                for (reset_j = 0; reset_j < NUM_WAYS;
                     reset_j = reset_j + 1) begin
                    valid_bits[reset_j][reset_i] <= 1'b0;
                    dirty_bits[reset_j][reset_i] <= 1'b0;
                    prefetched_bits[reset_j][reset_i] <= 1'b0;
                end
            end
        end else begin
            case (state)
                ST_LOOKUP: begin
                    if (l1_hit_comb) begin
                        if (!req_is_prefetch) begin
                            replacement_way[req_set_comb] <=
                                (hit_way_comb + 1) % NUM_WAYS;
                            if (prefetched_bits[hit_way_comb][req_set_comb]) begin
                                prefetched_bits[hit_way_comb][req_set_comb] <= 1'b0;
                            end
                        end
                    end
                end

                ST_HIT_WRITE: begin
                    dirty_bits[selected_way][req_set_comb] <= 1'b1;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                end

                ST_VC_SWAP: begin
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <= working_dirty;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    replacement_way[req_set_comb] <=
                        (selected_way + 1'b1) % NUM_WAYS;
                end

                ST_INSTALL: begin
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <=
                        (!req_is_prefetch && req_write);
                    prefetched_bits[selected_way][req_set_comb] <= req_is_prefetch;
                    replacement_way[req_set_comb] <=
                        (selected_way + 1'b1) % NUM_WAYS;
                end
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_cpu_hits <= '0;
            stat_cpu_misses <= '0;
            stat_victim_hits <= '0;
            stat_writebacks <= '0;
            stat_prefetch_fills <= '0;
            stat_prefetch_useful <= '0;
            stat_prefetch_useless <= '0;
            stat_prefetch_pollution <= '0;
            stat_prefetch_dropped <= '0;
            event_cpu_access <= 1'b0;
            event_cpu_hit <= 1'b0;
            event_cpu_miss <= 1'b0;
            event_victim_hit <= 1'b0;
            event_writeback <= 1'b0;
            event_prefetch_fill <= 1'b0;
            event_prefetch_useful <= 1'b0;
            event_prefetch_useless <= 1'b0;
            event_prefetch_pollution <= 1'b0;
        end else begin
            event_cpu_access <= 1'b0;
            event_cpu_hit <= 1'b0;
            event_cpu_miss <= 1'b0;
            event_victim_hit <= 1'b0;
            event_writeback <= 1'b0;
            event_prefetch_fill <= 1'b0;
            event_prefetch_useful <= 1'b0;
            event_prefetch_useless <= 1'b0;
            event_prefetch_pollution <= 1'b0;
            if (next_line_dropped) begin
                stat_prefetch_dropped <= stat_prefetch_dropped + 1'b1;
            end

            case (state)
                ST_IDLE: begin
                    if (cpu_req_valid) begin
                        event_cpu_access <= 1'b1;
                    end
                end

                ST_LOOKUP: begin
                    if (l1_hit_comb) begin
                        if (!req_is_prefetch) begin
                            stat_cpu_hits <= stat_cpu_hits + 1'b1;
                            event_cpu_hit <= 1'b1;
                            if (prefetched_bits[hit_way_comb][req_set_comb]) begin
                                stat_prefetch_useful <= stat_prefetch_useful + 1'b1;
                                event_prefetch_useful <= 1'b1;
                            end
                        end
                    end else if (victim_hit_valid_comb) begin
                        if (!req_is_prefetch) begin
                            stat_cpu_misses <= stat_cpu_misses + 1'b1;
                            stat_victim_hits <= stat_victim_hits + 1'b1;
                            event_cpu_miss <= 1'b1;
                            event_victim_hit <= 1'b1;
                            if (vc_prefetched[victim_hit_comb]) begin
                                stat_prefetch_useful <= stat_prefetch_useful + 1'b1;
                                event_prefetch_useful <= 1'b1;
                            end
                        end
                    end else begin
                        if (!req_is_prefetch) begin
                            stat_cpu_misses <= stat_cpu_misses + 1'b1;
                            event_cpu_miss <= 1'b1;
                        end
                        if (!invalid_way_valid_comb &&
                            req_is_prefetch &&
                            !prefetched_bits[replacement_way[req_set_comb]][req_set_comb]) begin
                            stat_prefetch_pollution <=
                                stat_prefetch_pollution + 1'b1;
                            event_prefetch_pollution <= 1'b1;
                        end
                    end
                end

                ST_WB_REQ: begin
                    if (mem_req_ready) begin
                        stat_writebacks <= stat_writebacks + 1'b1;
                        event_writeback <= 1'b1;
                    end
                end

                ST_VC_INSERT: begin
                    if (vc_valid[selected_vc] && vc_prefetched[selected_vc]) begin
                        stat_prefetch_useless <= stat_prefetch_useless + 1'b1;
                        event_prefetch_useless <= 1'b1;
                    end
                end

                ST_INSTALL: begin
                    if (req_is_prefetch) begin
                        stat_prefetch_fills <= stat_prefetch_fills + 1'b1;
                        event_prefetch_fill <= 1'b1;
                    end
                end
            endcase
        end
    end

    initial begin
        if (NUM_WAYS != 1 && NUM_WAYS != 2) begin
            $error("NUM_WAYS must be 1 or 2");
        end
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0) begin
            $error("NUM_SETS must be a power of two and at least 2");
        end
        if (DATA_WIDTH < 8 || (DATA_WIDTH % 8) != 0 ||
            (WORD_BYTES & (WORD_BYTES - 1)) != 0) begin
            $error("DATA_WIDTH must contain a power-of-two number of bytes");
        end
        if (LINE_BYTES < WORD_BYTES ||
            (LINE_BYTES % WORD_BYTES) != 0 ||
            (LINE_BYTES & (LINE_BYTES - 1)) != 0) begin
            $error("LINE_BYTES must be a power-of-two multiple of the CPU word");
        end
        if (VICTIM_ENTRIES < 1 ||
            (VICTIM_ENTRIES & (VICTIM_ENTRIES - 1)) != 0) begin
            $error("VICTIM_ENTRIES must be a non-zero power of two");
        end
        if (ADDR_WIDTH <= OFFSET_BITS + SET_BITS) begin
            $error("ADDR_WIDTH is too small for the configured cache geometry");
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n) begin
            if (cpu_req_valid && cpu_req_ready &&
                (cpu_req_addr % WORD_BYTES) != 0) begin
                $fatal(1, "CPU request address must be word aligned");
            end
            if (state == ST_LOOKUP && l1_hit_comb &&
                victim_hit_valid_comb) begin
                $fatal(1, "A line is simultaneously valid in L1 and victim cache");
            end
            for (assert_i = 0; assert_i < VICTIM_ENTRIES;
                 assert_i = assert_i + 1) begin
                for (assert_j = assert_i + 1;
                     assert_j < VICTIM_ENTRIES;
                     assert_j = assert_j + 1) begin
                    if (vc_valid[assert_i] && vc_valid[assert_j] &&
                        vc_addr[assert_i] == vc_addr[assert_j]) begin
                        $fatal(1, "Duplicate line in victim cache");
                    end
                end
            end
        end
    end
`endif
endmodule
