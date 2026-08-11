// -----------------------------------------------------------------------
// Testbench for the MSHR (Miss Status Holding Register).
//
// Structure (built up incrementally):
//   1. Clock/reset generation and DUT instantiation           <- this step
//   2. AXI memory model (slave-side BFM on the same axi_if)
//   3. Driver/helper tasks (alloc_miss, push_writeback, ...)
//   4. Directed test sequences
//
// See docs/MSHR_README.md for the design rationale being
// verified here (merge-over-new-alloc, round-robin AR arbitration,
// serialized writeback).
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module mshr_tb;

    // -------------------------------------------------------------------
    // Parameters, mirrored from the DUT defaults.
    // -------------------------------------------------------------------
    localparam int ADDR_WIDTH     = 32;
    localparam int DATA_WIDTH     = 32;
    localparam int ID_WIDTH       = 4;
    localparam int LINE_WORDS     = 4;
    localparam int LINE_WIDTH     = DATA_WIDTH * LINE_WORDS;
    localparam int WB_QUEUE_DEPTH = 4;
    localparam int NUM_ENTRIES    = (1 << ID_WIDTH);      // one MSHR entry per AXI ID, matches the DUT's default
    localparam int BEAT_CNT_WIDTH = $clog2(LINE_WORDS);  // matches the DUT's internal beat counters

    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------
    // Clock / reset generation.
    // -------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
    end

    // -------------------------------------------------------------------
    // Controller-side ports: driven by the TB, sampled from the DUT.
    // -------------------------------------------------------------------
    logic                  alloc_valid;
    logic [ADDR_WIDTH-1:0] alloc_addr;
    logic                  alloc_is_write;
    logic                  alloc_ready;
    logic [ID_WIDTH-1:0]   alloc_id;

    logic                    wb_valid;
    logic [ADDR_WIDTH-1:0]   wb_addr;
    logic [LINE_WIDTH-1:0]   wb_data;
    logic                    wb_ready;
    logic                    wb_done;

    logic                  fill_valid;
    logic [ID_WIDTH-1:0]   fill_id;
    logic [ADDR_WIDTH-1:0] fill_addr;
    logic [LINE_WIDTH-1:0] fill_data;
    logic                  fill_is_write;
    logic                  fill_ready;

    // -------------------------------------------------------------------
    // AXI interface instance. The DUT drives it as .master; the TB will
    // act as the memory (.slave side) once the BFM is added in step 2.
    // -------------------------------------------------------------------
    axi_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH  (ID_WIDTH)
    ) axi ();

    // -------------------------------------------------------------------
    // DUT instantiation.
    // -------------------------------------------------------------------
    mshr #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .ID_WIDTH      (ID_WIDTH),
        .LINE_WORDS    (LINE_WORDS),
        .WB_QUEUE_DEPTH(WB_QUEUE_DEPTH)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),

        .alloc_valid   (alloc_valid),
        .alloc_addr    (alloc_addr),
        .alloc_is_write(alloc_is_write),
        .alloc_ready   (alloc_ready),
        .alloc_id      (alloc_id),

        .wb_valid      (wb_valid),
        .wb_addr       (wb_addr),
        .wb_data       (wb_data),
        .wb_ready      (wb_ready),
        .wb_done       (wb_done),

        .fill_valid    (fill_valid),
        .fill_id       (fill_id),
        .fill_addr     (fill_addr),
        .fill_data     (fill_data),
        .fill_is_write (fill_is_write),
        .fill_ready    (fill_ready),

        .axi           (axi.master)
    );

    // ===================================================================
    // Step 2: AXI memory model (slave-side BFM).
    // The TB plays the role of main memory: it accepts the DUT's AR/AW
    // requests, serves reads out of a backing array, and stores writes
    // into it. Read and write channels are modeled as two small FSMs,
    // deliberately mirroring the DUT's own fill/writeback engines so the
    // two sides of the protocol read the same way.
    // ===================================================================

    // Backing store, indexed by word address (byte address / 4 words).
    // Associative array: no fixed memory range, unused addresses simply
    // have no entry rather than wasting space on a huge static array.
    logic [DATA_WIDTH-1:0] mem [bit [ADDR_WIDTH-1:0]];

    // Preloads one full cache line before a test drives a miss to that
    // address, so the fill engine has known, checkable data to return.
    task automatic mem_write_line(input logic [ADDR_WIDTH-1:0] addr,
                                   input logic [LINE_WIDTH-1:0] line_data);
        for (int i = 0; i < LINE_WORDS; i++)
            mem[(addr >> 2) + i] = line_data[i*DATA_WIDTH +: DATA_WIDTH];
    endtask

    // -------------------------------------------------------------------
    // Read channel (AR/R) model -- mirrors the DUT's fill engine.
    // MR_IDLE : arready asserted, waiting for a request.
    // MR_DATA : streaming back LINE_WORDS beats read out of `mem`,
    //           tagged with the latched arid so the DUT's per-entry
    //           demux (fe_line_buf[axi.rid]) lands in the right entry.
    // -------------------------------------------------------------------
    typedef enum logic { MR_IDLE, MR_DATA } mr_state_e;
    mr_state_e                 mr_state;
    logic [ID_WIDTH-1:0]       mr_id;
    logic [ADDR_WIDTH-1:0]     mr_addr;
    logic [BEAT_CNT_WIDTH-1:0] mr_beat_cnt;

    // Testbench-only override: when raised, forces the read-address
    // channel to refuse every request regardless of the read model's own
    // state. Not a real protocol condition -- used by test 7 to force
    // several fill-engine entries to pile up as simultaneous requesters,
    // which never happens if requests are served as fast as they arrive.
    logic ar_block;

    assign axi.arready = (mr_state == MR_IDLE) && !ar_block;
    assign axi.rvalid  = (mr_state == MR_DATA);
    assign axi.rid     = mr_id;
    assign axi.rresp   = 2'b00;   // OKAY -- no error injection yet
    assign axi.rlast   = (mr_beat_cnt == LINE_WORDS - 1);

    // Reading an associative array through a continuous assign is not
    // reliably supported across simulators; an always_comb read is.
    // Gated to MR_DATA only -- outside a burst, mr_addr still holds its
    // reset value and indexes a `mem` entry that was never written.
    always_comb begin
        axi.rdata = '0;
        if (mr_state == MR_DATA) axi.rdata = mem[(mr_addr >> 2) + mr_beat_cnt];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mr_state    <= MR_IDLE;
            mr_beat_cnt <= '0;
        end else begin
            unique case (mr_state)
                MR_IDLE: begin
                    if (axi.arvalid && axi.arready) begin
                        mr_id       <= axi.arid;
                        mr_addr     <= axi.araddr;
                        mr_beat_cnt <= '0;
                        mr_state    <= MR_DATA;
                    end
                end
                MR_DATA: begin
                    if (axi.rvalid && axi.rready) begin
                        if (axi.rlast) mr_state <= MR_IDLE;
                        else mr_beat_cnt <= mr_beat_cnt + 1'b1;
                    end
                end
                default: mr_state <= MR_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------------------
    // Write channel (AW/W/B) model -- mirrors the DUT's writeback engine.
    // MW_IDLE : awready asserted, waiting for a victim write request.
    // MW_DATA : wready asserted, capturing LINE_WORDS beats into `mem`.
    // MW_RESP : bvalid asserted, waiting for the DUT to accept the
    //           write response (its bready is only high in WB_WAIT_B).
    // -------------------------------------------------------------------
    typedef enum logic [1:0] { MW_IDLE, MW_DATA, MW_RESP } mw_state_e;
    mw_state_e                 mw_state;
    logic [ID_WIDTH-1:0]       mw_id;
    logic [ADDR_WIDTH-1:0]     mw_addr;
    logic [BEAT_CNT_WIDTH-1:0] mw_beat_cnt;

    assign axi.awready = (mw_state == MW_IDLE);
    assign axi.wready  = (mw_state == MW_DATA);
    assign axi.bvalid  = (mw_state == MW_RESP);
    assign axi.bid     = mw_id;
    assign axi.bresp   = 2'b00;   // OKAY -- no error injection yet

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mw_state    <= MW_IDLE;
            mw_beat_cnt <= '0;
        end else begin
            unique case (mw_state)
                MW_IDLE: begin
                    if (axi.awvalid && axi.awready) begin
                        mw_id       <= axi.awid;
                        mw_addr     <= axi.awaddr;
                        mw_beat_cnt <= '0;
                        mw_state    <= MW_DATA;
                    end
                end
                MW_DATA: begin
                    if (axi.wvalid && axi.wready) begin
                        // Non-blocking assignment into an associative
                        // array element is not supported; blocking is
                        // safe here since mem is a TB-only memory model,
                        // not synthesizable register state.
                        mem[(mw_addr >> 2) + mw_beat_cnt] = axi.wdata;
                        if (axi.wlast) mw_state <= MW_RESP;
                        else mw_beat_cnt <= mw_beat_cnt + 1'b1;
                    end
                end
                MW_RESP: begin
                    if (axi.bvalid && axi.bready) mw_state <= MW_IDLE;
                end
                default: mw_state <= MW_IDLE;
            endcase
        end
    end

    // ===================================================================
    // Step 3: Driver tasks.
    // Give tests a transaction-level vocabulary (send_miss, ...) instead
    // of making every test wiggle alloc_valid/alloc_addr by hand.
    // ===================================================================

    // Reports a miss to the MSHR and blocks until it's accepted, handing
    // back the entry index the DUT assigned. Works whether the DUT is
    // free or busy: if every entry is occupied, alloc_ready simply stays
    // low and the while loop waits -- exactly what a real controller
    // would see under the same stall condition.
    task automatic send_miss(input  logic [ADDR_WIDTH-1:0] addr,
                              input  logic                  is_write,
                              output logic [ID_WIDTH-1:0]    id);
        alloc_addr     = addr;
        alloc_is_write = is_write;
        alloc_valid    = 1'b1;

        @(posedge clk);
        // alloc_ready deasserting here is genuine DUT behavior (no free or
        // matching entry) -- this loop is not simulating the stall itself,
        // only standing in for the not-yet-designed cache controller's
        // reaction to it: hold alloc_valid and keep waiting.
        while (!alloc_ready) @(posedge clk);

        id          = alloc_id;
        alloc_valid = 1'b0;
    endtask

    // Blocks until the entry `id` presents its completed fill, then
    // returns the reassembled line and the dirty/is_write flag. Relies
    // on fill_ready being held permanently high below -- this simplified
    // TB "controller" never stalls a fill, so the wait here is purely
    // about which entry is being presented this cycle, not a handshake
    // retry loop like send_miss's alloc_ready wait.
    task automatic wait_for_fill(input  logic [ID_WIDTH-1:0]   id,
                                  output logic [LINE_WIDTH-1:0] data,
                                  output logic                  is_write);
        do @(posedge clk); while (!(fill_valid && fill_id == id));
        data     = fill_data;
        is_write = fill_is_write;
    endtask

    // Hands a dirty victim line to the MSHR's writeback queue and blocks
    // until it's accepted. Mirrors send_miss's shape: if the queue is
    // full, wb_ready simply stays low and the while loop waits, standing
    // in for the not-yet-designed controller's reaction to that stall.
    task automatic push_writeback(input logic [ADDR_WIDTH-1:0] addr,
                                   input logic [LINE_WIDTH-1:0] data);
        wb_addr  = addr;
        wb_data  = data;
        wb_valid = 1'b1;

        @(posedge clk);
        while (!wb_ready) @(posedge clk);

        wb_valid = 1'b0;
    endtask

    // Blocks until the writeback engine confirms the head-of-queue victim
    // was written back (its AXI B response arrived). wb_done is a single-
    // cycle pulse, so the wait ends the instant it's seen.
    task automatic wait_for_wb_done();
        do @(posedge clk); while (!wb_done);
    endtask

    // Blocks until the read-address channel completes a handshake --
    // i.e. some fill-engine entry has just won AR arbitration -- then
    // returns the winning entry's id. Watches the AXI interface directly
    // rather than any DUT-internal arbiter state, so it observes exactly
    // what a real memory would see.
    task automatic wait_for_ar_grant(output logic [ID_WIDTH-1:0] granted_id);
        do @(posedge clk); while (!(axi.arvalid && axi.arready));
        granted_id = axi.arid;
    endtask

    // Blocks until the fill-completion mux presents and hands off some
    // entry (fill_valid && fill_ready), then returns which entry it was.
    // Mirrors wait_for_ar_grant's shape one stage further down the
    // pipeline: that task reports which entry won the AR arbiter, this
    // one reports which entry won the fill-handoff mux.
    task automatic wait_for_fill_grant(output logic [ID_WIDTH-1:0] granted_id);
        do @(posedge clk); while (!(fill_valid && fill_ready));
        granted_id = fill_id;
    endtask

    // -------------------------------------------------------------------
    // Idle-value drive for controller-side inputs. Overridden by driver
    // tasks in later steps; keeping this here means the DUT always sees
    // legal, deasserted inputs even before any stimulus exists.
    // -------------------------------------------------------------------
    initial begin
        alloc_valid    = 1'b0;
        alloc_addr     = '0;
        alloc_is_write = 1'b0;
        wb_valid       = 1'b0;
        wb_addr        = '0;
        wb_data        = '0;
        // Held permanently high: this TB models a controller that always
        // has room to accept a completed fill, the same simplification
        // the DUT itself makes on the AXI side (axi.rready tied high).
        fill_ready     = 1'b1;
        // Off by default -- only test 7 raises this to force simultaneous
        // AR requesters; every other test sees the memory model's normal
        // as-fast-as-possible accept behavior.
        ar_block       = 1'b0;
    end

    // ===================================================================
    // Test sequence. Directed tests run in order inside one initial
    // block, each reporting its own PASS/FAIL, with a single $finish
    // once every test has run.
    // ===================================================================
    initial begin
        // ---------------------------------------------------------------
        // Test 1: reset sanity check.
        // After reset, with no stimulus applied, the DUT must report a
        // free MSHR entry (alloc_ready) and an empty writeback queue
        // (wb_ready). Confirms reset correctly initializes the per-entry
        // state arrays and the FIFO pointers -- no AXI traffic yet.
        // ---------------------------------------------------------------
        @(posedge rst_n);
        @(posedge clk);
        #1;
        if (!alloc_ready) $error("[FAIL] test 1: alloc_ready low after reset, expected a free entry");
        if (!wb_ready)     $error("[FAIL] test 1: wb_ready low after reset, expected an empty queue");
        if (fill_valid)    $error("[FAIL] test 1: fill_valid high after reset, expected no completed entries");
        $display("[PASS] test 1: reset sanity check");

        // ---------------------------------------------------------------
        // Test 2: single read miss -> fill.
        // Preloads a known line, drives one read miss to it, and checks
        // the line handed back via fill_valid/fill_data exactly matches
        // what was preloaded. Exercises the full read-miss data path:
        // alloc -> AR/R fetch from the memory model -> beat reassembly
        // in the fill engine -> fill handoff.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] test_addr;
            logic [LINE_WIDTH-1:0] test_line;
            logic [ID_WIDTH-1:0]   got_id;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;

            test_addr = 32'h0000_1000;
            test_line = {32'hCAFEBABE, 32'hDEADBEEF, 32'h1234_5678, 32'h0000_0001};

            mem_write_line(test_addr, test_line);
            send_miss(test_addr, 1'b0, got_id);
            wait_for_fill(got_id, got_data, got_is_write);

            if (got_data !== test_line)
                $error("[FAIL] test 2: fill_data = %h, expected %h", got_data, test_line);
            else if (got_is_write !== 1'b0)
                $error("[FAIL] test 2: fill_is_write = %0d, expected 0 (this miss was a load)", got_is_write);
            else
                $display("[PASS] test 2: single read miss returned the correct line");
        end

        // ---------------------------------------------------------------
        // Test 3: single write miss -> fill.
        // Same alloc -> AR/R -> fill data path as test 2, but with
        // alloc_is_write=1. Write-allocate means a store miss still
        // fetches the full line from memory (the store itself is merged
        // in later by the controller, not the MSHR), so fill_data should
        // be unaffected -- the one new thing being checked here is that
        // fill_is_write correctly reports 1, proving the flag latched at
        // allocation (mshr.sv fe_is_write) survives untouched through the
        // fill engine.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] test_addr;
            logic [LINE_WIDTH-1:0] test_line;
            logic [ID_WIDTH-1:0]   got_id;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;

            test_addr = 32'h0000_2000;
            test_line = {32'h55555555, 32'hAAAAAAAA, 32'h89AB_CDEF, 32'h0123_4567};

            mem_write_line(test_addr, test_line);
            send_miss(test_addr, 1'b1, got_id);
            wait_for_fill(got_id, got_data, got_is_write);

            if (got_data !== test_line)
                $error("[FAIL] test 3: fill_data = %h, expected %h", got_data, test_line);
            else if (got_is_write !== 1'b1)
                $error("[FAIL] test 3: fill_is_write = %0d, expected 1 (this miss was a store)", got_is_write);
            else
                $display("[PASS] test 3: single write miss correctly flagged fill_is_write");
        end

        // ---------------------------------------------------------------
        // Test 4: hit-under-miss merge.
        // A second miss to the same in-flight address must merge into the
        // existing MSHR entry instead of opening a new one (mshr.sv
        // fe_match_vec / fe_is_write OR-in). The primary access is a load
        // and the merged access is a store, so a correct merge must also
        // carry the store's dirty flag through to fill_is_write even
        // though the entry itself was opened by a load.
        //
        // send_miss returns as soon as alloc_ready pulses for the first
        // miss -- well before the AXI AR/R burst can possibly finish --
        // so the second send_miss is guaranteed to see the entry still
        // in flight (FE_REQ/FE_DATA), never FE_IDLE/FE_DONE.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] test_addr;
            logic [LINE_WIDTH-1:0] test_line;
            logic [ID_WIDTH-1:0]   id1, id2;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;

            test_addr = 32'h0000_3000;
            test_line = {32'h11112222, 32'h33334444, 32'h5555_6666, 32'h7777_8888};

            mem_write_line(test_addr, test_line);
            send_miss(test_addr, 1'b0, id1);  // primary access: a load
            send_miss(test_addr, 1'b1, id2);  // merged access: a store, same address, still in flight

            if (id1 !== id2)
                $error("[FAIL] test 4: second miss got id %0d, expected merge into id %0d", id2, id1);
            else begin
                wait_for_fill(id1, got_data, got_is_write);

                if (got_data !== test_line)
                    $error("[FAIL] test 4: fill_data = %h, expected %h", got_data, test_line);
                else if (got_is_write !== 1'b1)
                    $error("[FAIL] test 4: fill_is_write = %0d, expected 1 (merged store must dirty the line)", got_is_write);
                else
                    $display("[PASS] test 4: hit-under-miss merge preserved id and dirty flag");
            end
        end

        // ---------------------------------------------------------------
        // Test 5: single victim writeback.
        // Exercises the writeback engine end-to-end for the first time:
        // wb_valid/wb_addr/wb_data -> queue accept -> AW/W/B drain ->
        // wb_done. This TB plays the role of the (not-yet-designed) cache
        // controller, handing the MSHR a made-up dirty line directly --
        // the same simplification send_miss makes on the alloc side.
        //
        // The target address is preloaded with a sentinel value first, so
        // a readback matching the sentinel (instead of the victim data)
        // would reveal a writeback that never actually happened.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] test_addr;
            logic [LINE_WIDTH-1:0] victim_line;
            logic [LINE_WIDTH-1:0] sentinel_line;
            logic                  mismatch;

            test_addr     = 32'h0000_4000;
            sentinel_line = {4{32'hBAAD_BAAD}};
            victim_line   = {32'hFEED_0004, 32'hFEED_0003, 32'hFEED_0002, 32'hFEED_0001};

            mem_write_line(test_addr, sentinel_line);
            push_writeback(test_addr, victim_line);
            wait_for_wb_done();

            mismatch = 1'b0;
            for (int i = 0; i < LINE_WORDS; i++) begin
                if (mem[(test_addr >> 2) + i] !== victim_line[i*DATA_WIDTH +: DATA_WIDTH]) begin
                    $error("[FAIL] test 5: mem word %0d = %h, expected %h",
                           i, mem[(test_addr >> 2) + i], victim_line[i*DATA_WIDTH +: DATA_WIDTH]);
                    mismatch = 1'b1;
                end
            end

            @(posedge clk);
            if (wb_done) begin
                $error("[FAIL] test 5: wb_done stayed high past one cycle, expected a single pulse");
                mismatch = 1'b1;
            end

            if (!mismatch)
                $display("[PASS] test 5: victim writeback landed correctly in memory with a clean wb_done pulse");
        end

        // ---------------------------------------------------------------
        // Test 6: MSHR full -> alloc_ready stall -> recovery.
        // All NUM_ENTRIES entries are occupied by distinct addresses, so
        // neither a free entry nor an address match exists; alloc_ready
        // must deassert (mshr.sv fe_any_match | fe_any_free) until an
        // entry is retired.
        //
        // fill_ready is deliberately forced low for the fill-up phase.
        // Left at its usual permanently-high value, a fetch that finishes
        // its AXI burst frees its entry on the very same cycle (FE_DONE
        // -> FE_IDLE happens the instant fill_valid && fill_ready are
        // both true) -- racing against the 16 cycles it takes just to
        // issue all 16 allocations. Holding fill_ready low keeps every
        // completed entry parked in FE_DONE (still occupied, not freed)
        // so the "0 free entries" condition is guaranteed, not a race.
        // ---------------------------------------------------------------
        begin
            localparam logic [ADDR_WIDTH-1:0] BASE_ADDR = 32'h0000_6000;
            localparam int LINE_BYTES = LINE_WORDS * (DATA_WIDTH / 8);

            logic [ID_WIDTH-1:0] ids   [NUM_ENTRIES];
            logic                seen  [NUM_ENTRIES];
            logic [ID_WIDTH-1:0] extra_id;
            logic                mismatch;

            mismatch = 1'b0;
            for (int i = 0; i < NUM_ENTRIES; i++) seen[i] = 1'b0;

            // Fill every entry with a distinct address while fills can't
            // drain, so the MSHR is genuinely, unambiguously full once
            // the loop ends.
            fill_ready = 1'b0;
            for (int i = 0; i < NUM_ENTRIES; i++) begin
                // Data content is irrelevant to this test (only alloc_ready/
                // alloc_id behavior is checked) -- preloaded purely so the
                // read-channel model isn't indexing unwritten mem entries.
                mem_write_line(BASE_ADDR + i * LINE_BYTES, '0);
                send_miss(BASE_ADDR + i * LINE_BYTES, 1'b0, ids[i]);
                if (seen[ids[i]]) begin
                    $error("[FAIL] test 6: id %0d handed out twice -- entries did not stay distinct", ids[i]);
                    mismatch = 1'b1;
                end
                seen[ids[i]] = 1'b1;
            end

            // Probe a 17th, distinct-address miss directly (not through
            // send_miss, which would just block silently through the
            // stall): with zero free entries and zero address matches,
            // alloc_ready must read 0 for as long as fill_ready stays low.
            mem_write_line(BASE_ADDR + NUM_ENTRIES * LINE_BYTES, '0);
            alloc_addr     = BASE_ADDR + NUM_ENTRIES * LINE_BYTES;
            alloc_is_write = 1'b0;
            alloc_valid    = 1'b1;

            repeat (3) begin
                @(posedge clk);
                if (alloc_ready) begin
                    $error("[FAIL] test 6: alloc_ready high while MSHR should be full");
                    mismatch = 1'b1;
                end
            end

            // Release the backlog: entries parked in FE_DONE can now be
            // handed off and retired, freeing entries back up.
            fill_ready = 1'b1;

            // Same stall-recovery pattern as send_miss: keep alloc_valid
            // asserted (a real controller would still be retrying the
            // same request) until alloc_ready finally reasserts.
            while (!alloc_ready) @(posedge clk);
            extra_id    = alloc_id;
            alloc_valid = 1'b0;

            if (!mismatch)
                $display("[PASS] test 6: MSHR correctly stalled alloc_ready when full and recovered once an entry freed (id %0d)", extra_id);
        end

        // ---------------------------------------------------------------
        // Test 7: round-robin AR arbitration.
        // Verifies the AR arbiter's fairness rule (mshr.sv ar_last_grant /
        // ar_hi_mask): among several entries simultaneously requesting the
        // read-address channel, the next grant goes to the lowest-indexed
        // requester *above* whoever was granted last, wrapping around
        // only once none qualify. A fixed low-index-first arbiter would
        // produce a different order in the scenario below (it would grant
        // id 0 first), which is what makes this scenario a meaningful
        // test rather than a coincidence check.
        //
        // Test 6 leaves the MSHR mid-drain (it only guarantees one entry
        // freed, not all sixteen), so this test opens with a generous
        // fixed settle window -- long enough for everything left in
        // flight from test 6 to fully retire -- before relying on entries
        // 0/1/2 being free and on the arbiter's last-granted pointer
        // being back at its reset value (0).
        // ---------------------------------------------------------------
        begin
            localparam logic [ADDR_WIDTH-1:0] BASE_ADDR  = 32'h0000_7000;
            localparam int                    LINE_BYTES = LINE_WORDS * (DATA_WIDTH / 8);

            logic [ID_WIDTH-1:0] id0, id1, id2;
            logic [ID_WIDTH-1:0] grant_order    [3];
            logic [ID_WIDTH-1:0] expected_order [3];
            logic                mismatch;
            logic                all_idle;
            int                  watchdog;

            expected_order[0] = 4'd1;
            expected_order[1] = 4'd2;
            expected_order[2] = 4'd0;
            mismatch = 1'b0;

            // Let every entry left in flight from test 6 fully retire so
            // the MSHR starts this test genuinely idle. Checked directly
            // against each entry's own state rather than by counting
            // retirement pulses: a pulse can land on a clock edge that
            // test 6's own polling loop consumes before this one starts
            // watching, so a pulse count taken across that boundary can
            // silently undercount. Reading the state array sidesteps
            // that -- it reflects reality at the instant it's read, with
            // nothing to miss.
            watchdog = 0;
            do begin
                @(posedge clk);
                all_idle = 1'b1;
                for (int i = 0; i < NUM_ENTRIES; i++)
                    if (dut.fe_state[i] != 0) all_idle = 1'b0;  // 0 == FE_IDLE
                watchdog++;
            end while (!all_idle && watchdog < 500);

            if (!all_idle) begin
                $error("[FAIL] test 7: MSHR still not idle after %0d cycles -- some entry from test 6 never retired",
                       watchdog);
                mismatch = 1'b1;
                $display("[DIAG] test 7: ar_last_grant = %0d", dut.ar_last_grant);
                for (int i = 0; i < NUM_ENTRIES; i++) begin
                    if (dut.fe_state[i] != 0)
                        $display("[DIAG] test 7: entry %0d state=%0d addr=%h",
                                 i, dut.fe_state[i], dut.fe_addr[i]);
                end
            end

            mem_write_line(BASE_ADDR + 0 * LINE_BYTES, '0);
            mem_write_line(BASE_ADDR + 1 * LINE_BYTES, '0);
            mem_write_line(BASE_ADDR + 2 * LINE_BYTES, '0);

            // Close the read-address channel so all three misses pile up
            // as simultaneous requesters instead of being granted one at
            // a time as they arrive.
            ar_block = 1'b1;
            send_miss(BASE_ADDR + 0 * LINE_BYTES, 1'b0, id0);
            send_miss(BASE_ADDR + 1 * LINE_BYTES, 1'b0, id1);
            send_miss(BASE_ADDR + 2 * LINE_BYTES, 1'b0, id2);

            if (id0 !== 4'd0 || id1 !== 4'd1 || id2 !== 4'd2) begin
                $error("[FAIL] test 7: expected ids 0,1,2, got %0d,%0d,%0d -- MSHR was not cleanly idle before the test",
                       id0, id1, id2);
                mismatch = 1'b1;
            end

            // Reopen the channel: all three entries now compete for the
            // same grant at once.
            ar_block = 1'b0;

            for (int i = 0; i < 3; i++) wait_for_ar_grant(grant_order[i]);

            for (int i = 0; i < 3; i++) begin
                if (grant_order[i] !== expected_order[i]) begin
                    $error("[FAIL] test 7: grant %0d = id %0d, expected id %0d",
                           i, grant_order[i], expected_order[i]);
                    mismatch = 1'b1;
                end
            end

            if (!mismatch)
                $display("[PASS] test 7: AR arbiter granted in round-robin order 1,2,0 -- not fixed low-index priority");
        end

        // ---------------------------------------------------------------
        // Test 8: writeback queue full -> wb_ready stall -> recovery.
        // Mirrors test 6's alloc-side full/stall/recovery check, but for
        // the independent victim writeback FIFO (WB_QUEUE_DEPTH entries)
        // instead of the miss-tracking table. Pushing a victim takes one
        // cycle; draining one takes several (address phase + LINE_WORDS
        // data beats + response), so pushing WB_QUEUE_DEPTH victims
        // back-to-back reliably outpaces the drain and leaves the queue
        // genuinely full on its own -- no artificial channel-blocking
        // trick needed here, unlike test 6.
        //
        // The probe push is driven directly (not through push_writeback,
        // which would just block silently through the stall) so the
        // stall itself is observable, mirroring test 6's direct
        // 17th-alloc probe.
        // ---------------------------------------------------------------
        begin
            localparam logic [ADDR_WIDTH-1:0] BASE_ADDR  = 32'h0000_8000;
            localparam int                    LINE_BYTES = LINE_WORDS * (DATA_WIDTH / 8);

            logic mismatch;

            mismatch = 1'b0;

            // Fill the queue with WB_QUEUE_DEPTH victims. Each push
            // completes in one cycle and the queue isn't full until the
            // last of these, so every one of these succeeds immediately.
            // Data content is irrelevant to this test (only wb_ready/
            // wb_done stall-and-recovery behavior is checked) -- distinct
            // addresses are used purely so each victim is individually
            // identifiable if this ever needs debugging.
            for (int i = 0; i < WB_QUEUE_DEPTH; i++)
                push_writeback(BASE_ADDR + i * LINE_BYTES, LINE_WIDTH'(i));

            // Probe one more, distinct-address victim directly: with the
            // queue genuinely full, wb_ready must read 0 for as long as
            // no drain has completed yet.
            wb_addr  = BASE_ADDR + WB_QUEUE_DEPTH * LINE_BYTES;
            wb_data  = LINE_WIDTH'(WB_QUEUE_DEPTH);
            wb_valid = 1'b1;

            repeat (3) begin
                @(posedge clk);
                if (wb_ready) begin
                    $error("[FAIL] test 8: wb_ready high while writeback queue should be full");
                    mismatch = 1'b1;
                end
            end

            // Recovery is automatic here: once the head-of-queue victim's
            // write is confirmed, wb_count drops below WB_QUEUE_DEPTH and
            // wb_ready reasserts on its own -- no forcing anything,
            // unlike test 6's fill_ready trick.
            while (!wb_ready) @(posedge clk);
            wb_valid = 1'b0;

            // Confirm the backlog -- the three remaining originally-
            // queued victims, plus the one that had been stalled -- all
            // eventually drain, so the recovery didn't just re-open
            // wb_ready without actually being able to finish the job.
            for (int i = 0; i < WB_QUEUE_DEPTH; i++) wait_for_wb_done();

            if (!mismatch)
                $display("[PASS] test 8: writeback queue correctly stalled wb_ready when full and recovered once a victim drained");
        end

        // ---------------------------------------------------------------
        // Test 9: fill-completion mux ordering.
        // Verifies the fill-completion mux (mshr.sv fe_done_sel) always
        // hands off the lowest-indexed completed entry first, regardless
        // of which order the entries actually finished fetching in. A
        // "first-completed-first-served" mux would produce a different
        // order in the scenario below, which is what makes it a
        // meaningful test rather than a coincidence check.
        //
        // Reuses test 7's ar_block technique to force ids 0/1/2 to
        // request the AR channel simultaneously, so round-robin
        // arbitration -- not arrival order -- decides which finishes
        // fetching first. ar_last_grant is left at 0 by test 7 (its last
        // grant went to id 0), so the same round-robin order (1, 2, 0)
        // applies here: entry 0 is guaranteed to finish LAST even though
        // it must be presented FIRST once every entry is done.
        // fill_ready is held low throughout the fetch phase so all three
        // pile up in FE_DONE together, the same technique test 6 uses to
        // guarantee zero free entries rather than racing a timing guess.
        // ---------------------------------------------------------------
        begin
            localparam logic [ADDR_WIDTH-1:0] BASE_ADDR  = 32'h0000_9000;
            localparam int                    LINE_BYTES = LINE_WORDS * (DATA_WIDTH / 8);

            logic [ID_WIDTH-1:0] id0, id1, id2;
            logic [ID_WIDTH-1:0] fill_order     [3];
            logic [ID_WIDTH-1:0] expected_order [3];
            logic                mismatch;
            logic                all_idle, all_done;
            int                  watchdog;

            expected_order[0] = 4'd0;
            expected_order[1] = 4'd1;
            expected_order[2] = 4'd2;
            mismatch = 1'b0;

            // Let every entry left in flight from test 7 fully retire so
            // the MSHR starts this test genuinely idle -- same rationale
            // and technique as test 7's own opening wait.
            watchdog = 0;
            do begin
                @(posedge clk);
                all_idle = 1'b1;
                for (int i = 0; i < NUM_ENTRIES; i++)
                    if (dut.fe_state[i] != 0) all_idle = 1'b0;  // 0 == FE_IDLE
                watchdog++;
            end while (!all_idle && watchdog < 500);

            if (!all_idle) begin
                $error("[FAIL] test 9: MSHR still not idle after %0d cycles -- some entry from test 7 never retired",
                       watchdog);
                mismatch = 1'b1;
            end

            // Block retirement so all three entries accumulate in
            // FE_DONE instead of draining as soon as each one finishes.
            fill_ready = 1'b0;

            mem_write_line(BASE_ADDR + 0 * LINE_BYTES, {4{32'hA0A0_0000}});
            mem_write_line(BASE_ADDR + 1 * LINE_BYTES, {4{32'hB1B1_0001}});
            mem_write_line(BASE_ADDR + 2 * LINE_BYTES, {4{32'hC2C2_0002}});

            // Close the read-address channel so all three misses pile up
            // as simultaneous requesters instead of being fetched one at
            // a time as they arrive.
            ar_block = 1'b1;
            send_miss(BASE_ADDR + 0 * LINE_BYTES, 1'b0, id0);
            send_miss(BASE_ADDR + 1 * LINE_BYTES, 1'b0, id1);
            send_miss(BASE_ADDR + 2 * LINE_BYTES, 1'b0, id2);

            if (id0 !== 4'd0 || id1 !== 4'd1 || id2 !== 4'd2) begin
                $error("[FAIL] test 9: expected ids 0,1,2, got %0d,%0d,%0d -- MSHR was not cleanly idle before the test",
                       id0, id1, id2);
                mismatch = 1'b1;
            end

            // Reopen the channel: round-robin arbitration now decides
            // fetch order, independent of allocation order.
            ar_block = 1'b0;

            // Wait for all three to finish fetching and land in FE_DONE.
            // fill_ready is still low, so none of them can retire yet --
            // this is what lets an out-of-completion-order handoff be
            // observed once the gate opens below.
            watchdog = 0;
            do begin
                @(posedge clk);
                all_done = (dut.fe_state[id0] == 3) && (dut.fe_state[id1] == 3) && (dut.fe_state[id2] == 3);  // 3 == FE_DONE
                watchdog++;
            end while (!all_done && watchdog < 200);

            if (!all_done) begin
                $error("[FAIL] test 9: not all three entries reached FE_DONE within %0d cycles", watchdog);
                mismatch = 1'b1;
            end

            // Open the gate: the mux must hand off id 0 first, even
            // though (round-robin order 1,2,0, same as test 7) it was
            // the last of the three to actually finish fetching.
            fill_ready = 1'b1;
            for (int i = 0; i < 3; i++) wait_for_fill_grant(fill_order[i]);

            for (int i = 0; i < 3; i++) begin
                if (fill_order[i] !== expected_order[i]) begin
                    $error("[FAIL] test 9: handoff %0d = id %0d, expected id %0d",
                           i, fill_order[i], expected_order[i]);
                    mismatch = 1'b1;
                end
            end

            if (!mismatch)
                $display("[PASS] test 9: fill-completion mux handed off in ascending-id order 0,1,2 -- not completion order");
        end

        // ---------------------------------------------------------------
        // Test 10: concurrent fill + writeback traffic.
        // The fill engine (AR/R) and the writeback engine (AW/W/B) are
        // meant to be two independent engines that merely share one AXI
        // port. If some accidental coupling in the shared control logic
        // actually serialized them, starting a writeback and a read miss
        // together would show one engine stalled until the other
        // finished. This test starts both close together and checks that
        // both still produce correct data, and that a read-data beat and
        // a write-data beat are observed landing in the very same
        // cycle -- direct evidence the two channel pairs genuinely run in
        // parallel, not just eventually-both-finished.
        //
        // A background "forever" process (fork/join_none) samples both
        // data-beat handshakes on every clock edge for as long as the
        // test runs, since the exact overlapping cycle isn't known ahead
        // of time and isn't something a completion-only wait could catch.
        //
        // wait_for_fill and wait_for_wb_done are launched together inside
        // a blocking fork/join rather than called one after another:
        // each engine's completion (fill_valid for this id; wb_done) is
        // only a single-cycle pulse, and test 9's timing shows both
        // bursts start in near lockstep, so their completions can land on
        // the same cycle. Waiting on them sequentially would risk the
        // first wait's multi-cycle block silently swallowing the other
        // pulse before its own wait task ever starts polling for it.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] miss_addr, victim_addr;
            logic [LINE_WIDTH-1:0] miss_line, victim_line;
            logic [ID_WIDTH-1:0]   got_id;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;
            logic                  overlap_seen;
            logic                  mismatch;

            miss_addr    = 32'h0000_A000;
            victim_addr  = 32'h0000_B000;
            miss_line    = {32'h0A0A_0004, 32'h0A0A_0003, 32'h0A0A_0002, 32'h0A0A_0001};
            victim_line  = {32'h0B0B_0004, 32'h0B0B_0003, 32'h0B0B_0002, 32'h0B0B_0001};
            overlap_seen = 1'b0;
            mismatch     = 1'b0;

            mem_write_line(miss_addr, miss_line);

            fork : overlap_monitor
                forever begin
                    @(posedge clk);
                    if ((axi.rvalid && axi.rready) && (axi.wvalid && axi.wready))
                        overlap_seen = 1'b1;
                end
            join_none

            // Start the writeback first, then the read miss right after --
            // close enough together that, since each engine drives a fixed
            // LINE_WORDS-beat burst once granted, their data phases are
            // guaranteed to overlap for at least a couple of cycles.
            push_writeback(victim_addr, victim_line);
            send_miss(miss_addr, 1'b0, got_id);

            fork
                wait_for_fill(got_id, got_data, got_is_write);
                wait_for_wb_done();
            join

            disable overlap_monitor;

            if (got_data !== miss_line) begin
                $error("[FAIL] test 10: fill_data = %h, expected %h", got_data, miss_line);
                mismatch = 1'b1;
            end

            for (int i = 0; i < LINE_WORDS; i++) begin
                if (mem[(victim_addr >> 2) + i] !== victim_line[i*DATA_WIDTH +: DATA_WIDTH]) begin
                    $error("[FAIL] test 10: mem word %0d = %h, expected %h",
                           i, mem[(victim_addr >> 2) + i], victim_line[i*DATA_WIDTH +: DATA_WIDTH]);
                    mismatch = 1'b1;
                end
            end

            if (!overlap_seen) begin
                $error("[FAIL] test 10: never observed a read-data beat and a write-data beat in the same cycle -- engines appear serialized");
                mismatch = 1'b1;
            end

            if (!mismatch)
                $display("[PASS] test 10: fill and writeback engines made simultaneous progress on independent AXI channels");
        end

        // ---------------------------------------------------------------
        // Test 11: multi-way merge with an out-of-order dirty flag.
        // Test 4 proved a *second* access merges into an in-flight miss.
        // This test raises that to four total accesses -- one primary
        // plus three merges -- to the same still-outstanding address, in
        // the order load, store, load, load. The store is deliberately
        // sandwiched in the middle rather than placed last: an
        // implementation that (incorrectly) just remembers the most
        // recently merged access's dirty flag, instead of OR-ing every
        // merge together (mshr.sv fe_is_write <= fe_is_write |
        // alloc_is_write), would let the two trailing loads erase the
        // store's dirty marking. Checking that fill_is_write still comes
        // back 1 is what catches that specific bug -- a design that only
        // ever correctly handles exactly one merge (test 4's scenario)
        // would still pass this test's id checks but not its dirty-flag
        // check if it had that flaw.
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] test_addr;
            logic [LINE_WIDTH-1:0] test_line;
            logic [ID_WIDTH-1:0]   id0, id1, id2, id3;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;
            logic                  mismatch;

            test_addr = 32'h0000_C000;
            test_line = {32'h9999_0004, 32'h9999_0003, 32'h9999_0002, 32'h9999_0001};
            mismatch  = 1'b0;

            mem_write_line(test_addr, test_line);

            send_miss(test_addr, 1'b0, id0);  // primary access: a load
            send_miss(test_addr, 1'b1, id1);  // merge 1: a store -- must dirty the line
            send_miss(test_addr, 1'b0, id2);  // merge 2: a load -- must NOT clear the dirty flag
            send_miss(test_addr, 1'b0, id3);  // merge 3: a load -- same, must NOT clear it

            if (id0 !== id1 || id0 !== id2 || id0 !== id3) begin
                $error("[FAIL] test 11: ids %0d,%0d,%0d,%0d -- all four accesses should have merged into one entry",
                       id0, id1, id2, id3);
                mismatch = 1'b1;
            end else begin
                wait_for_fill(id0, got_data, got_is_write);

                if (got_data !== test_line) begin
                    $error("[FAIL] test 11: fill_data = %h, expected %h", got_data, test_line);
                    mismatch = 1'b1;
                end
                if (got_is_write !== 1'b1) begin
                    $error("[FAIL] test 11: fill_is_write = %0d, expected 1 -- the middle merge's dirty flag must survive later clean merges",
                           got_is_write);
                    mismatch = 1'b1;
                end
            end

            if (!mismatch)
                $display("[PASS] test 11: four-way merge (load/store/load/load) preserved one entry id and the mid-sequence dirty flag");
        end

        // ---------------------------------------------------------------
        // Test 12: entry reuse does not leak a stale dirty flag.
        // Once an entry that was dirtied by a store finishes and is
        // handed back to the controller, its slot becomes available
        // again. The free-entry picker (mshr.sv fe_free_idx = pick_lowest
        // (fe_free_vec)) always chooses the lowest-indexed free entry, so
        // driving one miss to completion and then driving a second,
        // unrelated miss -- starting from an all-idle MSHR, guaranteed by
        // every prior test fully draining what it used -- naturally
        // reuses the exact same slot: nothing lower than entry 0 exists,
        // so whichever miss goes first claims it, and it claims it again
        // once free. No artificial "fill every other entry" trick is
        // needed to force the reuse.
        //
        // The reused slot's new occupant is a plain load to a completely
        // different address. If the RTL ever failed to explicitly reset
        // the dirty flag for a freshly-opened entry, this clean load
        // could incorrectly inherit dirty status left over from the
        // previous, already-retired store -- the same class of bug test
        // 11 targeted, mirrored in the opposite direction (overwrite is
        // correct here; carrying the old value forward would be the bug).
        // ---------------------------------------------------------------
        begin
            logic [ADDR_WIDTH-1:0] dirty_addr, clean_addr;
            logic [LINE_WIDTH-1:0] dirty_line, clean_line;
            logic [ID_WIDTH-1:0]   id_dirty, id_clean;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;
            logic                  mismatch;

            dirty_addr = 32'h0000_D000;
            clean_addr = 32'h0000_E000;
            dirty_line = {32'h7A7A_0004, 32'h7A7A_0003, 32'h7A7A_0002, 32'h7A7A_0001};
            clean_line = {32'h7C7C_0004, 32'h7C7C_0003, 32'h7C7C_0002, 32'h7C7C_0001};
            mismatch   = 1'b0;

            mem_write_line(dirty_addr, dirty_line);
            mem_write_line(clean_addr, clean_line);

            // First occupant: a store, must retire fully dirty before its
            // slot can be reused.
            send_miss(dirty_addr, 1'b1, id_dirty);
            wait_for_fill(id_dirty, got_data, got_is_write);

            if (got_is_write !== 1'b1) begin
                $error("[FAIL] test 12: fill_is_write = %0d for the first (store) miss, expected 1", got_is_write);
                mismatch = 1'b1;
            end

            // Second occupant: an unrelated load, expected to reuse the
            // exact same slot now that it has retired.
            send_miss(clean_addr, 1'b0, id_clean);

            if (id_clean !== id_dirty) begin
                $error("[FAIL] test 12: second miss got id %0d, expected it to reuse id %0d -- test setup assumption broken",
                       id_clean, id_dirty);
                mismatch = 1'b1;
            end else begin
                wait_for_fill(id_clean, got_data, got_is_write);

                if (got_data !== clean_line) begin
                    $error("[FAIL] test 12: fill_data = %h, expected %h", got_data, clean_line);
                    mismatch = 1'b1;
                end
                if (got_is_write !== 1'b0) begin
                    $error("[FAIL] test 12: fill_is_write = %0d, expected 0 -- reused slot leaked the previous occupant's dirty flag",
                           got_is_write);
                    mismatch = 1'b1;
                end
            end

            if (!mismatch)
                $display("[PASS] test 12: reused entry slot correctly reset the dirty flag for its new, unrelated occupant");
        end

        // ---------------------------------------------------------------
        // Test 13: reset mid-fetch does not leave a stale merge target.
        // Every test so far only ever sees reset once, at the very
        // start, with nothing in flight. This test asserts it again --
        // deliberately while a read miss is only partway through its
        // AXI burst -- and checks the interrupted entry is not just
        // superficially idle, but genuinely available: a fresh miss to
        // that exact same address afterward must be treated as a
        // brand-new allocation (a real AR request re-issued on the bus),
        // not silently absorbed as a "merge" into the leftover,
        // address-matching entry left over from before the reset.
        //
        // The returned id alone can't distinguish those two outcomes --
        // with every entry free after reset, the lowest-free-index rule
        // would likely hand out the same id either way. The real tell is
        // whether a genuine AR handshake happens at all: the merge path
        // only updates a dirty flag and never touches the AXI bus, so if
        // fe_state ever failed to actually reset, the interrupted entry
        // would silently swallow the new miss and never issue a new
        // fetch -- hanging forever rather than failing loudly. The wait
        // below is watchdog-bounded for exactly that reason, mirroring
        // tests 7/9's pattern, and wait_for_fill is only reached once the
        // AR handshake is confirmed, so a genuine hang can't happen here.
        // ---------------------------------------------------------------
        begin
            localparam logic [ADDR_WIDTH-1:0] TEST_ADDR = 32'h0000_F000;

            logic [LINE_WIDTH-1:0] test_line;
            logic [ID_WIDTH-1:0]   id_before, id_after;
            logic [LINE_WIDTH-1:0] got_data;
            logic                  got_is_write;
            logic                  mismatch;
            int                    watchdog;

            test_line = {32'h5E5E_0004, 32'h5E5E_0003, 32'h5E5E_0002, 32'h5E5E_0001};
            mismatch  = 1'b0;

            mem_write_line(TEST_ADDR, test_line);

            // Start a miss, let it win AR arbitration, then let a couple
            // of R beats land -- partway through the burst, not
            // finished -- before interrupting it.
            send_miss(TEST_ADDR, 1'b0, id_before);
            begin
                logic [ID_WIDTH-1:0] granted_id;
                wait_for_ar_grant(granted_id);
            end
            repeat (2) @(posedge clk);

            // Reset mid-burst: the same shape as the top-level reset
            // generation block, just triggered later instead of only at
            // time 0.
            rst_n = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;

            // A fresh miss to the exact same address the interrupted
            // entry was still holding. If that entry is genuinely idle,
            // this looks identical to any other first-time miss: it must
            // win AR arbitration again and fetch a real burst.
            send_miss(TEST_ADDR, 1'b0, id_after);

            watchdog = 0;
            while (!(axi.arvalid && axi.arready) && watchdog < 200) begin
                @(posedge clk);
                watchdog++;
            end

            if (watchdog >= 200) begin
                $error("[FAIL] test 13: no new AR request seen within %0d cycles after reset -- the interrupted entry appears to have silently absorbed the new miss instead of re-fetching",
                       watchdog);
                mismatch = 1'b1;
            end else begin
                wait_for_fill(id_after, got_data, got_is_write);

                if (got_data !== test_line) begin
                    $error("[FAIL] test 13: fill_data = %h, expected %h", got_data, test_line);
                    mismatch = 1'b1;
                end
            end

            if (!mismatch)
                $display("[PASS] test 13: reset mid-fetch left no stale merge target -- a fresh miss to the same address re-issued a real AXI burst");
        end

        $finish;
    end

endmodule : mshr_tb

`default_nettype wire
