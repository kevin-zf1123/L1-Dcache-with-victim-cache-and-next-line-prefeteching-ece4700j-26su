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
    logic [11-OFFSET_BITS:0] current_line_comb;
    logic access_plus;
    logic access_minus;
    logic [1:0] access_next_conf;
    logic candidate_offer_valid;
    logic [ADDR_WIDTH-1:0] candidate_offer_addr;
    logic [1:0] candidate_offer_confidence;
    logic [SID_BITS-1:0] candidate_offer_stream_id;
    logic [1:0] candidate_offer_generation;
    (* DONT_TOUCH = "yes" *) logic candidate_offer_valid_q;
    (* DONT_TOUCH = "yes" *) logic [ADDR_WIDTH-1:0] candidate_offer_addr_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] candidate_offer_confidence_q;
    (* DONT_TOUCH = "yes" *) logic [SID_BITS-1:0]
        candidate_offer_stream_id_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] candidate_offer_generation_q;
    logic keep_candidate_0;
    logic keep_candidate_1;
    logic duplicate_candidate_0;
    logic duplicate_candidate_1;
    (* DONT_TOUCH = "yes" *) logic candidate_enable_q;
    (* DONT_TOUCH = "yes" *) logic candidate_ready_q;
    (* DONT_TOUCH = "yes" *) logic demand_lookup_valid_q;
    (* DONT_TOUCH = "yes" *) logic demand_found_valid_q;
    (* DONT_TOUCH = "yes" *) logic [SID_BITS-1:0] demand_found_q;
    (* DONT_TOUCH = "yes" *) logic [SID_BITS-1:0] demand_alloc_q;
    (* DONT_TOUCH = "yes" *) logic [ADDR_WIDTH-1:0] demand_line_addr_q;
    (* DONT_TOUCH = "yes" *) logic [11-OFFSET_BITS:0]
        demand_current_line_q;
    (* DONT_TOUCH = "yes" *) logic demand_lower_miss_q;
    (* DONT_TOUCH = "yes" *) logic demand_prefetch_hit_q;
    (* DONT_TOUCH = "yes" *) logic [SID_BITS-1:0] demand_stream_id_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] demand_stream_generation_q;

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

        if (enable && demand_lookup_valid_q) begin
            if (MODE_STREAM == 0) begin
                if (candidate_enable_q && demand_lower_miss_q &&
                    demand_line_addr_q[11:0] <=
                        (12'hfff - LINE_BYTES)) begin
                    candidate_offer_valid = 1'b1;
                    candidate_offer_addr = demand_line_addr_q + LINE_BYTES;
                    candidate_offer_confidence = 2'b11;
                end
            end else if (demand_found_valid_q &&
                         demand_current_line_q !=
                             stream_last[demand_found_q]) begin
                access_plus =
                    (demand_current_line_q ==
                     stream_last[demand_found_q] + 1'b1);
                access_minus =
                    (demand_current_line_q + 1'b1 ==
                     stream_last[demand_found_q]);

                if (access_plus) begin
                    if (stream_dir_valid[demand_found_q] &&
                        !stream_dir_negative[demand_found_q]) begin
                        if (stream_confidence[demand_found_q] != 2'b11)
                            access_next_conf =
                                stream_confidence[demand_found_q] + 1'b1;
                        else
                            access_next_conf = 2'b11;
                    end
                    if (candidate_enable_q && demand_current_line_q !=
                        {($bits(demand_current_line_q)){1'b1}}) begin
                        candidate_offer_valid = 1'b1;
                        candidate_offer_addr =
                            demand_line_addr_q + LINE_BYTES;
                    end
                end else if (access_minus) begin
                    if (stream_dir_valid[demand_found_q] &&
                        stream_dir_negative[demand_found_q]) begin
                        if (stream_confidence[demand_found_q] != 2'b11)
                            access_next_conf =
                                stream_confidence[demand_found_q] + 1'b1;
                        else
                            access_next_conf = 2'b11;
                    end
                    if (candidate_enable_q && demand_current_line_q != 0) begin
                        candidate_offer_valid = 1'b1;
                        candidate_offer_addr =
                            demand_line_addr_q - LINE_BYTES;
                    end
                end

                candidate_offer_confidence = access_next_conf;
                candidate_offer_stream_id = demand_found_q;
                candidate_offer_generation =
                    stream_generation[demand_found_q];
            end
        end
    end

    // Compact FIFO next state.  Candidate detection is registered separately,
    // so stream-table matching and the FIFO's duplicate/TTL logic occupy
    // different timing stages.
    always_comb begin
        candidate_count_d = '0;
        event_dropped_d = 1'b0;
        event_expired_d = 1'b0;
        keep_candidate_0 = 1'b0;
        keep_candidate_1 = 1'b0;
        duplicate_candidate_0 = 1'b0;
        duplicate_candidate_1 = 1'b0;
        for (fifo_comb_i = 0; fifo_comb_i < CANDIDATE_ENTRIES;
             fifo_comb_i = fifo_comb_i + 1) begin
            candidate_addr_d[fifo_comb_i] = '0;
            candidate_confidence_d[fifo_comb_i] = '0;
            candidate_stream_id_d[fifo_comb_i] = '0;
            candidate_generation_d[fifo_comb_i] = '0;
            candidate_age_d[fifo_comb_i] = '0;
        end

        if (enable && candidate_enable_q) begin
            keep_candidate_0 = (candidate_count_q != 0) &&
                !(candidate_valid && candidate_ready_q) &&
                !(demand_lookup_valid_q &&
                  candidate_age_q[0] >= CANDIDATE_TTL-1);
            keep_candidate_1 = (candidate_count_q == 2) &&
                !(demand_lookup_valid_q &&
                  candidate_age_q[1] >= CANDIDATE_TTL-1);
            event_expired_d =
                ((candidate_count_q != 0) &&
                 !(candidate_valid && candidate_ready_q) &&
                 demand_lookup_valid_q &&
                 candidate_age_q[0] >= CANDIDATE_TTL-1) ||
                ((candidate_count_q == 2) && demand_lookup_valid_q &&
                 candidate_age_q[1] >= CANDIDATE_TTL-1);

            if (keep_candidate_0) begin
                candidate_addr_d[0] = candidate_addr_q[0];
                candidate_confidence_d[0] = candidate_confidence_q[0];
                candidate_stream_id_d[0] = candidate_stream_id_q[0];
                candidate_generation_d[0] = candidate_generation_q[0];
                candidate_age_d[0] = demand_lookup_valid_q ?
                    candidate_age_q[0] + 1'b1 : candidate_age_q[0];
                candidate_count_d = 1;
                if (keep_candidate_1) begin
                    candidate_addr_d[1] = candidate_addr_q[1];
                    candidate_confidence_d[1] = candidate_confidence_q[1];
                    candidate_stream_id_d[1] = candidate_stream_id_q[1];
                    candidate_generation_d[1] = candidate_generation_q[1];
                    candidate_age_d[1] = demand_lookup_valid_q ?
                        candidate_age_q[1] + 1'b1 : candidate_age_q[1];
                    candidate_count_d = 2;
                end
            end else if (keep_candidate_1) begin
                candidate_addr_d[0] = candidate_addr_q[1];
                candidate_confidence_d[0] = candidate_confidence_q[1];
                candidate_stream_id_d[0] = candidate_stream_id_q[1];
                candidate_generation_d[0] = candidate_generation_q[1];
                candidate_age_d[0] = demand_lookup_valid_q ?
                    candidate_age_q[1] + 1'b1 : candidate_age_q[1];
                candidate_count_d = 1;
            end

            duplicate_candidate_0 = (candidate_count_d != 0) &&
                candidate_addr_d[0] == candidate_offer_addr_q;
            duplicate_candidate_1 = (candidate_count_d == 2) &&
                candidate_addr_d[1] == candidate_offer_addr_q;

            if (candidate_offer_valid_q) begin
                if (duplicate_candidate_0) begin
                    candidate_age_d[0] = '0;
                    if (candidate_offer_confidence_q >
                        candidate_confidence_d[0]) begin
                        candidate_confidence_d[0] =
                            candidate_offer_confidence_q;
                        candidate_stream_id_d[0] =
                            candidate_offer_stream_id_q;
                        candidate_generation_d[0] =
                            candidate_offer_generation_q;
                    end
                end else if (duplicate_candidate_1) begin
                    candidate_age_d[1] = '0;
                    if (candidate_offer_confidence_q >
                        candidate_confidence_d[1]) begin
                        candidate_confidence_d[1] =
                            candidate_offer_confidence_q;
                        candidate_stream_id_d[1] =
                            candidate_offer_stream_id_q;
                        candidate_generation_d[1] =
                            candidate_offer_generation_q;
                    end
                end else if (candidate_count_d == 0) begin
                    candidate_addr_d[0] = candidate_offer_addr_q;
                    candidate_confidence_d[0] =
                        candidate_offer_confidence_q;
                    candidate_stream_id_d[0] =
                        candidate_offer_stream_id_q;
                    candidate_generation_d[0] =
                        candidate_offer_generation_q;
                    candidate_age_d[0] = '0;
                    candidate_count_d = 1;
                end else if (candidate_count_d == 1) begin
                    candidate_addr_d[1] = candidate_offer_addr_q;
                    candidate_confidence_d[1] =
                        candidate_offer_confidence_q;
                    candidate_stream_id_d[1] =
                        candidate_offer_stream_id_q;
                    candidate_generation_d[1] =
                        candidate_offer_generation_q;
                    candidate_age_d[1] = '0;
                    candidate_count_d = 2;
                end else begin
                    candidate_addr_d[0] = candidate_addr_d[1];
                    candidate_confidence_d[0] = candidate_confidence_d[1];
                    candidate_stream_id_d[0] = candidate_stream_id_d[1];
                    candidate_generation_d[0] = candidate_generation_d[1];
                    candidate_age_d[0] = candidate_age_d[1];
                    candidate_addr_d[1] = candidate_offer_addr_q;
                    candidate_confidence_d[1] =
                        candidate_offer_confidence_q;
                    candidate_stream_id_d[1] =
                        candidate_offer_stream_id_q;
                    candidate_generation_d[1] =
                        candidate_offer_generation_q;
                    candidate_age_d[1] = '0;
                    candidate_count_d = 2;
                    event_dropped_d = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            candidate_enable_q <= 1'b0;
            candidate_ready_q <= 1'b0;
            demand_lookup_valid_q <= 1'b0;
            demand_found_valid_q <= 1'b0;
            demand_found_q <= '0;
            demand_alloc_q <= '0;
            demand_line_addr_q <= '0;
            demand_current_line_q <= '0;
            demand_lower_miss_q <= 1'b0;
            demand_prefetch_hit_q <= 1'b0;
            demand_stream_id_q <= '0;
            demand_stream_generation_q <= '0;
            candidate_offer_valid_q <= 1'b0;
            candidate_offer_addr_q <= '0;
            candidate_offer_confidence_q <= '0;
            candidate_offer_stream_id_q <= '0;
            candidate_offer_generation_q <= '0;
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
            candidate_enable_q <= enable && candidate_enable;
            candidate_ready_q <= candidate_ready;
            demand_lookup_valid_q <= enable && demand_access_valid;
            demand_found_valid_q <= (found_comb >= 0);
            demand_found_q <= found_comb[SID_BITS-1:0];
            demand_alloc_q <= alloc_comb[SID_BITS-1:0];
            demand_line_addr_q <= demand_line_addr;
            demand_current_line_q <= current_line_comb;
            demand_lower_miss_q <= demand_lower_miss;
            demand_prefetch_hit_q <= demand_prefetch_hit;
            demand_stream_id_q <= demand_stream_id;
            demand_stream_generation_q <= demand_stream_generation;
            if (enable && candidate_enable) begin
                candidate_offer_valid_q <= candidate_offer_valid;
                candidate_offer_addr_q <= candidate_offer_addr;
                candidate_offer_confidence_q <= candidate_offer_confidence;
                candidate_offer_stream_id_q <= candidate_offer_stream_id;
                candidate_offer_generation_q <= candidate_offer_generation;
            end else begin
                candidate_offer_valid_q <= 1'b0;
                candidate_offer_addr_q <= '0;
                candidate_offer_confidence_q <= '0;
                candidate_offer_stream_id_q <= '0;
                candidate_offer_generation_q <= '0;
            end
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

            if (demand_prefetch_hit_q &&
                stream_valid[demand_stream_id_q] &&
                stream_generation[demand_stream_id_q] ==
                    demand_stream_generation_q &&
                stream_confidence[demand_stream_id_q] != 2'b11) begin
                stream_confidence[demand_stream_id_q] <=
                    stream_confidence[demand_stream_id_q] + 1'b1;
            end

            if (demand_lookup_valid_q && MODE_STREAM != 0) begin
                if (!demand_found_valid_q) begin
                    stream_valid[demand_alloc_q] <= 1'b1;
                    stream_page[demand_alloc_q] <=
                        demand_line_addr_q[ADDR_WIDTH-1:12];
                    stream_last[demand_alloc_q] <= demand_current_line_q;
                    stream_dir_valid[demand_alloc_q] <= 1'b0;
                    stream_dir_negative[demand_alloc_q] <= 1'b0;
                    stream_confidence[demand_alloc_q] <= '0;
                    stream_generation[demand_alloc_q] <=
                        stream_generation[demand_alloc_q] + 1'b1;
                    if (stream_rr == STREAM_ENTRIES-1)
                        stream_rr <= '0;
                    else
                        stream_rr <= stream_rr + 1'b1;
                end else if (demand_current_line_q !=
                             stream_last[demand_found_q]) begin
                    stream_last[demand_found_q] <= demand_current_line_q;
                    if (access_plus) begin
                        stream_dir_valid[demand_found_q] <= 1'b1;
                        stream_dir_negative[demand_found_q] <= 1'b0;
                        stream_confidence[demand_found_q] <= access_next_conf;
                    end else if (access_minus) begin
                        stream_dir_valid[demand_found_q] <= 1'b1;
                        stream_dir_negative[demand_found_q] <= 1'b1;
                        stream_confidence[demand_found_q] <= access_next_conf;
                    end else begin
                        stream_dir_valid[demand_found_q] <= 1'b0;
                        stream_confidence[demand_found_q] <= '0;
                    end
                end
            end
        end
    end
endmodule
