`timescale 1ns/1ps

module l1d_prefetch_buffer #(
    parameter integer ADDR_WIDTH = 64,
    parameter integer PB_SIZE    = 4
)(
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  enable,
    input  logic                  pb_alloc_valid,
    input  logic [ADDR_WIDTH-1:0] pb_alloc_addr,
    output logic                  pb_alloc_ready,
    input  logic                  pb_fill_valid,
    input  logic [ADDR_WIDTH-1:0] pb_fill_addr,
    output logic                  pb_fill_ready,
    input  logic                  pb_free_valid,
    input  logic [ADDR_WIDTH-1:0] pb_free_addr,
    output logic                  pb_free_ready,
    input  logic [ADDR_WIDTH-1:0] pb_lookup_addr,
    output logic                  pb_lookup_hit,
    output logic                  pb_full,
    output logic                  pb_empty
);
    localparam integer PB_INDEX_BITS = (PB_SIZE > 1) ? $clog2(PB_SIZE) : 1;

    logic [ADDR_WIDTH-1:0] pb_addr [0:PB_SIZE-1];
    logic                  pb_valid [0:PB_SIZE-1];
    logic                  pb_filled [0:PB_SIZE-1];

    integer alloc_index_comb;
    integer fill_index_comb;
    integer free_index_comb;
    integer slot_index;

    always_comb begin
        pb_lookup_hit = 1'b0;
        for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
            if (pb_valid[slot_index] &&
                pb_addr[slot_index] == pb_lookup_addr) begin
                pb_lookup_hit = 1'b1;
            end
        end
    end

    always_comb begin
        pb_empty = 1'b1;
        pb_full = 1'b1;
        for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
            if (pb_valid[slot_index]) begin
                pb_empty = 1'b0;
            end else begin
                pb_full = 1'b0;
            end
        end
    end

    always_comb begin
        alloc_index_comb = -1;
        if (enable) begin
            for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
                if (!pb_valid[slot_index] && alloc_index_comb < 0) begin
                    alloc_index_comb = slot_index;
                end
            end
        end
    end

    always_comb begin
        pb_fill_ready = 1'b0;
        fill_index_comb = -1;
        if (enable) begin
            for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
                if (pb_valid[slot_index] &&
                    pb_addr[slot_index] == pb_fill_addr &&
                    !pb_filled[slot_index] &&
                    fill_index_comb < 0) begin
                    fill_index_comb = slot_index;
                    pb_fill_ready = 1'b1;
                end
            end
        end
    end

    always_comb begin
        pb_free_ready = 1'b0;
        free_index_comb = -1;
        if (enable) begin
            for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
                if (pb_valid[slot_index] &&
                    pb_addr[slot_index] == pb_free_addr &&
                    free_index_comb < 0) begin
                    free_index_comb = slot_index;
                    pb_free_ready = 1'b1;
                end
            end
        end
    end

    assign pb_alloc_ready = enable && (alloc_index_comb >= 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
                pb_valid[slot_index] <= 1'b0;
                pb_filled[slot_index] <= 1'b0;
                pb_addr[slot_index] <= '0;
            end
        end else if (!enable) begin
            for (slot_index = 0; slot_index < PB_SIZE; slot_index = slot_index + 1) begin
                pb_valid[slot_index] <= 1'b0;
                pb_filled[slot_index] <= 1'b0;
                pb_addr[slot_index] <= '0;
            end
        end else begin
            if (pb_alloc_valid && pb_alloc_ready) begin
                pb_addr[alloc_index_comb] <= pb_alloc_addr;
                pb_valid[alloc_index_comb] <= 1'b1;
                pb_filled[alloc_index_comb] <= 1'b0;
            end

            if (pb_fill_valid && pb_fill_ready) begin
                pb_filled[fill_index_comb] <= 1'b1;
            end

            if (pb_free_valid && pb_free_ready) begin
                pb_valid[free_index_comb] <= 1'b0;
                pb_filled[free_index_comb] <= 1'b0;
                pb_addr[free_index_comb] <= '0;
            end
        end
    end
endmodule
