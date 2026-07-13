`timescale 1ns/1ps

module tb_l1d_cache_p3;
    localparam integer ADDR_WIDTH = 64;
    localparam integer DATA_WIDTH = 64;
    localparam integer LINE_BYTES = 16;
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer NUM_SETS = 4;
    localparam integer NUM_WAYS = 2;
    localparam integer VICTIM_ENTRIES = 4;

    localparam logic [1:0] SIZE_DOUBLE = 2'b11;

    logic clk;
    logic rst_n;

    logic cfg_prefetch_enable;
    logic cfg_next_line_enable;
    logic ext_prefetch_valid;
    logic ext_prefetch_ready;
    logic [ADDR_WIDTH-1:0] ext_prefetch_addr;

    logic cpu_req_valid;
    logic cpu_req_ready;
    logic [ADDR_WIDTH-1:0] cpu_req_addr;
    logic cpu_req_write;
    logic [1:0] cpu_req_size;
    logic cpu_req_unsigned;
    logic [DATA_WIDTH-1:0] cpu_req_wdata;
    logic cpu_rsp_valid;
    logic cpu_rsp_ready;
    logic [DATA_WIDTH-1:0] cpu_rsp_rdata;
    logic cpu_rsp_error;
    logic [1:0] cpu_rsp_error_cause;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    logic [ADDR_WIDTH-1:0] mem_req_addr;
    logic [LINE_BITS-1:0] mem_req_wdata;
    logic mem_rsp_valid;
    logic [LINE_BITS-1:0] mem_rsp_rdata;

    logic [31:0] stat_cpu_hits;
    logic [31:0] stat_cpu_misses;
    logic [31:0] stat_prefetch_fills;
    logic [31:0] stat_prefetch_useful;
    logic [31:0] stat_pf_issued;
    logic [31:0] stat_pf_returned;
    logic [31:0] stat_pf_installed;
    logic [31:0] stat_pf_merged;
    logic [31:0] stat_pf_discarded;
    logic [31:0] stat_pf_caused_writebacks;
    logic [31:0] stat_pf_same_line_coalesced;
    logic [3:0] debug_state;
    logic debug_req_is_prefetch;
    logic debug_pf_mshr_valid;
    logic [ADDR_WIDTH-1:0] debug_pf_mshr_addr;
    logic [1:0] debug_pf_mshr_confidence;

    integer checks;

    l1d_cache_optimized #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .ENABLE_PREFETCH(1),
        .PF_OPT_LEVEL(3)
    ) dut (
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
        .stat_prefetch_fills(stat_prefetch_fills),
        .stat_prefetch_useful(stat_prefetch_useful),
        .debug_state(debug_state),
        .debug_req_is_prefetch(debug_req_is_prefetch),
        .stat_pf_issued(stat_pf_issued),
        .stat_pf_returned(stat_pf_returned),
        .stat_pf_installed(stat_pf_installed),
        .stat_pf_merged(stat_pf_merged),
        .stat_pf_discarded(stat_pf_discarded),
        .stat_pf_caused_writebacks(stat_pf_caused_writebacks),
        .stat_pf_same_line_coalesced(stat_pf_same_line_coalesced),
        .debug_pf_mshr_valid(debug_pf_mshr_valid),
        .debug_pf_mshr_addr(debug_pf_mshr_addr),
        .debug_pf_mshr_confidence(debug_pf_mshr_confidence)
    );

    always #5 clk = ~clk;

    function automatic [LINE_BITS-1:0] memory_line(
        input logic [ADDR_WIDTH-1:0] line_addr
    );
        memory_line = {line_addr + 64'd8, line_addr};
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL: %s (time=%0t state=%0d)",
                         message, $time, debug_state);
                $fatal(1);
            end
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst_n = 1'b0;
            cfg_prefetch_enable = 1'b1;
            cfg_next_line_enable = 1'b0;
            ext_prefetch_valid = 1'b0;
            ext_prefetch_addr = '0;
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;
            cpu_rsp_ready = 1'b1;
            mem_req_ready = 1'b1;
            mem_rsp_valid = 1'b0;
            mem_rsp_rdata = '0;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic enqueue_external_prefetch(
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer timeout;
        begin
            @(negedge clk);
            ext_prefetch_addr = addr;
            ext_prefetch_valid = 1'b1;
            timeout = 0;
            while (!ext_prefetch_ready) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 20)
                    $fatal(1, "external prefetch skid timeout");
            end
            @(posedge clk);
            @(negedge clk);
            ext_prefetch_valid = 1'b0;
            ext_prefetch_addr = '0;
        end
    endtask

    task automatic wait_for_read_issue(
        input logic [ADDR_WIDTH-1:0] expected_addr
    );
        integer timeout;
        begin
            timeout = 0;
            while (!(mem_req_valid && mem_req_ready && !mem_req_write &&
                     mem_req_addr == expected_addr)) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 40) begin
                    $display("FAIL: memory read issue timeout expected=%h actual=%h",
                             expected_addr, mem_req_addr);
                    $fatal(1);
                end
            end
            @(posedge clk);
            #1;
        end
    endtask

    task automatic return_read(
        input logic [ADDR_WIDTH-1:0] addr,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles) @(negedge clk);
            mem_rsp_rdata = memory_line(addr);
            mem_rsp_valid = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            mem_rsp_valid = 1'b0;
            mem_rsp_rdata = '0;
        end
    endtask

    task automatic start_load(input logic [ADDR_WIDTH-1:0] addr);
        integer timeout;
        begin
            @(negedge clk);
            cpu_req_addr = addr;
            cpu_req_write = 1'b0;
            cpu_req_size = SIZE_DOUBLE;
            cpu_req_unsigned = 1'b0;
            cpu_req_wdata = '0;
            cpu_req_valid = 1'b1;
            timeout = 0;
            while (!cpu_req_ready) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 40)
                    $fatal(1, "CPU request acceptance timeout");
            end
            @(posedge clk);
            @(negedge clk);
            cpu_req_valid = 1'b0;
            cpu_req_addr = '0;
        end
    endtask

    task automatic wait_load_response(
        input logic [DATA_WIDTH-1:0] expected_data
    );
        integer timeout;
        begin
            timeout = 0;
            while (!cpu_rsp_valid) begin
                @(negedge clk);
                timeout = timeout + 1;
                if (timeout > 50)
                    $fatal(1, "CPU response timeout");
            end
            check(!cpu_rsp_error, "load response must not report an error");
            check(cpu_rsp_rdata == expected_data,
                  "load response data must match the lower-memory line");
            @(posedge clk);
            #1;
        end
    endtask

    task automatic test_no_demand_install;
        logic [ADDR_WIDTH-1:0] pf_addr;
        begin
            $display("TEST: P3 no-demand response installs directly in L1");
            reset_dut();
            pf_addr = 64'h0000_0000_0000_0100;
            enqueue_external_prefetch(pf_addr);
            wait_for_read_issue(pf_addr);
            check(debug_pf_mshr_valid, "prefetch issue must allocate PF MSHR");
            return_read(pf_addr, 3);
            wait (stat_pf_installed == 1);
            @(negedge clk);
            check(!debug_pf_mshr_valid, "installed prefetch must release PF MSHR");
            check(stat_pf_returned == 1, "prefetch return must be counted");
            check(stat_prefetch_fills == 1, "speculative install must count as fill");

            start_load(pf_addr);
            wait_load_response(pf_addr);
            check(stat_cpu_hits == 1, "installed prefetch must satisfy an L1 hit");
            check(stat_prefetch_useful == 1,
                  "first demand use must promote the prefetched line");
        end
    endtask

    task automatic test_same_line_merge;
        logic [ADDR_WIDTH-1:0] pf_addr;
        begin
            $display("TEST: P3 same-line demand merges with PF MSHR");
            reset_dut();
            pf_addr = 64'h0000_0000_0000_0200;
            enqueue_external_prefetch(pf_addr);
            wait_for_read_issue(pf_addr);
            start_load(pf_addr);
            return_read(pf_addr, 2);
            wait_load_response(pf_addr);
            check(stat_pf_merged == 1, "same-line waiter must count as merged");
            check(stat_pf_discarded == 0,
                  "same-line waiter must not discard the PF response");
            check(stat_pf_same_line_coalesced == 1,
                  "same-line coalescing event must be counted");
            check(!debug_pf_mshr_valid, "merged response must release PF MSHR");
        end
    endtask

    task automatic test_set_quota_with_invalid_way;
        logic [ADDR_WIDTH-1:0] first_pf;
        logic [ADDR_WIDTH-1:0] second_pf;
        logic [ADDR_WIDTH-1:0] refill_addr;
        integer n;
        integer speculative_count;
        begin
            $display("TEST: P3 invalid-first insertion preserves one-PF set quota");
            reset_dut();
            first_pf = 64'h0000_0000_0000_0100;
            second_pf = 64'h0000_0000_0000_0140;
            refill_addr = 64'h0000_0000_0000_0010;

            enqueue_external_prefetch(first_pf);
            wait_for_read_issue(first_pf);
            return_read(first_pf, 1);
            wait (stat_pf_installed == 1);

            // Refill the PROBE token without touching set zero.
            start_load(refill_addr);
            wait_for_read_issue(refill_addr);
            return_read(refill_addr, 1);
            wait_load_response(refill_addr);
            for (n = 0; n < 15; n = n + 1) begin
                start_load(refill_addr);
                wait_load_response(refill_addr);
            end

            enqueue_external_prefetch(second_pf);
            wait_for_read_issue(second_pf);
            return_read(second_pf, 1);
            wait (stat_pf_installed == 2);
            @(negedge clk);
            speculative_count = dut.prefetched_bits[0][0] +
                                dut.prefetched_bits[1][0];
            check(speculative_count == 1,
                  "set quota must retain exactly one unused prefetch");
            check(dut.stat_pf_unused_evicted == 1 &&
                  dut.stat_pf_vc_bypass == 1,
                  "replaced speculative line must bypass VC and count unused");
        end
    endtask

    task automatic test_different_line_miss;
        logic [ADDR_WIDTH-1:0] pf_addr;
        logic [ADDR_WIDTH-1:0] demand_addr;
        begin
            $display("TEST: P3 different-line lower miss discards PF then replays");
            reset_dut();
            pf_addr = 64'h0000_0000_0000_0300;
            demand_addr = 64'h0000_0000_0000_0440;
            enqueue_external_prefetch(pf_addr);
            wait_for_read_issue(pf_addr);
            start_load(demand_addr);
            return_read(pf_addr, 2);
            wait_for_read_issue(demand_addr);
            check(stat_pf_discarded == 1,
                  "completed speculative response must be discarded");
            return_read(demand_addr, 2);
            wait_load_response(demand_addr);
            check(stat_pf_merged == 0,
                  "different-line demand must not count as a PF merge");
            check(!debug_pf_mshr_valid,
                  "discarded response must release PF MSHR before replay");
        end
    endtask

    task automatic test_hit_under_prefetch;
        logic [ADDR_WIDTH-1:0] hit_addr;
        logic [ADDR_WIDTH-1:0] pf_addr;
        begin
            $display("TEST: P3 cached demand hits while PF read is outstanding");
            reset_dut();
            hit_addr = 64'h0000_0000_0000_0500;
            pf_addr = 64'h0000_0000_0000_0610;

            start_load(hit_addr);
            wait_for_read_issue(hit_addr);
            return_read(hit_addr, 2);
            wait_load_response(hit_addr);

            enqueue_external_prefetch(pf_addr);
            wait_for_read_issue(pf_addr);
            check(debug_pf_mshr_valid, "PF MSHR must remain live during hit test");
            start_load(hit_addr);
            wait_load_response(hit_addr);
            check(debug_pf_mshr_valid,
                  "unrelated L1 hit must not consume the outstanding PF MSHR");
            check(stat_cpu_hits == 1,
                  "cached demand must hit while prefetch is outstanding");

            return_read(pf_addr, 2);
            wait (stat_pf_installed == 1);
            @(negedge clk);
            check(!debug_pf_mshr_valid,
                  "PF response must install after the unrelated demand hit");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cfg_prefetch_enable = 1'b1;
        cfg_next_line_enable = 1'b0;
        ext_prefetch_valid = 1'b0;
        ext_prefetch_addr = '0;
        cpu_req_valid = 1'b0;
        cpu_req_addr = '0;
        cpu_req_write = 1'b0;
        cpu_req_size = SIZE_DOUBLE;
        cpu_req_unsigned = 1'b0;
        cpu_req_wdata = '0;
        cpu_rsp_ready = 1'b1;
        mem_req_ready = 1'b1;
        mem_rsp_valid = 1'b0;
        mem_rsp_rdata = '0;
        checks = 0;

        fork
            begin
                #20000;
                $fatal(1, "P3 simulation-time watchdog expired");
            end
        join_none

        test_no_demand_install();
        test_set_quota_with_invalid_way();
        test_same_line_merge();
        test_different_line_miss();
        test_hit_under_prefetch();

        check(stat_pf_caused_writebacks == 0,
              "speculative traffic must not be attributed a writeback");

        $display("PASS: %0d directed P3 PF-MSHR checks", checks);
        $finish;
    end
endmodule
