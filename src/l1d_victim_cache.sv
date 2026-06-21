`timescale 1ns/1ps

import l1d_cache_pkg::*;

module l1d_victim_cache #(
    parameter integer ADDR_WIDTH     = 32,
    parameter integer LINE_BITS      = 128,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer VC_BITS        = (VICTIM_ENTRIES > 1) ? $clog2(VICTIM_ENTRIES) : 1
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  state_t                            state,
    input  logic [VC_BITS-1:0]                selected_vc,
    input  logic                              evicted_valid,
    input  logic                              evicted_dirty,
    input  logic                              evicted_prefetched,
    input  logic [ADDR_WIDTH-1:0]             evicted_addr,
    input  logic [LINE_BITS-1:0]              evicted_data,
    output logic [VC_BITS-1:0]                vc_rr,
    output logic [VICTIM_ENTRIES-1:0]         vc_valid_flat,
    output logic [VICTIM_ENTRIES-1:0]         vc_dirty_flat,
    output logic [VICTIM_ENTRIES-1:0]         vc_prefetched_flat,
    output logic [VICTIM_ENTRIES*ADDR_WIDTH-1:0] vc_addr_flat,
    output logic [VICTIM_ENTRIES*LINE_BITS-1:0]  vc_data_flat
) ;
    integer reset_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vc_rr <= '0;
            vc_valid_flat <= '0;
            vc_dirty_flat <= '0;
            vc_prefetched_flat <= '0;
            vc_addr_flat <= '0;
            vc_data_flat <= '0;
        end else begin
            case (state)
                ST_VC_SWAP: begin
                    if (evicted_valid) begin
                        vc_valid_flat[selected_vc] <= 1'b1;
                        vc_dirty_flat[selected_vc] <= evicted_dirty;
                        vc_prefetched_flat[selected_vc] <= evicted_prefetched;
                        vc_addr_flat[selected_vc*ADDR_WIDTH +: ADDR_WIDTH] <= evicted_addr;
                        vc_data_flat[selected_vc*LINE_BITS +: LINE_BITS] <= evicted_data;
                    end else begin
                        vc_valid_flat[selected_vc] <= 1'b0;
                        vc_dirty_flat[selected_vc] <= 1'b0;
                        vc_prefetched_flat[selected_vc] <= 1'b0;
                    end
                end

                ST_VC_INSERT: begin
                    vc_valid_flat[selected_vc] <= evicted_valid;
                    vc_dirty_flat[selected_vc] <= evicted_dirty;
                    vc_prefetched_flat[selected_vc] <= evicted_prefetched;
                    vc_addr_flat[selected_vc*ADDR_WIDTH +: ADDR_WIDTH] <= evicted_addr;
                    vc_data_flat[selected_vc*LINE_BITS +: LINE_BITS] <= evicted_data;
                    if (vc_rr == VICTIM_ENTRIES-1) begin
                        vc_rr <= '0;
                    end else begin
                        vc_rr <= vc_rr + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
