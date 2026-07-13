`timescale 1ns/1ps

module tb_l1d_prefetch_units;
    localparam logic [1:0] LEVEL_L1    = 2'd0;
    localparam logic [1:0] LEVEL_VC    = 2'd1;
    localparam logic [1:0] LEVEL_LOWER = 2'd2;
    localparam logic [1:0] CTRL_OFF    = 2'd0;
    localparam logic [1:0] CTRL_PROBE  = 2'd1;
    localparam logic [1:0] CTRL_ON     = 2'd2;

    logic clk;
    integer checks;

    logic stream_rst_n;
    logic stream_enable;
    logic stream_candidate_enable;
    logic demand_access_valid;
    logic demand_lower_miss;
    logic [63:0] demand_line_addr;
    logic demand_prefetch_hit;
    logic [1:0] demand_stream_id;
    logic [1:0] demand_stream_generation;
    logic unused_feedback_valid;
    logic [1:0] unused_stream_id;
    logic [1:0] unused_stream_generation;
    logic candidate_valid;
    logic candidate_ready;
    logic [63:0] candidate_addr;
    logic [1:0] candidate_confidence;
    logic [1:0] candidate_stream_id;
    logic [1:0] candidate_stream_generation;
    logic stream_event_dropped;
    logic stream_event_expired;

    logic ctrl_rst_n;
    logic ctrl_enable;
    logic ctrl_demand_access;
    logic ctrl_consume_token;
    logic ctrl_feedback_help;
    logic ctrl_feedback_pollution;
    logic ctrl_feedback_late_merge;
    logic ctrl_feedback_blocked_cycle;
    logic ctrl_feedback_pf_writeback;
    logic ctrl_issue_enable;
    logic ctrl_token_available;
    logic [1:0] ctrl_state;
    logic [1:0] ctrl_min_confidence;
    logic [15:0] ctrl_saved;
    logic [15:0] ctrl_cost;
    logic [7:0] ctrl_miss_penalty;
    logic [7:0] ctrl_wb_penalty;
    logic [7:0] ctrl_late_merge_credit;

    logic shadow_rst_n;
    logic shadow_access_valid;
    logic [63:0] shadow_access_line_addr;
    logic shadow_access_write;
    logic [1:0] shadow_actual_level;
    logic shadow_true_help;
    logic shadow_true_pollution;
    logic shadow_l1;
    logic shadow_victim;
    logic shadow_lower;

    l1d_stream_prefetch #(
        .ADDR_WIDTH(64),
        .LINE_BYTES(16),
        .STREAM_ENTRIES(4),
        .CANDIDATE_ENTRIES(2),
        .CANDIDATE_TTL(3),
        .MODE_STREAM(1)
    ) u_stream (
        .clk(clk),
        .rst_n(stream_rst_n),
        .enable(stream_enable),
        .candidate_enable(stream_candidate_enable),
        .demand_access_valid(demand_access_valid),
        .demand_lower_miss(demand_lower_miss),
        .demand_line_addr(demand_line_addr),
        .demand_prefetch_hit(demand_prefetch_hit),
        .demand_stream_id(demand_stream_id),
        .demand_stream_generation(demand_stream_generation),
        .unused_feedback_valid(unused_feedback_valid),
        .unused_stream_id(unused_stream_id),
        .unused_stream_generation(unused_stream_generation),
        .candidate_valid(candidate_valid),
        .candidate_ready(candidate_ready),
        .candidate_addr(candidate_addr),
        .candidate_confidence(candidate_confidence),
        .candidate_stream_id(candidate_stream_id),
        .candidate_stream_generation(candidate_stream_generation),
        .event_dropped(stream_event_dropped),
        .event_expired(stream_event_expired)
    );

    l1d_prefetch_controller #(
        .ADAPTIVE(1),
        .EPOCH_DEMANDS(20),
        .OFF_DEMANDS(5),
        .PROBE_BUDGET(8)
    ) u_controller (
        .clk(clk),
        .rst_n(ctrl_rst_n),
        .enable(ctrl_enable),
        .demand_access(ctrl_demand_access),
        .consume_token(ctrl_consume_token),
        .feedback_help(ctrl_feedback_help),
        .feedback_pollution(ctrl_feedback_pollution),
        .feedback_late_merge(ctrl_feedback_late_merge),
        .feedback_blocked_cycle(ctrl_feedback_blocked_cycle),
        .feedback_pf_writeback(ctrl_feedback_pf_writeback),
        .miss_penalty(ctrl_miss_penalty),
        .wb_penalty(ctrl_wb_penalty),
        .late_merge_credit(ctrl_late_merge_credit),
        .issue_enable(ctrl_issue_enable),
        .token_available(ctrl_token_available),
        .controller_state(ctrl_state),
        .min_confidence(ctrl_min_confidence),
        .debug_epoch_saved(ctrl_saved),
        .debug_epoch_cost(ctrl_cost)
    );

    l1d_shadow_cache #(
        .ADDR_WIDTH(64),
        .LINE_BYTES(16),
        .NUM_SETS(2),
        .NUM_WAYS(2),
        .VICTIM_ENTRIES(2)
    ) u_shadow (
        .clk(clk),
        .rst_n(shadow_rst_n),
        .access_valid(shadow_access_valid),
        .access_line_addr(shadow_access_line_addr),
        .access_write(shadow_access_write),
        .actual_level(shadow_actual_level),
        .event_true_help(shadow_true_help),
        .event_true_pollution(shadow_true_pollution),
        .event_shadow_l1(shadow_l1),
        .event_shadow_victim(shadow_victim),
        .event_shadow_lower(shadow_lower)
    );

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL: %s (time=%0t)", message, $time);
                $fatal(1);
            end
        end
    endtask

    task automatic reset_stream;
        begin
            stream_enable = 1'b0;
            stream_candidate_enable = 1'b0;
            stream_rst_n = 1'b0;
            demand_access_valid = 1'b0;
            demand_lower_miss = 1'b0;
            demand_line_addr = '0;
            demand_prefetch_hit = 1'b0;
            demand_stream_id = '0;
            demand_stream_generation = '0;
            unused_feedback_valid = 1'b0;
            unused_stream_id = '0;
            unused_stream_generation = '0;
            candidate_ready = 1'b0;
            repeat (2) @(posedge clk);
            @(negedge clk);
            stream_rst_n = 1'b1;
            stream_enable = 1'b1;
            stream_candidate_enable = 1'b1;
        end
    endtask

    task automatic stream_access(
        input logic [63:0] addr,
        input logic pf_hit,
        input logic [1:0] sid,
        input logic [1:0] generation
    );
        begin
            @(negedge clk);
            demand_access_valid = 1'b1;
            demand_lower_miss = 1'b1;
            demand_line_addr = addr;
            demand_prefetch_hit = pf_hit;
            demand_stream_id = sid;
            demand_stream_generation = generation;
            @(posedge clk);
            #1;
            demand_access_valid = 1'b0;
            demand_lower_miss = 1'b0;
            demand_prefetch_hit = 1'b0;
        end
    endtask

    task automatic accept_candidate;
        begin
            check(candidate_valid, "candidate handshake requires valid head");
            @(negedge clk);
            candidate_ready = 1'b1;
            @(posedge clk);
            #1;
            candidate_ready = 1'b0;
        end
    endtask

    task automatic unused_feedback(
        input logic [1:0] sid,
        input logic [1:0] generation
    );
        begin
            @(negedge clk);
            unused_stream_id = sid;
            unused_stream_generation = generation;
            unused_feedback_valid = 1'b1;
            @(posedge clk);
            #1;
            unused_feedback_valid = 1'b0;
        end
    endtask

    task automatic reset_controller;
        begin
            ctrl_enable = 1'b0;
            ctrl_rst_n = 1'b0;
            ctrl_demand_access = 1'b0;
            ctrl_consume_token = 1'b0;
            ctrl_feedback_help = 1'b0;
            ctrl_feedback_pollution = 1'b0;
            ctrl_feedback_late_merge = 1'b0;
            ctrl_feedback_blocked_cycle = 1'b0;
            ctrl_feedback_pf_writeback = 1'b0;
            ctrl_miss_penalty = 8'd8;
            ctrl_wb_penalty = 8'd8;
            ctrl_late_merge_credit = 8'd4;
            repeat (2) @(posedge clk);
            @(negedge clk);
            ctrl_rst_n = 1'b1;
            ctrl_enable = 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic controller_demands(input integer count);
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                @(negedge clk);
                ctrl_demand_access = 1'b1;
                @(posedge clk);
                #1;
                ctrl_demand_access = 1'b0;
            end
        end
    endtask

    task automatic controller_pulse(input integer which_feedback);
        begin
            @(negedge clk);
            case (which_feedback)
                0: ctrl_consume_token = 1'b1;
                1: ctrl_feedback_help = 1'b1;
                2: ctrl_feedback_pollution = 1'b1;
                3: ctrl_feedback_late_merge = 1'b1;
                4: ctrl_feedback_blocked_cycle = 1'b1;
                default: $fatal(1, "unknown controller pulse");
            endcase
            @(posedge clk);
            #1;
            ctrl_consume_token = 1'b0;
            ctrl_feedback_help = 1'b0;
            ctrl_feedback_pollution = 1'b0;
            ctrl_feedback_late_merge = 1'b0;
            ctrl_feedback_blocked_cycle = 1'b0;
            ctrl_feedback_pf_writeback = 1'b0;
        end
    endtask

    task automatic controller_demand_with_help;
        begin
            @(negedge clk);
            ctrl_demand_access = 1'b1;
            ctrl_feedback_help = 1'b1;
            @(posedge clk);
            #1;
            ctrl_demand_access = 1'b0;
            ctrl_feedback_help = 1'b0;
        end
    endtask

    task automatic controller_demand_with_issue;
        begin
            @(negedge clk);
            ctrl_demand_access = 1'b1;
            ctrl_consume_token = 1'b1;
            @(posedge clk);
            #1;
            ctrl_demand_access = 1'b0;
            ctrl_consume_token = 1'b0;
        end
    endtask

    task automatic controller_demand_with_pollution;
        begin
            @(negedge clk);
            ctrl_demand_access = 1'b1;
            ctrl_feedback_pollution = 1'b1;
            @(posedge clk);
            #1;
            ctrl_demand_access = 1'b0;
            ctrl_feedback_pollution = 1'b0;
        end
    endtask

    task automatic reset_shadow;
        begin
            shadow_rst_n = 1'b0;
            shadow_access_valid = 1'b0;
            shadow_access_line_addr = '0;
            shadow_access_write = 1'b0;
            shadow_actual_level = LEVEL_LOWER;
            repeat (2) @(posedge clk);
            @(negedge clk);
            shadow_rst_n = 1'b1;
        end
    endtask

    task automatic shadow_access(
        input logic [63:0] addr,
        input logic [1:0] actual_level,
        input logic is_write
    );
        begin
            @(negedge clk);
            shadow_access_line_addr = addr;
            shadow_actual_level = actual_level;
            shadow_access_write = is_write;
            shadow_access_valid = 1'b1;
            @(posedge clk);
            #1;
            shadow_access_valid = 1'b0;
        end
    endtask

    initial begin
        logic [1:0] saved_sid;
        logic [1:0] saved_generation;
        integer saturation_i;

        clk = 1'b0;
        checks = 0;
        stream_rst_n = 1'b0;
        ctrl_rst_n = 1'b0;
        shadow_rst_n = 1'b0;
        stream_enable = 1'b0;
        ctrl_enable = 1'b0;
        demand_access_valid = 1'b0;
        candidate_ready = 1'b0;
        unused_feedback_valid = 1'b0;
        ctrl_demand_access = 1'b0;
        ctrl_consume_token = 1'b0;
        ctrl_feedback_help = 1'b0;
        ctrl_feedback_pollution = 1'b0;
        ctrl_feedback_late_merge = 1'b0;
        ctrl_feedback_blocked_cycle = 1'b0;
        ctrl_feedback_pf_writeback = 1'b0;
        ctrl_miss_penalty = 8'd8;
        ctrl_wb_penalty = 8'd8;
        ctrl_late_merge_credit = 8'd4;
        shadow_access_valid = 1'b0;

        $display("TEST: stream +1 training and feedback");
        reset_stream();
        stream_access(64'h0000_0000_0000_1000, 1'b0, '0, '0);
        check(!candidate_valid, "first page access must only allocate a stream");
        stream_access(64'h0000_0000_0000_1010, 1'b0, '0, '0);
        check(candidate_valid, "second adjacent +1 access must create candidate");
        check(candidate_addr == 64'h1020, "+1 candidate must target next line");
        check(candidate_confidence == 2'd1, "new +1 stream confidence must be one");
        saved_sid = candidate_stream_id;
        saved_generation = candidate_stream_generation;
        accept_candidate();
        stream_access(64'h1020, 1'b0, '0, '0);
        check(candidate_addr == 64'h1030, "continued +1 stream must advance one line");
        check(candidate_confidence == 2'd2, "continued +1 stream must gain confidence");
        accept_candidate();
        unused_feedback(saved_sid, saved_generation);
        stream_access(64'h1030, 1'b0, '0, '0);
        check(candidate_confidence == 2'd2,
              "matching unused feedback must reduce confidence before retraining");
        accept_candidate();
        stream_access(64'h1030, 1'b1, saved_sid, saved_generation);
        check(!candidate_valid, "repeated prefetch hit must not create duplicate candidate");
        stream_access(64'h1040, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h1050,
              "prefetch-hit feedback must preserve +1 continuation");
        check(candidate_confidence == 2'd3,
              "matching prefetch-hit feedback must promote confidence to three");

        $display("TEST: stream -1 and 4 KiB boundaries");
        reset_stream();
        stream_access(64'h2030, 1'b0, '0, '0);
        stream_access(64'h2020, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h2010,
              "second adjacent -1 access must create previous-line candidate");
        check(candidate_confidence == 2'd1, "new -1 stream confidence must be one");
        accept_candidate();
        stream_access(64'h2010, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h2000,
              "continued -1 stream must advance toward page start");
        check(candidate_confidence == 2'd2, "continued -1 stream must gain confidence");
        accept_candidate();
        stream_access(64'h2000, 1'b0, '0, '0);
        check(!candidate_valid, "-1 stream must not prefetch below 4 KiB page");

        reset_stream();
        stream_access(64'h0fe0, 1'b0, '0, '0);
        stream_access(64'h0ff0, 1'b0, '0, '0);
        check(!candidate_valid, "+1 stream must not prefetch across 4 KiB page");
        stream_access(64'h1000, 1'b0, '0, '0);
        check(!candidate_valid, "cross-page demand pair must train separate streams");

        $display("TEST: two-entry FIFO ordering and independent TTL");
        reset_stream();
        stream_access(64'h3000, 1'b0, '0, '0);
        stream_access(64'h3010, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h3020,
              "TTL setup must create candidate");
        stream_access(64'h3020, 1'b0, '0, '0);
        check(candidate_addr == 64'h3020 && !stream_event_dropped,
              "second enqueue must preserve the older FIFO head");
        stream_access(64'h3020, 1'b0, '0, '0);
        check(candidate_addr == 64'h3020 && !stream_event_expired,
              "older FIFO entry must survive its second age increment");
        stream_access(64'h3020, 1'b0, '0, '0);
        check(stream_event_expired && candidate_valid &&
              candidate_addr == 64'h3030,
              "older entry expiry must expose independently younger entry");
        stream_access(64'h3020, 1'b0, '0, '0);
        check(stream_event_expired && !candidate_valid,
              "younger FIFO entry must expire on its own TTL schedule");

        reset_stream();
        stream_access(64'h4000, 1'b0, '0, '0);
        stream_access(64'h4010, 1'b0, '0, '0);
        stream_access(64'h4020, 1'b0, '0, '0);
        check(candidate_addr == 64'h4020 && !stream_event_dropped,
              "two queued candidates must remain in generation order");
        accept_candidate();
        check(candidate_valid && candidate_addr == 64'h4030,
              "dequeue must expose the second FIFO entry");
        accept_candidate();
        check(!candidate_valid, "second dequeue must empty the candidate FIFO");

        $display("TEST: candidate coalesce, latest-wins, and feedback generation");
        reset_stream();
        stream_access(64'h5000, 1'b0, '0, '0);
        stream_access(64'h5010, 1'b0, '0, '0);
        accept_candidate();
        stream_access(64'h5020, 1'b0, '0, '0);
        accept_candidate();
        stream_access(64'h5030, 1'b0, '0, '0);
        check(candidate_addr == 64'h5040 && candidate_confidence == 2'd3,
              "steady +1 stream must queue high-confidence candidate");
        stream_access(64'h5060, 1'b0, '0, '0);
        stream_access(64'h5050, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h5040,
              "same-address candidate must coalesce in place");
        check(candidate_confidence == 2'd3 && !stream_event_dropped,
              "coalesce must retain higher confidence without a drop");
        stream_access(64'h5050, 1'b0, '0, '0);
        stream_access(64'h5050, 1'b0, '0, '0);
        check(candidate_valid && !stream_event_expired,
              "coalesce must refresh the retained candidate TTL");
        stream_access(64'h5050, 1'b0, '0, '0);
        check(!candidate_valid && stream_event_expired,
              "refreshed coalesced candidate must eventually expire");

        reset_stream();
        stream_access(64'h6000, 1'b0, '0, '0);
        stream_access(64'h6010, 1'b0, '0, '0);
        stream_access(64'h6020, 1'b0, '0, '0);
        check(candidate_addr == 64'h6020 && !stream_event_dropped,
              "FIFO must accept two distinct candidates without dropping");
        stream_access(64'h6030, 1'b0, '0, '0);
        check(stream_event_dropped && candidate_addr == 64'h6030,
              "full FIFO latest-wins must replace the oldest candidate");
        check(candidate_confidence == 2'd2,
              "replacement must retain the surviving head metadata");
        accept_candidate();
        check(candidate_valid && candidate_addr == 64'h6040 &&
              candidate_confidence == 2'd3,
              "latest-wins tail must contain the newest candidate metadata");

        reset_stream();
        stream_access(64'h7000, 1'b0, '0, '0);
        stream_access(64'h7010, 1'b0, '0, '0);
        saved_sid = candidate_stream_id;
        saved_generation = candidate_stream_generation;
        accept_candidate();
        unused_feedback(saved_sid, saved_generation + 2'd1);
        stream_access(64'h7020, 1'b0, '0, '0);
        check(candidate_addr == 64'h7030 && candidate_confidence == 2'd2,
              "stale-generation unused feedback must not reduce confidence");

        reset_stream();
        stream_candidate_enable = 1'b0;
        stream_access(64'h8000, 1'b0, '0, '0);
        stream_access(64'h8010, 1'b0, '0, '0);
        check(!candidate_valid,
              "controller OFF must retain no speculative candidates");
        stream_candidate_enable = 1'b1;
        stream_access(64'h8020, 1'b0, '0, '0);
        check(candidate_valid && candidate_addr == 64'h8030 &&
              candidate_confidence == 2'd2,
              "OFF training must survive candidate-queue suppression");

        $display("TEST: controller token bucket and OFF/PROBE/ON states");
        reset_controller();
        check(ctrl_state == CTRL_PROBE && ctrl_issue_enable,
              "adaptive controller must start in enabled PROBE state");
        check(ctrl_token_available, "controller reset must seed one issue token");
        controller_pulse(0);
        check(!ctrl_token_available && ctrl_cost == 16'd1,
              "issuing must consume token and charge one cost unit");
        controller_demands(15);
        check(!ctrl_token_available,
              "PROBE token must not refill before sixteen demands");
        controller_demands(1);
        check(ctrl_token_available, "PROBE token must refill on demand sixteen");
        controller_pulse(1);
        controller_pulse(1);
        check(ctrl_saved == 16'd16, "two helps must credit sixteen saved cycles");
        controller_demands(4);
        check(ctrl_state == CTRL_ON && ctrl_issue_enable,
              "positive PROBE epoch with two helps must transition to ON");
        check(ctrl_saved == 0 && ctrl_cost == 0,
              "epoch transition must clear saved and cost accumulators");
        controller_pulse(0);
        check(!ctrl_token_available, "ON issue must consume available token");
        controller_demands(8);
        check(ctrl_token_available, "ON token bucket must refill within eight demands");
        controller_pulse(2);
        controller_pulse(2);
        controller_demands(12);
        check(ctrl_state == CTRL_OFF && !ctrl_issue_enable,
              "strongly negative ON epoch must transition to OFF");
        check(!ctrl_token_available, "OFF transition must clear all issue tokens");
        controller_demands(4);
        check(ctrl_state == CTRL_OFF, "OFF cooldown must last configured demand count");
        controller_demands(1);
        check(ctrl_state == CTRL_PROBE && ctrl_issue_enable && ctrl_token_available,
              "OFF cooldown completion must re-enter PROBE with one token");

        $display("TEST: controller includes boundary-cycle feedback");
        reset_controller();
        controller_pulse(1);
        controller_demands(19);
        controller_demand_with_help();
        check(ctrl_state == CTRL_ON,
              "second help on the final epoch demand must transition PROBE to ON");
        check(ctrl_saved == 0 && ctrl_cost == 0,
              "boundary transition must clear the completed epoch totals");

        reset_controller();
        controller_demands(19);
        controller_demand_with_pollution();
        check(ctrl_state == CTRL_OFF,
              "pollution on the final epoch demand must transition PROBE to OFF");

        reset_controller();
        controller_pulse(1);
        controller_demands(19);
        controller_demand_with_help();
        check(ctrl_state == CTRL_ON,
              "issue-boundary setup must enter ON");
        controller_pulse(0);
        controller_pulse(0);
        controller_demands(19);
        controller_demand_with_issue();
        check(ctrl_state == CTRL_OFF,
              "third issue on the final epoch demand must trigger ON rate cutoff");

        $display("TEST: controller accumulators saturate without wrapping");
        reset_controller();
        ctrl_miss_penalty = 8'hff;
        for (saturation_i = 0; saturation_i < 258;
             saturation_i = saturation_i + 1)
            controller_pulse(1);
        check(ctrl_saved == 16'hffff,
              "saved accumulator must remain saturated after overflow pressure");
        check(ctrl_state == CTRL_PROBE,
              "saved saturation must not force the adaptive controller OFF");

        reset_controller();
        ctrl_miss_penalty = 8'hff;
        for (saturation_i = 0; saturation_i < 256;
             saturation_i = saturation_i + 1)
            controller_pulse(2);
        check(ctrl_cost == 16'hff00 && ctrl_state == CTRL_PROBE,
              "cost below saturation must preserve the current controller state");
        controller_pulse(2);
        check(ctrl_cost == 16'hffff && ctrl_state == CTRL_OFF &&
              !ctrl_issue_enable && !ctrl_token_available,
              "cost saturation must enter fail-safe OFF and clear tokens");

        $display("TEST: shadow L1/victim classification and causal feedback");
        reset_shadow();
        shadow_access(64'h0000, LEVEL_LOWER, 1'b0);
        check(shadow_lower && !shadow_true_help && !shadow_true_pollution,
              "cold demand must classify as neutral shadow lower miss");
        shadow_access(64'h0000, LEVEL_L1, 1'b1);
        check(shadow_l1 && !shadow_true_help && !shadow_true_pollution,
              "repeated demand must classify as neutral shadow L1 hit");
        shadow_access(64'h0020, LEVEL_LOWER, 1'b0);
        shadow_access(64'h0040, LEVEL_LOWER, 1'b0);
        shadow_access(64'h0000, LEVEL_VC, 1'b0);
        check(shadow_victim && !shadow_true_help && !shadow_true_pollution,
              "evicted line must be recovered from shadow victim cache");
        shadow_access(64'h0060, LEVEL_L1, 1'b0);
        check(shadow_lower && shadow_true_help && !shadow_true_pollution,
              "actual hit absent from shadow must report true help");
        shadow_access(64'h0020, LEVEL_LOWER, 1'b0);
        check(shadow_victim && !shadow_true_help && shadow_true_pollution,
              "actual lower miss present in shadow must report true pollution");

        $display("PASS: %0d directed prefetch-unit checks", checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "timeout in directed prefetch-unit test");
    end
endmodule
