`timescale 1ns/1ps

// Small-I/O implementation harness.  It generates deterministic cache traffic
// and supplies an always-correct single-outstanding lower-memory model so the
// deployable cache can be placed and routed without exporting wide CPU/memory
// buses as package pins.
module l1d_fpga_harness #(
    parameter integer ADDR_WIDTH       = 64,
    parameter integer DATA_WIDTH       = 64,
    parameter integer LINE_BYTES       = 16,
    parameter integer NUM_SETS         = 8,
    parameter integer NUM_WAYS         = 2,
    parameter integer VICTIM_ENTRIES   = 4,
    parameter integer ENABLE_PREFETCH  = 0,
    parameter integer PREFETCH_POLICY  = 1,
    parameter integer PF_OPT_LEVEL     = 1,
    parameter integer PF_USE_STREAM    = (PF_OPT_LEVEL >= 2),
    parameter integer PF_USE_ADAPTIVE  = (PF_OPT_LEVEL >= 2),
    parameter integer PF_USE_SHADOW    = (PF_OPT_LEVEL >= 3),
    parameter integer PF_USE_MSHR      = (PF_OPT_LEVEL >= 3),
    parameter integer PF_IDLE_GUARD    = 2,
    parameter integer PF_EPOCH_DEMANDS = 256,
    parameter integer PF_OFF_DEMANDS   = 512,
    parameter integer PF_PROBE_BUDGET  = 8,
    parameter integer PF_PROBE_REFILL  = 16,
    parameter integer PF_ON_REFILL     = 8,
    parameter integer VC_FORMAT_IN_SWAP = 1
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         start,
    output logic         done,
    output logic         pass,
    output logic [31:0]  signature
);
    localparam integer LINE_BITS = LINE_BYTES * 8;
    localparam integer OP_COUNT = 8;

    typedef enum logic [1:0] {
        HARNESS_IDLE,
        HARNESS_ISSUE,
        HARNESS_WAIT
    } harness_state_t;

    harness_state_t state;
    logic [3:0] op_index;
    logic run_ok;

    logic cpu_req_valid;
    logic cpu_req_ready;
    logic [ADDR_WIDTH-1:0] cpu_req_addr;
    logic cpu_rsp_valid;
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
    logic mem_read_pending;
    logic [ADDR_WIDTH-1:0] mem_read_addr;
    logic cache_idle;

    function automatic [ADDR_WIDTH-1:0] operation_addr(
        input logic [3:0] index
    );
        begin
            case (index)
                4'd0: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h100};
                4'd1: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h110};
                4'd2: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h120};
                4'd3: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h100};
                4'd4: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h180};
                4'd5: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h110};
                4'd6: operation_addr = {{(ADDR_WIDTH-12){1'b0}}, 12'h190};
                default: operation_addr =
                    {{(ADDR_WIDTH-12){1'b0}}, 12'h120};
            endcase
        end
    endfunction

    function automatic [LINE_BITS-1:0] memory_line(
        input logic [ADDR_WIDTH-1:0] line_addr
    );
        integer word;
        begin
            memory_line = {LINE_BITS{1'b0}};
            for (word = 0; word < LINE_BITS / DATA_WIDTH; word = word + 1)
                memory_line[word*DATA_WIDTH +: DATA_WIDTH] =
                    line_addr + word * (DATA_WIDTH / 8);
        end
    endfunction

    assign cpu_req_valid = (state == HARNESS_ISSUE);
    assign cpu_req_addr = operation_addr(op_index);
    assign mem_req_ready = !mem_read_pending;

    l1d_cache_deploy #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(LINE_BYTES),
        .NUM_SETS(NUM_SETS),
        .NUM_WAYS(NUM_WAYS),
        .VICTIM_ENTRIES(VICTIM_ENTRIES),
        .ENABLE_PREFETCH(ENABLE_PREFETCH),
        .PREFETCH_POLICY(PREFETCH_POLICY),
        .PF_OPT_LEVEL(PF_OPT_LEVEL),
        .PF_USE_STREAM(PF_USE_STREAM),
        .PF_USE_ADAPTIVE(PF_USE_ADAPTIVE),
        .PF_USE_SHADOW(PF_USE_SHADOW),
        .PF_USE_MSHR(PF_USE_MSHR),
        .PF_IDLE_GUARD(PF_IDLE_GUARD),
        .PF_EPOCH_DEMANDS(PF_EPOCH_DEMANDS),
        .PF_OFF_DEMANDS(PF_OFF_DEMANDS),
        .PF_PROBE_BUDGET(PF_PROBE_BUDGET),
        .PF_PROBE_REFILL(PF_PROBE_REFILL),
        .PF_ON_REFILL(PF_ON_REFILL),
        .VC_FORMAT_IN_SWAP(VC_FORMAT_IN_SWAP)
    ) u_cache (
        .clk(clk),
        .rst_n(rst_n),
        .cfg_prefetch_enable(ENABLE_PREFETCH != 0),
        .cfg_next_line_enable(ENABLE_PREFETCH != 0),
        .cpu_req_valid(cpu_req_valid),
        .cpu_req_ready(cpu_req_ready),
        .cpu_req_addr(cpu_req_addr),
        .cpu_req_write(1'b0),
        .cpu_req_size(2'b11),
        .cpu_req_unsigned(1'b0),
        .cpu_req_wdata({DATA_WIDTH{1'b0}}),
        .cpu_rsp_valid(cpu_rsp_valid),
        .cpu_rsp_ready(1'b1),
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
        .cache_idle(cache_idle)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= HARNESS_IDLE;
            op_index <= 4'd0;
            run_ok <= 1'b1;
            done <= 1'b0;
            pass <= 1'b0;
            signature <= 32'h1dca_4700;
            mem_rsp_valid <= 1'b0;
            mem_rsp_rdata <= {LINE_BITS{1'b0}};
            mem_read_pending <= 1'b0;
            mem_read_addr <= {ADDR_WIDTH{1'b0}};
        end else begin
            mem_rsp_valid <= mem_read_pending;
            if (mem_read_pending)
                mem_rsp_rdata <= memory_line(mem_read_addr);
            mem_read_pending <= 1'b0;

            if (mem_req_valid && mem_req_ready && !mem_req_write) begin
                mem_read_pending <= 1'b1;
                mem_read_addr <= mem_req_addr;
            end

            case (state)
                HARNESS_IDLE: begin
                    if (!start)
                        done <= 1'b0;
                    if (start && !done) begin
                        op_index <= 4'd0;
                        run_ok <= 1'b1;
                        pass <= 1'b0;
                        signature <= 32'h1dca_4700;
                        state <= HARNESS_ISSUE;
                    end
                end
                HARNESS_ISSUE: begin
                    if (cpu_req_ready)
                        state <= HARNESS_WAIT;
                end
                HARNESS_WAIT: begin
                    if (cpu_rsp_valid) begin
                        signature <= {signature[30:0], signature[31]} ^
                                     cpu_rsp_rdata[31:0] ^
                                     cpu_req_addr[31:0];
                        if (cpu_rsp_error ||
                            cpu_rsp_rdata != operation_addr(op_index))
                            run_ok <= 1'b0;
                        if (op_index == OP_COUNT - 1) begin
                            done <= 1'b1;
                            pass <= run_ok && !cpu_rsp_error &&
                                    (cpu_rsp_rdata == operation_addr(op_index));
                            state <= HARNESS_IDLE;
                        end else begin
                            op_index <= op_index + 1'b1;
                            state <= HARNESS_ISSUE;
                        end
                    end
                end
                default: state <= HARNESS_IDLE;
            endcase
        end
    end
endmodule
