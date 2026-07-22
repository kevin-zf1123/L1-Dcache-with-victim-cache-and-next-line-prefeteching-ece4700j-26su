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

    assign controller_state = controller_state_reg;
    assign issue_enable = enable &&
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
        end else if (ADAPTIVE == 0) begin
            // Fixed deploy profile: retain only the two-token rate limiter.
            // Keeping the adaptive epoch/state arithmetic outside this
            // elaborated branch lets synthesis remove its counters and wide
            // saturating add/compare network completely.
            controller_state_reg <= CTRL_ON;
            demand_count <= '0;
            probe_issues <= '0;
            probe_second_epoch <= 1'b0;
            weak_on <= 1'b0;
            negative_epoch <= 1'b0;
            epoch_pf_issued <= '0;
            epoch_help <= '0;
            saved <= '0;
            cost <= '0;

            if (consume_token && tokens != 0 &&
                !(demand_access && refill_count == ON_REFILL-1))
                tokens <= tokens - 1'b1;

            if (demand_access) begin
                if (refill_count == ON_REFILL-1) begin
                    refill_count <= '0;
                    if (!consume_token && tokens != 2)
                        tokens <= tokens + 1'b1;
                end else begin
                    refill_count <= refill_count + 1'b1;
                end
            end
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
                    if (ADAPTIVE != 0 &&
                        controller_state_reg == CTRL_PROBE) begin
                        if ({1'b0, saved_accumulate_value} >=
                                {1'b0, cost_accumulate_value} + 17'd8 &&
                            epoch_help_effective >= 2) begin
                            controller_state_reg <= CTRL_ON;
                            probe_issues <= '0;
                            probe_second_epoch <= 1'b0;
                            weak_on <= 1'b0;
                            negative_epoch <= 1'b0;
                        end else if (probe_issues_effective >= PROBE_BUDGET ||
                                     {1'b0, cost_accumulate_value} >=
                                         {1'b0, saved_accumulate_value} +
                                         17'd8 ||
                                     probe_second_epoch) begin
                            controller_state_reg <= CTRL_OFF;
                            tokens <= '0;
                            probe_issues <= '0;
                            probe_second_epoch <= 1'b0;
                        end else begin
                            // A sparse phase may need a second epoch to spend
                            // the eight-request probe budget.  The budget is
                            // cumulative and never resets every epoch.
                            probe_second_epoch <= 1'b1;
                        end
                    end else if (ADAPTIVE != 0 &&
                                 controller_state_reg == CTRL_ON) begin
                        if ({1'b0, cost_accumulate_value} >=
                                {1'b0, saved_accumulate_value} + 17'd8 ||
                            (epoch_pf_issued_effective * 10 >
                             EPOCH_DEMANDS)) begin
                            controller_state_reg <= CTRL_OFF;
                            tokens <= '0;
                            weak_on <= 1'b0;
                            negative_epoch <= 1'b0;
                            probe_second_epoch <= 1'b0;
                        end else if (cost_accumulate_value >
                                     saved_accumulate_value) begin
                            if (negative_epoch) begin
                                controller_state_reg <= CTRL_OFF;
                                tokens <= '0;
                                weak_on <= 1'b0;
                                negative_epoch <= 1'b0;
                                probe_second_epoch <= 1'b0;
                            end else begin
                                weak_on <= 1'b1;
                                negative_epoch <= 1'b1;
                            end
                        end else begin
                            weak_on <= 1'b0;
                            negative_epoch <= 1'b0;
                        end
                    end
                    saved <= '0;
                    cost <= '0;
                    epoch_pf_issued <= '0;
                    epoch_help <= '0;
                end
            end

            // Cost overflow must never wrap into an apparently profitable
            // epoch.  Adaptive policies fail closed immediately; the OFF
            // cooldown later clears the completed epoch before probing again.
            if (ADAPTIVE != 0 && controller_state_reg != CTRL_OFF &&
                cost_reaches_saturation) begin
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
            end
        end
    end
endmodule
