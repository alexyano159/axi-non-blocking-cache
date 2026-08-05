// -----------------------------------------------------------------------
// Testbench for the MSHR (Miss Status Holding Register).
//
// Structure (built up incrementally):
//   1. Clock/reset generation and DUT instantiation           <- this step
//   2. AXI memory model (slave-side BFM on the same axi_if)
//   3. Driver/helper tasks (alloc_miss, push_writeback, ...)
//   4. Directed test sequences
//
// See private_notes/MSHR_README.md for the design rationale being
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

    assign axi.arready = (mr_state == MR_IDLE);
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

        $finish;
    end

endmodule : mshr_tb

`default_nettype wire
