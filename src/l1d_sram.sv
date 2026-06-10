`timescale 1ns/1ps

module l1d_sram #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 64,
    parameter integer ADDR_WIDTH = $clog2(DEPTH)
) (
    input  logic                  clk,
    input  logic                  en,
    input  logic                  we,
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [WIDTH-1:0]      wdata,
    output logic [WIDTH-1:0]      rdata
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (en) begin
            if (we) begin
                mem[addr] <= wdata;
                rdata <= wdata;
            end else begin
                rdata <= mem[addr];
            end
        end
    end
endmodule
