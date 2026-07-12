`timescale 1ns/1ps

module l1d_cache #(
    parameter integer ADDR_WIDTH       = 64,
    parameter integer DATA_WIDTH       = 64,
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
    input  logic [1:0]                   cpu_req_size,
    input  logic                         cpu_req_unsigned,
    input  logic [DATA_WIDTH-1:0]        cpu_req_wdata,

    output logic                         cpu_rsp_valid,
    input  logic                         cpu_rsp_ready,
    output logic [DATA_WIDTH-1:0]        cpu_rsp_rdata,
    output logic                         cpu_rsp_error,
    output logic [1:0]                   cpu_rsp_error_cause,

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
    output logic                         event_prefetch_dropped,

    output logic [3:0]                   debug_state,
    output logic                         debug_req_is_prefetch
);
    localparam integer LINE_BITS       = LINE_BYTES * 8;
    localparam integer WORD_BYTES      = DATA_WIDTH / 8;
    localparam integer OFFSET_BITS     = $clog2(LINE_BYTES);
    localparam integer SET_BITS        = $clog2(NUM_SETS);
    localparam integer TAG_BITS        = ADDR_WIDTH - OFFSET_BITS - SET_BITS;
    localparam integer SRAM_ADDR_WIDTH = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer WAY_BITS        = (NUM_WAYS > 1) ? $clog2(NUM_WAYS) : 1;
    localparam integer VC_BITS         = (VICTIM_ENTRIES > 1) ? $clog2(VICTIM_ENTRIES) : 1;

    localparam logic [1:0] ACCESS_BYTE   = 2'b00;
    localparam logic [1:0] ACCESS_HALF   = 2'b01;
    localparam logic [1:0] ACCESS_WORD   = 2'b10;
    localparam logic [1:0] ACCESS_DOUBLE = 2'b11;

    localparam logic [1:0] RSP_OK                = 2'b00;
    localparam logic [1:0] RSP_LOAD_MISALIGNED  = 2'b01;
    localparam logic [1:0] RSP_STORE_MISALIGNED = 2'b10;

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_LOOKUP,
        ST_HIT_WRITE,
        ST_VC_SWAP,
        ST_WB_REQ,
        ST_VC_INSERT,
        ST_MEM_READ_REQ,
        ST_MEM_READ_WAIT,
        ST_INSTALL,
        ST_RESP
    } state_t;

    state_t state;

    logic array_en;
    logic [NUM_WAYS-1:0] tag_we;
    logic [NUM_WAYS-1:0] data_we;
    logic [SRAM_ADDR_WIDTH-1:0] array_addr;
    logic [TAG_BITS-1:0] array_wtag;
    logic [LINE_BITS-1:0] array_wdata;
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

    logic [ADDR_WIDTH-1:0] req_addr;
    logic req_write;
    logic [1:0] req_size;
    logic req_unsigned;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic req_is_prefetch;

    assign debug_state = state;
    assign debug_req_is_prefetch = req_is_prefetch;

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
    logic response_error;
    logic [1:0] response_error_cause;
    logic next_line_trigger;
    logic next_line_candidate_valid;
    logic next_line_candidate_ready;
    logic [ADDR_WIDTH-1:0] next_line_candidate_addr;
    logic next_line_dropped;
    logic accept_cpu;
    logic accept_ext;
    logic accept_next;

    integer lookup_i;
    integer reset_i;
    integer reset_j;
    integer assert_i;
    integer assert_j;
    integer hit_way_comb;
    integer invalid_way_comb;
    integer victim_hit_comb;
    logic l1_hit_comb;
    logic victim_hit_valid_comb;
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

    function automatic integer access_bytes(
        input logic [1:0] size
    );
        begin
            case (size)
                ACCESS_BYTE:   access_bytes = 1;
                ACCESS_HALF:   access_bytes = 2;
                ACCESS_WORD:   access_bytes = 4;
                default:       access_bytes = 8;
            endcase
        end
    endfunction

    function automatic logic access_misaligned(
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size
    );
        begin
            case (size)
                ACCESS_BYTE:   access_misaligned = 1'b0;
                ACCESS_HALF:   access_misaligned = addr[0];
                ACCESS_WORD:   access_misaligned = |addr[1:0];
                default:       access_misaligned = |addr[2:0];
            endcase
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] line_load_data(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [1:0] size,
        input logic unsigned_load
    );
        integer byte_offset;
        integer byte_index;
        logic [DATA_WIDTH-1:0] raw;
        begin
            raw = '0;
            byte_offset = addr[OFFSET_BITS-1:0];
            for (byte_index = 0; byte_index < WORD_BYTES;
                 byte_index = byte_index + 1) begin
                if (byte_index < access_bytes(size)) begin
                    raw[byte_index*8 +: 8] =
                        line[(byte_offset + byte_index)*8 +: 8];
                end
            end

            case (size)
                ACCESS_BYTE: begin
                    line_load_data = unsigned_load ?
                        {{(DATA_WIDTH-8){1'b0}}, raw[7:0]} :
                        {{(DATA_WIDTH-8){raw[7]}}, raw[7:0]};
                end
                ACCESS_HALF: begin
                    line_load_data = unsigned_load ?
                        {{(DATA_WIDTH-16){1'b0}}, raw[15:0]} :
                        {{(DATA_WIDTH-16){raw[15]}}, raw[15:0]};
                end
                ACCESS_WORD: begin
                    line_load_data = unsigned_load ?
                        {{(DATA_WIDTH-32){1'b0}}, raw[31:0]} :
                        {{(DATA_WIDTH-32){raw[31]}}, raw[31:0]};
                end
                default: begin
                    line_load_data = raw;
                end
            endcase
        end
    endfunction

    function automatic [LINE_BITS-1:0] merge_store_data(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] wdata,
        input logic [1:0] size
    );
        integer byte_offset;
        integer byte_index;
        logic [LINE_BITS-1:0] result;
        begin
            result = line;
            byte_offset = addr[OFFSET_BITS-1:0];
            for (byte_index = 0; byte_index < WORD_BYTES; byte_index = byte_index + 1) begin
                if (byte_index < access_bytes(size)) begin
                    result[(byte_offset + byte_index)*8 +: 8] =
                        wdata[(byte_index*8) +: 8];
                end
            end
            merge_store_data = result;
        end
    endfunction

    generate
        genvar way;
        for (way = 0; way < NUM_WAYS; way = way + 1) begin : gen_arrays
            l1d_sram #(
                .WIDTH(TAG_BITS),
                .DEPTH(NUM_SETS),
                .ADDR_WIDTH(SRAM_ADDR_WIDTH)
            ) tag_array (
                .clk(clk),
                .en(array_en),
                .we(tag_we[way]),
                .addr(array_addr),
                .wdata(array_wtag),
                .rdata(tag_q[way])
            );

            l1d_sram #(
                .WIDTH(LINE_BITS),
                .DEPTH(NUM_SETS),
                .ADDR_WIDTH(SRAM_ADDR_WIDTH)
            ) data_array (
                .clk(clk),
                .en(array_en),
                .we(data_we[way]),
                .addr(array_addr),
                .wdata(array_wdata),
                .rdata(data_q[way])
            );
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

    always_comb begin
        req_set_comb = address_set(req_addr);
        req_tag_comb = address_tag(req_addr);
        req_line_addr_comb = line_address(req_addr);

        l1_hit_comb = 1'b0;
        hit_way_comb = 0;
        invalid_way_comb = -1;
        for (lookup_i = 0; lookup_i < NUM_WAYS;
             lookup_i = lookup_i + 1) begin
            if (valid_bits[lookup_i][req_set_comb] &&
                tag_q[lookup_i] == req_tag_comb) begin
                l1_hit_comb = 1'b1;
                hit_way_comb = lookup_i;
            end
            if (!valid_bits[lookup_i][req_set_comb] &&
                invalid_way_comb == -1) begin
                invalid_way_comb = lookup_i;
            end
        end

        victim_hit_valid_comb = 1'b0;
        victim_hit_comb = 0;
        for (lookup_i = 0; lookup_i < VICTIM_ENTRIES;
             lookup_i = lookup_i + 1) begin
            if (vc_valid[lookup_i] &&
                vc_addr[lookup_i] == req_line_addr_comb) begin
                victim_hit_valid_comb = 1'b1;
                victim_hit_comb = lookup_i;
            end
        end
    end

    always_comb begin
        accept_cpu = (state == ST_IDLE) && cpu_req_valid;
        ext_prefetch_ready = (state == ST_IDLE) && !cpu_req_valid &&
            (ENABLE_PREFETCH != 0) && cfg_prefetch_enable;
        accept_ext = ext_prefetch_ready && ext_prefetch_valid;
        next_line_candidate_ready = (state == ST_IDLE) && !cpu_req_valid &&
            !ext_prefetch_valid && (ENABLE_PREFETCH != 0) &&
            cfg_prefetch_enable;
        accept_next = next_line_candidate_ready &&
            next_line_candidate_valid;

        cpu_req_ready = (state == ST_IDLE);
        cpu_rsp_valid = (state == ST_RESP);
        cpu_rsp_rdata = response_data;
        cpu_rsp_error = response_error;
        cpu_rsp_error_cause = response_error_cause;
        cache_idle = (state == ST_IDLE);
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
            if (accept_cpu) begin
                if (!access_misaligned(cpu_req_addr, cpu_req_size)) begin
                    array_en = 1'b1;
                    array_addr = address_set(cpu_req_addr);
                end
            end else if (accept_ext) begin
                array_en = 1'b1;
                array_addr = address_set(ext_prefetch_addr);
            end else if (accept_next) begin
                array_en = 1'b1;
                array_addr = address_set(next_line_candidate_addr);
            end
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
            state <= ST_IDLE;
            req_addr <= '0;
            req_write <= 1'b0;
            req_size <= ACCESS_DOUBLE;
            req_unsigned <= 1'b0;
            req_wdata <= '0;
            req_is_prefetch <= 1'b0;
            selected_way <= '0;
            selected_vc <= '0;
            working_line <= '0;
            working_dirty <= 1'b0;
            fill_line <= '0;
            evicted_valid <= 1'b0;
            evicted_dirty <= 1'b0;
            evicted_prefetched <= 1'b0;
            evicted_addr <= '0;
            evicted_data <= '0;
            wb_addr <= '0;
            wb_data <= '0;
            response_data <= '0;
            response_error <= 1'b0;
            response_error_cause <= RSP_OK;
            vc_rr <= '0;

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
            for (reset_i = 0; reset_i < VICTIM_ENTRIES;
                 reset_i = reset_i + 1) begin
                vc_valid[reset_i] <= 1'b0;
                vc_dirty[reset_i] <= 1'b0;
                vc_prefetched[reset_i] <= 1'b0;
                vc_addr[reset_i] <= '0;
                vc_data[reset_i] <= '0;
            end
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
                    if (accept_cpu) begin
                        req_addr <= cpu_req_addr;
                        req_write <= cpu_req_write;
                        req_size <= cpu_req_size;
                        req_unsigned <= cpu_req_unsigned;
                        req_wdata <= cpu_req_wdata;
                        req_is_prefetch <= 1'b0;
                        response_data <= '0;
                        response_error <= access_misaligned(cpu_req_addr, cpu_req_size);
                        response_error_cause <= RSP_OK;
                        event_cpu_access <= 1'b1;
                        if (access_misaligned(cpu_req_addr, cpu_req_size)) begin
                            response_error_cause <= cpu_req_write ?
                                RSP_STORE_MISALIGNED : RSP_LOAD_MISALIGNED;
                            state <= ST_RESP;
                        end else begin
                            state <= ST_LOOKUP;
                        end
                    end else if (accept_ext) begin
                        req_addr <= line_address(ext_prefetch_addr);
                        req_write <= 1'b0;
                        req_size <= ACCESS_DOUBLE;
                        req_unsigned <= 1'b0;
                        req_wdata <= '0;
                        req_is_prefetch <= 1'b1;
                        state <= ST_LOOKUP;
                    end else if (accept_next) begin
                        req_addr <= next_line_candidate_addr;
                        req_write <= 1'b0;
                        req_size <= ACCESS_DOUBLE;
                        req_unsigned <= 1'b0;
                        req_wdata <= '0;
                        req_is_prefetch <= 1'b1;
                        state <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    if (l1_hit_comb) begin
                        selected_way <= hit_way_comb[WAY_BITS-1:0];
                        if (req_is_prefetch) begin
                            state <= ST_IDLE;
                        end else begin
                            stat_cpu_hits <= stat_cpu_hits + 1'b1;
                            event_cpu_hit <= 1'b1;
                            replacement_way[req_set_comb] <=
                                (hit_way_comb + 1) % NUM_WAYS;
                            if (prefetched_bits[hit_way_comb][req_set_comb]) begin
                                prefetched_bits[hit_way_comb][req_set_comb] <= 1'b0;
                                stat_prefetch_useful <= stat_prefetch_useful + 1'b1;
                                event_prefetch_useful <= 1'b1;
                            end
                            if (req_write) begin
                                working_line <= merge_store_data(
                                    data_q[hit_way_comb], req_addr,
                                    req_wdata, req_size
                                );
                                response_data <= line_load_data(
                                    merge_store_data(data_q[hit_way_comb], req_addr,
                                                     req_wdata, req_size),
                                    req_addr, req_size, req_unsigned
                                );
                                state <= ST_HIT_WRITE;
                            end else begin
                                response_data <= line_load_data(
                                    data_q[hit_way_comb], req_addr,
                                    req_size, req_unsigned
                                );
                                state <= ST_RESP;
                            end
                        end
                    end else if (victim_hit_valid_comb) begin
                        if (req_is_prefetch) begin
                            state <= ST_IDLE;
                        end else begin
                            stat_cpu_misses <= stat_cpu_misses + 1'b1;
                            stat_victim_hits <= stat_victim_hits + 1'b1;
                            event_cpu_miss <= 1'b1;
                            event_victim_hit <= 1'b1;
                            selected_vc <= victim_hit_comb[VC_BITS-1:0];
                            if (invalid_way_comb >= 0) begin
                                selected_way <= invalid_way_comb[WAY_BITS-1:0];
                            end else begin
                                selected_way <= replacement_way[req_set_comb];
                            end

                            evicted_valid <= (invalid_way_comb < 0);
                            if (invalid_way_comb >= 0) begin
                                evicted_dirty <= 1'b0;
                                evicted_prefetched <= 1'b0;
                                evicted_addr <= '0;
                                evicted_data <= '0;
                            end else begin
                                evicted_dirty <=
                                    dirty_bits[replacement_way[req_set_comb]][req_set_comb];
                                evicted_prefetched <=
                                    prefetched_bits[replacement_way[req_set_comb]][req_set_comb];
                                evicted_addr <= compose_line_address(
                                    tag_q[replacement_way[req_set_comb]],
                                    req_set_comb
                                );
                                evicted_data <= data_q[replacement_way[req_set_comb]];
                            end

                            if (req_write) begin
                                working_line <= merge_store_data(
                                    vc_data[victim_hit_comb], req_addr,
                                    req_wdata, req_size
                                );
                                working_dirty <= 1'b1;
                                response_data <= line_load_data(
                                    merge_store_data(vc_data[victim_hit_comb],
                                                     req_addr, req_wdata,
                                                     req_size),
                                    req_addr, req_size, req_unsigned
                                );
                            end else begin
                                working_line <= vc_data[victim_hit_comb];
                                working_dirty <= vc_dirty[victim_hit_comb];
                                response_data <= line_load_data(
                                    vc_data[victim_hit_comb], req_addr,
                                    req_size, req_unsigned
                                );
                            end
                            if (vc_prefetched[victim_hit_comb]) begin
                                stat_prefetch_useful <= stat_prefetch_useful + 1'b1;
                                event_prefetch_useful <= 1'b1;
                            end
                            state <= ST_VC_SWAP;
                        end
                    end else begin
                        if (!req_is_prefetch) begin
                            stat_cpu_misses <= stat_cpu_misses + 1'b1;
                            event_cpu_miss <= 1'b1;
                        end
                        if (invalid_way_comb >= 0) begin
                            selected_way <= invalid_way_comb[WAY_BITS-1:0];
                            evicted_valid <= 1'b0;
                            evicted_dirty <= 1'b0;
                            evicted_prefetched <= 1'b0;
                            evicted_addr <= '0;
                            evicted_data <= '0;
                            state <= ST_MEM_READ_REQ;
                        end else begin
                            selected_way <= replacement_way[req_set_comb];
                            evicted_valid <= 1'b1;
                            evicted_dirty <=
                                dirty_bits[replacement_way[req_set_comb]][req_set_comb];
                            evicted_prefetched <=
                                prefetched_bits[replacement_way[req_set_comb]][req_set_comb];
                            evicted_addr <= compose_line_address(
                                tag_q[replacement_way[req_set_comb]], req_set_comb
                            );
                            evicted_data <= data_q[replacement_way[req_set_comb]];
                            selected_vc <= vc_rr;

                            if (req_is_prefetch &&
                                !prefetched_bits[replacement_way[req_set_comb]][req_set_comb]) begin
                                stat_prefetch_pollution <=
                                    stat_prefetch_pollution + 1'b1;
                                event_prefetch_pollution <= 1'b1;
                            end

                            if (vc_valid[vc_rr] && vc_dirty[vc_rr]) begin
                                wb_addr <= vc_addr[vc_rr];
                                wb_data <= vc_data[vc_rr];
                                state <= ST_WB_REQ;
                            end else begin
                                state <= ST_VC_INSERT;
                            end
                        end
                    end
                end

                ST_HIT_WRITE: begin
                    dirty_bits[selected_way][req_set_comb] <= 1'b1;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    state <= ST_RESP;
                end

                ST_VC_SWAP: begin
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <= working_dirty;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    replacement_way[req_set_comb] <=
                        (selected_way + 1'b1) % NUM_WAYS;

                    if (evicted_valid) begin
                        vc_valid[selected_vc] <= 1'b1;
                        vc_dirty[selected_vc] <= evicted_dirty;
                        vc_prefetched[selected_vc] <= evicted_prefetched;
                        vc_addr[selected_vc] <= evicted_addr;
                        vc_data[selected_vc] <= evicted_data;
                    end else begin
                        vc_valid[selected_vc] <= 1'b0;
                        vc_dirty[selected_vc] <= 1'b0;
                        vc_prefetched[selected_vc] <= 1'b0;
                    end
                    state <= ST_RESP;
                end

                ST_WB_REQ: begin
                    if (mem_req_ready) begin
                        stat_writebacks <= stat_writebacks + 1'b1;
                        event_writeback <= 1'b1;
                        state <= ST_VC_INSERT;
                    end
                end

                ST_VC_INSERT: begin
                    if (vc_valid[selected_vc] && vc_prefetched[selected_vc]) begin
                        stat_prefetch_useless <= stat_prefetch_useless + 1'b1;
                        event_prefetch_useless <= 1'b1;
                    end
                    vc_valid[selected_vc] <= evicted_valid;
                    vc_dirty[selected_vc] <= evicted_dirty;
                    vc_prefetched[selected_vc] <= evicted_prefetched;
                    vc_addr[selected_vc] <= evicted_addr;
                    vc_data[selected_vc] <= evicted_data;
                    valid_bits[selected_way][req_set_comb] <= 1'b0;
                    dirty_bits[selected_way][req_set_comb] <= 1'b0;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    if (vc_rr == VICTIM_ENTRIES-1) begin
                        vc_rr <= '0;
                    end else begin
                        vc_rr <= vc_rr + 1'b1;
                    end
                    state <= ST_MEM_READ_REQ;
                end

                ST_MEM_READ_REQ: begin
                    if (mem_req_ready) begin
                        state <= ST_MEM_READ_WAIT;
                    end
                end

                ST_MEM_READ_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (!req_is_prefetch && req_write) begin
                            fill_line <= merge_store_data(
                                mem_rsp_rdata, req_addr, req_wdata, req_size
                            );
                            response_data <= line_load_data(
                                merge_store_data(mem_rsp_rdata, req_addr,
                                                 req_wdata, req_size),
                                req_addr, req_size, req_unsigned
                            );
                        end else begin
                            fill_line <= mem_rsp_rdata;
                            response_data <= line_load_data(
                                mem_rsp_rdata, req_addr, req_size, req_unsigned
                            );
                        end
                        state <= ST_INSTALL;
                    end
                end

                ST_INSTALL: begin
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <=
                        (!req_is_prefetch && req_write);
                    prefetched_bits[selected_way][req_set_comb] <= req_is_prefetch;
                    replacement_way[req_set_comb] <=
                        (selected_way + 1'b1) % NUM_WAYS;
                    if (req_is_prefetch) begin
                        stat_prefetch_fills <= stat_prefetch_fills + 1'b1;
                        event_prefetch_fill <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_RESP;
                    end
                end

                ST_RESP: begin
                    if (cpu_rsp_ready) begin
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
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
        if (ADDR_WIDTH != 64) begin
            $error("RV64 mode requires ADDR_WIDTH to be 64");
        end
        if (DATA_WIDTH != 64) begin
            $error("RV64 mode requires DATA_WIDTH to be 64");
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
            assert (!((accept_cpu && accept_ext) ||
                      (accept_cpu && accept_next) ||
                      (accept_ext && accept_next)))
                else $fatal(1, "CPU/external/next-line accepts are not one-hot");
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
