module l1_dcache #(
    parameter int ADDR_W                = 32,
    parameter int DATA_W                = 32,
    parameter int LINE_BYTES            = 64,
    parameter int NUM_SETS              = 64,
    parameter int NUM_WAYS              = 4,
    parameter int VICTIM_DEPTH          = 4,
    parameter bit ENABLE_VICTIM_CACHE   = 1'b1,
    parameter bit ENABLE_NEXT_PREFETCH  = 1'b1,
    parameter int MSHR_DEPTH            = 2
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic                  cpu_req_valid,
    output logic                  cpu_req_ready,
    input  logic [ADDR_W-1:0]     cpu_req_addr,
    input  logic                  cpu_req_we,
    input  logic [DATA_W/8-1:0]   cpu_req_be,
    input  logic [DATA_W-1:0]     cpu_req_wdata,

    output logic                  cpu_rsp_valid,
    input  logic                  cpu_rsp_ready,
    output logic [DATA_W-1:0]     cpu_rsp_rdata,
    output logic                  cpu_rsp_err,

    output logic                  mem_req_valid,
    input  logic                  mem_req_ready,
    output logic [ADDR_W-1:0]     mem_req_addr,
    output logic                  mem_req_we,
    output logic [LINE_BYTES*8-1:0] mem_req_wdata,

    input  logic                  mem_rsp_valid,
    input  logic [LINE_BYTES*8-1:0] mem_rsp_rdata,
    input  logic                  mem_rsp_err
);

    localparam int LINE_W       = LINE_BYTES * 8;
    localparam int OFFSET_W     = (LINE_BYTES <= 1) ? 1 : $clog2(LINE_BYTES);
    localparam int INDEX_W      = (NUM_SETS   <= 1) ? 1 : $clog2(NUM_SETS);
    localparam int WORD_OFF_W   = (LINE_BYTES * 8 / DATA_W <= 1) ? 1 : $clog2(LINE_BYTES * 8 / DATA_W);
    localparam int TAG_W        = ADDR_W - INDEX_W - OFFSET_W;
    localparam int WAY_W        = (NUM_WAYS   <= 1) ? 1 : $clog2(NUM_WAYS);
    localparam int VICTIM_IDX_W = (VICTIM_DEPTH <= 1) ? 1 : $clog2(VICTIM_DEPTH);

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_TAG_LOOKUP,
        ST_HIT_RESP,
        ST_MISS_SELECT,
        ST_REFILL_REQ,
        ST_REFILL_WAIT,
        ST_EVICT_WRITEBACK
    } state_t;

    typedef struct packed {
        logic [TAG_W-1:0] tag;
        logic             valid;
        logic             dirty;
    } tag_entry_t;

    typedef struct packed {
        logic [TAG_W-1:0]    tag;
        logic [INDEX_W-1:0]  index;
        logic [LINE_W-1:0]   data;
        logic                valid;
        logic                dirty;
    } victim_entry_t;

    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic              we;
        logic [DATA_W/8-1:0] be;
        logic [DATA_W-1:0] wdata;
    } cpu_req_t;

    state_t state_q, state_d;
    cpu_req_t req_q, req_d;

    tag_entry_t   tag_array_q    [NUM_SETS][NUM_WAYS];
    logic [LINE_W-1:0] data_array_q   [NUM_SETS][NUM_WAYS];
    logic [WAY_W-1:0]  repl_ptr_q     [NUM_SETS];

    victim_entry_t victim_q [VICTIM_DEPTH];

    logic [INDEX_W-1:0] req_index;
    logic [TAG_W-1:0]   req_tag;
    logic [OFFSET_W-1:0] req_offset;

    logic [NUM_WAYS-1:0] hit_vec;
    logic                hit;
    logic [WAY_W-1:0]    hit_way;
    logic                victim_hit;
    logic [VICTIM_IDX_W-1:0] victim_hit_idx;

    logic [LINE_W-1:0] selected_line;
    logic [LINE_W-1:0] refill_line;
    logic [WAY_W-1:0]  replace_way;

    logic [ADDR_W-1:0] next_line_addr;

    assign req_offset = req_q.addr[OFFSET_W-1:0];
    assign req_index  = req_q.addr[OFFSET_W + INDEX_W - 1:OFFSET_W];
    assign req_tag    = req_q.addr[ADDR_W-1 -: TAG_W];

    always_comb begin
        hit_vec = '0;
        hit_way = '0;
        for (int way = 0; way < NUM_WAYS; way++) begin
            if (tag_array_q[req_index][way].valid &&
                tag_array_q[req_index][way].tag == req_tag) begin
                hit_vec[way] = 1'b1;
                hit_way      = way[WAY_W-1:0];
            end
        end
    end

    assign hit = |hit_vec;

    always_comb begin
        victim_hit     = 1'b0;
        victim_hit_idx = '0;
        if (ENABLE_VICTIM_CACHE) begin
            for (int i = 0; i < VICTIM_DEPTH; i++) begin
                if (victim_q[i].valid &&
                    victim_q[i].tag   == req_tag &&
                    victim_q[i].index == req_index) begin
                    victim_hit     = 1'b1;
                    victim_hit_idx = i[VICTIM_IDX_W-1:0];
                end
            end
        end
    end

    always_comb begin
        state_d        = state_q;
        req_d          = req_q;
        replace_way    = repl_ptr_q[req_index];
        selected_line  = '0;
        refill_line    = mem_rsp_rdata;
        next_line_addr = {req_q.addr[ADDR_W-1:OFFSET_W], {OFFSET_W{1'b0}}} + LINE_BYTES;

        cpu_req_ready  = 1'b0;
        cpu_rsp_valid  = 1'b0;
        cpu_rsp_rdata  = '0;
        cpu_rsp_err    = 1'b0;

        mem_req_valid  = 1'b0;
        mem_req_addr   = '0;
        mem_req_we     = 1'b0;
        mem_req_wdata  = '0;

        case (state_q)
            ST_IDLE: begin
                cpu_req_ready = 1'b1;
                if (cpu_req_valid) begin
                    req_d   = '{addr: cpu_req_addr, we: cpu_req_we, be: cpu_req_be, wdata: cpu_req_wdata};
                    state_d = ST_TAG_LOOKUP;
                end
            end

            ST_TAG_LOOKUP: begin
                if (hit) begin
                    selected_line = data_array_q[req_index][hit_way];
                    state_d       = ST_HIT_RESP;
                end else begin
                    state_d = ST_MISS_SELECT;
                end
            end

            ST_HIT_RESP: begin
                cpu_rsp_valid = 1'b1;
                cpu_rsp_rdata = extract_word(data_array_q[req_index][hit_way], req_offset);
                if (cpu_rsp_ready) begin
                    state_d = ST_IDLE;
                end
            end

            ST_MISS_SELECT: begin
                if (victim_hit) begin
                    // TODO: Swap victim entry with selected replacement way.
                    state_d = ST_HIT_RESP;
                end else begin
                    state_d = ST_REFILL_REQ;
                end
            end

            ST_REFILL_REQ: begin
                mem_req_valid = 1'b1;
                mem_req_addr  = {req_q.addr[ADDR_W-1:OFFSET_W], {OFFSET_W{1'b0}}};
                if (mem_req_ready) begin
                    state_d = ST_REFILL_WAIT;
                end
            end

            ST_REFILL_WAIT: begin
                if (mem_rsp_valid) begin
                    cpu_rsp_err = mem_rsp_err;
                    state_d     = ST_HIT_RESP;
                end
            end

            ST_EVICT_WRITEBACK: begin
                mem_req_valid = 1'b1;
                mem_req_we    = 1'b1;
                // TODO: Drive writeback address/data for dirty victim or selected way.
                if (mem_req_ready) begin
                    state_d = ST_REFILL_REQ;
                end
            end

            default: state_d = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            req_q   <= '0;

            for (int set = 0; set < NUM_SETS; set++) begin
                repl_ptr_q[set] <= '0;
                for (int way = 0; way < NUM_WAYS; way++) begin
                    tag_array_q[set][way]  <= '0;
                    data_array_q[set][way] <= '0;
                end
            end

            for (int i = 0; i < VICTIM_DEPTH; i++) begin
                victim_q[i] <= '0;
            end
        end else begin
            state_q <= state_d;
            req_q   <= req_d;

            case (state_q)
                ST_TAG_LOOKUP: begin
                    if (hit && req_q.we) begin
                        data_array_q[req_index][hit_way] <= merge_store(
                            data_array_q[req_index][hit_way],
                            req_q.wdata,
                            req_q.be,
                            req_offset
                        );
                        tag_array_q[req_index][hit_way].dirty <= 1'b1;
                    end
                end

                ST_REFILL_WAIT: begin
                    if (mem_rsp_valid && !mem_rsp_err) begin
                        data_array_q[req_index][replace_way] <= mem_rsp_rdata;
                        tag_array_q[req_index][replace_way]  <= '{
                            tag:   req_tag,
                            valid: 1'b1,
                            dirty: req_q.we
                        };
                        repl_ptr_q[req_index] <= repl_ptr_q[req_index] + 1'b1;

                        if (req_q.we) begin
                            data_array_q[req_index][replace_way] <= merge_store(
                                mem_rsp_rdata,
                                req_q.wdata,
                                req_q.be,
                                req_offset
                            );
                        end

                        if (ENABLE_NEXT_PREFETCH) begin
                            // TODO: Add a prefetch request queue or throttle logic.
                        end
                    end
                end

                default: begin
                    // Intentional no-op. State transitions handled combinationally.
                end
            endcase
        end
    end

    function automatic logic [DATA_W-1:0] extract_word(
        input logic [LINE_W-1:0] line,
        input logic [OFFSET_W-1:0] offset
    );
        int bit_idx;
        begin
            bit_idx      = (offset / (DATA_W/8)) * DATA_W;
            extract_word = line[bit_idx +: DATA_W];
        end
    endfunction

    function automatic logic [LINE_W-1:0] merge_store(
        input logic [LINE_W-1:0] line,
        input logic [DATA_W-1:0] wdata,
        input logic [DATA_W/8-1:0] be,
        input logic [OFFSET_W-1:0] offset
    );
        logic [LINE_W-1:0] merged;
        int bit_idx;
        begin
            merged  = line;
            bit_idx = (offset / (DATA_W/8)) * DATA_W;
            for (int byte = 0; byte < DATA_W/8; byte++) begin
                if (be[byte]) begin
                    merged[bit_idx + byte*8 +: 8] = wdata[byte*8 +: 8];
                end
            end
            merge_store = merged;
        end
    endfunction

endmodule
