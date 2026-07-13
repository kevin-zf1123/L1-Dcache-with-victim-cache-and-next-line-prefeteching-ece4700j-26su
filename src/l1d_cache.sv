`timescale 1ns/1ps

// Elaboration-time policy selector.  Policy 0 preserves the original blocking
// next-line cache exactly; policy 1 selects the direct-to-L1 optimized cache.
module l1d_cache #(
    parameter integer ADDR_WIDTH       = 64,
    parameter integer DATA_WIDTH       = 64,
    parameter integer LINE_BYTES       = 16,
    parameter integer NUM_SETS         = 8,
    parameter integer NUM_WAYS         = 2,
    parameter integer VICTIM_ENTRIES   = 4,
    parameter integer ENABLE_PREFETCH  = 1,
    parameter integer PREFETCH_POLICY  = 1,
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
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = $clog2(NUM_SETS);
    localparam integer TAG_BITS = ADDR_WIDTH - OFFSET_BITS - SET_BITS;

`ifndef SYNTHESIS
    // Stable simulation-only white-box aliases used by both verification
    // environments.  Keep these names at wrapper scope so policy selection
    // does not leak into TBs or create synthesis-time cross-module reads.
    wire valid_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    wire prefetched_bits [0:NUM_WAYS-1][0:NUM_SETS-1];
    wire vc_valid [0:VICTIM_ENTRIES-1];
    wire vc_prefetched [0:VICTIM_ENTRIES-1];
    wire [ADDR_WIDTH-1:0] vc_addr [0:VICTIM_ENTRIES-1];
    wire [ADDR_WIDTH-1:0] req_line_addr_comb;
    wire next_line_candidate_valid;
    wire next_line_candidate_ready;
    wire [ADDR_WIDTH-1:0] next_line_candidate_addr;
    wire [1:0] next_line_candidate_confidence;
    wire [TAG_BITS-1:0] debug_tag [0:NUM_WAYS-1][0:NUM_SETS-1];
`endif

    generate
        if (PREFETCH_POLICY == 0) begin : gen_legacy
            l1d_cache_legacy #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .LINE_BYTES(LINE_BYTES),
                .NUM_SETS(NUM_SETS),
                .NUM_WAYS(NUM_WAYS),
                .VICTIM_ENTRIES(VICTIM_ENTRIES),
                .ENABLE_PREFETCH(ENABLE_PREFETCH)
            ) u_cache (
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
                .debug_req_is_prefetch(debug_req_is_prefetch)
            );

            assign stat_pf_candidates = 32'b0;
            assign stat_pf_admitted = 32'b0;
            assign stat_pf_issued = 32'b0;
            assign stat_pf_returned = 32'b0;
            assign stat_pf_installed = 32'b0;
            assign stat_pf_merged = 32'b0;
            assign stat_pf_discarded = 32'b0;
            assign stat_pf_cancelled = 32'b0;
            assign stat_pf_unused_evicted = 32'b0;
            assign stat_pf_vc_bypass = 32'b0;
            assign stat_pf_caused_writebacks = 32'b0;
            assign stat_pf_demand_block_cycles = 32'b0;
            assign stat_pf_true_help = 32'b0;
            assign stat_pf_true_pollution = 32'b0;
            assign stat_pf_suppressed_quota = 32'b0;
            assign stat_pf_suppressed_unsafe = 32'b0;
            assign stat_pf_same_line_coalesced = 32'b0;
            assign debug_pf_controller_state = 2'b00;
            assign debug_pf_mshr_valid = 1'b0;
            assign debug_pf_mshr_addr = {ADDR_WIDTH{1'b0}};
            assign debug_pf_mshr_confidence = 2'b00;

`ifndef SYNTHESIS
            assign req_line_addr_comb = u_cache.req_line_addr_comb;
            assign next_line_candidate_valid =
                u_cache.next_line_candidate_valid;
            assign next_line_candidate_ready =
                u_cache.next_line_candidate_ready;
            assign next_line_candidate_addr =
                u_cache.next_line_candidate_addr;
            assign next_line_candidate_confidence = 2'b11;

            genvar legacy_way;
            genvar legacy_set;
            for (legacy_way = 0; legacy_way < NUM_WAYS;
                 legacy_way = legacy_way + 1) begin : gen_debug_way
                for (legacy_set = 0; legacy_set < NUM_SETS;
                     legacy_set = legacy_set + 1) begin : gen_debug_set
                    assign valid_bits[legacy_way][legacy_set] =
                        u_cache.valid_bits[legacy_way][legacy_set];
                    assign prefetched_bits[legacy_way][legacy_set] =
                        u_cache.prefetched_bits[legacy_way][legacy_set];
                    assign debug_tag[legacy_way][legacy_set] =
                        u_cache.gen_arrays[legacy_way].tag_array.mem[legacy_set];
                end
            end

            genvar legacy_vc;
            for (legacy_vc = 0; legacy_vc < VICTIM_ENTRIES;
                 legacy_vc = legacy_vc + 1) begin : gen_debug_vc
                assign vc_valid[legacy_vc] = u_cache.vc_valid[legacy_vc];
                assign vc_prefetched[legacy_vc] =
                    u_cache.vc_prefetched[legacy_vc];
                assign vc_addr[legacy_vc] = u_cache.vc_addr[legacy_vc];
            end
`endif
        end else begin : gen_optimized
            l1d_cache_optimized #(
                .ADDR_WIDTH(ADDR_WIDTH),
                .DATA_WIDTH(DATA_WIDTH),
                .LINE_BYTES(LINE_BYTES),
                .NUM_SETS(NUM_SETS),
                .NUM_WAYS(NUM_WAYS),
                .VICTIM_ENTRIES(VICTIM_ENTRIES),
                .ENABLE_PREFETCH(ENABLE_PREFETCH),
                .PF_OPT_LEVEL(PF_OPT_LEVEL)
            ) u_cache (
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

`ifndef SYNTHESIS
            assign req_line_addr_comb = u_cache.req_line_addr_comb;
            assign next_line_candidate_valid =
                u_cache.stream_candidate_valid;
            assign next_line_candidate_ready =
                u_cache.stream_candidate_ready;
            assign next_line_candidate_addr =
                u_cache.stream_candidate_addr;
            assign next_line_candidate_confidence =
                u_cache.stream_candidate_confidence;

            genvar optimized_way;
            genvar optimized_set;
            for (optimized_way = 0; optimized_way < NUM_WAYS;
                 optimized_way = optimized_way + 1) begin : gen_debug_way
                for (optimized_set = 0; optimized_set < NUM_SETS;
                     optimized_set = optimized_set + 1) begin : gen_debug_set
                    assign valid_bits[optimized_way][optimized_set] =
                        u_cache.valid_bits[optimized_way][optimized_set];
                    assign prefetched_bits[optimized_way][optimized_set] =
                        u_cache.prefetched_bits[optimized_way][optimized_set];
                    assign debug_tag[optimized_way][optimized_set] =
                        u_cache.gen_arrays[optimized_way].tag_array.mem[optimized_set];
                end
            end

            genvar optimized_vc;
            for (optimized_vc = 0; optimized_vc < VICTIM_ENTRIES;
                 optimized_vc = optimized_vc + 1) begin : gen_debug_vc
                assign vc_valid[optimized_vc] = u_cache.vc_valid[optimized_vc];
                assign vc_prefetched[optimized_vc] =
                    u_cache.vc_prefetched[optimized_vc];
                assign vc_addr[optimized_vc] = u_cache.vc_addr[optimized_vc];
            end
`endif
        end
    endgenerate

    initial begin
        if (PREFETCH_POLICY != 0 && PREFETCH_POLICY != 1) begin
            $error("PREFETCH_POLICY must be 0 (legacy) or 1 (optimized)");
        end
        if ((PREFETCH_POLICY == 0 &&
             (PF_OPT_LEVEL < 0 || PF_OPT_LEVEL > 3)) ||
            (PREFETCH_POLICY == 1 &&
             (PF_OPT_LEVEL < 1 || PF_OPT_LEVEL > 3))) begin
            $error("PF_OPT_LEVEL must be 0..3 for legacy or 1..3 for optimized");
        end
    end
endmodule
