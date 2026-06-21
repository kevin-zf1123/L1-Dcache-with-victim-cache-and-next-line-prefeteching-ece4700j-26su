`timescale 1ns/1ps

module l1d_request_arbiter #(
    parameter integer ADDR_WIDTH      = 32,
    parameter integer DATA_WIDTH      = 32,
    parameter integer LINE_BYTES      = 16,
    parameter integer NUM_SETS        = 8,
    parameter integer SRAM_ADDR_WIDTH = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1
) (
    input  logic                      state_idle,
    input  logic                      prefetch_feature_en,

    input  logic                      cpu_req_valid,
    input  logic [ADDR_WIDTH-1:0]     cpu_req_addr,
    input  logic                      cpu_req_write,
    input  logic [DATA_WIDTH-1:0]     cpu_req_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] cpu_req_wstrb,

    input  logic                      ext_prefetch_valid,
    input  logic [ADDR_WIDTH-1:0]     ext_prefetch_addr,

    input  logic                      next_line_candidate_valid,
    input  logic [ADDR_WIDTH-1:0]     next_line_candidate_addr,

    output logic                      cpu_req_ready,
    output logic                      ext_prefetch_ready,
    output logic                      next_line_candidate_ready,

    output logic                      idle_array_en,
    output logic [SRAM_ADDR_WIDTH-1:0] idle_array_addr,

    output logic                      launch_req_valid,
    output logic [ADDR_WIDTH-1:0]     launch_req_addr,
    output logic                      launch_req_write,
    output logic [DATA_WIDTH-1:0]     launch_req_wdata,
    output logic [(DATA_WIDTH/8)-1:0] launch_req_wstrb,
    output logic                      launch_req_is_prefetch
);
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);

    function automatic [SRAM_ADDR_WIDTH-1:0] address_set(
        input logic [ADDR_WIDTH-1:0] addr
    );
        address_set = (addr >> OFFSET_BITS);
    endfunction

    function automatic [ADDR_WIDTH-1:0] line_address(
        input logic [ADDR_WIDTH-1:0] addr
    );
        line_address = {addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
    endfunction

    always_comb begin
        cpu_req_ready = state_idle;
        ext_prefetch_ready = 1'b0;
        next_line_candidate_ready = 1'b0;

        idle_array_en = 1'b0;
        idle_array_addr = '0;

        launch_req_valid = 1'b0;
        launch_req_addr = '0;
        launch_req_write = 1'b0;
        launch_req_wdata = '0;
        launch_req_wstrb = '0;
        launch_req_is_prefetch = 1'b0;

        if (state_idle) begin
            if (cpu_req_valid) begin
                idle_array_en = 1'b1;
                idle_array_addr = address_set(cpu_req_addr);

                launch_req_valid = 1'b1;
                launch_req_addr = cpu_req_addr;
                launch_req_write = cpu_req_write;
                launch_req_wdata = cpu_req_wdata;
                launch_req_wstrb = cpu_req_wstrb;
            end else if (prefetch_feature_en && ext_prefetch_valid) begin
                ext_prefetch_ready = 1'b1;
                idle_array_en = 1'b1;
                idle_array_addr = address_set(ext_prefetch_addr);

                launch_req_valid = 1'b1;
                launch_req_addr = line_address(ext_prefetch_addr);
                launch_req_is_prefetch = 1'b1;
            end else if (prefetch_feature_en && next_line_candidate_valid) begin
                next_line_candidate_ready = 1'b1;
                idle_array_en = 1'b1;
                idle_array_addr = address_set(next_line_candidate_addr);

                launch_req_valid = 1'b1;
                launch_req_addr = next_line_candidate_addr;
                launch_req_is_prefetch = 1'b1;
            end
        end
    end
endmodule
