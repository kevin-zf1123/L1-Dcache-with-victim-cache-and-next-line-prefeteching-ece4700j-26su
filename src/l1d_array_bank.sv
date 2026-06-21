`timescale 1ns/1ps

module l1d_array_bank #(
    parameter integer NUM_WAYS        = 2,
    parameter integer NUM_SETS        = 8,
    parameter integer TAG_BITS        = 26,
    parameter integer LINE_BITS       = 128,
    parameter integer SRAM_ADDR_WIDTH = (NUM_SETS > 1) ? $clog2(NUM_SETS) : 1
) (
    input  logic                         clk,
    input  logic                         array_en,
    input  logic [NUM_WAYS-1:0]          tag_we,
    input  logic [NUM_WAYS-1:0]          data_we,
    input  logic [SRAM_ADDR_WIDTH-1:0]   array_addr,
    input  logic [TAG_BITS-1:0]          array_wtag,
    input  logic [LINE_BITS-1:0]         array_wdata,
    output logic [NUM_WAYS*TAG_BITS-1:0] tag_q_flat,
    output logic [NUM_WAYS*LINE_BITS-1:0] data_q_flat
);
    genvar way;
    generate
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
                .rdata(tag_q_flat[way*TAG_BITS +: TAG_BITS])
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
                .rdata(data_q_flat[way*LINE_BITS +: LINE_BITS])
            );
        end
    endgenerate
endmodule
