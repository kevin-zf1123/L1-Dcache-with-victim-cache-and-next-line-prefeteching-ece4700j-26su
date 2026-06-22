`timescale 1ns/1ps

module l1d_next_line_prefetch #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer LINE_BYTES = 16
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  enable,
    input  logic                  demand_fill_valid,
    input  logic [ADDR_WIDTH-1:0] demand_line_addr,
    output logic                  candidate_valid,
    input  logic                  candidate_ready,
    output logic [ADDR_WIDTH-1:0] candidate_addr,
    output logic                  dropped
);
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);

    logic pending;
    logic [ADDR_WIDTH-1:0] pending_addr;

    assign candidate_valid = pending;
    assign candidate_addr = pending_addr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= 1'b0;
            pending_addr <= '0;
            dropped <= 1'b0;
        end else begin
            dropped <= 1'b0;

            if (!enable) begin
                pending <= 1'b0;
            end else if (candidate_valid && candidate_ready) begin
                pending <= 1'b0;
            end

            if (demand_fill_valid && enable) begin
                if (pending && !candidate_ready) begin
                    dropped <= 1'b1;
                end else begin
                    pending <= 1'b1;
                    pending_addr <= {
                        demand_line_addr[ADDR_WIDTH-1:OFFSET_BITS],
                        {OFFSET_BITS{1'b0}}
                    } + LINE_BYTES;
                end
            end
        end
    end
endmodule
