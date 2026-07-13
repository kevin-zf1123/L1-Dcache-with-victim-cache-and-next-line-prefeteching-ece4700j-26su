`timescale 1ns/1ps

// Small metadata-only adjacent-line stream detector.  It deliberately owns no
// cache-line data: candidates are addresses plus attribution metadata only.
module l1d_stream_prefetch #(
    parameter integer ADDR_WIDTH        = 64,
    parameter integer LINE_BYTES        = 16,
    parameter integer STREAM_ENTRIES    = 4,
    parameter integer CANDIDATE_ENTRIES = 2,
    parameter integer CANDIDATE_TTL     = 16,
    parameter integer MODE_STREAM       = 1
) (
    input  logic                    clk,
    input  logic                    rst_n,
    // Training remains enabled in controller OFF; candidate_enable clears
    // speculative queue state while preserving learned stream metadata.
    input  logic                    enable,
    input  logic                    candidate_enable,
    input  logic                    demand_access_valid,
    input  logic                    demand_lower_miss,
    input  logic [ADDR_WIDTH-1:0]   demand_line_addr,
    input  logic                    demand_prefetch_hit,
    input  logic [$clog2(STREAM_ENTRIES)-1:0] demand_stream_id,
    input  logic [1:0]              demand_stream_generation,
    input  logic                    unused_feedback_valid,
    input  logic [$clog2(STREAM_ENTRIES)-1:0] unused_stream_id,
    input  logic [1:0]              unused_stream_generation,
    output logic                    candidate_valid,
    input  logic                    candidate_ready,
    output logic [ADDR_WIDTH-1:0]   candidate_addr,
    output logic [1:0]              candidate_confidence,
    output logic [$clog2(STREAM_ENTRIES)-1:0] candidate_stream_id,
    output logic [1:0]              candidate_stream_generation,
    output logic                    event_dropped,
    output logic                    event_expired
);
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SID_BITS = (STREAM_ENTRIES > 1) ?
                                  $clog2(STREAM_ENTRIES) : 1;
    localparam integer COUNT_BITS = (CANDIDATE_ENTRIES > 1) ?
                                    $clog2(CANDIDATE_ENTRIES + 1) : 1;
    localparam integer AGE_BITS = (CANDIDATE_TTL > 1) ?
                                  $clog2(CANDIDATE_TTL + 1) : 1;

    logic stream_valid [0:STREAM_ENTRIES-1];
    logic [ADDR_WIDTH-13:0] stream_page [0:STREAM_ENTRIES-1];
    logic [11-OFFSET_BITS:0] stream_last [0:STREAM_ENTRIES-1];
    logic stream_dir_valid [0:STREAM_ENTRIES-1];
    logic stream_dir_negative [0:STREAM_ENTRIES-1];
    logic [1:0] stream_confidence [0:STREAM_ENTRIES-1];
    logic [1:0] stream_generation [0:STREAM_ENTRIES-1];
    logic [SID_BITS-1:0] stream_rr;

    logic [ADDR_WIDTH-1:0] candidate_addr_q [0:CANDIDATE_ENTRIES-1];
    logic [ADDR_WIDTH-1:0] candidate_addr_d [0:CANDIDATE_ENTRIES-1];
    logic [1:0] candidate_confidence_q [0:CANDIDATE_ENTRIES-1];
    logic [1:0] candidate_confidence_d [0:CANDIDATE_ENTRIES-1];
    logic [SID_BITS-1:0] candidate_stream_id_q [0:CANDIDATE_ENTRIES-1];
    logic [SID_BITS-1:0] candidate_stream_id_d [0:CANDIDATE_ENTRIES-1];
    logic [1:0] candidate_generation_q [0:CANDIDATE_ENTRIES-1];
    logic [1:0] candidate_generation_d [0:CANDIDATE_ENTRIES-1];
    logic [AGE_BITS-1:0] candidate_age_q [0:CANDIDATE_ENTRIES-1];
    logic [AGE_BITS-1:0] candidate_age_d [0:CANDIDATE_ENTRIES-1];
    logic [COUNT_BITS-1:0] candidate_count_q;
    logic [COUNT_BITS-1:0] candidate_count_d;
    logic event_dropped_d;
    logic event_expired_d;

    integer stream_search_i;
    integer fifo_comb_i;
    integer candidate_ff_i;
    integer stream_ff_i;
    integer found_comb;
    integer alloc_comb;
    integer build_count;
    integer duplicate_index;
    logic [11-OFFSET_BITS:0] current_line_comb;
    logic access_plus;
    logic access_minus;
    logic [1:0] access_next_conf;
    logic candidate_offer_valid;
    logic [ADDR_WIDTH-1:0] candidate_offer_addr;
    logic [1:0] candidate_offer_confidence;
    logic [SID_BITS-1:0] candidate_offer_stream_id;
    logic [1:0] candidate_offer_generation;

    always_comb begin
        candidate_valid = (candidate_count_q != 0);
        candidate_addr = candidate_addr_q[0];
        candidate_confidence = candidate_confidence_q[0];
        candidate_stream_id = candidate_stream_id_q[0];
        candidate_stream_generation = candidate_generation_q[0];
    end

    // Derive the candidate associated with this demand from the current stream
    // metadata.  Stream state is updated after the same edge, preserving the
    // original detector's confidence semantics.
    always_comb begin
        found_comb = -1;
        alloc_comb = -1;
        current_line_comb = demand_line_addr[11:OFFSET_BITS];
        access_plus = 1'b0;
        access_minus = 1'b0;
        access_next_conf = 2'b01;
        candidate_offer_valid = 1'b0;
        candidate_offer_addr = '0;
        candidate_offer_confidence = 2'b01;
        candidate_offer_stream_id = '0;
        candidate_offer_generation = '0;

        for (stream_search_i = 0; stream_search_i < STREAM_ENTRIES;
             stream_search_i = stream_search_i + 1) begin
            if (stream_valid[stream_search_i] &&
                stream_page[stream_search_i] ==
                    demand_line_addr[ADDR_WIDTH-1:12])
                found_comb = stream_search_i;
            if (!stream_valid[stream_search_i] && alloc_comb == -1)
                alloc_comb = stream_search_i;
        end
        if (alloc_comb == -1)
            alloc_comb = stream_rr;

        if (enable && demand_access_valid) begin
            if (MODE_STREAM == 0) begin
                if (candidate_enable && demand_lower_miss &&
                    demand_line_addr[11:0] <= (12'hfff - LINE_BYTES)) begin
                    candidate_offer_valid = 1'b1;
                    candidate_offer_addr = demand_line_addr + LINE_BYTES;
                    candidate_offer_confidence = 2'b11;
                end
            end else if (found_comb >= 0 &&
                         current_line_comb != stream_last[found_comb]) begin
                access_plus =
                    (current_line_comb == stream_last[found_comb] + 1'b1);
                access_minus =
                    (current_line_comb + 1'b1 == stream_last[found_comb]);

                if (access_plus) begin
                    if (stream_dir_valid[found_comb] &&
                        !stream_dir_negative[found_comb]) begin
                        if (stream_confidence[found_comb] != 2'b11)
                            access_next_conf =
                                stream_confidence[found_comb] + 1'b1;
                        else
                            access_next_conf = 2'b11;
                    end
                    if (candidate_enable && current_line_comb !=
                        {($bits(current_line_comb)){1'b1}}) begin
                        candidate_offer_valid = 1'b1;
                        candidate_offer_addr = demand_line_addr + LINE_BYTES;
                    end
                end else if (access_minus) begin
                    if (stream_dir_valid[found_comb] &&
                        stream_dir_negative[found_comb]) begin
                        if (stream_confidence[found_comb] != 2'b11)
                            access_next_conf =
                                stream_confidence[found_comb] + 1'b1;
                        else
                            access_next_conf = 2'b11;
                    end
                    if (candidate_enable && current_line_comb != 0) begin
                        candidate_offer_valid = 1'b1;
                        candidate_offer_addr = demand_line_addr - LINE_BYTES;
                    end
                end

                candidate_offer_confidence = access_next_conf;
                candidate_offer_stream_id = found_comb[SID_BITS-1:0];
                candidate_offer_generation = stream_generation[found_comb];
            end
        end
    end

    // Compact FIFO next state.  Handshake removal and expiration happen before
    // the current access offers a new candidate, so a same-cycle dequeue makes
    // room without reporting a drop and a newly generated entry starts at age 0.
    always_comb begin
        candidate_count_d = '0;
        event_dropped_d = 1'b0;
        event_expired_d = 1'b0;
        build_count = 0;
        duplicate_index = -1;
        for (fifo_comb_i = 0; fifo_comb_i < CANDIDATE_ENTRIES;
             fifo_comb_i = fifo_comb_i + 1) begin
            candidate_addr_d[fifo_comb_i] = '0;
            candidate_confidence_d[fifo_comb_i] = '0;
            candidate_stream_id_d[fifo_comb_i] = '0;
            candidate_generation_d[fifo_comb_i] = '0;
            candidate_age_d[fifo_comb_i] = '0;
        end

        if (enable && candidate_enable) begin
            for (fifo_comb_i = 0; fifo_comb_i < CANDIDATE_ENTRIES;
                 fifo_comb_i = fifo_comb_i + 1) begin
                if (fifo_comb_i < candidate_count_q &&
                    !(fifo_comb_i == 0 && candidate_valid &&
                      candidate_ready)) begin
                    if (demand_access_valid &&
                        candidate_age_q[fifo_comb_i] >= CANDIDATE_TTL-1) begin
                        event_expired_d = 1'b1;
                    end else begin
                        candidate_addr_d[build_count] =
                            candidate_addr_q[fifo_comb_i];
                        candidate_confidence_d[build_count] =
                            candidate_confidence_q[fifo_comb_i];
                        candidate_stream_id_d[build_count] =
                            candidate_stream_id_q[fifo_comb_i];
                        candidate_generation_d[build_count] =
                            candidate_generation_q[fifo_comb_i];
                        if (demand_access_valid)
                            candidate_age_d[build_count] =
                                candidate_age_q[fifo_comb_i] + 1'b1;
                        else
                            candidate_age_d[build_count] =
                                candidate_age_q[fifo_comb_i];
                        build_count = build_count + 1;
                    end
                end
            end
            candidate_count_d = build_count[COUNT_BITS-1:0];

            for (fifo_comb_i = 0; fifo_comb_i < CANDIDATE_ENTRIES;
                 fifo_comb_i = fifo_comb_i + 1) begin
                if (fifo_comb_i < build_count &&
                    candidate_addr_d[fifo_comb_i] == candidate_offer_addr)
                    duplicate_index = fifo_comb_i;
            end

            if (candidate_offer_valid) begin
                if (duplicate_index >= 0) begin
                    candidate_age_d[duplicate_index] = '0;
                    if (candidate_offer_confidence >
                        candidate_confidence_d[duplicate_index]) begin
                        candidate_confidence_d[duplicate_index] =
                            candidate_offer_confidence;
                        candidate_stream_id_d[duplicate_index] =
                            candidate_offer_stream_id;
                        candidate_generation_d[duplicate_index] =
                            candidate_offer_generation;
                    end
                end else if (build_count < CANDIDATE_ENTRIES) begin
                    candidate_addr_d[build_count] = candidate_offer_addr;
                    candidate_confidence_d[build_count] =
                        candidate_offer_confidence;
                    candidate_stream_id_d[build_count] =
                        candidate_offer_stream_id;
                    candidate_generation_d[build_count] =
                        candidate_offer_generation;
                    candidate_age_d[build_count] = '0;
                    build_count = build_count + 1;
                    candidate_count_d = build_count[COUNT_BITS-1:0];
                end else begin
                    for (fifo_comb_i = 0;
                         fifo_comb_i < CANDIDATE_ENTRIES-1;
                         fifo_comb_i = fifo_comb_i + 1) begin
                        candidate_addr_d[fifo_comb_i] =
                            candidate_addr_d[fifo_comb_i+1];
                        candidate_confidence_d[fifo_comb_i] =
                            candidate_confidence_d[fifo_comb_i+1];
                        candidate_stream_id_d[fifo_comb_i] =
                            candidate_stream_id_d[fifo_comb_i+1];
                        candidate_generation_d[fifo_comb_i] =
                            candidate_generation_d[fifo_comb_i+1];
                        candidate_age_d[fifo_comb_i] =
                            candidate_age_d[fifo_comb_i+1];
                    end
                    candidate_addr_d[CANDIDATE_ENTRIES-1] =
                        candidate_offer_addr;
                    candidate_confidence_d[CANDIDATE_ENTRIES-1] =
                        candidate_offer_confidence;
                    candidate_stream_id_d[CANDIDATE_ENTRIES-1] =
                        candidate_offer_stream_id;
                    candidate_generation_d[CANDIDATE_ENTRIES-1] =
                        candidate_offer_generation;
                    candidate_age_d[CANDIDATE_ENTRIES-1] = '0;
                    candidate_count_d = CANDIDATE_ENTRIES;
                    event_dropped_d = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate_count_q <= '0;
            event_dropped <= 1'b0;
            event_expired <= 1'b0;
            for (candidate_ff_i = 0; candidate_ff_i < CANDIDATE_ENTRIES;
                 candidate_ff_i = candidate_ff_i + 1) begin
                candidate_addr_q[candidate_ff_i] <= '0;
                candidate_confidence_q[candidate_ff_i] <= '0;
                candidate_stream_id_q[candidate_ff_i] <= '0;
                candidate_generation_q[candidate_ff_i] <= '0;
                candidate_age_q[candidate_ff_i] <= '0;
            end
        end else begin
            candidate_count_q <= candidate_count_d;
            event_dropped <= event_dropped_d;
            event_expired <= event_expired_d;
            for (candidate_ff_i = 0; candidate_ff_i < CANDIDATE_ENTRIES;
                 candidate_ff_i = candidate_ff_i + 1) begin
                candidate_addr_q[candidate_ff_i] <=
                    candidate_addr_d[candidate_ff_i];
                candidate_confidence_q[candidate_ff_i] <=
                    candidate_confidence_d[candidate_ff_i];
                candidate_stream_id_q[candidate_ff_i] <=
                    candidate_stream_id_d[candidate_ff_i];
                candidate_generation_q[candidate_ff_i] <=
                    candidate_generation_d[candidate_ff_i];
                candidate_age_q[candidate_ff_i] <=
                    candidate_age_d[candidate_ff_i];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stream_rr <= '0;
            for (stream_ff_i = 0; stream_ff_i < STREAM_ENTRIES;
                 stream_ff_i = stream_ff_i + 1) begin
                stream_valid[stream_ff_i] <= 1'b0;
                stream_page[stream_ff_i] <= '0;
                stream_last[stream_ff_i] <= '0;
                stream_dir_valid[stream_ff_i] <= 1'b0;
                stream_dir_negative[stream_ff_i] <= 1'b0;
                stream_confidence[stream_ff_i] <= '0;
                stream_generation[stream_ff_i] <= '0;
            end
        end else if (enable) begin
            if (unused_feedback_valid &&
                stream_valid[unused_stream_id] &&
                stream_generation[unused_stream_id] ==
                    unused_stream_generation &&
                stream_confidence[unused_stream_id] != 0) begin
                stream_confidence[unused_stream_id] <=
                    stream_confidence[unused_stream_id] - 1'b1;
            end

            if (demand_prefetch_hit &&
                stream_valid[demand_stream_id] &&
                stream_generation[demand_stream_id] ==
                    demand_stream_generation &&
                stream_confidence[demand_stream_id] != 2'b11) begin
                stream_confidence[demand_stream_id] <=
                    stream_confidence[demand_stream_id] + 1'b1;
            end

            if (demand_access_valid && MODE_STREAM != 0) begin
                if (found_comb == -1) begin
                    stream_valid[alloc_comb] <= 1'b1;
                    stream_page[alloc_comb] <=
                        demand_line_addr[ADDR_WIDTH-1:12];
                    stream_last[alloc_comb] <= current_line_comb;
                    stream_dir_valid[alloc_comb] <= 1'b0;
                    stream_dir_negative[alloc_comb] <= 1'b0;
                    stream_confidence[alloc_comb] <= '0;
                    stream_generation[alloc_comb] <=
                        stream_generation[alloc_comb] + 1'b1;
                    if (stream_rr == STREAM_ENTRIES-1)
                        stream_rr <= '0;
                    else
                        stream_rr <= stream_rr + 1'b1;
                end else if (current_line_comb != stream_last[found_comb]) begin
                    stream_last[found_comb] <= current_line_comb;
                    if (access_plus) begin
                        stream_dir_valid[found_comb] <= 1'b1;
                        stream_dir_negative[found_comb] <= 1'b0;
                        stream_confidence[found_comb] <= access_next_conf;
                    end else if (access_minus) begin
                        stream_dir_valid[found_comb] <= 1'b1;
                        stream_dir_negative[found_comb] <= 1'b1;
                        stream_confidence[found_comb] <= access_next_conf;
                    end else begin
                        stream_dir_valid[found_comb] <= 1'b0;
                        stream_confidence[found_comb] <= '0;
                    end
                end
            end
        end
    end
endmodule
