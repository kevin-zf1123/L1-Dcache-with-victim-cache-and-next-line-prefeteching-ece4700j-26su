`timescale 1ns/1ps

module tb_l1d_fpga_harness #(
    parameter integer LINE_BYTES = 16,
    parameter integer NUM_SETS = 4,
    parameter integer NUM_WAYS = 2,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer ENABLE_PREFETCH = 1,
    parameter integer PREFETCH_POLICY = 1,
    parameter integer PF_OPT_LEVEL = 3,
    parameter integer PF_USE_STREAM = (PF_OPT_LEVEL >= 2),
    parameter integer PF_USE_ADAPTIVE = (PF_OPT_LEVEL >= 2),
    parameter integer PF_USE_SHADOW = (PF_OPT_LEVEL >= 3),
    parameter integer PF_USE_MSHR = (PF_OPT_LEVEL >= 3),
    parameter integer PF_IDLE_GUARD = 2,
    parameter integer PF_EPOCH_DEMANDS = 256,
    parameter integer PF_OFF_DEMANDS = 512,
    parameter integer PF_PROBE_BUDGET = 8,
    parameter integer PF_PROBE_REFILL = 16,
    parameter integer PF_ON_REFILL = 8,
    parameter integer VC_FORMAT_IN_SWAP = 1
);
    logic clk;
    logic rst_n;
    logic start;
    logic done;
    logic pass;
    logic [31:0] signature;

    l1d_fpga_harness #(
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .ENABLE_PREFETCH(ENABLE_PREFETCH),
        .PREFETCH_POLICY(PREFETCH_POLICY),
        .PF_OPT_LEVEL(PF_OPT_LEVEL),
        .PF_USE_STREAM(PF_USE_STREAM),
        .PF_USE_ADAPTIVE(PF_USE_ADAPTIVE),
        .PF_USE_SHADOW(PF_USE_SHADOW),
        .PF_USE_MSHR(PF_USE_MSHR),
        .PF_IDLE_GUARD(PF_IDLE_GUARD),
        .PF_EPOCH_DEMANDS(PF_EPOCH_DEMANDS),
        .PF_OFF_DEMANDS(PF_OFF_DEMANDS),
        .PF_PROBE_BUDGET(PF_PROBE_BUDGET),
        .PF_PROBE_REFILL(PF_PROBE_REFILL),
        .PF_ON_REFILL(PF_ON_REFILL),
        .VC_FORMAT_IN_SWAP(VC_FORMAT_IN_SWAP)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done),
        .pass(pass),
        .signature(signature)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        start = 1'b1;
        @(posedge done);
        #1;
        if (!pass)
            $fatal(1, "deploy harness reported a data mismatch");
        $display("PASS: deploy harness policy=%0d level=%0d stream=%0d adaptive=%0d shadow=%0d mshr=%0d signature=%08x",
                 PREFETCH_POLICY, PF_OPT_LEVEL, PF_USE_STREAM,
                 PF_USE_ADAPTIVE, PF_USE_SHADOW, PF_USE_MSHR, signature);
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "deploy harness watchdog expired");
    end
endmodule
