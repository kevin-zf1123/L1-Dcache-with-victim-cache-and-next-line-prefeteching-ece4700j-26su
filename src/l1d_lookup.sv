`timescale 1ns/1ps

module l1d_lookup #(
    parameter integer ADDR_WIDTH     = 32,
    parameter integer LINE_BYTES     = 16,
    parameter integer NUM_SETS       = 8,
    parameter integer NUM_WAYS       = 2,
    parameter integer VICTIM_ENTRIES = 4,
    parameter integer LINE_BITS      = LINE_BYTES * 8,
    parameter integer TAG_BITS       = ADDR_WIDTH - $clog2(LINE_BYTES) - $clog2(NUM_SETS),
    parameter integer SET_BITS       = $clog2(NUM_SETS),
    parameter integer WAY_BITS       = (NUM_WAYS > 1) ? $clog2(NUM_WAYS) : 1,
    parameter integer VC_BITS        = (VICTIM_ENTRIES > 1) ? $clog2(VICTIM_ENTRIES) : 1
) (
    input  logic [ADDR_WIDTH-1:0] req_addr,
    input  logic [NUM_WAYS-1:0]   way_match,
    input  logic                  valid_bits [0:NUM_WAYS-1][0:NUM_SETS-1],
    input  logic                  vc_valid [0:VICTIM_ENTRIES-1],
    input  logic [ADDR_WIDTH-1:0] vc_addr [0:VICTIM_ENTRIES-1],

    output logic                  l1_hit,
    output logic [WAY_BITS-1:0]   hit_way,
    output logic                  invalid_way_valid,
    output logic [WAY_BITS-1:0]   invalid_way,
    output logic                  victim_hit_valid,
    output logic [VC_BITS-1:0]    victim_hit,
    output logic [SET_BITS-1:0]   req_set,
    output logic [TAG_BITS-1:0]   req_tag,
    output logic [ADDR_WIDTH-1:0] req_line_addr
);
    localparam integer OFFSET_BITS = $clog2(LINE_BYTES);

    integer lookup_i;
    integer hit_way_comb;
    integer invalid_way_comb;
    integer victim_hit_comb;

    function automatic [SET_BITS-1:0] address_set(
        input logic [ADDR_WIDTH-1:0] addr
    );
        address_set = (addr >> OFFSET_BITS);
    endfunction

    function automatic [TAG_BITS-1:0] address_tag(
        input logic [ADDR_WIDTH-1:0] addr
    );
        address_tag = addr[ADDR_WIDTH-1 -: TAG_BITS];
    endfunction

    function automatic [ADDR_WIDTH-1:0] line_address(
        input logic [ADDR_WIDTH-1:0] addr
    );
        line_address = {addr[ADDR_WIDTH-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
    endfunction

    always_comb begin
        req_set = address_set(req_addr);
        req_tag = address_tag(req_addr);
        req_line_addr = line_address(req_addr);

        l1_hit = 1'b0;
        hit_way_comb = 0;
        invalid_way_valid = 1'b0;
        invalid_way_comb = 0;
        for (lookup_i = 0; lookup_i < NUM_WAYS; lookup_i = lookup_i + 1) begin
            if (valid_bits[lookup_i][req_set] &&
                way_match[lookup_i]) begin
                l1_hit = 1'b1;
                hit_way_comb = lookup_i;
            end
            if (!valid_bits[lookup_i][req_set] &&
                !invalid_way_valid) begin
                invalid_way_valid = 1'b1;
                invalid_way_comb = lookup_i;
            end
        end
        hit_way = hit_way_comb[WAY_BITS-1:0];
        invalid_way = invalid_way_comb[WAY_BITS-1:0];

        victim_hit_valid = 1'b0;
        victim_hit_comb = 0;
        for (lookup_i = 0; lookup_i < VICTIM_ENTRIES; lookup_i = lookup_i + 1) begin
            if (vc_valid[lookup_i] &&
                vc_addr[lookup_i] == req_line_addr) begin
                victim_hit_valid = 1'b1;
                victim_hit_comb = lookup_i;
            end
        end
        victim_hit = victim_hit_comb[VC_BITS-1:0];
    end
endmodule
