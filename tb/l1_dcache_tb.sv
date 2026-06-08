`timescale 1ns/1ps

module l1_dcache_tb;

    localparam int ADDR_W     = 32;
    localparam int DATA_W     = 32;
    localparam int LINE_BYTES = 16;
    localparam int LINE_W     = LINE_BYTES * 8;

    logic clk;
    logic rst_n;

    logic                cpu_req_valid;
    logic                cpu_req_ready;
    logic [ADDR_W-1:0]   cpu_req_addr;
    logic                cpu_req_we;
    logic [DATA_W/8-1:0] cpu_req_be;
    logic [DATA_W-1:0]   cpu_req_wdata;

    logic                cpu_rsp_valid;
    logic                cpu_rsp_ready;
    logic [DATA_W-1:0]   cpu_rsp_rdata;
    logic                cpu_rsp_err;

    logic                mem_req_valid;
    logic                mem_req_ready;
    logic [ADDR_W-1:0]   mem_req_addr;
    logic                mem_req_we;
    logic [LINE_W-1:0]   mem_req_wdata;

    logic                mem_rsp_valid;
    logic [LINE_W-1:0]   mem_rsp_rdata;
    logic                mem_rsp_err;

    logic [LINE_W-1:0] backing_mem [0:15];
    logic [ADDR_W-1:0] last_mem_req_addr;
    logic              last_mem_req_seen;
    int pass_count;

    l1_dcache #(
        .ADDR_W(ADDR_W),
        .DATA_W(DATA_W),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(4),
        .NUM_WAYS(2),
        .VICTIM_DEPTH(1),
        .ENABLE_VICTIM_CACHE(1'b0),
        .ENABLE_NEXT_PREFETCH(1'b0),
        .MSHR_DEPTH(1)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_we(cpu_req_we),
        .cpu_req_be(cpu_req_be),
        .cpu_req_wdata(cpu_req_wdata),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_ready(cpu_rsp_ready),
        .cpu_rsp_rdata(cpu_rsp_rdata),
        .cpu_rsp_err(cpu_rsp_err),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_addr(mem_req_addr),
        .mem_req_we(mem_req_we),
        .mem_req_wdata(mem_req_wdata),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_err(mem_rsp_err)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("l1_dcache.vcd");
        $dumpvars();

        cpu_req_valid = 1'b0;
        cpu_req_addr  = '0;
        cpu_req_we    = 1'b0;
        cpu_req_be    = '1;
        cpu_req_wdata = '0;
        cpu_rsp_ready = 1'b1;

        mem_req_ready = 1'b1;
        mem_rsp_valid = 1'b0;
        mem_rsp_rdata = '0;
        mem_rsp_err   = 1'b0;
        last_mem_req_addr = '0;
        last_mem_req_seen = 1'b0;

        rst_n = 1'b0;
        pass_count = 0;

        init_backing_mem();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        run_smoke_test();

        $display("TESTBENCH PASSED (%0d checks)", pass_count);
        $finish;
    end

    initial begin
        forever begin
            @(posedge clk);
            mem_rsp_valid <= 1'b0;
            if (mem_req_valid && mem_req_ready && !mem_req_we) begin
                last_mem_req_addr <= mem_req_addr;
                last_mem_req_seen <= 1'b1;
                mem_rsp_rdata <= backing_mem[line_index(mem_req_addr)];
                mem_rsp_err   <= 1'b0;
                mem_rsp_valid <= 1'b1;
            end
        end
    end

    task automatic init_backing_mem;
        begin
            backing_mem[0]  = 128'h33334444_11112222_CCCC_DDDD_AAAABBBB;
            backing_mem[1]  = 128'h76543210_FEDCBA98_89ABCDEF_01234567;
            backing_mem[2]  = 128'hCAFEBABE_0BADF00D_5555AAAA_DEADBEEF;
            backing_mem[3]  = 128'h13579BDF_2468ACE0_F0F0F0F0_0F0F0F0F;
            backing_mem[4]  = 128'h11111111_22222222_33333333_44444444;
            backing_mem[5]  = 128'h55555555_66666666_77777777_88888888;
            backing_mem[6]  = 128'h99999999_AAAAAAAA_BBBBBBBB_CCCCCCCC;
            backing_mem[7]  = 128'hDDDDDDDD_EEEEEEEE_FFFFFFFF_12345678;
            backing_mem[8]  = 128'h89ABCDEF_10203040_50607080_90A0B0C0;
            backing_mem[9]  = 128'h0ACE0ACE_1BDF1BDF_2CEF2CEF_3DEF3DEF;
            backing_mem[10] = 128'hAAAABBBB_CCCCDDDD_EEEEFFFF_00001111;
            backing_mem[11] = 128'h12121212_34343434_56565656_78787878;
            backing_mem[12] = 128'hFACECAFE_BEEFBEEF_ABCD1234_DCBA4321;
            backing_mem[13] = 128'h01010101_02020202_03030303_04040404;
            backing_mem[14] = 128'hABCDEF01_23456789_13572468_24681357;
            backing_mem[15] = 128'hFEEDC0DE_C001D00D_BADCAFE0_600D600D;
        end
    endtask

    task automatic run_smoke_test;
        logic [DATA_W-1:0] rdata;
        begin
            do_read_check(32'h0000_0000, 32'hAAAA_BBBB, "first read refills line and returns word 0");
            check_ok(last_mem_req_seen && last_mem_req_addr == 32'h0000_0000, "refill aligned first line address");
            last_mem_req_seen = 1'b0;

            do_read_check(32'h0000_0004, 32'hCCCC_DDDD, "second word read hits in same line");
            check_ok(mem_req_valid == 1'b0, "no new memory request after cached read");

            do_write(32'h0000_0004, 32'h1122_3344, 4'b1111);
            do_read(32'h0000_0004, rdata);
            check_ok(rdata == 32'h1122_3344, "write hit updates cached data");

            do_read_check(32'h0000_0010, 32'h0123_4567, "different line read triggers second refill");
            check_ok(last_mem_req_seen && last_mem_req_addr == 32'h0000_0010, "refill aligned second line address");
        end
    endtask

    task automatic do_read_check(
        input logic [ADDR_W-1:0] addr,
        input logic [DATA_W-1:0] expected,
        input [8*80-1:0] label
    );
        logic [DATA_W-1:0] rdata;
        begin
            do_read(addr, rdata);
            check_ok(rdata == expected, label);
        end
    endtask

    task automatic do_read(
        input logic [ADDR_W-1:0] addr,
        output logic [DATA_W-1:0] rdata
    );
        begin
            issue_req(addr, 1'b0, {DATA_W/8{1'b1}}, {DATA_W{1'b0}});
            wait_for_rsp(rdata);
        end
    endtask

    task automatic do_write(
        input logic [ADDR_W-1:0] addr,
        input logic [DATA_W-1:0] wdata,
        input logic [DATA_W/8-1:0] be
    );
        logic [DATA_W-1:0] ignored;
        begin
            issue_req(addr, 1'b1, be, wdata);
            wait_for_rsp(ignored);
        end
    endtask

    task automatic issue_req(
        input logic [ADDR_W-1:0] addr,
        input logic we,
        input logic [DATA_W/8-1:0] be,
        input logic [DATA_W-1:0] wdata
    );
        begin
            @(posedge clk);
            while (!cpu_req_ready) @(posedge clk);
            cpu_req_addr  <= addr;
            cpu_req_we    <= we;
            cpu_req_be    <= be;
            cpu_req_wdata <= wdata;
            cpu_req_valid <= 1'b1;

            @(posedge clk);
            while (!cpu_req_ready) @(posedge clk);
            cpu_req_valid <= 1'b0;
            cpu_req_addr  <= '0;
            cpu_req_we    <= 1'b0;
            cpu_req_be    <= '1;
            cpu_req_wdata <= '0;
        end
    endtask

    task automatic wait_for_rsp(output logic [DATA_W-1:0] rdata);
        begin
            while (!cpu_rsp_valid) @(posedge clk);
            rdata = cpu_rsp_rdata;
            check_ok(cpu_rsp_err == 1'b0, "response completed without error");
            @(posedge clk);
        end
    endtask

    task automatic check_ok(input logic cond, input [8*80-1:0] label);
        begin
            if (!cond) begin
                $error("CHECK FAILED: %s", label);
                $fatal(1);
            end
            pass_count++;
            $display("PASS: %s", label);
        end
    endtask

    function automatic int line_index(input logic [ADDR_W-1:0] addr);
        line_index = (addr / LINE_BYTES) % 16;
    endfunction

endmodule
