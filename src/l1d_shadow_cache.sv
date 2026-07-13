`timescale 1ns/1ps

// Demand-only counterfactual cache.  Tags, dirty bits and replacement state are
// modelled; no cache-line data is stored and this module is never on the CPU
// response path.
module l1d_shadow_cache #(
    parameter integer ADDR_WIDTH     = 64,
    parameter integer LINE_BYTES     = 16,
    parameter integer NUM_SETS       = 8,
    parameter integer NUM_WAYS       = 2,
    parameter integer VICTIM_ENTRIES = 4
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    access_valid,
    input  logic [ADDR_WIDTH-1:0]   access_line_addr,
    input  logic                    access_write,
    input  logic [1:0]              actual_level,
    output logic                    event_true_help,
    output logic                    event_true_pollution,
    output logic                    event_shadow_l1,
    output logic                    event_shadow_victim,
    output logic                    event_shadow_lower
);
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);
    localparam integer SET_BITS = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1;
    localparam integer WAY_BITS = (NUM_WAYS > 1) ? $clog2(NUM_WAYS) : 1;
    localparam integer VC_BITS = (VICTIM_ENTRIES > 1) ?
                                 $clog2(VICTIM_ENTRIES) : 1;
    localparam logic [1:0] LEVEL_L1 = 2'd0;
    localparam logic [1:0] LEVEL_VC = 2'd1;
    localparam logic [1:0] LEVEL_LOWER = 2'd2;

    logic l1_valid [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic l1_dirty [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [ADDR_WIDTH-1:0] l1_addr [0:NUM_WAYS-1][0:NUM_SETS-1];
    logic [WAY_BITS-1:0] l1_replacement [0:NUM_SETS-1];
    logic vc_valid [0:VICTIM_ENTRIES-1];
    logic vc_dirty [0:VICTIM_ENTRIES-1];
    logic [ADDR_WIDTH-1:0] vc_addr [0:VICTIM_ENTRIES-1];
    logic [VC_BITS-1:0] vc_rr;

    integer i;
    integer j;
    integer hit_way;
    integer invalid_way;
    integer vc_hit;
    integer selected_way_i;
    integer selected_vc_i;
    integer assert_set;
    integer assert_way;
    integer assert_other;
    integer assert_vc;
    logic [SET_BITS-1:0] set_index;
    logic [1:0] shadow_level;
    logic evicted_valid;
    logic evicted_dirty;
    logic [ADDR_WIDTH-1:0] evicted_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_true_help <= 1'b0;
            event_true_pollution <= 1'b0;
            event_shadow_l1 <= 1'b0;
            event_shadow_victim <= 1'b0;
            event_shadow_lower <= 1'b0;
            vc_rr <= '0;
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                l1_replacement[i] <= '0;
                for (j = 0; j < NUM_WAYS; j = j + 1) begin
                    l1_valid[j][i] <= 1'b0;
                    l1_dirty[j][i] <= 1'b0;
                    l1_addr[j][i] <= '0;
                end
            end
            for (i = 0; i < VICTIM_ENTRIES; i = i + 1) begin
                vc_valid[i] <= 1'b0;
                vc_dirty[i] <= 1'b0;
                vc_addr[i] <= '0;
            end
        end else begin
            event_true_help <= 1'b0;
            event_true_pollution <= 1'b0;
            event_shadow_l1 <= 1'b0;
            event_shadow_victim <= 1'b0;
            event_shadow_lower <= 1'b0;

            if (access_valid) begin
                set_index = access_line_addr[OFFSET_BITS + SET_BITS-1:OFFSET_BITS];
                hit_way = -1;
                invalid_way = -1;
                vc_hit = -1;
                for (i = 0; i < NUM_WAYS; i = i + 1) begin
                    if (l1_valid[i][set_index] &&
                        l1_addr[i][set_index] == access_line_addr)
                        hit_way = i;
                    if (!l1_valid[i][set_index] && invalid_way == -1)
                        invalid_way = i;
                end
                for (i = 0; i < VICTIM_ENTRIES; i = i + 1) begin
                    if (vc_valid[i] && vc_addr[i] == access_line_addr)
                        vc_hit = i;
                end

                if (hit_way >= 0)
                    shadow_level = LEVEL_L1;
                else if (vc_hit >= 0)
                    shadow_level = LEVEL_VC;
                else
                    shadow_level = LEVEL_LOWER;

                event_shadow_l1 <= (shadow_level == LEVEL_L1);
                event_shadow_victim <= (shadow_level == LEVEL_VC);
                event_shadow_lower <= (shadow_level == LEVEL_LOWER);
                if (actual_level != LEVEL_LOWER &&
                    shadow_level == LEVEL_LOWER)
                    event_true_help <= 1'b1;
                if (actual_level == LEVEL_LOWER &&
                    shadow_level != LEVEL_LOWER)
                    event_true_pollution <= 1'b1;

                if (hit_way >= 0) begin
                    if (access_write)
                        l1_dirty[hit_way][set_index] <= 1'b1;
                    l1_replacement[set_index] <=
                        (hit_way + 1) % NUM_WAYS;
                end else begin
                    if (invalid_way >= 0)
                        selected_way_i = invalid_way;
                    else
                        selected_way_i = l1_replacement[set_index];

                    evicted_valid = l1_valid[selected_way_i][set_index];
                    evicted_dirty = l1_dirty[selected_way_i][set_index];
                    evicted_addr = l1_addr[selected_way_i][set_index];

                    if (vc_hit >= 0) begin
                        l1_valid[selected_way_i][set_index] <= 1'b1;
                        l1_dirty[selected_way_i][set_index] <=
                            access_write ? 1'b1 : vc_dirty[vc_hit];
                        l1_addr[selected_way_i][set_index] <= access_line_addr;
                        if (evicted_valid) begin
                            vc_valid[vc_hit] <= 1'b1;
                            vc_dirty[vc_hit] <= evicted_dirty;
                            vc_addr[vc_hit] <= evicted_addr;
                        end else begin
                            vc_valid[vc_hit] <= 1'b0;
                            vc_dirty[vc_hit] <= 1'b0;
                            vc_addr[vc_hit] <= '0;
                        end
                    end else begin
                        if (evicted_valid) begin
                            // Mirror the optimized demand-only datapath: a
                            // lower fill inserts into the current RR victim
                            // slot.  Do not search for a different invalid
                            // slot, because VC swaps can leave holes away from
                            // vc_rr and that would diverge counterfactual state.
                            selected_vc_i = vc_rr;
                            vc_valid[selected_vc_i] <= 1'b1;
                            vc_dirty[selected_vc_i] <= evicted_dirty;
                            vc_addr[selected_vc_i] <= evicted_addr;
                            if (vc_rr == VICTIM_ENTRIES-1)
                                vc_rr <= '0;
                            else
                                vc_rr <= vc_rr + 1'b1;
                        end
                        l1_valid[selected_way_i][set_index] <= 1'b1;
                        l1_dirty[selected_way_i][set_index] <= access_write;
                        l1_addr[selected_way_i][set_index] <= access_line_addr;
                    end
                    l1_replacement[set_index] <=
                        (selected_way_i + 1) % NUM_WAYS;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Shadow state is a counterfactual cache, but it must obey the same
    // one-copy invariant internally as the demand-only real cache.
    always @(posedge clk) begin
        if (rst_n) begin
            for (assert_set = 0; assert_set < NUM_SETS;
                 assert_set = assert_set + 1) begin
                for (assert_way = 0; assert_way < NUM_WAYS;
                     assert_way = assert_way + 1) begin
                    for (assert_other = assert_way + 1;
                         assert_other < NUM_WAYS;
                         assert_other = assert_other + 1) begin
                        if (l1_valid[assert_way][assert_set] &&
                            l1_valid[assert_other][assert_set] &&
                            l1_addr[assert_way][assert_set] ==
                                l1_addr[assert_other][assert_set])
                            $fatal(1, "Duplicate line in shadow L1 ways");
                    end
                    for (assert_vc = 0; assert_vc < VICTIM_ENTRIES;
                         assert_vc = assert_vc + 1) begin
                        if (l1_valid[assert_way][assert_set] &&
                            vc_valid[assert_vc] &&
                            l1_addr[assert_way][assert_set] ==
                                vc_addr[assert_vc])
                            $fatal(1,
                                   "Duplicate line in shadow L1 and victim cache");
                    end
                end
            end
            for (assert_vc = 0; assert_vc < VICTIM_ENTRIES;
                 assert_vc = assert_vc + 1) begin
                for (assert_other = assert_vc + 1;
                     assert_other < VICTIM_ENTRIES;
                     assert_other = assert_other + 1) begin
                    if (vc_valid[assert_vc] && vc_valid[assert_other] &&
                        vc_addr[assert_vc] == vc_addr[assert_other])
                        $fatal(1, "Duplicate line in shadow victim cache");
                end
            end
        end
    end
`endif
endmodule
