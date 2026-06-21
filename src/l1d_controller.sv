`timescale 1ns/1ps

import l1d_cache_pkg::*;

module l1d_controller #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 32,
    parameter integer LINE_BYTES = 16,
    parameter integer LINE_BITS  = LINE_BYTES * 8,
    parameter integer WAY_BITS   = 1,
    parameter integer VC_BITS    = 1
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      arb_launch_req_valid,
    input  logic [ADDR_WIDTH-1:0]     arb_launch_req_addr,
    input  logic                      arb_launch_req_write,
    input  logic [DATA_WIDTH-1:0]     arb_launch_req_wdata,
    input  logic [(DATA_WIDTH/8)-1:0] arb_launch_req_wstrb,
    input  logic                      arb_launch_req_is_prefetch,

    input  logic                      l1_hit_comb,
    input  logic [WAY_BITS-1:0]       hit_way_comb,
    input  logic                      victim_hit_valid_comb,
    input  logic [VC_BITS-1:0]        victim_hit_comb,
    input  logic                      invalid_way_valid_comb,
    input  logic [WAY_BITS-1:0]       invalid_way_comb,

    input  logic [WAY_BITS-1:0]       replacement_way_current,
    input  logic [VC_BITS-1:0]        victim_rr_index_current,
    input  logic [ADDR_WIDTH-1:0]     replacement_line_addr_current,
    input  logic [LINE_BITS-1:0]      replacement_line_data_current,
    input  logic                      replacement_line_dirty_current,
    input  logic                      replacement_line_prefetched_current,

    input  logic [LINE_BITS-1:0]      hit_line_data_current,
    input  logic [LINE_BITS-1:0]      victim_line_data_current,
    input  logic                      victim_line_dirty_current,

    input  logic                      victim_rr_valid_current,
    input  logic                      victim_rr_dirty_current,
    input  logic [ADDR_WIDTH-1:0]     victim_rr_addr_current,
    input  logic [LINE_BITS-1:0]      victim_rr_data_current,

    input  logic                      mem_req_ready,
    input  logic                      mem_rsp_valid,
    input  logic [LINE_BITS-1:0]      mem_rsp_rdata,
    input  logic                      cpu_rsp_ready,

    output state_t                    state,
    output logic [ADDR_WIDTH-1:0]     req_addr,
    output logic                      req_write,
    output logic [DATA_WIDTH-1:0]     req_wdata,
    output logic [(DATA_WIDTH/8)-1:0] req_wstrb,
    output logic                      req_is_prefetch,
    output logic [WAY_BITS-1:0]       selected_way,
    output logic [VC_BITS-1:0]        selected_vc,
    output logic [LINE_BITS-1:0]      working_line,
    output logic                      working_dirty,
    output logic [LINE_BITS-1:0]      fill_line,
    output logic                      evicted_valid,
    output logic                      evicted_dirty,
    output logic                      evicted_prefetched,
    output logic [ADDR_WIDTH-1:0]     evicted_addr,
    output logic [LINE_BITS-1:0]      evicted_data,
    output logic [ADDR_WIDTH-1:0]     wb_addr,
    output logic [LINE_BITS-1:0]      wb_data,
    output logic [DATA_WIDTH-1:0]     response_data
);
    localparam integer WORD_BYTES = DATA_WIDTH / 8;

    function automatic [DATA_WIDTH-1:0] line_word(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr
    );
        integer word_index;
        begin
            word_index = (addr >> $clog2(WORD_BYTES)) %
                         (LINE_BYTES / WORD_BYTES);
            line_word = line[word_index*DATA_WIDTH +: DATA_WIDTH];
        end
    endfunction

    function automatic [LINE_BITS-1:0] merge_word(
        input logic [LINE_BITS-1:0] line,
        input logic [ADDR_WIDTH-1:0] addr,
        input logic [DATA_WIDTH-1:0] wdata,
        input logic [WORD_BYTES-1:0] wstrb
    );
        integer word_index;
        integer byte_index;
        logic [LINE_BITS-1:0] result;
        begin
            result = line;
            word_index = (addr >> $clog2(WORD_BYTES)) %
                         (LINE_BYTES / WORD_BYTES);
            for (byte_index = 0; byte_index < WORD_BYTES; byte_index = byte_index + 1) begin
                if (wstrb[byte_index]) begin
                    result[(word_index*DATA_WIDTH)+(byte_index*8) +: 8] =
                        wdata[(byte_index*8) +: 8];
                end
            end
            merge_word = result;
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            req_addr <= '0;
            req_write <= 1'b0;
            req_wdata <= '0;
            req_wstrb <= '0;
            req_is_prefetch <= 1'b0;
            selected_way <= '0;
            selected_vc <= '0;
            working_line <= '0;
            working_dirty <= 1'b0;
            fill_line <= '0;
            evicted_valid <= 1'b0;
            evicted_dirty <= 1'b0;
            evicted_prefetched <= 1'b0;
            evicted_addr <= '0;
            evicted_data <= '0;
            wb_addr <= '0;
            wb_data <= '0;
            response_data <= '0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (arb_launch_req_valid) begin
                        req_addr <= arb_launch_req_addr;
                        req_write <= arb_launch_req_write;
                        req_wdata <= arb_launch_req_wdata;
                        req_wstrb <= arb_launch_req_wstrb;
                        req_is_prefetch <= arb_launch_req_is_prefetch;
                        state <= ST_LOOKUP;
                    end
                end

                ST_LOOKUP: begin
                    if (l1_hit_comb) begin
                        selected_way <= hit_way_comb;
                        if (req_is_prefetch) begin
                            state <= ST_IDLE;
                        end else if (req_write) begin
                            working_line <= merge_word(
                                hit_line_data_current, req_addr,
                                req_wdata, req_wstrb
                            );
                            response_data <= line_word(
                                merge_word(hit_line_data_current, req_addr,
                                           req_wdata, req_wstrb),
                                req_addr
                            );
                            state <= ST_HIT_WRITE;
                        end else begin
                            response_data <= line_word(
                                hit_line_data_current, req_addr
                            );
                            state <= ST_RESP;
                        end
                    end else if (victim_hit_valid_comb) begin
                        if (req_is_prefetch) begin
                            state <= ST_IDLE;
                        end else begin
                            selected_vc <= victim_hit_comb;
                            if (invalid_way_valid_comb) begin
                                selected_way <= invalid_way_comb;
                            end else begin
                                selected_way <= replacement_way_current;
                            end

                            evicted_valid <= !invalid_way_valid_comb;
                            if (invalid_way_valid_comb) begin
                                evicted_dirty <= 1'b0;
                                evicted_prefetched <= 1'b0;
                                evicted_addr <= '0;
                                evicted_data <= '0;
                            end else begin
                                evicted_dirty <= replacement_line_dirty_current;
                                evicted_prefetched <= replacement_line_prefetched_current;
                                evicted_addr <= replacement_line_addr_current;
                                evicted_data <= replacement_line_data_current;
                            end

                            if (req_write) begin
                                working_line <= merge_word(
                                    victim_line_data_current, req_addr,
                                    req_wdata, req_wstrb
                                );
                                working_dirty <= 1'b1;
                                response_data <= line_word(
                                    merge_word(victim_line_data_current, req_addr,
                                               req_wdata, req_wstrb),
                                    req_addr
                                );
                            end else begin
                                working_line <= victim_line_data_current;
                                working_dirty <= victim_line_dirty_current;
                                response_data <= line_word(
                                    victim_line_data_current, req_addr
                                );
                            end
                            state <= ST_VC_SWAP;
                        end
                    end else begin
                        if (invalid_way_valid_comb) begin
                            selected_way <= invalid_way_comb;
                            evicted_valid <= 1'b0;
                            evicted_dirty <= 1'b0;
                            evicted_prefetched <= 1'b0;
                            evicted_addr <= '0;
                            evicted_data <= '0;
                            state <= ST_MEM_READ_REQ;
                        end else begin
                            selected_way <= replacement_way_current;
                            evicted_valid <= 1'b1;
                            evicted_dirty <= replacement_line_dirty_current;
                            evicted_prefetched <= replacement_line_prefetched_current;
                            evicted_addr <= replacement_line_addr_current;
                            evicted_data <= replacement_line_data_current;
                            selected_vc <= victim_rr_index_current;
                            if (victim_rr_valid_current && victim_rr_dirty_current) begin
                                wb_addr <= victim_rr_addr_current;
                                wb_data <= victim_rr_data_current;
                                state <= ST_WB_REQ;
                            end else begin
                                state <= ST_VC_INSERT;
                            end
                        end
                    end
                end

                ST_HIT_WRITE: begin
                    state <= ST_RESP;
                end

                ST_VC_SWAP: begin
                    state <= ST_RESP;
                end

                ST_WB_REQ: begin
                    if (mem_req_ready) begin
                        state <= ST_VC_INSERT;
                    end
                end

                ST_VC_INSERT: begin
                    state <= ST_MEM_READ_REQ;
                end

                ST_MEM_READ_REQ: begin
                    if (mem_req_ready) begin
                        state <= ST_MEM_READ_WAIT;
                    end
                end

                ST_MEM_READ_WAIT: begin
                    if (mem_rsp_valid) begin
                        if (!req_is_prefetch && req_write) begin
                            fill_line <= merge_word(
                                mem_rsp_rdata, req_addr, req_wdata, req_wstrb
                            );
                            response_data <= line_word(
                                merge_word(mem_rsp_rdata, req_addr,
                                           req_wdata, req_wstrb),
                                req_addr
                            );
                        end else begin
                            fill_line <= mem_rsp_rdata;
                            response_data <= line_word(mem_rsp_rdata, req_addr);
                        end
                        state <= ST_INSTALL;
                    end
                end

                ST_INSTALL: begin
                    if (req_is_prefetch) begin
                        state <= ST_IDLE;
                    end else begin
                        state <= ST_RESP;
                    end
                end

                ST_RESP: begin
                    if (cpu_rsp_ready) begin
                        state <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
