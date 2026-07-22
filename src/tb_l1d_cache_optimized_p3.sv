`timescale 1ns/1ps
module tb_l1d_cache_optimized_p3;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic cfg_prefetch_enable=1, cfg_next_line_enable=0;
  logic ext_prefetch_valid=0, ext_prefetch_ready;
  logic [63:0] ext_prefetch_addr=0;
  logic cpu_req_valid=0, cpu_req_ready, cpu_req_write=0;
  logic [63:0] cpu_req_addr=0, cpu_req_wdata=0;
  logic [1:0] cpu_req_size=2'b11;
  logic cpu_req_unsigned=1;
  logic cpu_rsp_valid, cpu_rsp_ready=1;
  logic [63:0] cpu_rsp_rdata;
  logic cpu_rsp_error;
  logic [1:0] cpu_rsp_error_cause;
  logic mem_req_valid, mem_req_ready=1, mem_req_write;
  logic [63:0] mem_req_addr;
  logic [127:0] mem_req_wdata;
  logic mem_rsp_valid=0;
  logic [127:0] mem_rsp_rdata=0;
  logic read_outstanding=0;
  logic [63:0] last_read_addr=0;
  integer reads=0;
  integer check_i;
  integer response_i;
  integer late_merge_events=0;
  logic [31:0] stat_cpu_hits, stat_cpu_misses, stat_victim_hits;
  logic [31:0] stat_writebacks, stat_prefetch_fills;
  logic [31:0] stat_prefetch_useful, stat_prefetch_useless;
  logic [31:0] stat_prefetch_pollution, stat_prefetch_dropped;
  logic [31:0] stat_pf_candidates, stat_pf_admitted, stat_pf_issued;
  logic [31:0] stat_pf_returned, stat_pf_installed, stat_pf_merged;
  logic [31:0] stat_pf_discarded, stat_pf_cancelled;
  logic [31:0] stat_pf_unused_evicted, stat_pf_vc_bypass;
  logic [31:0] stat_pf_caused_writebacks, stat_pf_demand_block_cycles;
  logic [31:0] stat_pf_true_help, stat_pf_true_pollution;
  logic [31:0] stat_pf_suppressed_quota, stat_pf_suppressed_unsafe;
  logic [31:0] stat_pf_same_line_coalesced;
  logic cache_idle;
  logic [3:0] debug_state;
  logic debug_req_is_prefetch;
  logic debug_pf_mshr_valid;
  logic [63:0] debug_pf_mshr_addr;
  logic [1:0] debug_pf_mshr_confidence;

  initial begin
    #100000;
    $fatal(1,"timeout t=%0t state=%0d mshr=%0b pending=%0b outstanding=%0b",
           $time,debug_state,debug_pf_mshr_valid,dut.pf_response_pending,
           read_outstanding);
  end

  l1d_cache_optimized #(.NUM_SETS(4), .PF_OPT_LEVEL(3)) dut (
    .clk, .rst_n, .cfg_prefetch_enable, .cfg_next_line_enable,
    .ext_prefetch_valid, .ext_prefetch_ready, .ext_prefetch_addr,
    .cpu_req_valid, .cpu_req_ready, .cpu_req_addr, .cpu_req_write,
    .cpu_req_size, .cpu_req_unsigned, .cpu_req_wdata,
    .cpu_rsp_valid, .cpu_rsp_ready, .cpu_rsp_rdata, .cpu_rsp_error,
    .cpu_rsp_error_cause, .mem_req_valid, .mem_req_ready, .mem_req_write,
    .mem_req_addr, .mem_req_wdata, .mem_rsp_valid, .mem_rsp_rdata,
    .stat_cpu_hits, .stat_cpu_misses, .stat_victim_hits, .stat_writebacks,
    .stat_prefetch_fills, .stat_prefetch_useful, .stat_prefetch_useless,
    .stat_prefetch_pollution, .stat_prefetch_dropped, .cache_idle,
    .debug_state, .debug_req_is_prefetch,
    .stat_pf_candidates, .stat_pf_admitted, .stat_pf_issued,
    .stat_pf_returned, .stat_pf_installed, .stat_pf_merged,
    .stat_pf_discarded, .stat_pf_cancelled, .stat_pf_unused_evicted,
    .stat_pf_vc_bypass, .stat_pf_caused_writebacks,
    .stat_pf_demand_block_cycles, .stat_pf_true_help,
    .stat_pf_true_pollution, .stat_pf_suppressed_quota,
    .stat_pf_suppressed_unsafe, .stat_pf_same_line_coalesced,
    .debug_pf_mshr_valid, .debug_pf_mshr_addr,
    .debug_pf_mshr_confidence
  );

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_outstanding <= 0;
      last_read_addr <= 0;
      reads <= 0;
      late_merge_events <= 0;
    end else begin
      if (mem_req_valid && mem_req_ready && !mem_req_write) begin
        if (read_outstanding) $fatal(1,"more than one lower read");
        read_outstanding <= 1;
        last_read_addr <= mem_req_addr;
        reads <= reads+1;
      end
      if (mem_rsp_valid) read_outstanding <= 0;
      if (dut.pf_late_merge_event)
        late_merge_events <= late_merge_events + 1;
    end
  end

  task automatic reset_dut;
    begin
      @(negedge clk); rst_n=0; ext_prefetch_valid=0; cpu_req_valid=0;
      mem_rsp_valid=0; cfg_prefetch_enable=1; cpu_rsp_ready=1;
      mem_req_ready=1;
      repeat(3) @(posedge clk); @(negedge clk); rst_n=1;
    end
  endtask

  task automatic respond_line(input logic [127:0] line);
    begin
      wait(read_outstanding);
      @(negedge clk); mem_rsp_rdata=line; mem_rsp_valid=1;
      @(posedge clk); @(negedge clk); mem_rsp_valid=0;
    end
  endtask

  task automatic issue_pf(input logic [63:0] addr);
    begin
      @(negedge clk); ext_prefetch_addr=addr; ext_prefetch_valid=1;
      do @(posedge clk); while(!ext_prefetch_ready);
      @(negedge clk); ext_prefetch_valid=0;
      wait(debug_pf_mshr_valid && read_outstanding);
    end
  endtask

  task automatic enqueue_pf(input logic [63:0] addr);
    begin
      @(negedge clk); ext_prefetch_addr=addr; ext_prefetch_valid=1;
      do @(posedge clk); while(!ext_prefetch_ready);
      @(negedge clk); ext_prefetch_valid=0;
    end
  endtask

  task automatic start_req(input logic [63:0] addr, input logic wr,
                           input logic [63:0] wdata);
    begin
      @(negedge clk); cpu_req_addr=addr; cpu_req_write=wr;
      cpu_req_wdata=wdata; cpu_req_valid=1;
      do @(posedge clk); while(!cpu_req_ready);
      @(negedge clk); cpu_req_valid=0;
    end
  endtask

  task automatic wait_rsp(input logic [63:0] expected);
    integer n;
    begin
      n=0;
      while(!cpu_rsp_valid && n<100) begin @(posedge clk); n=n+1; end
      if(!cpu_rsp_valid) $fatal(1,"CPU response timeout state=%0d",debug_state);
      if(cpu_rsp_rdata !== expected)
        $fatal(1,"bad CPU data got=%h expected=%h",cpu_rsp_rdata,expected);
      @(posedge clk);
    end
  endtask

  initial begin
    // A speculative lookup has not yet declared mem_req_valid.  A demand that
    // becomes visible in this cancellation window must abort the PF and be
    // accepted on the following cycle; no lower PF read may be issued.
    $display("P3 scenario lookup cancellation start");
    reset_dut();
    enqueue_pf(64'h1040);
    wait(debug_state == 4'd1 && debug_req_is_prefetch);
    @(negedge clk); cpu_req_addr=64'h2000; cpu_req_write=0;
    cpu_req_wdata=0; cpu_req_valid=1;
    @(posedge clk); @(negedge clk);
    if(debug_state != 4'd0 || mem_req_valid || stat_pf_issued != 0 ||
       stat_pf_cancelled != 1 || dut.prefetch_controller.tokens != 1 ||
       dut.prefetch_controller.probe_issues != 0 ||
       dut.prefetch_controller.epoch_pf_issued != 0 ||
       dut.controller_cost != stat_pf_demand_block_cycles)
      $fatal(1,"lookup PF cancellation mismatch state=%0d mem_valid=%0b issued=%0d cancelled=%0d tokens=%0d probe=%0d epoch_issued=%0d cost=%0d blocked=%0d",
             debug_state, mem_req_valid, stat_pf_issued, stat_pf_cancelled,
             dut.prefetch_controller.tokens,
             dut.prefetch_controller.probe_issues,
             dut.prefetch_controller.epoch_pf_issued, dut.controller_cost,
             stat_pf_demand_block_cycles);
    if(!cpu_req_ready)
      $fatal(1,"demand was not given priority after lookup cancellation");
    @(posedge clk); @(negedge clk); cpu_req_valid=0;
    wait(read_outstanding && last_read_addr==64'h2000);
    respond_line(128'h0_3333333333333333);
    wait_rsp(64'h3333333333333333);

    // Fault-inject the otherwise excluded overlap to lock down the lower-port
    // arbiter invariant: a state-owned demand read must suppress a pending
    // background PF grant and its issue accounting.  This protects future FSM
    // changes from treating mem_req_ready as a handshake for the wrong owner.
    $display("P3 scenario explicit lower-read arbitration start");
    reset_dut();
    force dut.pf_mshr_valid = 1'b1;
    force dut.pf_mshr_issued = 1'b0;
    force dut.pf_mshr_addr = 64'h4140;
    force dut.req_addr = 64'h5200;
    force dut.req_is_prefetch = 1'b0;
    force dut.state = 4'd6; // ST_MEM_READ_REQ
    #1;
    if(!dut.background_pf_request || dut.background_pf_grant ||
       dut.background_pf_issue || !mem_req_valid || mem_req_write ||
       mem_req_addr!=64'h5200 || debug_req_is_prefetch)
      $fatal(1,"demand lower read did not own explicit PF arbitration");
    release dut.state;
    release dut.req_is_prefetch;
    release dut.req_addr;
    release dut.pf_mshr_addr;
    release dut.pf_mshr_issued;
    release dut.pf_mshr_valid;

    // A full FIFO can replace or expire its head without deasserting valid.
    // The cache must publish a new identity for the changed head exactly once.
    $display("P3 scenario candidate head turnover start");
    reset_dut(); cfg_next_line_enable=0;
    force dut.stream_candidate_valid = 1'b1;
    force dut.stream_candidate_addr = 64'h7e00;
    force dut.stream_candidate_confidence = 2'b01;
    force dut.stream_candidate_id = 2'b00;
    force dut.stream_candidate_generation = 2'b01;
    @(posedge clk); @(negedge clk);
    if(stat_pf_candidates!=1 || dut.stream_candidate_new)
      $fatal(1,"initial forced candidate identity was not sampled once");
    force dut.stream_candidate_addr = 64'h7e40;
    force dut.stream_candidate_generation = 2'b10;
    #1;
    if(!dut.stream_candidate_new)
      $fatal(1,"valid-high candidate head change was not detected");
    @(posedge clk); @(negedge clk);
    if(stat_pf_candidates!=2 || dut.stream_candidate_new ||
       dut.stream_candidate_seen_addr!=64'h7e40 ||
       dut.stream_candidate_seen_generation!=2'b10)
      $fatal(1,"changed candidate head identity was not sampled once");
    release dut.stream_candidate_valid;
    release dut.stream_candidate_addr;
    release dut.stream_candidate_confidence;
    release dut.stream_candidate_id;
    release dut.stream_candidate_generation;

    // Queue a candidate behind a demand miss.  It launches on the response
    // transfer edge, and a request already holding valid merges next cycle.
    $display("P3 scenario zero-bubble background issue start");
    reset_dut();
    start_req(64'h8000,0,0);
    wait(read_outstanding); enqueue_pf(64'h8040);
    respond_line(128'h0_1111111111111111);
    wait(cpu_rsp_valid);
    @(negedge clk); cpu_req_addr=64'h8040; cpu_req_write=0;
    cpu_req_wdata=0; cpu_req_valid=1;
    do @(posedge clk); while(!cpu_req_ready);
    @(negedge clk); cpu_req_valid=0;
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    respond_line(128'h0_2222222222222222);
    wait_rsp(64'h2222222222222222);
    if(stat_pf_issued!=1 || stat_pf_merged!=1)
      $fatal(1,"zero-bubble background issue/merge missing");

    // The registered scheduler must advertise and hold one stable PF request
    // while lower memory is backpressured.  Admission alone must not consume a
    // token; the request and the waiting same-line demand complete normally
    // after the eventual handshake.
    $display("P3 scenario registered scheduler backpressure start");
    reset_dut();
    start_req(64'h8100,0,0);
    wait(read_outstanding); enqueue_pf(64'h8140);
    respond_line(128'h0_0101010101010101);
    wait(cpu_rsp_valid);
    @(negedge clk); mem_req_ready=0; cpu_req_addr=64'h8140;
    cpu_req_write=0; cpu_req_wdata=0; cpu_req_valid=1;
    @(posedge clk); // capture S0 while the previous response transfers
    @(negedge clk);
    if(!mem_req_valid || mem_req_write || mem_req_addr!=64'h8140 ||
       !dut.pf_mshr_valid || dut.pf_mshr_issued || stat_pf_admitted!=1 ||
       stat_pf_issued!=0 || dut.prefetch_controller.tokens!=1)
      $fatal(1,"registered PF request was not admitted before handshake");
    if(!cpu_req_ready)
      $fatal(1,"registered PF request suppressed the next demand handshake");
    @(posedge clk); // accept the same-line demand while PF remains stalled
    @(negedge clk); cpu_req_valid=0;
    repeat(3) begin
      if(!mem_req_valid || mem_req_write || mem_req_addr!=64'h8140 ||
         dut.pf_mshr_issued || stat_pf_issued!=0 ||
         dut.prefetch_controller.tokens!=1)
        $fatal(1,"stalled registered PF payload/accounting changed");
      @(posedge clk); @(negedge clk);
    end
    mem_req_ready=1;
    @(posedge clk); @(negedge clk);
    if(!dut.pf_mshr_issued || stat_pf_issued!=1 ||
       dut.prefetch_controller.tokens!=0 ||
       dut.prefetch_controller.probe_issues!=1)
      $fatal(1,"registered PF handshake did not charge exactly once");
    respond_line(128'h0_0202020202020202);
    wait_rsp(64'h0202020202020202);
    if(stat_pf_merged!=1 || stat_pf_discarded!=0)
      $fatal(1,"stalled registered PF did not merge after handshake");

    // A resident hit completes while an unrelated PF read is still in flight.
    $display("P3 scenario hit-under start");
    reset_dut(); cfg_prefetch_enable=0;
    start_req(64'h1000,0,0); respond_line(128'h0_0123456789abcdef);
    wait_rsp(64'h0123456789abcdef);
    cfg_prefetch_enable=1; issue_pf(64'h2040);
    start_req(64'h1000,0,0); wait_rsp(64'h0123456789abcdef);
    if(!read_outstanding || stat_cpu_hits!=1)
      $fatal(1,"PF flight blocked an independent L1 hit");
    respond_line(128'h0_1111222233334444);
    wait(!debug_pf_mshr_valid);

    // A detached PF response has no lower-memory backpressure.  If it returns
    // while an unrelated CPU hit response is held, capture it immediately,
    // discard it within two cycles, and preserve the CPU response payload.
    $display("P3 scenario backpressured CPU response start");
    reset_dut(); cfg_prefetch_enable=0;
    start_req(64'h9000,0,0); respond_line(128'h0_0123456789abcdef);
    wait_rsp(64'h0123456789abcdef);
    if(dut.miss_penalty_ewma==0 || dut.miss_penalty_ewma==8)
      $fatal(1,"miss penalty EWMA did not update after lower miss: %0d",
             dut.miss_penalty_ewma);
    cfg_prefetch_enable=1; issue_pf(64'ha040);
    @(negedge clk); cpu_rsp_ready=0;
    start_req(64'h9000,0,0);
    wait(cpu_rsp_valid);
    if(cpu_rsp_rdata!==64'h0123456789abcdef)
      $fatal(1,"unexpected held CPU response before PF return");
    respond_line(128'h0_bad0bad0bad0bad0);
    if(!dut.pf_response_pending || stat_pf_returned!=1)
      $fatal(1,"PF response was not captured during CPU backpressure");
    if(!cpu_rsp_valid || cpu_rsp_rdata!==64'h0123456789abcdef)
      $fatal(1,"PF response corrupted held CPU response on capture");
    repeat(2) @(posedge clk);
    @(negedge clk);
    if(debug_pf_mshr_valid || dut.pf_response_pending ||
       stat_pf_discarded!=1 || stat_pf_installed!=0)
      $fatal(1,"backpressured PF response was not discarded in two cycles");
    if(!cpu_rsp_valid || cpu_rsp_rdata!==64'h0123456789abcdef)
      $fatal(1,"held CPU response changed while PF response expired");
    cpu_rsp_ready=1;
    wait_rsp(64'h0123456789abcdef);

    // If a captured PF response and a waiting demand reach IDLE together,
    // demand owns the SRAM port.  The speculative response may expire, but it
    // must never insert/revalidate ahead of the already-present CPU request.
    $display("P3 scenario demand priority over PF response start");
    reset_dut(); cfg_prefetch_enable=0;
    start_req(64'hd000,0,0); respond_line(128'h0_55aa55aa55aa55aa);
    wait_rsp(64'h55aa55aa55aa55aa);
    cfg_prefetch_enable=1; issue_pf(64'he040);
    @(negedge clk); cpu_rsp_ready=0;
    start_req(64'hd000,0,0);
    wait(cpu_rsp_valid);
    respond_line(128'h0_1111222233334444);
    if(!dut.pf_response_pending)
      $fatal(1,"PF response was not captured before demand-priority test");
    @(negedge clk); cpu_req_addr=64'hd000; cpu_req_write=0;
    cpu_req_wdata=0; cpu_req_valid=1; cpu_rsp_ready=1;
    @(posedge clk); // transfer the held response and return to IDLE
    @(negedge clk);
    if(!cpu_req_ready)
      $fatal(1,"pending PF response suppressed demand ready in IDLE");
    @(posedge clk); // demand must win the IDLE array arbitration
    @(negedge clk); cpu_req_valid=0;
    wait_rsp(64'h55aa55aa55aa55aa);
    if(stat_pf_installed!=0 || stat_pf_discarded!=1 || stat_cpu_hits!=2)
      $fatal(1,"demand priority/PF discard lifecycle mismatch");

    // The external skid entry has a 16-accepted-demand TTL.  Keep it from
    // issuing with a continuous stream of unrelated L1 hits: the two-cycle
    // idle guard prevents the single idle response bubble from admitting it.
    $display("P3 scenario external skid TTL start");
    reset_dut(); cfg_prefetch_enable=0;
    start_req(64'hb000,0,0); respond_line(128'h0_1122334455667788);
    wait_rsp(64'h1122334455667788);
    cfg_prefetch_enable=1; enqueue_pf(64'hb040);
    cpu_req_addr=64'hb000; cpu_req_write=0; cpu_req_wdata=0;
    cpu_req_valid=1; check_i=0; response_i=0;
    while(response_i<16) begin
      @(posedge clk);
      if(cpu_req_valid && cpu_req_ready) check_i=check_i+1;
      if(cpu_rsp_valid && cpu_rsp_ready) begin
        if(cpu_rsp_rdata!==64'h1122334455667788)
          $fatal(1,"bad CPU hit while aging external skid");
        response_i=response_i+1;
      end
      @(negedge clk);
      if(!dut.ext_pending_valid && check_i<16)
        $fatal(1,"external skid expired after only %0d demands",check_i);
    end
    cpu_req_valid=0;
    if(check_i!=16)
      $fatal(1,"external skid TTL drove %0d accepts, expected 16",check_i);
    if(dut.ext_pending_valid || stat_pf_cancelled!=1 ||
       stat_prefetch_dropped!=1 || stat_pf_issued!=0 ||
       stat_pf_admitted!=0)
      $fatal(1,"external skid did not expire on demand 16");

    // Seven dirty misses to one two-way set fill the four-entry victim cache
    // and force its first dirty replacement.  The observed writeback must
    // update the nonzero 1/8-EWMA penalty from its reset value.
    $display("P3 scenario writeback penalty EWMA start");
    reset_dut(); cfg_prefetch_enable=0;
    for(check_i=0; check_i<7; check_i=check_i+1) begin
      start_req(64'hc000 + check_i*64,1,
                64'hface000000000000 + check_i);
      respond_line(128'b0);
      wait_rsp(64'hface000000000000 + check_i);
    end
    if(stat_writebacks==0)
      $fatal(1,"directed dirty VC sequence did not write back");
    if(dut.wb_penalty_ewma==0 || dut.wb_penalty_ewma==8)
      $fatal(1,"writeback penalty EWMA did not update: %0d",
             dut.wb_penalty_ewma);

    // Same-line load merges into the MSHR and is served by its response.
    $display("P3 scenario load merge start");
    reset_dut(); issue_pf(64'h3000);
    if(dut.prefetch_controller.tokens != 0 ||
       dut.prefetch_controller.probe_issues != 1 || dut.controller_cost != 1)
      $fatal(1,"actual PF handshake did not consume exactly one issue token");
    start_req(64'h3000,0,0);
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    respond_line(128'h0_a5a5a5a55a5a5a5a);
    wait_rsp(64'ha5a5a5a55a5a5a5a);
    if(stat_pf_merged!=1 || stat_pf_installed!=0 ||
       stat_pf_same_line_coalesced!=1)
      $fatal(1,"same-line load lifecycle mismatch");

    // A same-line merge is not causal help when the demand-only shadow would
    // have hit.  Populate both caches through demand, remove only the actual
    // copy to model prior speculative pollution, then merge the refetch.
    $display("P3 scenario noncausal shadow-hit merge start");
    reset_dut(); cfg_prefetch_enable=0;
    start_req(64'h3400,0,0);
    respond_line(128'h0_3333444455556666);
    wait_rsp(64'h3333444455556666);
    @(negedge clk);
    dut.valid_bits[0][0]=1'b0;
    dut.dirty_bits[0][0]=1'b0;
    dut.prefetched_bits[0][0]=1'b0;
    cfg_prefetch_enable=1;
    issue_pf(64'h3400);
    start_req(64'h3400,0,0);
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    respond_line(128'h0_777788889999aaaa);
    wait_rsp(64'h777788889999aaaa);
    if(stat_pf_merged!=1 || late_merge_events!=0 || dut.controller_saved!=0)
      $fatal(1,"shadow-hit merge received non-causal late-merge reward");

    // A causal merge that waits at least the estimated miss penalty has saved
    // no cycles.  It remains a merge, but its controller credit must be zero.
    $display("P3 scenario zero-savings merge start");
    reset_dut(); issue_pf(64'h3800);
    start_req(64'h3800,0,0);
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    repeat(10) @(posedge clk);
    respond_line(128'h0_bbbbccccddddeeee);
    wait_rsp(64'hbbbbccccddddeeee);
    if(stat_pf_merged!=1 || late_merge_events!=1 ||
       dut.late_merge_credit!=0 || dut.controller_saved!=0)
      $fatal(1,"no-savings merge received nonzero controller credit");

    // A merged store updates refill data, returns it, and installs dirty.
    $display("P3 scenario store merge start");
    reset_dut(); issue_pf(64'h4000);
    start_req(64'h4000,1,64'hfeedfacecafebeef);
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    respond_line(128'h0_0102030405060708);
    wait_rsp(64'hfeedfacecafebeef);
    if(stat_pf_merged!=1) $fatal(1,"same-line store did not merge");
    start_req(64'h4000,0,0); wait_rsp(64'hfeedfacecafebeef);

    // A different lower miss discards the PF response, then issues demand.
    $display("P3 scenario different miss start");
    reset_dut(); issue_pf(64'h5000);
    start_req(64'h6040,0,0);
    wait(dut.pf_waiter_valid && !dut.pf_waiter_same_line);
    respond_line(128'h0_deadbeefdeadbeef);
    wait(read_outstanding && last_read_addr==64'h6040);
    respond_line(128'h0_8877665544332211);
    wait_rsp(64'h8877665544332211);
    if(stat_pf_discarded!=1 || stat_pf_installed!=0)
      $fatal(1,"different-line conflict did not discard PF");

    // Disable after issue: response is captured, then rejected at revalidate.
    $display("P3 scenario revalidate disable start");
    reset_dut(); issue_pf(64'h7000); cfg_prefetch_enable=0;
    respond_line(128'h0_9999999999999999);
    wait(!debug_pf_mshr_valid);
    if(stat_pf_discarded!=1) $fatal(1,"disable did not discard response");

    // Controller OFF is also a response-time cancellation condition for a
    // still-speculative line.
    $display("P3 scenario controller-off speculative discard start");
    reset_dut(); issue_pf(64'h7400);
    force dut.prefetch_controller.controller_state_reg = 2'd0;
    respond_line(128'h0_1111000022220000);
    wait(!debug_pf_mshr_valid);
    if(stat_pf_discarded!=1 || stat_pf_installed!=0)
      $fatal(1,"controller OFF did not discard speculative response");
    release dut.prefetch_controller.controller_state_reg;

    // If OFF becomes visible with the same-line demand lookup, the returned
    // line is mandatory demand data and must still merge and respond.
    $display("P3 scenario controller-off mandatory merge start");
    reset_dut(); issue_pf(64'h7800);
    start_req(64'h7800,0,0);
    force dut.prefetch_controller.controller_state_reg = 2'd0;
    wait(dut.pf_waiter_valid && dut.pf_waiter_same_line);
    respond_line(128'h0_123456789abcdef0);
    wait_rsp(64'h123456789abcdef0);
    if(stat_pf_merged!=1 || stat_pf_discarded!=0)
      $fatal(1,"controller OFF discarded mandatory demand waiter");
    release dut.prefetch_controller.controller_state_reg;

    $display("PASS P3 accounting, causal merge, registered payload stability, flight/backpressure, skid TTL, EWMA, discard/revalidate");
    $finish;
  end
endmodule
