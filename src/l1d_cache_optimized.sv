`timescale 1ns/1ps

// Direct-to-L1 optimized policy.  P1/P2 deliberately retain the blocking
// refill datapath, but make speculative work cold, bounded and feedback
// controlled.  PF_OPT_LEVEL 1 selects safe next-line generation; levels 2/3
// select the adjacent-stream detector, and level 3 additionally enables the
// tag-only counterfactual cache and single metadata-only prefetch MSHR.
module l1d_cache_optimized #(
    parameter integer ADDR_WIDTH       = 64,
    parameter integer DATA_WIDTH       = 64,
    parameter integer LINE_BYTES       = 16,
    parameter integer NUM_SETS         = 8,
    parameter integer NUM_WAYS         = 2,
    parameter integer VICTIM_ENTRIES   = 4,
    parameter integer ENABLE_PREFETCH  = 1,
    parameter integer PF_OPT_LEVEL     = 3
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
    output logic                         debug_req_is_prefetch,

    output logic [31:0]                  stat_pf_candidates,
    output logic [31:0]                  stat_pf_admitted,
    output logic [31:0]                  stat_pf_issued,
    output logic [31:0]                  stat_pf_returned,
    output logic [31:0]                  stat_pf_installed,
    output logic [31:0]                  stat_pf_merged,
    output logic [31:0]                  stat_pf_discarded,
    output logic [31:0]                  stat_pf_cancelled,
    output logic [31:0]                  stat_pf_unused_evicted,
    output logic [31:0]                  stat_pf_vc_bypass,
    output logic [31:0]                  stat_pf_caused_writebacks,
    output logic [31:0]                  stat_pf_demand_block_cycles,
    output logic [31:0]                  stat_pf_true_help,
    output logic [31:0]                  stat_pf_true_pollution,
    output logic [31:0]                  stat_pf_suppressed_quota,
    output logic [31:0]                  stat_pf_suppressed_unsafe,
    output logic [31:0]                  stat_pf_same_line_coalesced,
    output logic [1:0]                   debug_pf_controller_state,
    output logic                         debug_pf_mshr_valid,
    output logic [ADDR_WIDTH-1:0]        debug_pf_mshr_addr,
    output logic [1:0]                   debug_pf_mshr_confidence
);
    localparam integer LINE_BITS       = LINE_BYTES * 8;
    localparam integer WORD_BYTES      = DATA_WIDTH / 8;
    localparam integer OFFSET_BITS     = $clog2(LINE_BYTES);
    localparam integer SET_BITS        = $clog2(NUM_SETS);
    localparam integer TAG_BITS        = ADDR_WIDTH - OFFSET_BITS - SET_BITS;
    localparam integer SRAM_ADDR_WIDTH = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer WAY_BITS        = (NUM_WAYS > 1) ? $clog2(NUM_WAYS) : 1;
    localparam integer VC_BITS         = (VICTIM_ENTRIES > 1) ? $clog2(VICTIM_ENTRIES) : 1;
    localparam integer STREAM_ENTRIES  = 4;
    localparam integer STREAM_BITS     = $clog2(STREAM_ENTRIES);
    localparam integer IDLE_GUARD      = 2;

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
        ST_RESP,
        ST_PF_WAIT,
        ST_PF_REVALIDATE,
        ST_PF_MERGE_WB,
        ST_PF_MERGE_VC,
        ST_PF_INSTALL
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
    // A tag-only mirror enables the P3 response-cycle scheduler to prove that
    // the already-visible next demand is not an L1 hit before promoting its
    // matching candidate.  It mirrors SRAM tag writes and stores no line data.
    logic [TAG_BITS-1:0] tag_mirror [0:NUM_WAYS-1][0:NUM_SETS-1];

    logic valid_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic dirty_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic prefetched_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [STREAM_BITS-1:0] prefetched_stream_id [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [1:0] prefetched_stream_generation [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [WAY_BITS-1:0] replacement_way [0:NUM_SETS-1];

    logic vc_valid [0:VICTIM_ENTRIES-1];
    logic vc_dirty [0:VICTIM_ENTRIES-1];
    logic vc_prefetched [0:VICTIM_ENTRIES-1];
    logic [STREAM_BITS-1:0] vc_stream_id [0:VICTIM_ENTRIES-1];
    logic [1:0] vc_stream_generation [0:VICTIM_ENTRIES-1];
    logic [ADDR_WIDTH-1:0] vc_addr [0:VICTIM_ENTRIES-1];
    logic [LINE_BITS-1:0] vc_data [0:VICTIM_ENTRIES-1];
    logic [VC_BITS-1:0] vc_rr;

    logic [ADDR_WIDTH-1:0] req_addr;
    logic req_write;
    logic [1:0] req_size;
    logic req_unsigned;
    logic [DATA_WIDTH-1:0] req_wdata;
    logic req_is_prefetch;
    logic req_pf_external;
    logic [1:0] req_pf_confidence;
    logic [STREAM_BITS-1:0] req_pf_stream_id;
    logic [1:0] req_pf_stream_generation;
    logic req_miss_recorded;

    logic pf_mshr_valid;
    logic [ADDR_WIDTH-1:0] pf_mshr_addr;
    logic pf_mshr_external;
    logic [1:0] pf_mshr_confidence;
    logic [STREAM_BITS-1:0] pf_mshr_stream_id;
    logic [1:0] pf_mshr_stream_generation;
    logic pf_response_pending;
    logic [1:0] pf_response_age;
    logic pf_waiter_valid;
    logic pf_waiter_same_line;
    logic background_pf_prepare;
    logic background_pf_issue;
    (* DONT_TOUCH = "yes" *) logic background_pf_pending;
    logic background_pf_external_q;
    logic [ADDR_WIDTH-1:0] background_pf_addr_q;
    logic [1:0] background_pf_confidence_q;
    logic [STREAM_BITS-1:0] background_pf_stream_id_q;
    logic [1:0] background_pf_stream_generation_q;

    assign debug_state = state;
    // Background P3 reads launch while req_* still describes the completing
    // demand response, so expose the actual lower request class explicitly.
    assign debug_req_is_prefetch = req_is_prefetch || background_pf_issue;

    logic [WAY_BITS-1:0] selected_way;
    logic [VC_BITS-1:0] selected_vc;
    logic [LINE_BITS-1:0] working_line;
    logic working_dirty;
    logic [LINE_BITS-1:0] fill_line;

    logic evicted_valid;
    logic evicted_dirty;
    logic evicted_prefetched;
    logic [STREAM_BITS-1:0] evicted_stream_id;
    logic [1:0] evicted_stream_generation;
    logic eviction_deferred;
    logic [ADDR_WIDTH-1:0] evicted_addr;
    logic [LINE_BITS-1:0] evicted_data;
    logic quota_drop_pf;
    logic [WAY_BITS-1:0] quota_drop_way;

    logic [ADDR_WIDTH-1:0] wb_addr;
    logic [LINE_BITS-1:0] wb_data;

    logic [DATA_WIDTH-1:0] response_data;
    logic response_error;
    logic [1:0] response_error_cause;
    logic accept_cpu;
    logic accept_ext;
    logic accept_next;
    logic accept_bg_ext;
    logic accept_bg_next;
    logic background_next_l1_hit;
    logic background_next_vc_hit;

    logic stream_candidate_valid;
    logic stream_candidate_ready;
    logic [ADDR_WIDTH-1:0] stream_candidate_addr;
    logic [1:0] stream_candidate_confidence;
    logic [STREAM_BITS-1:0] stream_candidate_id;
    logic [1:0] stream_candidate_generation;
    logic stream_event_dropped;
    logic stream_event_expired;
    logic stream_candidate_seen;
    logic stream_demand_access;
    logic stream_demand_lower_miss;
    logic stream_demand_prefetch_hit;
    logic [STREAM_BITS-1:0] stream_demand_id;
    logic [1:0] stream_demand_generation;
    (* DONT_TOUCH = "yes" *) logic stream_demand_access_q;
    (* DONT_TOUCH = "yes" *) logic stream_demand_lower_miss_q;
    (* DONT_TOUCH = "yes" *) logic [ADDR_WIDTH-1:0]
        stream_demand_line_addr_q;
    (* DONT_TOUCH = "yes" *) logic stream_demand_prefetch_hit_q;
    (* DONT_TOUCH = "yes" *) logic [STREAM_BITS-1:0]
        stream_demand_id_q;
    (* DONT_TOUCH = "yes" *) logic [1:0] stream_demand_generation_q;
    logic stream_unused_feedback;
    logic [STREAM_BITS-1:0] stream_unused_id;
    logic [1:0] stream_unused_generation;

    logic ext_pending_valid;
    logic [ADDR_WIDTH-1:0] ext_pending_addr;
    logic [4:0] ext_pending_age;
    logic ext_event_dropped;
    logic [2:0] idle_age;
    logic controller_issue_enable;
    logic controller_token_available;
    logic [1:0] controller_min_confidence;
    logic controller_consume_token;
    logic controller_feedback_help;
    logic controller_feedback_pollution;
    (* DONT_TOUCH = "yes" *) logic controller_demand_access_q;
    (* DONT_TOUCH = "yes" *) logic controller_consume_token_q;
    (* DONT_TOUCH = "yes" *) logic controller_feedback_help_q;
    (* DONT_TOUCH = "yes" *) logic controller_feedback_pollution_q;
    (* DONT_TOUCH = "yes" *) logic controller_feedback_late_merge_q;
    (* DONT_TOUCH = "yes" *) logic controller_feedback_blocked_q;
    logic shadow_access_valid;
    logic [1:0] shadow_actual_level;
    logic shadow_true_help;
    logic shadow_true_pollution;
    logic shadow_l1;
    logic shadow_victim;
    logic shadow_lower;
    logic [15:0] controller_saved;
    logic [15:0] controller_cost;
    logic pf_late_merge_event;
    logic pf_demand_block_event;
    logic [7:0] miss_penalty_ewma;
    logic [7:0] wb_penalty_ewma;
    logic [7:0] late_merge_credit;
    logic demand_read_timing;
    logic [7:0] demand_read_cycles;
    logic [7:0] wb_wait_cycles;
    logic [7:0] pf_wait_cycles;

    integer unused_pf_way_comb;
    integer invalid_vc_comb;
    logic pf_admission_safe_comb;
    logic [WAY_BITS-1:0] pf_selected_way_comb;
    logic pf_selected_evict_demand_comb;

    integer pf_resp_hit_way_comb;
    integer pf_resp_invalid_way_comb;
    integer pf_resp_unused_way_comb;
    integer pf_resp_victim_hit_comb;
    integer pf_resp_invalid_vc_comb;
    logic [SET_BITS-1:0] pf_resp_set_comb;
    logic [TAG_BITS-1:0] pf_resp_tag_comb;
    logic pf_resp_l1_hit_comb;
    logic pf_resp_victim_hit_valid_comb;
    logic pf_resp_safe_comb;
    logic [WAY_BITS-1:0] pf_resp_selected_way_comb;
    logic pf_resp_evict_demand_comb;

    integer lookup_i;
    integer background_lookup_i;
    integer pf_seq_i;
    integer reset_i;
    integer reset_j;
    integer assert_i;
    integer assert_j;
    integer assert_way;
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

    function automatic [7:0] ewma_eighth(
        input logic [7:0] old_value,
        input logic [7:0] sample
    );
        logic [11:0] weighted;
        begin
            weighted = old_value * 7 + sample + 4;
            ewma_eighth = weighted >> 3;
            if (ewma_eighth == 0)
                ewma_eighth = 8'd1;
        end
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

    l1d_stream_prefetch #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .STREAM_ENTRIES(STREAM_ENTRIES),
        .CANDIDATE_TTL(16),
        .MODE_STREAM(PF_OPT_LEVEL >= 2)
    ) stream_prefetch (
        .clk(clk),
        .rst_n(rst_n),
        .enable((ENABLE_PREFETCH != 0) &&
                cfg_prefetch_enable && cfg_next_line_enable),
        .candidate_enable(controller_issue_enable),
        .demand_access_valid(stream_demand_access_q),
        .demand_lower_miss(stream_demand_lower_miss_q),
        .demand_line_addr(stream_demand_line_addr_q),
        .demand_prefetch_hit(stream_demand_prefetch_hit_q),
        .demand_stream_id(stream_demand_id_q),
        .demand_stream_generation(stream_demand_generation_q),
        .unused_feedback_valid(stream_unused_feedback),
        .unused_stream_id(stream_unused_id),
        .unused_stream_generation(stream_unused_generation),
        .candidate_valid(stream_candidate_valid),
        .candidate_ready(stream_candidate_ready),
        .candidate_addr(stream_candidate_addr),
        .candidate_confidence(stream_candidate_confidence),
        .candidate_stream_id(stream_candidate_id),
        .candidate_stream_generation(stream_candidate_generation),
        .event_dropped(stream_event_dropped),
        .event_expired(stream_event_expired)
    );

    l1d_prefetch_controller #(
        .ADAPTIVE(PF_OPT_LEVEL >= 2),
        .EPOCH_DEMANDS(256),
        .OFF_DEMANDS(512),
        .PROBE_BUDGET(8)
    ) prefetch_controller (
        .clk(clk),
        .rst_n(rst_n),
        .enable((ENABLE_PREFETCH != 0) && cfg_prefetch_enable),
        .demand_access(controller_demand_access_q),
        .consume_token(controller_consume_token_q),
        .feedback_help(controller_feedback_help_q),
        .feedback_pollution(controller_feedback_pollution_q),
        .feedback_late_merge(controller_feedback_late_merge_q),
        .feedback_blocked_cycle(controller_feedback_blocked_q),
        .feedback_pf_writeback(1'b0),
        .miss_penalty(miss_penalty_ewma),
        .wb_penalty(wb_penalty_ewma),
        .late_merge_credit(late_merge_credit),
        .issue_enable(controller_issue_enable),
        .token_available(controller_token_available),
        .controller_state(debug_pf_controller_state),
        .min_confidence(controller_min_confidence),
        .debug_epoch_saved(controller_saved),
        .debug_epoch_cost(controller_cost)
    );

    generate
        if (ENABLE_PREFETCH != 0 && PF_OPT_LEVEL >= 3) begin : gen_shadow
            l1d_shadow_cache #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .LINE_BYTES(LINE_BYTES),
                .NUM_SETS(NUM_SETS),
                .NUM_WAYS(NUM_WAYS),
                .VICTIM_ENTRIES(VICTIM_ENTRIES)
            ) shadow_cache (
                .clk(clk),
                .rst_n(rst_n),
                .access_valid(shadow_access_valid),
                .access_line_addr(req_line_addr_comb),
                .access_write(req_write),
                .actual_level(shadow_actual_level),
                .event_true_help(shadow_true_help),
                .event_true_pollution(shadow_true_pollution),
                .event_shadow_l1(shadow_l1),
                .event_shadow_victim(shadow_victim),
                .event_shadow_lower(shadow_lower)
            );
        end else begin : gen_no_shadow
            assign shadow_true_help = 1'b0;
            assign shadow_true_pollution = 1'b0;
            assign shadow_l1 = 1'b0;
            assign shadow_victim = 1'b0;
            assign shadow_lower = 1'b0;
        end
    endgenerate

    assign debug_pf_mshr_valid = (PF_OPT_LEVEL >= 3) && pf_mshr_valid;
    assign debug_pf_mshr_addr = pf_mshr_addr;
    assign debug_pf_mshr_confidence = pf_mshr_confidence;
    assign controller_feedback_help = (PF_OPT_LEVEL >= 3) ?
                                      shadow_true_help : event_prefetch_useful;
    assign controller_feedback_pollution = (PF_OPT_LEVEL >= 3) ?
                                           shadow_true_pollution :
                                           event_prefetch_pollution;

    // Policy accounting is intentionally one cycle behind the cache FSM.
    // These registers prevent residency compares, issue arbitration and
    // shadow classification from feeding the controller's wide accumulators
    // and state decoder in the same timing path.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            controller_demand_access_q <= 1'b0;
            controller_consume_token_q <= 1'b0;
            controller_feedback_help_q <= 1'b0;
            controller_feedback_pollution_q <= 1'b0;
            controller_feedback_late_merge_q <= 1'b0;
            controller_feedback_blocked_q <= 1'b0;
            stream_demand_access_q <= 1'b0;
            stream_demand_lower_miss_q <= 1'b0;
            stream_demand_line_addr_q <= '0;
            stream_demand_prefetch_hit_q <= 1'b0;
            stream_demand_id_q <= '0;
            stream_demand_generation_q <= '0;
        end else begin
            controller_demand_access_q <= event_cpu_access;
            controller_consume_token_q <= controller_consume_token;
            controller_feedback_help_q <= controller_feedback_help;
            controller_feedback_pollution_q <= controller_feedback_pollution;
            controller_feedback_late_merge_q <= pf_late_merge_event;
            controller_feedback_blocked_q <= pf_demand_block_event;
            stream_demand_access_q <= stream_demand_access;
            stream_demand_lower_miss_q <= stream_demand_lower_miss;
            stream_demand_line_addr_q <= req_line_addr_comb;
            stream_demand_prefetch_hit_q <= stream_demand_prefetch_hit;
            stream_demand_id_q <= stream_demand_id;
            stream_demand_generation_q <= stream_demand_generation;
        end
    end

    always_comb begin
        req_set_comb = address_set(req_addr);
        req_tag_comb = address_tag(req_addr);
        req_line_addr_comb = line_address(req_addr);

        l1_hit_comb = 1'b0;
        hit_way_comb = 0;
        invalid_way_comb = -1;
        unused_pf_way_comb = -1;
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
            if (valid_bits[lookup_i][req_set_comb] &&
                prefetched_bits[lookup_i][req_set_comb] &&
                unused_pf_way_comb == -1) begin
                unused_pf_way_comb = lookup_i;
            end
        end

        victim_hit_valid_comb = 1'b0;
        victim_hit_comb = 0;
        invalid_vc_comb = -1;
        for (lookup_i = 0; lookup_i < VICTIM_ENTRIES;
             lookup_i = lookup_i + 1) begin
            if (vc_valid[lookup_i] &&
                vc_addr[lookup_i] == req_line_addr_comb) begin
                victim_hit_valid_comb = 1'b1;
                victim_hit_comb = lookup_i;
            end
            if (!vc_valid[lookup_i] && invalid_vc_comb == -1)
                invalid_vc_comb = lookup_i;
        end

        // At most one speculative line may reside in a set.  Preserve the
        // specified admission order: consume free capacity first, then
        // replace the set's existing cold speculative line.
        pf_admission_safe_comb = 1'b0;
        pf_selected_way_comb = replacement_way[req_set_comb];
        pf_selected_evict_demand_comb = 1'b0;
        if (invalid_way_comb >= 0) begin
            pf_admission_safe_comb = 1'b1;
            pf_selected_way_comb = invalid_way_comb[WAY_BITS-1:0];
        end else if (unused_pf_way_comb >= 0) begin
            pf_admission_safe_comb = 1'b1;
            pf_selected_way_comb = unused_pf_way_comb[WAY_BITS-1:0];
        end else if (req_pf_confidence == 2'b11 &&
                     !dirty_bits[replacement_way[req_set_comb]][req_set_comb] &&
                     invalid_vc_comb >= 0) begin
            // A high-confidence candidate may displace a clean demand line,
            // but only into an invalid VC entry, so it can never cause a
            // speculative dirty-victim writeback.
            pf_admission_safe_comb = 1'b1;
            pf_selected_way_comb = replacement_way[req_set_comb];
            pf_selected_evict_demand_comb = 1'b1;
        end
    end

    // Response-time lookup for the detached PF MSHR.  The SRAM read is
    // launched before ST_PF_REVALIDATE, so tag_q/data_q describe this set.
    assign pf_resp_set_comb = address_set(pf_mshr_addr);
    assign pf_resp_tag_comb = address_tag(pf_mshr_addr);

    // Keep arbitration predicates as acyclic continuous expressions.  This is
    // important for Icarus: a monolithic always_comb that writes then re-reads
    // these predicates can form a zero-time loop when the MSHR becomes live.
    assign accept_cpu = (state == ST_IDLE) && cpu_req_valid;
    assign ext_prefetch_ready = !ext_pending_valid &&
        (ENABLE_PREFETCH != 0) && cfg_prefetch_enable &&
        controller_issue_enable;
    assign accept_ext = (state == ST_IDLE) && !cpu_req_valid &&
        (ENABLE_PREFETCH != 0) && cfg_prefetch_enable &&
        idle_age >= IDLE_GUARD && controller_issue_enable &&
        controller_token_available && ext_pending_valid &&
        !(PF_OPT_LEVEL >= 3 && pf_mshr_valid);
    assign background_pf_prepare = (PF_OPT_LEVEL >= 3) &&
        (state == ST_RESP) && cpu_rsp_ready && cpu_req_valid &&
        (ENABLE_PREFETCH != 0) && cfg_prefetch_enable &&
        (ext_pending_valid || cfg_next_line_enable) &&
        !access_misaligned(cpu_req_addr, cpu_req_size) &&
        !background_next_l1_hit && !background_next_vc_hit &&
        ((ext_pending_valid ? ext_pending_addr : stream_candidate_addr) ==
         line_address(cpu_req_addr)) && !pf_mshr_valid &&
        controller_issue_enable && controller_token_available &&
        (ext_pending_valid ||
         (stream_candidate_valid &&
          stream_candidate_confidence >= controller_min_confidence));
    // Residency proof is registered in ST_RESP.  The actual lower-memory
    // launch occurs while the held demand is accepted from ST_IDLE, keeping
    // the wide L1/VC comparisons off candidate FIFO update paths.
    assign background_pf_issue = background_pf_pending &&
        (state == ST_IDLE) && cpu_req_valid && mem_req_ready &&
        cfg_prefetch_enable && controller_issue_enable &&
        !pf_mshr_valid;
    assign accept_bg_ext = background_pf_issue && background_pf_external_q;
    assign accept_bg_next = background_pf_issue && !background_pf_external_q &&
                            stream_candidate_valid;

    always @* begin : background_residency_lookup
        background_next_l1_hit = 1'b0;
        background_next_vc_hit = 1'b0;
        for (background_lookup_i = 0;
             background_lookup_i < NUM_WAYS;
             background_lookup_i = background_lookup_i + 1) begin
            if (valid_bits[background_lookup_i][address_set(cpu_req_addr)] &&
                tag_mirror[background_lookup_i][address_set(cpu_req_addr)] ==
                    address_tag(cpu_req_addr))
                background_next_l1_hit = 1'b1;
        end
        for (background_lookup_i = 0;
             background_lookup_i < VICTIM_ENTRIES;
             background_lookup_i = background_lookup_i + 1) begin
            if (vc_valid[background_lookup_i] &&
                vc_addr[background_lookup_i] == line_address(cpu_req_addr))
                background_next_vc_hit = 1'b1;
        end
    end
    assign stream_candidate_ready = ((state == ST_IDLE) && !cpu_req_valid &&
        (ENABLE_PREFETCH != 0) && cfg_prefetch_enable &&
        cfg_next_line_enable &&
        idle_age >= IDLE_GUARD && controller_issue_enable &&
        controller_token_available && !ext_pending_valid &&
        stream_candidate_confidence >= controller_min_confidence &&
        !(PF_OPT_LEVEL >= 3 && pf_mshr_valid)) || accept_bg_next;
    assign accept_next = stream_candidate_ready && stream_candidate_valid;
    assign controller_consume_token = accept_ext ||
        (accept_next && !accept_bg_next) || background_pf_issue;
    assign cpu_req_ready = (state == ST_IDLE);
    assign cpu_rsp_valid = (state == ST_RESP);
    assign cpu_rsp_rdata = response_data;
    assign cpu_rsp_error = response_error;
    assign cpu_rsp_error_cause = response_error_cause;
    // Quiescent means there is no accepted request, detached response, or
    // queued external candidate that can create a lifecycle event on the next
    // edge.  Runtime-disable gating above prevents a queued internal candidate
    // from being admitted while the testbench clocks it away during drain.
    assign cache_idle = (state == ST_IDLE) &&
                        !(PF_OPT_LEVEL >= 3 && pf_mshr_valid) &&
                        !pf_response_pending && !ext_pending_valid;
    assign event_prefetch_dropped = stream_event_dropped ||
                                    stream_event_expired ||
                                    ext_event_dropped;
    assign pf_demand_block_event =
        ((PF_OPT_LEVEL >= 3) && pf_waiter_valid &&
         !pf_waiter_same_line && state == ST_PF_WAIT) ||
        (cpu_req_valid && !cpu_req_ready &&
         (req_is_prefetch || state == ST_PF_REVALIDATE ||
          state == ST_PF_MERGE_WB || state == ST_PF_MERGE_VC ||
          state == ST_PF_INSTALL));
    assign stream_demand_access = (state == ST_LOOKUP) &&
        !req_is_prefetch && !req_miss_recorded;
    assign stream_demand_lower_miss = stream_demand_access &&
        !l1_hit_comb && !victim_hit_valid_comb;
    assign stream_demand_prefetch_hit = stream_demand_access &&
        ((l1_hit_comb && prefetched_bits[hit_way_comb][req_set_comb]) ||
         (victim_hit_valid_comb && vc_prefetched[victim_hit_comb]));
    assign shadow_access_valid = stream_demand_access;
    assign shadow_actual_level = l1_hit_comb ? 2'd0 :
                                 victim_hit_valid_comb ? 2'd1 : 2'd2;

    always_comb begin
        stream_demand_id = '0;
        stream_demand_generation = '0;
        if (l1_hit_comb) begin
            stream_demand_id = prefetched_stream_id[hit_way_comb][req_set_comb];
            stream_demand_generation =
                prefetched_stream_generation[hit_way_comb][req_set_comb];
        end else if (victim_hit_valid_comb) begin
            stream_demand_id = vc_stream_id[victim_hit_comb];
            stream_demand_generation = vc_stream_generation[victim_hit_comb];
        end
    end

    always @* begin : datapath_outputs
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

        if (background_pf_issue) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b0;
            mem_req_addr = background_pf_addr_q;
        end

        if (state == ST_IDLE) begin
            if (accept_cpu) begin
                if (!access_misaligned(cpu_req_addr, cpu_req_size)) begin
                    array_en = 1'b1;
                    array_addr = address_set(cpu_req_addr);
                end
            end else if (PF_OPT_LEVEL >= 3 && pf_response_pending) begin
                array_en = 1'b1;
                array_addr = address_set(pf_mshr_addr);
            end else if (accept_ext) begin
                array_en = 1'b1;
                array_addr = address_set(ext_pending_addr);
            end else if (accept_next) begin
                array_en = 1'b1;
                array_addr = address_set(stream_candidate_addr);
            end
        end

        if (state == ST_PF_WAIT && pf_waiter_same_line &&
            pf_response_pending) begin
            array_en = 1'b1;
            array_addr = address_set(pf_mshr_addr);
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


        if (state == ST_PF_INSTALL) begin
            array_en = 1'b1;
            array_addr = address_set(pf_mshr_addr);
            tag_we[selected_way] = 1'b1;
            data_we[selected_way] = 1'b1;
            array_wtag = address_tag(pf_mshr_addr);
            array_wdata = fill_line;
        end

        if (state == ST_WB_REQ) begin
            mem_req_valid = 1'b1;
            mem_req_write = 1'b1;
            mem_req_addr = wb_addr;
            mem_req_wdata = wb_data;
        end


        if (state == ST_PF_MERGE_WB) begin
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
            req_pf_external <= 1'b0;
            req_pf_confidence <= '0;
            req_pf_stream_id <= '0;
            req_pf_stream_generation <= '0;
            req_miss_recorded <= 1'b0;
            pf_mshr_valid <= 1'b0;
            pf_mshr_addr <= '0;
            pf_mshr_external <= 1'b0;
            pf_mshr_confidence <= '0;
            pf_mshr_stream_id <= '0;
            pf_mshr_stream_generation <= '0;
            pf_response_pending <= 1'b0;
            pf_response_age <= '0;
            pf_waiter_valid <= 1'b0;
            pf_waiter_same_line <= 1'b0;
            background_pf_pending <= 1'b0;
            background_pf_external_q <= 1'b0;
            background_pf_addr_q <= '0;
            background_pf_confidence_q <= '0;
            background_pf_stream_id_q <= '0;
            background_pf_stream_generation_q <= '0;
            pf_late_merge_event <= 1'b0;
            miss_penalty_ewma <= 8'd8;
            wb_penalty_ewma <= 8'd8;
            late_merge_credit <= 8'd4;
            demand_read_timing <= 1'b0;
            demand_read_cycles <= '0;
            wb_wait_cycles <= '0;
            pf_wait_cycles <= '0;
            selected_way <= '0;
            selected_vc <= '0;
            working_line <= '0;
            working_dirty <= 1'b0;
            fill_line <= '0;
            evicted_valid <= 1'b0;
            evicted_dirty <= 1'b0;
            evicted_prefetched <= 1'b0;
            evicted_stream_id <= '0;
            evicted_stream_generation <= '0;
            eviction_deferred <= 1'b0;
            evicted_addr <= '0;
            evicted_data <= '0;
            quota_drop_pf <= 1'b0;
            quota_drop_way <= '0;
            wb_addr <= '0;
            wb_data <= '0;
            response_data <= '0;
            response_error <= 1'b0;
            response_error_cause <= RSP_OK;
            vc_rr <= '0;
            ext_pending_valid <= 1'b0;
            ext_pending_addr <= '0;
            ext_pending_age <= '0;
            ext_event_dropped <= 1'b0;
            idle_age <= '0;
            stream_candidate_seen <= 1'b0;
            stream_unused_feedback <= 1'b0;
            stream_unused_id <= '0;
            stream_unused_generation <= '0;

            stat_cpu_hits <= '0;
            stat_cpu_misses <= '0;
            stat_victim_hits <= '0;
            stat_writebacks <= '0;
            stat_prefetch_fills <= '0;
            stat_prefetch_useful <= '0;
            stat_prefetch_useless <= '0;
            stat_prefetch_pollution <= '0;
            stat_prefetch_dropped <= '0;
            stat_pf_candidates <= '0;
            stat_pf_admitted <= '0;
            stat_pf_issued <= '0;
            stat_pf_returned <= '0;
            stat_pf_installed <= '0;
            stat_pf_merged <= '0;
            stat_pf_discarded <= '0;
            stat_pf_cancelled <= '0;
            stat_pf_unused_evicted <= '0;
            stat_pf_vc_bypass <= '0;
            stat_pf_caused_writebacks <= '0;
            stat_pf_demand_block_cycles <= '0;
            stat_pf_true_help <= '0;
            stat_pf_true_pollution <= '0;
            stat_pf_suppressed_quota <= '0;
            stat_pf_suppressed_unsafe <= '0;
            stat_pf_same_line_coalesced <= '0;
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
                    tag_mirror[reset_j][reset_i] <= '0;
                    valid_bits[reset_j][reset_i] <= 1'b0;
                    dirty_bits[reset_j][reset_i] <= 1'b0;
                    prefetched_bits[reset_j][reset_i] <= 1'b0;
                    prefetched_stream_id[reset_j][reset_i] <= '0;
                    prefetched_stream_generation[reset_j][reset_i] <= '0;
                end
            end
            for (reset_i = 0; reset_i < VICTIM_ENTRIES;
                 reset_i = reset_i + 1) begin
                vc_valid[reset_i] <= 1'b0;
                vc_dirty[reset_i] <= 1'b0;
                vc_prefetched[reset_i] <= 1'b0;
                vc_stream_id[reset_i] <= '0;
                vc_stream_generation[reset_i] <= '0;
                vc_addr[reset_i] <= '0;
                vc_data[reset_i] <= '0;
            end
        end else begin
            if (background_pf_prepare) begin
                background_pf_pending <= 1'b1;
                background_pf_external_q <= ext_pending_valid;
                background_pf_addr_q <= ext_pending_valid ?
                    ext_pending_addr : stream_candidate_addr;
                background_pf_confidence_q <= ext_pending_valid ?
                    2'b11 : stream_candidate_confidence;
                background_pf_stream_id_q <= ext_pending_valid ?
                    '0 : stream_candidate_id;
                background_pf_stream_generation_q <= ext_pending_valid ?
                    '0 : stream_candidate_generation;
            end else if (background_pf_pending && state == ST_IDLE &&
                         (!cpu_req_valid || !mem_req_ready || pf_mshr_valid ||
                          !cfg_prefetch_enable || !controller_issue_enable)) begin
                // A speculative launch never stalls or outranks a demand.
                background_pf_pending <= 1'b0;
            end

            if (background_pf_issue) begin
                pf_mshr_valid <= 1'b1;
                pf_mshr_addr <= background_pf_addr_q;
                pf_mshr_external <= background_pf_external_q;
                pf_mshr_confidence <= background_pf_confidence_q;
                pf_mshr_stream_id <= background_pf_stream_id_q;
                pf_mshr_stream_generation <=
                    background_pf_stream_generation_q;
                pf_waiter_valid <= 1'b0;
                pf_waiter_same_line <= 1'b0;
                pf_response_pending <= mem_rsp_valid;
                stat_pf_admitted <= stat_pf_admitted + 1'b1;
                stat_pf_issued <= stat_pf_issued + 1'b1;
                background_pf_pending <= 1'b0;
                if (background_pf_external_q) begin
                    ext_pending_valid <= 1'b0;
                    ext_pending_age <= '0;
                end
                if (mem_rsp_valid) begin
                    fill_line <= mem_rsp_rdata;
                    stat_pf_returned <= stat_pf_returned + 1'b1;
                end
            end

            for (reset_i = 0; reset_i < NUM_WAYS;
                 reset_i = reset_i + 1) begin
                if (array_en && tag_we[reset_i])
                    tag_mirror[reset_i][array_addr] <= array_wtag;
            end
            stream_unused_feedback <= 1'b0;
            pf_late_merge_event <= 1'b0;
            ext_event_dropped <= 1'b0;
            event_cpu_access <= 1'b0;
            event_cpu_hit <= 1'b0;
            event_cpu_miss <= 1'b0;
            event_victim_hit <= 1'b0;
            event_writeback <= 1'b0;
            event_prefetch_fill <= 1'b0;
            event_prefetch_useful <= 1'b0;
            event_prefetch_useless <= 1'b0;
            event_prefetch_pollution <= 1'b0;
            if (stream_event_dropped || stream_event_expired ||
                ext_event_dropped) begin
                stat_prefetch_dropped <= stat_prefetch_dropped + 1'b1;
            end
            if ((PF_OPT_LEVEL >= 3 && shadow_true_help) ||
                (PF_OPT_LEVEL < 3 && event_prefetch_useful))
                stat_pf_true_help <= stat_pf_true_help + 1'b1;
            if ((PF_OPT_LEVEL >= 3 && shadow_true_pollution) ||
                (PF_OPT_LEVEL < 3 && event_prefetch_pollution))
                stat_pf_true_pollution <= stat_pf_true_pollution + 1'b1;
            if (pf_demand_block_event)
                stat_pf_demand_block_cycles <=
                    stat_pf_demand_block_cycles + 1'b1;

            // Calibrate cycle-equivalent miss and writeback penalties online.
            // The 1/8 EWMA is intentionally cheap (7*old + sample)/8 and
            // starts from eight cycles until the first directed observation.
            if (demand_read_timing && demand_read_cycles != 8'hff)
                demand_read_cycles <= demand_read_cycles + 1'b1;
            if (demand_read_timing && state == ST_MEM_READ_WAIT &&
                mem_rsp_valid) begin
                miss_penalty_ewma <= ewma_eighth(
                    miss_penalty_ewma, demand_read_cycles);
                demand_read_timing <= 1'b0;
                demand_read_cycles <= '0;
            end
            if (state == ST_WB_REQ || state == ST_PF_MERGE_WB) begin
                if (mem_req_ready) begin
                    wb_penalty_ewma <= ewma_eighth(
                        wb_penalty_ewma,
                        (wb_wait_cycles == 8'hff) ? 8'hff :
                        wb_wait_cycles + 1'b1);
                    wb_wait_cycles <= '0;
                end else if (wb_wait_cycles != 8'hff) begin
                    wb_wait_cycles <= wb_wait_cycles + 1'b1;
                end
            end else begin
                wb_wait_cycles <= '0;
            end
            if (pf_waiter_valid && pf_waiter_same_line) begin
                if (pf_wait_cycles != 8'hff)
                    pf_wait_cycles <= pf_wait_cycles + 1'b1;
            end else if (!pf_waiter_valid) begin
                pf_wait_cycles <= '0;
            end

            // A PF response has no backpressure pin.  Capture it immediately
            // into the existing transient refill register, independent of the
            // demand FSM's current hit/response state.
            if (PF_OPT_LEVEL >= 3 && pf_mshr_valid && mem_rsp_valid &&
                !pf_response_pending) begin
                fill_line <= mem_rsp_rdata;
                pf_response_pending <= 1'b1;
                pf_response_age <= '0;
                stat_pf_returned <= stat_pf_returned + 1'b1;
            end
            if (PF_OPT_LEVEL >= 3 && pf_response_pending) begin
                if ((state == ST_IDLE && !cpu_req_valid) ||
                    state == ST_PF_WAIT || state == ST_PF_REVALIDATE ||
                    (state == ST_LOOKUP && !req_is_prefetch &&
                     !l1_hit_comb && !victim_hit_valid_comb &&
                     pf_mshr_valid)) begin
                    pf_response_age <= '0;
                end else if (pf_response_age >= 2'd1 &&
                             !pf_waiter_valid) begin
                    // fill_line is a transient capture register, not a
                    // persistent prefetch buffer.  If array arbitration cannot
                    // consume the response within two cycles, drop it.
                    pf_mshr_valid <= 1'b0;
                    pf_response_pending <= 1'b0;
                    pf_response_age <= '0;
                    stat_pf_discarded <= stat_pf_discarded + 1'b1;
                end else begin
                    pf_response_age <= pf_response_age + 1'b1;
                end
            end else if (!pf_response_pending) begin
                pf_response_age <= '0;
            end

            if (state == ST_IDLE && !cpu_req_valid) begin
                if (idle_age != 3'b111)
                    idle_age <= idle_age + 1'b1;
            end else begin
                idle_age <= '0;
            end

            if (ext_prefetch_valid && ext_prefetch_ready) begin
                ext_pending_valid <= 1'b1;
                ext_pending_addr <= line_address(ext_prefetch_addr);
                ext_pending_age <= '0;
            end else if (ext_pending_valid &&
                         (!cfg_prefetch_enable || ENABLE_PREFETCH == 0 ||
                          !controller_issue_enable)) begin
                ext_pending_valid <= 1'b0;
                ext_pending_age <= '0;
                stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                stat_pf_suppressed_quota <=
                    stat_pf_suppressed_quota + 1'b1;
            end else if (ext_pending_valid && event_cpu_access) begin
                if (ext_pending_age >= 5'd15) begin
                    ext_pending_valid <= 1'b0;
                    ext_pending_age <= '0;
                    ext_event_dropped <= 1'b1;
                    stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                    if (!controller_token_available)
                        stat_pf_suppressed_quota <=
                            stat_pf_suppressed_quota + 1'b1;
                end else begin
                    ext_pending_age <= ext_pending_age + 1'b1;
                end
            end

            if (!stream_candidate_valid) begin
                stream_candidate_seen <= 1'b0;
            end else if (!stream_candidate_seen) begin
                stream_candidate_seen <= 1'b1;
                if (!controller_issue_enable ||
                    !controller_token_available ||
                    stream_candidate_confidence < controller_min_confidence)
                    stat_pf_suppressed_quota <=
                        stat_pf_suppressed_quota + 1'b1;
            end
            if ((ext_prefetch_valid && ext_prefetch_ready) &&
                (stream_candidate_valid && !stream_candidate_seen))
                stat_pf_candidates <= stat_pf_candidates + 2'd2;
            else if ((ext_prefetch_valid && ext_prefetch_ready) ||
                     (stream_candidate_valid && !stream_candidate_seen))
                stat_pf_candidates <= stat_pf_candidates + 1'b1;
            if (accept_next)
                stream_candidate_seen <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (accept_cpu) begin
                        req_addr <= cpu_req_addr;
                        req_write <= cpu_req_write;
                        req_size <= cpu_req_size;
                        req_unsigned <= cpu_req_unsigned;
                        req_wdata <= cpu_req_wdata;
                        req_is_prefetch <= 1'b0;
                        req_pf_external <= 1'b0;
                        req_pf_confidence <= '0;
                        req_pf_stream_id <= '0;
                        req_pf_stream_generation <= '0;
                        req_miss_recorded <= 1'b0;
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
                    end else if (PF_OPT_LEVEL >= 3 &&
                                 pf_response_pending) begin
                        state <= ST_PF_REVALIDATE;
                    end else if (accept_ext) begin
                        req_addr <= ext_pending_addr;
                        req_write <= 1'b0;
                        req_size <= ACCESS_DOUBLE;
                        req_unsigned <= 1'b0;
                        req_wdata <= '0;
                        req_is_prefetch <= 1'b1;
                        req_pf_external <= 1'b1;
                        req_pf_confidence <= 2'b11;
                        req_pf_stream_id <= '0;
                        req_pf_stream_generation <= '0;
                        req_miss_recorded <= 1'b0;
                        quota_drop_pf <= 1'b0;
                        ext_pending_valid <= 1'b0;
                        ext_pending_age <= '0;
                        stat_pf_admitted <= stat_pf_admitted + 1'b1;
                        state <= ST_LOOKUP;
                    end else if (accept_next) begin
                        req_addr <= stream_candidate_addr;
                        req_write <= 1'b0;
                        req_size <= ACCESS_DOUBLE;
                        req_unsigned <= 1'b0;
                        req_wdata <= '0;
                        req_is_prefetch <= 1'b1;
                        req_pf_external <= 1'b0;
                        req_pf_confidence <= stream_candidate_confidence;
                        req_pf_stream_id <= stream_candidate_id;
                        req_pf_stream_generation <=
                            stream_candidate_generation;
                        req_miss_recorded <= 1'b0;
                        quota_drop_pf <= 1'b0;
                        stat_pf_admitted <= stat_pf_admitted + 1'b1;
                        state <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    // The lookup itself has not declared a lower-memory
                    // request.  Speculative work remains cancellable here so
                    // a newly visible demand owns the next IDLE handshake.
                    if (req_is_prefetch && cpu_req_valid) begin
                        stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                        quota_drop_pf <= 1'b0;
                        state <= ST_IDLE;
                    end else if (l1_hit_comb) begin
                        eviction_deferred <= 1'b0;
                        selected_way <= hit_way_comb[WAY_BITS-1:0];
                        if (req_is_prefetch) begin
                            stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                            stat_pf_same_line_coalesced <=
                                stat_pf_same_line_coalesced + 1'b1;
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
                        eviction_deferred <= 1'b0;
                        if (req_is_prefetch) begin
                            stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                            stat_pf_same_line_coalesced <=
                                stat_pf_same_line_coalesced + 1'b1;
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
                                evicted_stream_id <= '0;
                                evicted_stream_generation <= '0;
                                evicted_addr <= '0;
                                evicted_data <= '0;
                            end else begin
                                evicted_dirty <=
                                    dirty_bits[replacement_way[req_set_comb]][req_set_comb];
                                evicted_prefetched <=
                                    prefetched_bits[replacement_way[req_set_comb]][req_set_comb];
                                evicted_stream_id <= prefetched_stream_id[
                                    replacement_way[req_set_comb]][req_set_comb];
                                evicted_stream_generation <=
                                    prefetched_stream_generation[
                                        replacement_way[req_set_comb]][req_set_comb];
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
                            end else begin
                                working_line <= vc_data[victim_hit_comb];
                                working_dirty <= vc_dirty[victim_hit_comb];
                            end
                            if (vc_prefetched[victim_hit_comb]) begin
                                stat_prefetch_useful <= stat_prefetch_useful + 1'b1;
                                event_prefetch_useful <= 1'b1;
                            end
                            state <= ST_VC_SWAP;
                        end
                    end else begin
                        if (!req_is_prefetch && !req_miss_recorded) begin
                            stat_cpu_misses <= stat_cpu_misses + 1'b1;
                            event_cpu_miss <= 1'b1;
                            req_miss_recorded <= 1'b1;
                        end
                        if (!req_is_prefetch && PF_OPT_LEVEL >= 3 &&
                            pf_mshr_valid) begin
                            // Lower memory is occupied by the sole PF MSHR.
                            // Hits above took their normal path; only a lower
                            // miss waits here.
                            pf_waiter_valid <= 1'b1;
                            pf_waiter_same_line <=
                                (req_line_addr_comb == pf_mshr_addr);
                            if (req_line_addr_comb == pf_mshr_addr)
                                stat_pf_same_line_coalesced <=
                                    stat_pf_same_line_coalesced + 1'b1;
                            state <= ST_PF_WAIT;
                        end else if (req_is_prefetch) begin
                            if (!pf_admission_safe_comb) begin
                                // Dirty L1 victims and occupied VC slots are
                                // never disturbed by speculative traffic.
                                stat_pf_suppressed_unsafe <=
                                    stat_pf_suppressed_unsafe + 1'b1;
                                stat_pf_cancelled <= stat_pf_cancelled + 1'b1;
                                state <= ST_IDLE;
                            end else begin
                                quota_drop_pf <=
                                    (invalid_way_comb >= 0 &&
                                     unused_pf_way_comb >= 0);
                                if (unused_pf_way_comb >= 0)
                                    quota_drop_way <=
                                        unused_pf_way_comb[WAY_BITS-1:0];
                                eviction_deferred <= valid_bits[
                                    pf_selected_way_comb][req_set_comb];
                                selected_way <= pf_selected_way_comb;
                                evicted_valid <= valid_bits[
                                    pf_selected_way_comb][req_set_comb];
                                evicted_dirty <= dirty_bits[
                                    pf_selected_way_comb][req_set_comb];
                                evicted_prefetched <= prefetched_bits[
                                    pf_selected_way_comb][req_set_comb];
                                evicted_stream_id <= prefetched_stream_id[
                                    pf_selected_way_comb][req_set_comb];
                                evicted_stream_generation <=
                                    prefetched_stream_generation[
                                        pf_selected_way_comb][req_set_comb];
                                evicted_addr <= compose_line_address(
                                    tag_q[pf_selected_way_comb], req_set_comb);
                                evicted_data <= data_q[pf_selected_way_comb];
                                if (pf_selected_evict_demand_comb) begin
                                    selected_vc <= invalid_vc_comb[VC_BITS-1:0];
                                end
                                // Preserve the selected line until the refill
                                // returns; speculative installation performs
                                // the VC move/drop atomically.
                                state <= ST_MEM_READ_REQ;
                            end
                        end else if (invalid_way_comb >= 0) begin
                            eviction_deferred <= 1'b0;
                            selected_way <= invalid_way_comb[WAY_BITS-1:0];
                            evicted_valid <= 1'b0;
                            evicted_dirty <= 1'b0;
                            evicted_prefetched <= 1'b0;
                            evicted_stream_id <= '0;
                            evicted_stream_generation <= '0;
                            evicted_addr <= '0;
                            evicted_data <= '0;
                            state <= ST_MEM_READ_REQ;
                        end else begin
                            eviction_deferred <= prefetched_bits[
                                replacement_way[req_set_comb]][req_set_comb];
                            selected_way <= replacement_way[req_set_comb];
                            evicted_valid <= 1'b1;
                            evicted_dirty <= dirty_bits[
                                replacement_way[req_set_comb]][req_set_comb];
                            evicted_prefetched <= prefetched_bits[
                                replacement_way[req_set_comb]][req_set_comb];
                            evicted_stream_id <= prefetched_stream_id[
                                replacement_way[req_set_comb]][req_set_comb];
                            evicted_stream_generation <=
                                prefetched_stream_generation[
                                    replacement_way[req_set_comb]][req_set_comb];
                            evicted_addr <= compose_line_address(
                                tag_q[replacement_way[req_set_comb]], req_set_comb
                            );
                            evicted_data <= data_q[replacement_way[req_set_comb]];
                            selected_vc <= vc_rr;

                            if (prefetched_bits[
                                    replacement_way[req_set_comb]][req_set_comb]) begin
                                // An unused clean prefetch is disposable and
                                // must never consume victim-cache residency.
                                state <= ST_MEM_READ_REQ;
                            end else if (vc_valid[vc_rr] && vc_dirty[vc_rr]) begin
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
                    prefetched_stream_id[selected_way][req_set_comb] <= '0;
                    prefetched_stream_generation[selected_way][req_set_comb] <= '0;
                    state <= ST_RESP;
                end

                ST_VC_SWAP: begin
                    // working_line was registered in ST_LOOKUP.  Extracting
                    // the response here keeps the VC tag compare and line-data
                    // mux out of the response register's timing cone without
                    // adding a CPU-visible cycle.
                    response_data <= line_load_data(
                        working_line, req_addr, req_size, req_unsigned);
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <= working_dirty;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    prefetched_stream_id[selected_way][req_set_comb] <= '0;
                    prefetched_stream_generation[selected_way][req_set_comb] <= '0;
                    replacement_way[req_set_comb] <=
                        (selected_way + 1'b1) % NUM_WAYS;

                    if (evicted_valid && !evicted_prefetched) begin
                        vc_valid[selected_vc] <= 1'b1;
                        vc_dirty[selected_vc] <= evicted_dirty;
                        vc_prefetched[selected_vc] <= evicted_prefetched;
                        vc_stream_id[selected_vc] <= evicted_stream_id;
                        vc_stream_generation[selected_vc] <=
                            evicted_stream_generation;
                        vc_addr[selected_vc] <= evicted_addr;
                        vc_data[selected_vc] <= evicted_data;
                    end else begin
                        vc_valid[selected_vc] <= 1'b0;
                        vc_dirty[selected_vc] <= 1'b0;
                        vc_prefetched[selected_vc] <= 1'b0;
                        vc_stream_id[selected_vc] <= '0;
                        vc_stream_generation[selected_vc] <= '0;
                        if (evicted_valid && evicted_prefetched) begin
                            stat_prefetch_useless <=
                                stat_prefetch_useless + 1'b1;
                            stat_pf_unused_evicted <=
                                stat_pf_unused_evicted + 1'b1;
                            stat_pf_vc_bypass <= stat_pf_vc_bypass + 1'b1;
                            event_prefetch_useless <= 1'b1;
                            stream_unused_feedback <= 1'b1;
                            stream_unused_id <= evicted_stream_id;
                            stream_unused_generation <=
                                evicted_stream_generation;
                        end
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
                    vc_stream_id[selected_vc] <= evicted_stream_id;
                    vc_stream_generation[selected_vc] <=
                        evicted_stream_generation;
                    vc_addr[selected_vc] <= evicted_addr;
                    vc_data[selected_vc] <= evicted_data;
                    valid_bits[selected_way][req_set_comb] <= 1'b0;
                    dirty_bits[selected_way][req_set_comb] <= 1'b0;
                    prefetched_bits[selected_way][req_set_comb] <= 1'b0;
                    prefetched_stream_id[selected_way][req_set_comb] <= '0;
                    prefetched_stream_generation[selected_way][req_set_comb] <= '0;
                    if (vc_rr == VICTIM_ENTRIES-1) begin
                        vc_rr <= '0;
                    end else begin
                        vc_rr <= vc_rr + 1'b1;
                    end
                    state <= ST_MEM_READ_REQ;
                end

                ST_MEM_READ_REQ: begin
                    if (mem_req_ready) begin
                        if (req_is_prefetch) begin
                            stat_pf_issued <= stat_pf_issued + 1'b1;
                            if (PF_OPT_LEVEL >= 3) begin
                                pf_mshr_valid <= 1'b1;
                                pf_mshr_addr <= req_line_addr_comb;
                                pf_mshr_external <= req_pf_external;
                                pf_mshr_confidence <= req_pf_confidence;
                                pf_mshr_stream_id <= req_pf_stream_id;
                                pf_mshr_stream_generation <=
                                    req_pf_stream_generation;
                                pf_waiter_valid <= 1'b0;
                                pf_waiter_same_line <= 1'b0;
                                pf_response_pending <= mem_rsp_valid;
                                if (mem_rsp_valid) begin
                                    fill_line <= mem_rsp_rdata;
                                    stat_pf_returned <=
                                        stat_pf_returned + 1'b1;
                                end
                                state <= ST_IDLE;
                            end else begin
                                state <= ST_MEM_READ_WAIT;
                            end
                        end else begin
                            demand_read_timing <= 1'b1;
                            demand_read_cycles <= 8'd1;
                            state <= ST_MEM_READ_WAIT;
                        end
                    end
                end

                ST_MEM_READ_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (req_is_prefetch) begin
                            stat_pf_returned <= stat_pf_returned + 1'b1;
                        end
                        if (req_is_prefetch &&
                            (!cfg_prefetch_enable || ENABLE_PREFETCH == 0)) begin
                            // A runtime disable never forces a stale response
                            // into L1.  The transient response is discarded.
                            stat_pf_discarded <= stat_pf_discarded + 1'b1;
                            state <= ST_IDLE;
                        end else if (!req_is_prefetch && req_write) begin
                            fill_line <= merge_store_data(
                                mem_rsp_rdata, req_addr, req_wdata, req_size
                            );
                            response_data <= line_load_data(
                                merge_store_data(mem_rsp_rdata, req_addr,
                                                 req_wdata, req_size),
                                req_addr, req_size, req_unsigned
                            );
                            state <= ST_INSTALL;
                        end else begin
                            fill_line <= mem_rsp_rdata;
                            response_data <= line_load_data(
                                mem_rsp_rdata, req_addr, req_size, req_unsigned
                            );
                            state <= ST_INSTALL;
                        end
                    end
                end

                ST_INSTALL: begin
                    valid_bits[selected_way][req_set_comb] <= 1'b1;
                    dirty_bits[selected_way][req_set_comb] <=
                        (!req_is_prefetch && req_write);
                    prefetched_bits[selected_way][req_set_comb] <= req_is_prefetch;
                    prefetched_stream_id[selected_way][req_set_comb] <=
                        req_pf_stream_id;
                    prefetched_stream_generation[selected_way][req_set_comb] <=
                        req_pf_stream_generation;

                    if (eviction_deferred && evicted_valid) begin
                        if (evicted_prefetched) begin
                            // Clean unused speculative data is dead on
                            // replacement and bypasses the victim cache.
                            stat_prefetch_useless <=
                                stat_prefetch_useless + 1'b1;
                            stat_pf_unused_evicted <=
                                stat_pf_unused_evicted + 1'b1;
                            stat_pf_vc_bypass <= stat_pf_vc_bypass + 1'b1;
                            event_prefetch_useless <= 1'b1;
                            stream_unused_feedback <= 1'b1;
                            stream_unused_id <= evicted_stream_id;
                            stream_unused_generation <=
                                evicted_stream_generation;
                        end else begin
                            // This path is reachable only for confidence-3
                            // prefetches admitted with an invalid VC entry.
                            if (req_is_prefetch) begin
                                stat_prefetch_pollution <=
                                    stat_prefetch_pollution + 1'b1;
                                event_prefetch_pollution <= 1'b1;
                            end
                            vc_valid[selected_vc] <= 1'b1;
                            vc_dirty[selected_vc] <= evicted_dirty;
                            vc_prefetched[selected_vc] <= 1'b0;
                            vc_stream_id[selected_vc] <= '0;
                            vc_stream_generation[selected_vc] <= '0;
                            vc_addr[selected_vc] <= evicted_addr;
                            vc_data[selected_vc] <= evicted_data;
                        end
                    end

                    if (req_is_prefetch) begin
                        if (quota_drop_pf) begin
                            valid_bits[quota_drop_way][req_set_comb] <= 1'b0;
                            dirty_bits[quota_drop_way][req_set_comb] <= 1'b0;
                            prefetched_bits[quota_drop_way][req_set_comb] <=
                                1'b0;
                            prefetched_stream_id[quota_drop_way][req_set_comb]
                                <= '0;
                            prefetched_stream_generation[quota_drop_way][
                                req_set_comb] <= '0;
                            stat_prefetch_useless <=
                                stat_prefetch_useless + 1'b1;
                            stat_pf_unused_evicted <=
                                stat_pf_unused_evicted + 1'b1;
                            stat_pf_vc_bypass <= stat_pf_vc_bypass + 1'b1;
                            event_prefetch_useless <= 1'b1;
                            stream_unused_feedback <= 1'b1;
                            stream_unused_id <= prefetched_stream_id[
                                quota_drop_way][req_set_comb];
                            stream_unused_generation <=
                                prefetched_stream_generation[
                                    quota_drop_way][req_set_comb];
                        end
                        quota_drop_pf <= 1'b0;
                        // Cold insertion: the speculative way is selected as
                        // the next replacement victim until demand promotes it.
                        replacement_way[req_set_comb] <= selected_way;
                        stat_prefetch_fills <= stat_prefetch_fills + 1'b1;
                        stat_pf_installed <= stat_pf_installed + 1'b1;
                        event_prefetch_fill <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        replacement_way[req_set_comb] <=
                            (selected_way + 1'b1) % NUM_WAYS;
                        state <= ST_RESP;
                    end
                end

                ST_PF_WAIT: begin
                    if (pf_response_pending) begin
                        if (pf_waiter_same_line) begin
                            // The combinational SRAM controls launch the
                            // response-time target-set lookup in this cycle.
                            state <= ST_PF_REVALIDATE;
                        end else begin
                            // A different lower miss owns the critical path.
                            // The completed speculative response is discarded
                            // before replaying that demand lookup.
                            stat_pf_discarded <= stat_pf_discarded + 1'b1;
                            pf_mshr_valid <= 1'b0;
                            pf_response_pending <= 1'b0;
                            pf_waiter_valid <= 1'b0;
                            pf_waiter_same_line <= 1'b0;
                            state <= ST_LOOKUP;
                        end
                    end
                end

                ST_PF_REVALIDATE: begin
                    // This lookup is evaluated once on the clock edge after
                    // the synchronous tag read.  Keeping the scan out of a
                    // self-sensitive combinational process also avoids an
                    // Icarus delta-cycle loop on unpacked arrays.
                    pf_resp_l1_hit_comb = 1'b0;
                    pf_resp_hit_way_comb = 0;
                    pf_resp_invalid_way_comb = -1;
                    pf_resp_unused_way_comb = -1;
                    for (pf_seq_i = 0; pf_seq_i < NUM_WAYS;
                         pf_seq_i = pf_seq_i + 1) begin
                        if (valid_bits[pf_seq_i][pf_resp_set_comb] &&
                            tag_q[pf_seq_i] == pf_resp_tag_comb) begin
                            pf_resp_l1_hit_comb = 1'b1;
                            pf_resp_hit_way_comb = pf_seq_i;
                        end
                        if (!valid_bits[pf_seq_i][pf_resp_set_comb] &&
                            pf_resp_invalid_way_comb == -1)
                            pf_resp_invalid_way_comb = pf_seq_i;
                        if (valid_bits[pf_seq_i][pf_resp_set_comb] &&
                            prefetched_bits[pf_seq_i][pf_resp_set_comb] &&
                            pf_resp_unused_way_comb == -1)
                            pf_resp_unused_way_comb = pf_seq_i;
                    end
                    pf_resp_victim_hit_valid_comb = 1'b0;
                    pf_resp_victim_hit_comb = 0;
                    pf_resp_invalid_vc_comb = -1;
                    for (pf_seq_i = 0; pf_seq_i < VICTIM_ENTRIES;
                         pf_seq_i = pf_seq_i + 1) begin
                        if (vc_valid[pf_seq_i] &&
                            vc_addr[pf_seq_i] == pf_mshr_addr) begin
                            pf_resp_victim_hit_valid_comb = 1'b1;
                            pf_resp_victim_hit_comb = pf_seq_i;
                        end
                        if (!vc_valid[pf_seq_i] &&
                            pf_resp_invalid_vc_comb == -1)
                            pf_resp_invalid_vc_comb = pf_seq_i;
                    end
                    pf_resp_safe_comb = 1'b0;
                    pf_resp_selected_way_comb =
                        replacement_way[pf_resp_set_comb];
                    pf_resp_evict_demand_comb = 1'b0;
                    if (pf_resp_invalid_way_comb >= 0) begin
                        pf_resp_safe_comb = 1'b1;
                        pf_resp_selected_way_comb =
                            pf_resp_invalid_way_comb[WAY_BITS-1:0];
                    end else if (pf_resp_unused_way_comb >= 0) begin
                        pf_resp_safe_comb = 1'b1;
                        pf_resp_selected_way_comb =
                            pf_resp_unused_way_comb[WAY_BITS-1:0];
                    end else if (pf_mshr_confidence == 2'b11 &&
                                 !dirty_bits[
                                     replacement_way[pf_resp_set_comb]][
                                         pf_resp_set_comb] &&
                                 pf_resp_invalid_vc_comb >= 0) begin
                        pf_resp_safe_comb = 1'b1;
                        pf_resp_selected_way_comb =
                            replacement_way[pf_resp_set_comb];
                        pf_resp_evict_demand_comb = 1'b1;
                    end

                    if (pf_waiter_valid && pf_waiter_same_line) begin
                        quota_drop_pf <= 1'b0;
                        // A merged demand makes this a mandatory demand fill,
                        // so normal replacement/writeback semantics apply.
                        if (pf_resp_l1_hit_comb) begin
                            selected_way <=
                                pf_resp_hit_way_comb[WAY_BITS-1:0];
                            evicted_valid <= 1'b0;
                            evicted_dirty <= 1'b0;
                            evicted_prefetched <= 1'b0;
                            evicted_stream_id <= '0;
                            evicted_stream_generation <= '0;
                            eviction_deferred <= 1'b0;
                            state <= ST_PF_INSTALL;
                        end else begin
                            if (pf_resp_invalid_way_comb >= 0)
                                selected_way <=
                                    pf_resp_invalid_way_comb[WAY_BITS-1:0];
                            else
                                selected_way <=
                                    replacement_way[pf_resp_set_comb];

                            evicted_valid <=
                                (pf_resp_invalid_way_comb < 0);
                            eviction_deferred <=
                                (pf_resp_invalid_way_comb < 0);
                            if (pf_resp_invalid_way_comb >= 0) begin
                                evicted_dirty <= 1'b0;
                                evicted_prefetched <= 1'b0;
                                evicted_stream_id <= '0;
                                evicted_stream_generation <= '0;
                                evicted_addr <= '0;
                                evicted_data <= '0;
                                state <= ST_PF_INSTALL;
                            end else begin
                                evicted_dirty <= dirty_bits[
                                    replacement_way[pf_resp_set_comb]][
                                        pf_resp_set_comb];
                                evicted_prefetched <= prefetched_bits[
                                    replacement_way[pf_resp_set_comb]][
                                        pf_resp_set_comb];
                                evicted_stream_id <= prefetched_stream_id[
                                    replacement_way[pf_resp_set_comb]][
                                        pf_resp_set_comb];
                                evicted_stream_generation <=
                                    prefetched_stream_generation[
                                        replacement_way[pf_resp_set_comb]][
                                            pf_resp_set_comb];
                                evicted_addr <= compose_line_address(
                                    tag_q[replacement_way[pf_resp_set_comb]],
                                    pf_resp_set_comb);
                                evicted_data <= data_q[
                                    replacement_way[pf_resp_set_comb]];
                                selected_vc <= vc_rr;
                                if (prefetched_bits[
                                        replacement_way[pf_resp_set_comb]][
                                            pf_resp_set_comb]) begin
                                    state <= ST_PF_INSTALL;
                                end else if (vc_valid[vc_rr] &&
                                             vc_dirty[vc_rr]) begin
                                    wb_addr <= vc_addr[vc_rr];
                                    wb_data <= vc_data[vc_rr];
                                    state <= ST_PF_MERGE_WB;
                                end else begin
                                    state <= ST_PF_MERGE_VC;
                                end
                            end
                        end

                        if (req_write) begin
                            fill_line <= merge_store_data(
                                fill_line, req_addr, req_wdata, req_size);
                            response_data <= line_load_data(
                                merge_store_data(fill_line, req_addr,
                                                 req_wdata, req_size),
                                req_addr, req_size, req_unsigned);
                        end else begin
                            response_data <= line_load_data(
                                fill_line, req_addr, req_size, req_unsigned);
                        end
                    end else if (!cfg_prefetch_enable ||
                                 ENABLE_PREFETCH == 0 ||
                                 pf_resp_l1_hit_comb ||
                                 pf_resp_victim_hit_valid_comb ||
                                 !pf_resp_safe_comb) begin
                        // Re-check all admission conditions after the refill;
                        // intervening demand hits/VC swaps may have changed
                        // replacement state or residency.
                        stat_pf_discarded <= stat_pf_discarded + 1'b1;
                        if (!pf_resp_l1_hit_comb &&
                            !pf_resp_victim_hit_valid_comb &&
                            cfg_prefetch_enable && ENABLE_PREFETCH != 0)
                            stat_pf_suppressed_unsafe <=
                                stat_pf_suppressed_unsafe + 1'b1;
                        pf_mshr_valid <= 1'b0;
                        pf_response_pending <= 1'b0;
                        pf_waiter_valid <= 1'b0;
                        state <= ST_IDLE;
                    end else begin
                        quota_drop_pf <=
                            (pf_resp_invalid_way_comb >= 0 &&
                             pf_resp_unused_way_comb >= 0);
                        if (pf_resp_unused_way_comb >= 0)
                            quota_drop_way <=
                                pf_resp_unused_way_comb[WAY_BITS-1:0];
                        selected_way <= pf_resp_selected_way_comb;
                        evicted_valid <= valid_bits[
                            pf_resp_selected_way_comb][pf_resp_set_comb];
                        eviction_deferred <= valid_bits[
                            pf_resp_selected_way_comb][pf_resp_set_comb];
                        evicted_dirty <= dirty_bits[
                            pf_resp_selected_way_comb][pf_resp_set_comb];
                        evicted_prefetched <= prefetched_bits[
                            pf_resp_selected_way_comb][pf_resp_set_comb];
                        evicted_stream_id <= prefetched_stream_id[
                            pf_resp_selected_way_comb][pf_resp_set_comb];
                        evicted_stream_generation <=
                            prefetched_stream_generation[
                                pf_resp_selected_way_comb][pf_resp_set_comb];
                        evicted_addr <= compose_line_address(
                            tag_q[pf_resp_selected_way_comb], pf_resp_set_comb);
                        evicted_data <= data_q[pf_resp_selected_way_comb];
                        if (pf_resp_evict_demand_comb) begin
                            selected_vc <=
                                pf_resp_invalid_vc_comb[VC_BITS-1:0];
                        end
                        state <= ST_PF_INSTALL;
                    end
                end

                ST_PF_MERGE_WB: begin
                    if (mem_req_ready) begin
                        stat_writebacks <= stat_writebacks + 1'b1;
                        event_writeback <= 1'b1;
                        state <= ST_PF_MERGE_VC;
                    end
                end

                ST_PF_MERGE_VC: begin
                    if (vc_valid[selected_vc] &&
                        vc_prefetched[selected_vc]) begin
                        stat_prefetch_useless <=
                            stat_prefetch_useless + 1'b1;
                        event_prefetch_useless <= 1'b1;
                    end
                    vc_valid[selected_vc] <= evicted_valid;
                    vc_dirty[selected_vc] <= evicted_dirty;
                    vc_prefetched[selected_vc] <= evicted_prefetched;
                    vc_stream_id[selected_vc] <= evicted_stream_id;
                    vc_stream_generation[selected_vc] <=
                        evicted_stream_generation;
                    vc_addr[selected_vc] <= evicted_addr;
                    vc_data[selected_vc] <= evicted_data;
                    // Complete the move atomically in metadata.  The captured
                    // evicted data no longer needs the source way, and leaving
                    // that way valid until ST_PF_INSTALL would create a
                    // one-cycle duplicate in L1 and VC.
                    valid_bits[selected_way][pf_resp_set_comb] <= 1'b0;
                    dirty_bits[selected_way][pf_resp_set_comb] <= 1'b0;
                    prefetched_bits[selected_way][pf_resp_set_comb] <= 1'b0;
                    prefetched_stream_id[selected_way][pf_resp_set_comb] <= '0;
                    prefetched_stream_generation[selected_way][
                        pf_resp_set_comb] <= '0;
                    if (vc_rr == VICTIM_ENTRIES-1)
                        vc_rr <= '0;
                    else
                        vc_rr <= vc_rr + 1'b1;
                    eviction_deferred <= 1'b0;
                    state <= ST_PF_INSTALL;
                end

                ST_PF_INSTALL: begin
                    valid_bits[selected_way][pf_resp_set_comb] <= 1'b1;
                    dirty_bits[selected_way][pf_resp_set_comb] <=
                        pf_waiter_valid && req_write;
                    prefetched_bits[selected_way][pf_resp_set_comb] <=
                        !pf_waiter_valid;
                    prefetched_stream_id[selected_way][pf_resp_set_comb] <=
                        pf_waiter_valid ? '0 : pf_mshr_stream_id;
                    prefetched_stream_generation[selected_way][
                        pf_resp_set_comb] <= pf_waiter_valid ? '0 :
                        pf_mshr_stream_generation;

                    if (eviction_deferred && evicted_valid) begin
                        if (evicted_prefetched) begin
                            stat_prefetch_useless <=
                                stat_prefetch_useless + 1'b1;
                            stat_pf_unused_evicted <=
                                stat_pf_unused_evicted + 1'b1;
                            stat_pf_vc_bypass <= stat_pf_vc_bypass + 1'b1;
                            event_prefetch_useless <= 1'b1;
                            stream_unused_feedback <= 1'b1;
                            stream_unused_id <= evicted_stream_id;
                            stream_unused_generation <=
                                evicted_stream_generation;
                        end else begin
                            if (!pf_waiter_valid) begin
                                stat_prefetch_pollution <=
                                    stat_prefetch_pollution + 1'b1;
                                event_prefetch_pollution <= 1'b1;
                            end
                            vc_valid[selected_vc] <= 1'b1;
                            vc_dirty[selected_vc] <= evicted_dirty;
                            vc_prefetched[selected_vc] <= 1'b0;
                            vc_stream_id[selected_vc] <= '0;
                            vc_stream_generation[selected_vc] <= '0;
                            vc_addr[selected_vc] <= evicted_addr;
                            vc_data[selected_vc] <= evicted_data;
                        end
                    end

                    if (quota_drop_pf) begin
                        valid_bits[quota_drop_way][pf_resp_set_comb] <= 1'b0;
                        dirty_bits[quota_drop_way][pf_resp_set_comb] <= 1'b0;
                        prefetched_bits[quota_drop_way][pf_resp_set_comb] <=
                            1'b0;
                        prefetched_stream_id[quota_drop_way][pf_resp_set_comb]
                            <= '0;
                        prefetched_stream_generation[quota_drop_way][
                            pf_resp_set_comb] <= '0;
                        stat_prefetch_useless <=
                            stat_prefetch_useless + 1'b1;
                        stat_pf_unused_evicted <=
                            stat_pf_unused_evicted + 1'b1;
                        stat_pf_vc_bypass <= stat_pf_vc_bypass + 1'b1;
                        event_prefetch_useless <= 1'b1;
                        stream_unused_feedback <= 1'b1;
                        stream_unused_id <= prefetched_stream_id[
                            quota_drop_way][pf_resp_set_comb];
                        stream_unused_generation <=
                            prefetched_stream_generation[
                                quota_drop_way][pf_resp_set_comb];
                    end
                    quota_drop_pf <= 1'b0;

                    pf_mshr_valid <= 1'b0;
                    pf_response_pending <= 1'b0;
                    pf_waiter_same_line <= 1'b0;
                    if (pf_waiter_valid) begin
                        replacement_way[pf_resp_set_comb] <=
                            (selected_way + 1'b1) % NUM_WAYS;
                        stat_pf_merged <= stat_pf_merged + 1'b1;
                        late_merge_credit <=
                            (miss_penalty_ewma > pf_wait_cycles) ?
                            (miss_penalty_ewma - pf_wait_cycles) : 8'd1;
                        pf_late_merge_event <= 1'b1;
                        pf_waiter_valid <= 1'b0;
                        state <= ST_RESP;
                    end else begin
                        replacement_way[pf_resp_set_comb] <= selected_way;
                        stat_prefetch_fills <= stat_prefetch_fills + 1'b1;
                        stat_pf_installed <= stat_pf_installed + 1'b1;
                        event_prefetch_fill <= 1'b1;
                        state <= ST_IDLE;
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
            if (state == ST_WB_REQ && req_is_prefetch)
                $fatal(1, "A prefetch must never trigger a writeback");
            if (stat_pf_caused_writebacks != 0)
                $fatal(1, "Prefetch-caused writeback counter must remain zero");
            if (stat_pf_returned > stat_pf_issued ||
                stat_pf_installed + stat_pf_merged + stat_pf_discarded >
                    stat_pf_returned)
                $fatal(1, "Prefetch lifecycle counters are not conserved");
            if (PF_OPT_LEVEL >= 3 && pf_response_pending && !pf_mshr_valid)
                $fatal(1, "PF response exists without an MSHR owner");
            if (PF_OPT_LEVEL >= 3 && pf_waiter_valid && !pf_mshr_valid)
                $fatal(1, "Demand waiter exists without an MSHR owner");
            if (PF_OPT_LEVEL >= 3 && pf_mshr_valid && mem_req_valid &&
                !mem_req_write)
                $fatal(1, "Second lower read issued while PF MSHR is live");
            for (assert_i = 0; assert_i < NUM_SETS;
                 assert_i = assert_i + 1) begin
                assert_j = 0;
                for (assert_way = 0; assert_way < NUM_WAYS;
                     assert_way = assert_way + 1) begin
                    if (prefetched_bits[assert_way][assert_i]) begin
                        if (!valid_bits[assert_way][assert_i] ||
                            dirty_bits[assert_way][assert_i])
                            $fatal(1, "Prefetched line must be valid and clean");
                        assert_j = assert_j + 1;
                    end
                end
                if (assert_j > 1)
                    $fatal(1, "More than one unused prefetch in an L1 set");
                for (assert_way = 0; assert_way < NUM_WAYS;
                     assert_way = assert_way + 1) begin
                    for (assert_j = assert_way + 1;
                         assert_j < NUM_WAYS;
                         assert_j = assert_j + 1) begin
                        if (valid_bits[assert_way][assert_i] &&
                            valid_bits[assert_j][assert_i] &&
                            tag_mirror[assert_way][assert_i] ==
                                tag_mirror[assert_j][assert_i])
                            $fatal(1, "Duplicate line in L1 ways");
                    end
                    for (assert_j = 0; assert_j < VICTIM_ENTRIES;
                         assert_j = assert_j + 1) begin
                        if (valid_bits[assert_way][assert_i] &&
                            vc_valid[assert_j] &&
                            compose_line_address(
                                tag_mirror[assert_way][assert_i], assert_i) ==
                                vc_addr[assert_j])
                            $fatal(1,
                                   "Duplicate line in L1 and victim cache state=%0d waiter=%0d same=%0d set=%0d way=%0d vc=%0d addr=%h",
                                   state, pf_waiter_valid,
                                   pf_waiter_same_line, assert_i, assert_way,
                                   assert_j,
                                   vc_addr[assert_j]);
                    end
                    if (PF_OPT_LEVEL >= 3 && pf_mshr_valid &&
                        valid_bits[assert_way][assert_i] &&
                        compose_line_address(
                            tag_mirror[assert_way][assert_i], assert_i) ==
                            pf_mshr_addr)
                        $fatal(1, "PF MSHR line already exists in L1");
                end
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
                if (PF_OPT_LEVEL >= 3 && pf_mshr_valid &&
                    vc_valid[assert_i] && vc_addr[assert_i] == pf_mshr_addr)
                    $fatal(1, "PF MSHR line already exists in victim cache");
            end
        end
    end
`endif
endmodule
