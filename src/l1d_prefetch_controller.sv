`timescale 1ns/1ps

// Hysteretic OFF/PROBE/ON controller with a two-token issue bucket.  Saved and
// cost are maintained in cycle-like units; no division is used.
module l1d_prefetch_controller #(
    parameter integer ADAPTIVE       = 1,
    parameter integer EPOCH_DEMANDS  = 256,
    parameter integer OFF_DEMANDS    = 512,
    parameter integer PROBE_BUDGET   = 8,
    parameter integer PROBE_REFILL   = 16,
    parameter integer ON_REFILL      = 8
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        enable,
    input  logic        demand_access,
    input  logic        consume_token,
    input  logic        feedback_help,
    input  logic        feedback_pollution,
    input  logic        feedback_late_merge,
    input  logic        feedback_blocked_cycle,
    input  logic        feedback_pf_writeback,
    input  logic [7:0]  miss_penalty,
    input  logic [7:0]  wb_penalty,
    input  logic [7:0]  late_merge_credit,
    output logic        issue_enable,
    output logic        token_available,
    output logic [1:0]  controller_state,
    output logic [1:0]  min_confidence,
    output logic [15:0] debug_epoch_saved,
    output logic [15:0] debug_epoch_cost
);
    localparam logic [1:0] CTRL_OFF   = 2'd0;
    localparam logic [1:0] CTRL_PROBE = 2'd1;
    localparam logic [1:0] CTRL_ON    = 2'd2;

    logic [9:0] demand_count;
    logic [4:0] refill_count;
    logic [3:0] probe_issues;
    logic       probe_second_epoch;
    logic [1:0] tokens;
    logic weak_on;
    logic negative_epoch;
    logic [7:0] epoch_pf_issued;
    logic [7:0] epoch_help;
    logic [15:0] saved;
    logic [15:0] cost;
    logic [5:0] refill_period;
    logic [8:0] saved_increment;
    logic [8:0] cost_increment;
    logic [16:0] saved_effective;
    logic [16:0] cost_effective;
    logic [8:0] epoch_pf_issued_effective;
    logic [8:0] epoch_help_effective;
    logic [4:0] probe_issues_effective;
    logic [15:0] saved_accumulate_value;
    logic [15:0] cost_accumulate_value;
    logic cost_reaches_saturation;
    logic [1:0] controller_state_reg;
    logic epoch_eval_pending;
    logic epoch_decision_pending;
    logic cost_overflow_pending;
    logic [1:0] epoch_state_snapshot;
    logic epoch_probe_second_snapshot;
    logic [15:0] epoch_saved_snapshot;
    logic [15:0] epoch_cost_snapshot;
    logic [8:0] epoch_pf_issued_snapshot;
    logic [8:0] epoch_help_snapshot;
    logic [4:0] epoch_probe_issues_snapshot;
    logic epoch_profitable;
    logic epoch_probe_fail;
    logic epoch_rate_exceeded;
    logic epoch_cost_gt_saved;

    assign controller_state = controller_state_reg;
    assign issue_enable = enable && !epoch_eval_pending &&
        !epoch_decision_pending &&
        !cost_overflow_pending &&
        ((ADAPTIVE == 0) ||
         (controller_state_reg == CTRL_ON) ||
         (controller_state_reg == CTRL_PROBE &&
          probe_issues < PROBE_BUDGET));
    assign token_available = (tokens != 0);
    assign debug_epoch_saved = saved;
    assign debug_epoch_cost = cost;
    assign min_confidence = (ADAPTIVE != 0 &&
                             controller_state_reg == CTRL_ON && weak_on) ?
                            2'd2 : 2'd1;
    always_comb begin
        if (ADAPTIVE == 0)
            refill_period = ON_REFILL;
        else if (controller_state_reg == CTRL_PROBE || weak_on)
            refill_period = PROBE_REFILL;
        else
            refill_period = ON_REFILL;
        saved_increment = (feedback_help ? {1'b0, miss_penalty} : 9'd0) +
                          (feedback_late_merge ?
                           {1'b0, late_merge_credit} : 9'd0);
        cost_increment = (feedback_pollution ?
                          {1'b0, miss_penalty} : 9'd0) +
                         (feedback_pf_writeback ?
                          {1'b0, wb_penalty} : 9'd0) +
                         (feedback_blocked_cycle ? 9'd1 : 9'd0) +
                         (consume_token ? 9'd1 : 9'd0);
        saved_effective = {1'b0, saved} + saved_increment;
        cost_effective = {1'b0, cost} + cost_increment;
        epoch_pf_issued_effective = {1'b0, epoch_pf_issued} +
                                    (consume_token ? 9'd1 : 9'd0);
        epoch_help_effective = {1'b0, epoch_help} +
                               (feedback_help ? 9'd1 : 9'd0);
        probe_issues_effective = {1'b0, probe_issues} +
                                 ((consume_token &&
                                   controller_state_reg == CTRL_PROBE) ?
                                  5'd1 : 5'd0);
        saved_accumulate_value = (saved_effective >= 17'h0ffff) ?
                                 16'hffff : saved_effective[15:0];
        cost_accumulate_value = (cost_effective >= 17'h0ffff) ?
                                16'hffff : cost_effective[15:0];
        cost_reaches_saturation = (cost_increment != 0) &&
                                  (cost_effective >= 17'h0ffff);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            controller_state_reg <= (ADAPTIVE != 0) ? CTRL_PROBE : CTRL_ON;
            demand_count <= '0;
            refill_count <= '0;
            probe_issues <= '0;
            probe_second_epoch <= 1'b0;
            tokens <= 2'd1;
            weak_on <= 1'b0;
            negative_epoch <= 1'b0;
            epoch_pf_issued <= '0;
            epoch_help <= '0;
            saved <= '0;
            cost <= '0;
            epoch_eval_pending <= 1'b0;
            epoch_decision_pending <= 1'b0;
            cost_overflow_pending <= 1'b0;
            epoch_state_snapshot <= CTRL_PROBE;
            epoch_probe_second_snapshot <= 1'b0;
            epoch_saved_snapshot <= '0;
            epoch_cost_snapshot <= '0;
            epoch_pf_issued_snapshot <= '0;
            epoch_help_snapshot <= '0;
            epoch_probe_issues_snapshot <= '0;
            epoch_profitable <= 1'b0;
            epoch_probe_fail <= 1'b0;
            epoch_rate_exceeded <= 1'b0;
            epoch_cost_gt_saved <= 1'b0;
        end else if (!enable) begin
            controller_state_reg <= (ADAPTIVE != 0) ? CTRL_PROBE : CTRL_ON;
            demand_count <= '0;
            refill_count <= '0;
            probe_issues <= '0;
            probe_second_epoch <= 1'b0;
            tokens <= 2'd1;
            weak_on <= 1'b0;
            negative_epoch <= 1'b0;
            epoch_pf_issued <= '0;
            epoch_help <= '0;
            saved <= '0;
            cost <= '0;
            epoch_eval_pending <= 1'b0;
            epoch_decision_pending <= 1'b0;
            cost_overflow_pending <= 1'b0;
            epoch_state_snapshot <= CTRL_PROBE;
            epoch_probe_second_snapshot <= 1'b0;
            epoch_saved_snapshot <= '0;
            epoch_cost_snapshot <= '0;
            epoch_pf_issued_snapshot <= '0;
            epoch_help_snapshot <= '0;
            epoch_probe_issues_snapshot <= '0;
            epoch_profitable <= 1'b0;
            epoch_probe_fail <= 1'b0;
            epoch_rate_exceeded <= 1'b0;
            epoch_cost_gt_saved <= 1'b0;
        end else begin
            if (saved_increment != 0)
                saved <= saved_accumulate_value;
            if (cost_increment != 0)
                cost <= cost_accumulate_value;
            if (feedback_help)
                epoch_help <= epoch_help + 1'b1;

            if (consume_token) begin
                // A refill and consume on the same demand have zero net token
                // change.  Otherwise the issued request consumes one token.
                if (tokens != 0 &&
                    !(demand_access && refill_count == refill_period-1))
                    tokens <= tokens - 1'b1;
                epoch_pf_issued <= epoch_pf_issued + 1'b1;
                if (controller_state_reg == CTRL_PROBE)
                    probe_issues <= probe_issues + 1'b1;
            end

            if (demand_access) begin
                demand_count <= demand_count + 1'b1;
                if (refill_count == refill_period-1) begin
                    refill_count <= '0;
                    if (!consume_token && tokens != 2)
                        tokens <= tokens + 1'b1;
                end else begin
                    refill_count <= refill_count + 1'b1;
                end

                if (ADAPTIVE != 0 && controller_state_reg == CTRL_OFF) begin
                    if (demand_count == OFF_DEMANDS-1) begin
                        controller_state_reg <= CTRL_PROBE;
                        demand_count <= '0;
                        probe_issues <= '0;
                        probe_second_epoch <= 1'b0;
                        tokens <= 2'd1;
                        saved <= '0;
                        cost <= '0;
                        epoch_pf_issued <= '0;
                        epoch_help <= '0;
                    end
                end else if (demand_count == EPOCH_DEMANDS-1) begin
                    demand_count <= '0;
                    // Snapshot the completed epoch, including feedback and an
                    // issue on this boundary cycle.  Registered predicates
                    // and a following decision stage keep accumulator carry
                    // chains off the controller state and issue-enable paths.
                    epoch_eval_pending <= (ADAPTIVE != 0);
                    epoch_state_snapshot <= controller_state_reg;
                    epoch_probe_second_snapshot <= probe_second_epoch;
                    epoch_saved_snapshot <= saved_accumulate_value;
                    epoch_cost_snapshot <= cost_accumulate_value;
                    epoch_pf_issued_snapshot <= epoch_pf_issued_effective;
                    epoch_help_snapshot <= epoch_help_effective;
                    epoch_probe_issues_snapshot <= probe_issues_effective;
                    saved <= '0;
                    cost <= '0;
                    epoch_pf_issued <= '0;
                    epoch_help <= '0;
                end
            end

            // Register overflow before changing policy state so the wide
            // saturation adder does not feed the state decoder in one cycle.
            if (ADAPTIVE != 0 && controller_state_reg != CTRL_OFF &&
                cost_reaches_saturation) begin
                cost <= 16'hffff;
                cost_overflow_pending <= 1'b1;
            end

            if (cost_overflow_pending) begin
                controller_state_reg <= CTRL_OFF;
                demand_count <= '0;
                probe_issues <= '0;
                probe_second_epoch <= 1'b0;
                tokens <= '0;
                weak_on <= 1'b0;
                negative_epoch <= 1'b0;
                epoch_pf_issued <= '0;
                epoch_help <= '0;
                saved <= '0;
                cost <= 16'hffff;
                epoch_eval_pending <= 1'b0;
                epoch_decision_pending <= 1'b0;
                cost_overflow_pending <= 1'b0;
            end else if (epoch_eval_pending) begin
                epoch_eval_pending <= 1'b0;
                epoch_decision_pending <= 1'b1;
                epoch_profitable <=
                    ({1'b0, epoch_saved_snapshot} >=
                     {1'b0, epoch_cost_snapshot} + 17'd8) &&
                    (epoch_help_snapshot >= 2);
                epoch_probe_fail <=
                    (epoch_probe_issues_snapshot >= PROBE_BUDGET) ||
                    ({1'b0, epoch_cost_snapshot} >=
                     {1'b0, epoch_saved_snapshot} + 17'd8) ||
                    epoch_probe_second_snapshot;
                epoch_rate_exceeded <=
                    ({1'b0, epoch_cost_snapshot} >=
                     {1'b0, epoch_saved_snapshot} + 17'd8) ||
                    (epoch_pf_issued_snapshot * 10 > EPOCH_DEMANDS);
                epoch_cost_gt_saved <=
                    epoch_cost_snapshot > epoch_saved_snapshot;
            end else if (epoch_decision_pending) begin
                epoch_decision_pending <= 1'b0;
                if (epoch_state_snapshot == CTRL_PROBE) begin
                    if (epoch_profitable) begin
                        controller_state_reg <= CTRL_ON;
                        probe_issues <= '0;
                        probe_second_epoch <= 1'b0;
                        weak_on <= 1'b0;
                        negative_epoch <= 1'b0;
                    end else if (epoch_probe_fail) begin
                        controller_state_reg <= CTRL_OFF;
                        tokens <= '0;
                        probe_issues <= '0;
                        probe_second_epoch <= 1'b0;
                        saved <= '0;
                        cost <= '0;
                        epoch_pf_issued <= '0;
                        epoch_help <= '0;
                    end else begin
                        probe_second_epoch <= 1'b1;
                    end
                end else if (epoch_state_snapshot == CTRL_ON) begin
                    if (epoch_rate_exceeded) begin
                        controller_state_reg <= CTRL_OFF;
                        tokens <= '0;
                        weak_on <= 1'b0;
                        negative_epoch <= 1'b0;
                        probe_second_epoch <= 1'b0;
                        saved <= '0;
                        cost <= '0;
                        epoch_pf_issued <= '0;
                        epoch_help <= '0;
                    end else if (epoch_cost_gt_saved) begin
                        if (negative_epoch) begin
                            controller_state_reg <= CTRL_OFF;
                            tokens <= '0;
                            weak_on <= 1'b0;
                            negative_epoch <= 1'b0;
                            probe_second_epoch <= 1'b0;
                            saved <= '0;
                            cost <= '0;
                            epoch_pf_issued <= '0;
                            epoch_help <= '0;
                        end else begin
                            weak_on <= 1'b1;
                            negative_epoch <= 1'b1;
                        end
                    end else begin
                        weak_on <= 1'b0;
                        negative_epoch <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
