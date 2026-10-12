// -----------------------------------------------------------------------
// System testbench for the complete cache (rtl/cache_top.sv).
//
// The DUT is the full cache -- controller, the three arrays and the
// MSHR -- connected to a TB-only AXI4 slave memory model. Nothing inside
// the DUT is stubbed or forced; the testbench only observes internal
// signals (white-box checks and coverage) through hierarchical
// references.
//
// Structure:
//   1. Parameters, clock/reset, DUT and AXI interface instance
//   2. Random number generator (+seed plusarg) and run-time knobs
//   3. Reference memory and backing store
//   4. AXI4 slave memory model with configurable latency/back-pressure,
//      out-of-order and interleaved read data, and master-side protocol
//      checks
//   5. Scoreboard and system monitor: acceptance-ordered reference
//      model, responses matched by id, procedural mirrors of the
//      controller's concurrent assertions, coverage counters
//   6. CPU driver tasks (directed and constrained-random)
//   7. Directed tests 1-10, constrained-random test 11, end-of-test
//      consistency test 12
//
// Correctness criterion: the cache must behave as a flat memory in
// which every request takes effect at its acceptance edge
// (req_valid && req_ready), in acceptance order. The expected data of a
// load is computed from the reference memory at acceptance; responses
// may return in any order and are matched by id, each exactly once.
//
// Every wait is watchdog-bounded: a hang is reported as a [FAIL] with a
// diagnostic dump and terminates the run, never stalls the simulator.
//
// Simulator note: ModelSim 18.1 does not evaluate concurrent assertions,
// so the controller's invariants are re-checked procedurally here (see
// "Mirrors of the controller's assertions").
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module cache_top_tb;

    // -------------------------------------------------------------------
    // Parameters, mirrored from the cache_top defaults.
    // -------------------------------------------------------------------
    localparam int ADDR_WIDTH     = 32;
    localparam int DATA_WIDTH     = 32;
    localparam int NUM_WAYS       = 4;
    localparam int WORDS_PER_LINE = 4;
    localparam int NUM_SETS       = 64;
    localparam int MSHR_ID_WIDTH  = 4;
    localparam int TXN_ID_WIDTH   = 4;
    localparam int WB_QUEUE_DEPTH = 4;

    localparam int SET_IDX_WIDTH  = $clog2(NUM_SETS);                          // 6
    localparam int WAY_WIDTH      = $clog2(NUM_WAYS);                          // 2
    localparam int WORD_OFF_WIDTH = $clog2(WORDS_PER_LINE);                    // 2
    localparam int BYTE_OFF_WIDTH = $clog2(DATA_WIDTH / 8);                    // 2
    localparam int LINE_OFF_WIDTH = WORD_OFF_WIDTH + BYTE_OFF_WIDTH;           // 4
    localparam int TAG_WIDTH      = ADDR_WIDTH - SET_IDX_WIDTH - LINE_OFF_WIDTH; // 22
    localparam int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE;               // 128
    localparam int NUM_IDS        = 2 ** TXN_ID_WIDTH;                         // 16 CPU ids

    localparam time CLK_PERIOD = 10ns;

    // Watchdog bounds, in clock cycles. Generous with respect to the
    // slowest memory profile used (a writeback-starved phase with ~3 %
    // write-address acceptance and up to 100-cycle write responses), but
    // finite.
    localparam int unsigned REQ_TIMEOUT    = 20000;    // request accepted
    localparam int unsigned RESP_TIMEOUT   = 20000;    // response returned
    localparam int unsigned IDLE_TIMEOUT   = 40000;    // system drained
    localparam int unsigned GLOBAL_TIMEOUT = 3000000;  // whole run, plus 400 per random request

    localparam int unsigned MAX_ERR_PRINT  = 40;       // error messages printed in full

    // Base of the tag field used by the directed tests; the random test
    // uses RND_TAG_BASE, so the two footprints never alias.
    localparam logic [TAG_WIDTH-1:0] DIR_TAG_BASE = 22'h00_0100;
    localparam logic [TAG_WIDTH-1:0] RND_TAG_BASE = 22'h00_0200;

    // -------------------------------------------------------------------
    // Clock and reset.
    // -------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------
    // CPU-side signals (driven by the TB #1 after a clock edge).
    // -------------------------------------------------------------------
    logic                    req_valid;
    logic                    req_ready;
    logic [ADDR_WIDTH-1:0]   req_addr;
    logic                    req_we;
    logic [DATA_WIDTH-1:0]   req_wdata;
    logic [TXN_ID_WIDTH-1:0] req_id;

    logic                    resp_valid;
    logic                    resp_ready;
    logic [TXN_ID_WIDTH-1:0] resp_id;
    logic [DATA_WIDTH-1:0]   resp_data;
    logic                    resp_we;

    // -------------------------------------------------------------------
    // AXI interface and DUT.
    // -------------------------------------------------------------------
    axi_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH  (MSHR_ID_WIDTH)
    ) axi ();

    cache_top #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS),
        .MSHR_ID_WIDTH (MSHR_ID_WIDTH),
        .TXN_ID_WIDTH  (TXN_ID_WIDTH),
        .WB_QUEUE_DEPTH(WB_QUEUE_DEPTH)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (req_valid),
        .req_ready (req_ready),
        .req_addr  (req_addr),
        .req_we    (req_we),
        .req_wdata (req_wdata),
        .req_id    (req_id),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp_id   (resp_id),
        .resp_data (resp_data),
        .resp_we   (resp_we),
        .axi       (axi.master)
    );

    // Shorthands for white-box references.
    `define CTRL dut.u_controller
    `define MSHR dut.u_mshr

    // ===================================================================
    // 2. Random number generator and run-time knobs
    // ===================================================================
    // A single xorshift32 generator shared by every TB process. Using one
    // explicit state, rather than the per-process $urandom streams, makes
    // a run fully reproducible from +seed regardless of how the simulator
    // seeds individual processes.
    int unsigned rng_state = 32'h1;
    int unsigned seed      = 1;

    function automatic int unsigned rnd();
        rng_state ^= rng_state << 13;
        rng_state ^= rng_state >> 17;
        rng_state ^= rng_state << 5;
        return rng_state;
    endfunction

    // Uniform draw in 0..99, for percentage knobs.
    function automatic int unsigned rnd_pct();
        return rnd() % 100;
    endfunction

    // Uniform draw in lo..hi (inclusive).
    function automatic int unsigned rnd_range(input int unsigned lo, input int unsigned hi);
        return (hi <= lo) ? lo : lo + rnd() % (hi - lo + 1);
    endfunction

    // Memory-model knobs. Each "ready" percentage is the per-cycle
    // probability that the slave asserts that ready signal; latencies are
    // in cycles from the address (read) or last write beat (write) to the
    // first R beat / the B response.
    int unsigned ar_ready_pct = 100;
    int unsigned aw_ready_pct = 100;
    int unsigned w_ready_pct  = 100;
    int unsigned r_gap_pct    = 0;      // probability of an idle cycle between R beats
    int unsigned r_lat_min    = 2;
    int unsigned r_lat_max    = 2;
    int unsigned b_lat_min    = 1;
    int unsigned b_lat_max    = 1;
    bit          r_interleave = 1'b0;   // 1: R beats of different IDs may interleave

    // Directed-test overrides: hold a channel completely.
    bit          ar_hold = 1'b0;        // arready forced low
    bit          aw_hold = 1'b0;        // awready forced low
    bit          r_hold  = 1'b0;        // no new R beat started
    bit          b_hold  = 1'b0;        // no new B response started
    int unsigned r_script [$];          // directed R beat order (one rid per beat)

    // CPU-side knobs.
    int unsigned resp_ready_pct = 100;  // per-cycle probability of resp_ready
    int unsigned resp_stall_pct = 0;    // per-cycle probability of starting a long resp_ready stall
    int unsigned resp_stall_len = 0;    // remaining cycles of the current stall

    // ===================================================================
    // 3. Reference memory and backing store
    // ===================================================================
    // Both are sparse, keyed by word address (byte address >> 2). A word
    // never written holds a fixed, address-derived pattern, so every
    // location has a distinct, predictable initial value without
    // preloading.
    logic [DATA_WIDTH-1:0] ref_mem [bit [ADDR_WIDTH-1:0]];   // architectural state (scoreboard)
    logic [DATA_WIDTH-1:0] mem     [bit [ADDR_WIDTH-1:0]];   // AXI slave backing store
    bit                    touched [bit [ADDR_WIDTH-1:0]];   // word addresses accessed by any request

    function automatic logic [DATA_WIDTH-1:0] init_word(input logic [ADDR_WIDTH-1:0] waddr);
        return (waddr * 32'h9E37_79B1) ^ 32'h5A5A_0000;
    endfunction

    function automatic logic [DATA_WIDTH-1:0] ref_rd(input logic [ADDR_WIDTH-1:0] waddr);
        return ref_mem.exists(waddr) ? ref_mem[waddr] : init_word(waddr);
    endfunction

    function automatic logic [DATA_WIDTH-1:0] mem_rd(input logic [ADDR_WIDTH-1:0] waddr);
        return mem.exists(waddr) ? mem[waddr] : init_word(waddr);
    endfunction

    // Full line of the reference image, word 0 in the low bits (the
    // MSHR's and the data SRAM's line layout).
    function automatic logic [LINE_WIDTH-1:0] ref_line(input logic [ADDR_WIDTH-1:0] line_addr);
        logic [LINE_WIDTH-1:0] l;
        for (int w = 0; w < WORDS_PER_LINE; w++)
            l[w*DATA_WIDTH +: DATA_WIDTH] = ref_rd((line_addr >> BYTE_OFF_WIDTH) + w);
        return l;
    endfunction

    function automatic logic [LINE_WIDTH-1:0] mem_line(input logic [ADDR_WIDTH-1:0] line_addr);
        logic [LINE_WIDTH-1:0] l;
        for (int w = 0; w < WORDS_PER_LINE; w++)
            l[w*DATA_WIDTH +: DATA_WIDTH] = mem_rd((line_addr >> BYTE_OFF_WIDTH) + w);
        return l;
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] make_addr(input logic [TAG_WIDTH-1:0]      tag,
                                                        input int unsigned             set,
                                                        input int unsigned             word);
        return {tag, SET_IDX_WIDTH'(set), WORD_OFF_WIDTH'(word), BYTE_OFF_WIDTH'(0)};
    endfunction

    function automatic logic [ADDR_WIDTH-1:0] line_of(input logic [ADDR_WIDTH-1:0] addr);
        return {addr[ADDR_WIDTH-1:LINE_OFF_WIDTH], LINE_OFF_WIDTH'(0)};
    endfunction

    // ===================================================================
    // Error accounting and test bookkeeping
    // ===================================================================
    longint unsigned cyc = 0;            // rising edges since time 0
    int unsigned     err_cnt  = 0;       // every error from any checker
    int unsigned     n_pass   = 0;
    int unsigned     n_fail   = 0;
    string           cur_test = "init";
    int unsigned     test_err0;

    function automatic void err(input string msg);
        err_cnt++;
        if (err_cnt <= MAX_ERR_PRINT)
            $error("[%s] cycle %0d: %s", cur_test, cyc, msg);
        else if (err_cnt == MAX_ERR_PRINT + 1)
            $display("** further error messages suppressed (count continues)");
    endfunction

    task automatic test_begin(input string name);
        cur_test  = name;
        test_err0 = err_cnt;
    endtask

    // A test passes only if no checker (including the always-on
    // monitors) reported an error while it ran.
    task automatic test_end(input string pass_msg);
        if (err_cnt == test_err0) begin
            $display("[PASS] %s: %s", cur_test, pass_msg);
            n_pass++;
        end else begin
            $display("[FAIL] %s: %0d error(s), see messages above", cur_test, err_cnt - test_err0);
            n_fail++;
        end
    endtask

    task automatic print_summary();
        $display("[SUMMARY] seed %0d: %0d test(s) passed, %0d failed, %0d error(s) in total",
                 seed, n_pass, n_fail, err_cnt);
    endtask

    // ===================================================================
    // 4. AXI4 slave memory model
    // ===================================================================
    // Reads: the line is snapshot from the backing store when the AR is
    // accepted. Several reads may be outstanding; their R bursts are
    // served out of order and, with r_interleave, beat-interleaved (AXI4
    // permits both across different IDs). Reads are never ordered against
    // writes: a read is served from whatever the backing store holds,
    // regardless of writes accepted but not yet answered.
    //
    // Writes: AW requests are queued; W beats are accepted only for a
    // queued AW, in AW order. A write takes effect in the backing store
    // when its B response is handshaken -- the latest point AXI allows --
    // so a read issued before the B response observes stale data. This
    // makes the MSHR's read-after-write rule observable: a re-miss whose
    // AR overtook the writeback of the same line would return stale data.
    //
    // All outputs are driven #1 after the clock edge; handshakes are
    // sampled on the edge (pre-edge values).
    // -------------------------------------------------------------------
    typedef struct {
        logic [MSHR_ID_WIDTH-1:0] id;
        logic [ADDR_WIDTH-1:0]    addr;
        logic [LINE_WIDTH-1:0]    data;
        int unsigned              beats;       // beats already returned
        longint unsigned          ready_cyc;   // first cycle a beat may be returned
    } rd_burst_t;

    typedef struct {
        logic [MSHR_ID_WIDTH-1:0] id;
        logic [ADDR_WIDTH-1:0]    addr;
        logic [LINE_WIDTH-1:0]    data;
        longint unsigned          ready_cyc;   // first cycle B may be presented
    } wr_burst_t;

    typedef struct {
        logic [ADDR_WIDTH-1:0]    addr;
        logic [MSHR_ID_WIDTH-1:0] id;
        longint unsigned          cyc;
    } addr_rec_t;

    typedef struct {
        logic [ADDR_WIDTH-1:0] addr;
        logic [LINE_WIDTH-1:0] data;
        longint unsigned       cyc;
    } line_rec_t;

    rd_burst_t   rd_tab   [int unsigned];   // outstanding reads, by ARID
    int unsigned rd_order [$];              // outstanding ARIDs, in AR acceptance order
    wr_burst_t   aw_q     [$];              // accepted AWs whose data is not yet complete
    wr_burst_t   b_q      [$];              // complete writes awaiting their B response

    bit          r_cur_valid = 1'b0;        // an R beat is being presented
    int unsigned r_cur_id;
    int          r_last_id   = -1;          // ID of the last R beat handshaken
    bit          b_cur_valid = 1'b0;        // a B response is being presented
    int unsigned w_beat      = 0;
    logic [LINE_WIDTH-1:0] w_buf;

    // Transaction logs, for directed-test checks.
    addr_rec_t   ar_log [$];                // AR handshakes
    addr_rec_t   aw_log [$];                // AW handshakes
    line_rec_t   wl_log [$];                // completed W bursts (address from AW, data)
    addr_rec_t   b_log  [$];                // B handshakes (write performed)

    // Writebacks handed from the controller to the MSHR and not yet
    // answered by B, per line address; and the handed-off lines in order,
    // compared against what arrives on W.
    int unsigned wb_pend      [bit [ADDR_WIDTH-1:0]];
    line_rec_t   wb_handoff_q [$];

    // Coverage counted by the slave.
    int unsigned cov_r_ooo        = 0;      // read bursts completed ahead of an older outstanding read
    int unsigned cov_r_interleave = 0;      // R beats taken from another burst while one was incomplete
    int unsigned cov_ar_stall     = 0;      // cycles with arvalid && !arready
    int unsigned cov_aw_stall     = 0;      // cycles with awvalid && !awready

    // Master-side stability bookkeeping: payload recorded on an edge on
    // which valid was high and ready low.
    bit                       ar_wait = 1'b0, aw_wait = 1'b0, w_wait = 1'b0;
    logic [MSHR_ID_WIDTH-1:0] arh_id,   awh_id;
    logic [ADDR_WIDTH-1:0]    arh_addr, awh_addr;
    logic [7:0]               arh_len,  awh_len;
    logic [2:0]               arh_size, awh_size;
    logic [1:0]               arh_burst, awh_burst;
    logic [DATA_WIDTH-1:0]    wh_data;
    logic [DATA_WIDTH/8-1:0]  wh_strb;
    logic                     wh_last;

    // Burst-format check shared by AR and AW: every transfer of this
    // cache is one full line, INCR, full-width beats, line-aligned.
    function automatic void check_burst(input string ch, input logic [ADDR_WIDTH-1:0] addr,
                                        input logic [7:0] len, input logic [2:0] size,
                                        input logic [1:0] burst);
        if (burst !== 2'b01)
            err($sformatf("%s 0x%08h: burst type %b, expected INCR (01)", ch, addr, burst));
        if (len !== 8'(WORDS_PER_LINE - 1))
            err($sformatf("%s 0x%08h: len %0d, expected %0d", ch, addr, len, WORDS_PER_LINE - 1));
        if (size !== 3'($clog2(DATA_WIDTH / 8)))
            err($sformatf("%s 0x%08h: size %0d, expected %0d", ch, addr, size, $clog2(DATA_WIDTH / 8)));
        if (addr[LINE_OFF_WIDTH-1:0] !== '0)
            err($sformatf("%s 0x%08h: address not line-aligned", ch, addr));
    endfunction

    always @(posedge clk) begin : slave
        rd_burst_t   rb;
        wr_burst_t   wb;
        line_rec_t   ho;
        int unsigned cand [$];
        int          pick;

        if (!rst_n) begin
            rd_tab.delete();
            rd_order.delete();
            aw_q.delete();
            b_q.delete();
            r_cur_valid = 1'b0;
            r_last_id   = -1;
            b_cur_valid = 1'b0;
            w_beat      = 0;
            ar_wait     = 1'b0;
            aw_wait     = 1'b0;
            w_wait      = 1'b0;
        end else begin
            // -----------------------------------------------------------
            // Master-side valid/payload stability. AXI requires a source
            // to keep VALID high and its payload unchanged from the cycle
            // VALID is asserted until the handshake.
            // -----------------------------------------------------------
            if (ar_wait && !(axi.arvalid === 1'b1 && axi.arid === arh_id && axi.araddr === arh_addr &&
                             axi.arlen === arh_len && axi.arsize === arh_size && axi.arburst === arh_burst))
                err($sformatf("AXI AR: request changed or withdrawn before arready (was id %0d addr 0x%08h, now valid %b id %0d addr 0x%08h)",
                              arh_id, arh_addr, axi.arvalid, axi.arid, axi.araddr));
            if (aw_wait && !(axi.awvalid === 1'b1 && axi.awid === awh_id && axi.awaddr === awh_addr &&
                             axi.awlen === awh_len && axi.awsize === awh_size && axi.awburst === awh_burst))
                err($sformatf("AXI AW: request changed or withdrawn before awready (was addr 0x%08h, now valid %b addr 0x%08h)",
                              awh_addr, axi.awvalid, axi.awaddr));
            if (w_wait && !(axi.wvalid === 1'b1 && axi.wdata === wh_data && axi.wstrb === wh_strb &&
                            axi.wlast === wh_last))
                err("AXI W: beat changed or withdrawn before wready");

            ar_wait   = (axi.arvalid === 1'b1) && (axi.arready !== 1'b1);
            arh_id    = axi.arid;    arh_addr = axi.araddr;  arh_len = axi.arlen;
            arh_size  = axi.arsize;  arh_burst = axi.arburst;
            aw_wait   = (axi.awvalid === 1'b1) && (axi.awready !== 1'b1);
            awh_id    = axi.awid;    awh_addr = axi.awaddr;  awh_len = axi.awlen;
            awh_size  = axi.awsize;  awh_burst = axi.awburst;
            w_wait    = (axi.wvalid === 1'b1) && (axi.wready !== 1'b1);
            wh_data   = axi.wdata;   wh_strb = axi.wstrb;    wh_last = axi.wlast;
            if (ar_wait) cov_ar_stall++;
            if (aw_wait) cov_aw_stall++;

            // -----------------------------------------------------------
            // AR handshake: check, snapshot the line, schedule the burst.
            // -----------------------------------------------------------
            if (axi.arvalid === 1'b1 && axi.arready === 1'b1) begin
                check_burst("AR", axi.araddr, axi.arlen, axi.arsize, axi.arburst);
                if (rd_tab.exists(axi.arid))
                    err($sformatf("AXI AR: id %0d reused while its previous read is outstanding", axi.arid));
                foreach (rd_order[k])
                    if (rd_tab[rd_order[k]].addr == axi.araddr)
                        err($sformatf("AXI AR: second read of line 0x%08h while the first is outstanding (missed merge)",
                                      axi.araddr));
                if (wb_pend.exists(axi.araddr) && wb_pend[axi.araddr] > 0)
                    err($sformatf("AXI AR: read of line 0x%08h issued while its writeback is unacknowledged (read-after-write rule)",
                                  axi.araddr));
                rb.id        = axi.arid;
                rb.addr      = axi.araddr;
                rb.data      = mem_line(axi.araddr);
                rb.beats     = 0;
                rb.ready_cyc = cyc + rnd_range(r_lat_min, r_lat_max);
                rd_tab[axi.arid] = rb;
                rd_order.push_back(axi.arid);
                ar_log.push_back('{addr: axi.araddr, id: axi.arid, cyc: cyc});
            end

            // -----------------------------------------------------------
            // R handshake: advance the presented burst.
            // -----------------------------------------------------------
            if (axi.rvalid === 1'b1 && axi.rready === 1'b1) begin
                rb = rd_tab[r_cur_id];
                if (r_last_id >= 0 && r_last_id != int'(r_cur_id) && rd_tab.exists(r_last_id))
                    cov_r_interleave++;
                rb.beats++;
                r_last_id = r_cur_id;
                if (rb.beats == WORDS_PER_LINE) begin
                    if (rd_order[0] != r_cur_id) cov_r_ooo++;
                    foreach (rd_order[k])
                        if (rd_order[k] == r_cur_id) begin
                            rd_order.delete(k);
                            break;
                        end
                    rd_tab.delete(r_cur_id);
                end else begin
                    rd_tab[r_cur_id] = rb;
                end
                r_cur_valid = 1'b0;
            end

            // -----------------------------------------------------------
            // AW handshake.
            // -----------------------------------------------------------
            if (axi.awvalid === 1'b1 && axi.awready === 1'b1) begin
                check_burst("AW", axi.awaddr, axi.awlen, axi.awsize, axi.awburst);
                wb.id   = axi.awid;
                wb.addr = axi.awaddr;
                aw_q.push_back(wb);
                aw_log.push_back('{addr: axi.awaddr, id: axi.awid, cyc: cyc});
            end

            // -----------------------------------------------------------
            // W handshake: collect beats; on the last beat, compare the
            // line with the one the controller handed to the MSHR and
            // schedule the B response.
            // -----------------------------------------------------------
            if (axi.wvalid === 1'b1 && axi.wready === 1'b1) begin
                if (axi.wstrb !== '1)
                    err($sformatf("AXI W: wstrb %b, expected all ones (full-line write)", axi.wstrb));
                if (axi.wlast !== (w_beat == WORDS_PER_LINE - 1))
                    err($sformatf("AXI W: wlast %b on beat %0d of %0d", axi.wlast, w_beat, WORDS_PER_LINE));
                w_buf[w_beat*DATA_WIDTH +: DATA_WIDTH] = axi.wdata;
                w_beat++;
                if (w_beat == WORDS_PER_LINE) begin
                    wb = aw_q.pop_front();
                    wb.data      = w_buf;
                    wb.ready_cyc = cyc + rnd_range(b_lat_min, b_lat_max);
                    b_q.push_back(wb);
                    wl_log.push_back('{addr: wb.addr, data: w_buf, cyc: cyc});
                    if (wb_handoff_q.size() == 0) begin
                        err($sformatf("AXI W: write of line 0x%08h with no matching victim handed to the MSHR", wb.addr));
                    end else begin
                        ho = wb_handoff_q.pop_front();
                        if (ho.addr !== wb.addr || ho.data !== w_buf)
                            err($sformatf("AXI AW/W: wrote line 0x%08h data %h, expected victim 0x%08h data %h (handoff order)",
                                          wb.addr, w_buf, ho.addr, ho.data));
                    end
                    w_beat = 0;
                end
            end

            // -----------------------------------------------------------
            // B handshake: the write is performed.
            // -----------------------------------------------------------
            if (axi.bvalid === 1'b1 && axi.bready === 1'b1) begin
                wb = b_q.pop_front();
                for (int w = 0; w < WORDS_PER_LINE; w++)
                    mem[(wb.addr >> BYTE_OFF_WIDTH) + w] = wb.data[w*DATA_WIDTH +: DATA_WIDTH];
                if (wb_pend.exists(wb.addr) && wb_pend[wb.addr] > 0)
                    wb_pend[wb.addr]--;
                else
                    err($sformatf("AXI B: write of line 0x%08h completed with no pending writeback recorded", wb.addr));
                b_log.push_back('{addr: wb.addr, id: wb.id, cyc: cyc});
                b_cur_valid = 1'b0;
            end
        end

        // ---------------------------------------------------------------
        // Drive phase, #1 after the edge.
        // ---------------------------------------------------------------
        #1;
        if (!rst_n) begin
            axi.arready = 1'b0;
            axi.awready = 1'b0;
            axi.wready  = 1'b0;
            axi.rvalid  = 1'b0;
            axi.rid     = '0;
            axi.rdata   = '0;
            axi.rresp   = 2'b00;
            axi.rlast   = 1'b0;
            axi.bvalid  = 1'b0;
            axi.bid     = '0;
            axi.bresp   = 2'b00;
        end else begin
            axi.arready = !ar_hold && (rnd_pct() < ar_ready_pct);
            axi.awready = !aw_hold && (rnd_pct() < aw_ready_pct);
            axi.wready  = (aw_q.size() > 0) && (rnd_pct() < w_ready_pct);

            // R: a presented beat stays until handshaken; otherwise pick
            // the next one. A directed script, when present, dictates
            // the order of beats by ID; otherwise a burst already in
            // progress is continued (no interleave) or any eligible burst
            // is chosen at random (out of order, and with r_interleave,
            // beat by beat).
            if (!r_cur_valid && !r_hold) begin
                pick = -1;
                cand.delete();
                foreach (rd_order[k])
                    if (rd_tab[rd_order[k]].ready_cyc <= cyc) cand.push_back(rd_order[k]);
                if (r_script.size() > 0) begin
                    if (rd_tab.exists(r_script[0]) && rd_tab[r_script[0]].ready_cyc <= cyc) begin
                        pick = r_script[0];
                        void'(r_script.pop_front());
                    end
                end else if (cand.size() > 0 && rnd_pct() >= r_gap_pct) begin
                    if (!r_interleave)
                        foreach (cand[k])
                            if (pick < 0 && rd_tab[cand[k]].beats > 0) pick = cand[k];
                    if (pick < 0) pick = cand[rnd() % cand.size()];
                end
                if (pick >= 0) begin
                    r_cur_valid = 1'b1;
                    r_cur_id    = pick;
                end
            end
            if (r_cur_valid) begin
                rb = rd_tab[r_cur_id];
                axi.rvalid = 1'b1;
                axi.rid    = r_cur_id;
                axi.rdata  = rb.data[rb.beats*DATA_WIDTH +: DATA_WIDTH];
                axi.rlast  = (rb.beats == WORDS_PER_LINE - 1);
            end else begin
                axi.rvalid = 1'b0;
                axi.rid    = '0;
                axi.rdata  = '0;
                axi.rlast  = 1'b0;
            end
            axi.rresp = 2'b00;

            // B: presented in order once its latency has elapsed.
            if (!b_cur_valid && b_q.size() > 0 && b_q[0].ready_cyc <= cyc && !b_hold)
                b_cur_valid = 1'b1;
            axi.bvalid = b_cur_valid;
            axi.bid    = b_cur_valid ? b_q[0].id : '0;
            axi.bresp  = 2'b00;
        end
    end

    // ===================================================================
    // 5. Scoreboard and system monitor
    // ===================================================================
    // Per CPU id: outstanding flag and the expectation recorded at
    // acceptance; the response, once received, is kept for directed
    // checks.
    bit                    sb_out      [NUM_IDS];
    bit                    sb_we       [NUM_IDS];
    logic [DATA_WIDTH-1:0] sb_exp      [NUM_IDS];
    logic [ADDR_WIDTH-1:0] sb_addr     [NUM_IDS];
    longint unsigned       sb_acc_cyc  [NUM_IDS];
    logic [DATA_WIDTH-1:0] sb_got      [NUM_IDS];
    longint unsigned       sb_resp_cyc [NUM_IDS];

    int unsigned n_acc      = 0;   // requests accepted
    int unsigned n_resp     = 0;   // responses received
    int unsigned n_loads    = 0;

    typedef struct {
        logic [MSHR_ID_WIDTH-1:0] id;
        logic [ADDR_WIDTH-1:0]    addr;
        longint unsigned          cyc;
    } fill_rec_t;
    fill_rec_t fill_log [$];       // fills installed (mshr_fill_valid && mshr_fill_ready)

    // Coverage counted by the system monitor.
    int unsigned cov_dirty_wb    = 0;   // dirty victims handed to the writeback queue
    int unsigned cov_miss        = 0;   // MSHR allocations (primary + merged)
    int unsigned cov_merge       = 0;   // allocations merged into an in-flight entry
    int unsigned cov_remiss_held = 0;   // new entries held behind a queued writeback of their line
    int unsigned cov_restart     = 0;   // fills displaced between F0 and F1
    int unsigned cov_replay      = 0;   // replays issued into the lookup stage
    int unsigned cov_hum         = 0;   // CPU hits served while a miss was pending
    int unsigned cov_hit         = 0;   // CPU hits
    int unsigned cov_fill        = 0;   // fills installed
    int unsigned cov_wbq_full    = 0;   // F1 cycles stalled on a full writeback queue
    int unsigned cov_raw_stall   = 0;   // presented requests held by the same-set write hazard
    int unsigned cov_resp_bp     = 0;   // cycles with a response held by resp_ready = 0
    int unsigned cov_resp_full   = 0;   // cycles with the response FIFO full
    int unsigned cov_max_out     = 0;   // peak number of outstanding CPU requests

    // CPU response stability (valid/ready rule on the response channel).
    bit                      rh_wait = 1'b0;
    logic [TXN_ID_WIDTH-1:0] rh_id;
    logic [DATA_WIDTH-1:0]   rh_data;
    logic                    rh_we;

    // True if the NUM_WAYS ages of one set form a permutation of
    // 0..NUM_WAYS-1 (mirror of the controller's LRU invariant).
    function automatic bit lru_ok(input logic [NUM_WAYS*WAY_WIDTH-1:0] ages);
        logic [NUM_WAYS-1:0] seen;
        seen = '0;
        for (int w = 0; w < NUM_WAYS; w++)
            seen[ages[w*WAY_WIDTH +: WAY_WIDTH]] = 1'b1;
        return &seen;
    endfunction

    always @(posedge clk) begin : monitor
        logic [ADDR_WIDTH-1:0] wa;
        int unsigned           n_out;

        cyc++;
        if (rst_n) begin
            // -----------------------------------------------------------
            // Acceptance: the request takes effect now, in acceptance
            // order. A store updates the reference image; a load's
            // expected data is the reference word at this instant.
            // -----------------------------------------------------------
            if (req_valid === 1'b1 && req_ready === 1'b1) begin
                if (sb_out[req_id])
                    err($sformatf("TB: request accepted with id %0d still outstanding", req_id));
                wa = req_addr >> BYTE_OFF_WIDTH;
                sb_out[req_id]     = 1'b1;
                sb_we[req_id]      = req_we;
                sb_addr[req_id]    = req_addr;
                sb_acc_cyc[req_id] = cyc;
                if (req_we) begin
                    ref_mem[wa] = req_wdata;
                end else begin
                    sb_exp[req_id] = ref_rd(wa);
                    n_loads++;
                end
                touched[wa] = 1'b1;
                n_acc++;
            end

            // -----------------------------------------------------------
            // Response: matched by id, exactly once.
            // -----------------------------------------------------------
            if (resp_valid === 1'b1 && resp_ready === 1'b1) begin
                if (!sb_out[resp_id]) begin
                    err($sformatf("CPU response for id %0d, which is not outstanding (duplicate or spurious)", resp_id));
                end else begin
                    if (resp_we !== sb_we[resp_id])
                        err($sformatf("CPU response id %0d: resp_we %b, expected %b", resp_id, resp_we, sb_we[resp_id]));
                    else if (!sb_we[resp_id] && resp_data !== sb_exp[resp_id])
                        err($sformatf("CPU response id %0d (load 0x%08h): data 0x%08h, expected 0x%08h",
                                      resp_id, sb_addr[resp_id], resp_data, sb_exp[resp_id]));
                    sb_out[resp_id]      = 1'b0;
                    sb_got[resp_id]      = resp_data;
                    sb_resp_cyc[resp_id] = cyc;
                    n_resp++;
                end
            end

            if (rh_wait && !(resp_valid === 1'b1 && resp_id === rh_id && resp_data === rh_data && resp_we === rh_we))
                err($sformatf("CPU response changed or withdrawn while resp_ready was low (held id %0d)", rh_id));
            rh_wait = (resp_valid === 1'b1) && (resp_ready !== 1'b1);
            rh_id   = resp_id;
            rh_data = resp_data;
            rh_we   = resp_we;
            if (rh_wait) cov_resp_bp++;

            n_out = 0;
            foreach (sb_out[i]) n_out += sb_out[i];
            if (n_out > cov_max_out) cov_max_out = n_out;

            // -----------------------------------------------------------
            // Victim handoff (controller -> MSHR writeback queue). The CPU
            // is held off during a fill, so every accepted store to the
            // victim line has already been applied: the handed-off line
            // must equal the reference image of that line.
            // -----------------------------------------------------------
            if (dut.mshr_wb_valid === 1'b1 && dut.mshr_wb_ready === 1'b1) begin
                if (dut.mshr_wb_data !== ref_line(dut.mshr_wb_addr))
                    err($sformatf("victim writeback of line 0x%08h: data %h, expected %h",
                                  dut.mshr_wb_addr, dut.mshr_wb_data, ref_line(dut.mshr_wb_addr)));
                wb_handoff_q.push_back('{addr: dut.mshr_wb_addr, data: dut.mshr_wb_data, cyc: cyc});
                if (wb_pend.exists(dut.mshr_wb_addr)) wb_pend[dut.mshr_wb_addr]++;
                else                                  wb_pend[dut.mshr_wb_addr] = 1;
                cov_dirty_wb++;
            end

            if (dut.mshr_fill_valid === 1'b1 && dut.mshr_fill_ready === 1'b1) begin
                fill_log.push_back('{id: dut.mshr_fill_id, addr: dut.mshr_fill_addr, cyc: cyc});
                cov_fill++;
            end

            // -----------------------------------------------------------
            // Mirrors of the controller's assertions (ModelSim 18.1 does
            // not evaluate concurrent assertions), plus interface rules
            // between the controller and the MSHR.
            // -----------------------------------------------------------
            if (`CTRL.mshr_alloc_valid && !`CTRL.mshr_alloc_ready)
                err($sformatf("mirror: MSHR refused the allocation of line 0x%08h", `CTRL.mshr_alloc_addr));
            if (`CTRL.lookup_q.valid && !$onehot0(`CTRL.hit_vec))
                err($sformatf("mirror: several ways hit in set %0d (hit_vec %b)", `CTRL.lookup_q.set_idx, `CTRL.hit_vec));
            if (`CTRL.lookup_q.valid && `CTRL.lookup_q.replay && !`CTRL.hit_any)
                err($sformatf("mirror: replay of 0x%08h (id %0d) missed", `CTRL.lookup_q.addr, `CTRL.lookup_q.id));
            if (`CTRL.fill_wr && (|(`CTRL.tag_match & `CTRL.valid_out)))
                err($sformatf("mirror: fill of 0x%08h duplicates a line already in its set", `CTRL.mshr_fill_addr));
            if (`CTRL.wait_alloc && !`CTRL.wait_any_free)
                err("mirror: waiting table full on a miss");
            if (`CTRL.resp_push && `CTRL.resp_count >= 3)
                err("mirror: response FIFO overflow");
            if (`CTRL.fill_busy && !`CTRL.mshr_fill_valid)
                err("mirror: fill withdrawn by the MSHR during F1");
            if (`CTRL.fill_busy && `CTRL.lookup_q.valid)
                err("mirror: request in the lookup stage during fill F1");
            if (`CTRL.fill_busy && `CTRL.replay_pending)
                err("mirror: replay pending during fill F1");
            if (`CTRL.replay_pending && !$onehot(`CTRL.replay_oldest))
                err($sformatf("mirror: replay selection not one-hot (oldest %b)", `CTRL.replay_oldest));
            if (`CTRL.lru_upd_en && !lru_ok(`CTRL.lru_nxt))
                err($sformatf("mirror: LRU ages of set %0d not a permutation after update", `CTRL.lru_upd_set));
            if (dut.mshr_fill_ready && !dut.mshr_fill_valid)
                err("mirror: fill_ready without a presented fill");
            if (req_ready === 1'b1 && dut.mshr_fill_valid)
                err("mirror: req_ready high while a fill is presented");

            // -----------------------------------------------------------
            // Coverage.
            // -----------------------------------------------------------
            if (`MSHR.alloc_valid && `MSHR.alloc_ready) begin
                cov_miss++;
                if (`MSHR.fe_any_match) cov_merge++;
                else if (|(`MSHR.wb_alloc_match & ~`MSHR.wb_pop_mask)) cov_remiss_held++;
            end
            if (`CTRL.fill_busy && !`CTRL.fill_id_same)                               cov_restart++;
            if (`CTRL.lookup_q.valid && `CTRL.lookup_q.replay)                        cov_replay++;
            if (`CTRL.lookup_hit && !`CTRL.lookup_q.replay)                           cov_hit++;
            if (`CTRL.lookup_hit && !`CTRL.lookup_q.replay && (|`CTRL.wait_valid))    cov_hum++;
            if (`CTRL.fill_busy && `CTRL.fill_id_same && `CTRL.victim_dirty && !`CTRL.mshr_wb_ready)
                cov_wbq_full++;
            if (req_valid === 1'b1 && `CTRL.raw_hazard)                               cov_raw_stall++;
            if (`CTRL.resp_count == 3)                                                cov_resp_full++;
        end
    end

    // CPU response back-pressure: re-drawn #1 after every edge. A long
    // stall (resp_stall_len cycles) can be started at random to back up
    // the response FIFO, the waiting table and, through them, the CPU.
    always @(posedge clk) begin
        #1;
        if (resp_stall_len > 0) begin
            resp_stall_len--;
            resp_ready = 1'b0;
        end else if (resp_stall_pct > 0 && rnd_pct() < resp_stall_pct) begin
            resp_stall_len = rnd_range(20, 80);
            resp_ready     = 1'b0;
        end else begin
            resp_ready = (resp_ready_pct >= 100) || (rnd_pct() < resp_ready_pct);
        end
    end

    // ===================================================================
    // Hang handling and idle detection
    // ===================================================================
    task automatic dump_state();
        $display("[DIAG] cycle %0d: outstanding CPU ids:", cyc);
        foreach (sb_out[i])
            if (sb_out[i])
                $display("[DIAG]   id %0d %s 0x%08h accepted at cycle %0d",
                         i, sb_we[i] ? "store" : "load", sb_addr[i], sb_acc_cyc[i]);
        for (int i = 0; i < 2 ** MSHR_ID_WIDTH; i++)
            if (`MSHR.fe_state[i] != 0)
                $display("[DIAG]   MSHR entry %0d state %0d addr 0x%08h wb_wait %b",
                         i, `MSHR.fe_state[i], `MSHR.fe_addr[i], `MSHR.fe_wb_wait[i]);
        $display("[DIAG]   MSHR wb_state %0d wb_count %0d; slave: %0d reads, %0d AW pending data, %0d B pending",
                 `MSHR.wb_state, `MSHR.wb_count, rd_order.size(), aw_q.size(), b_q.size());
        $display("[DIAG]   controller: wait_valid %b wait_ready %b fill_busy %b resp_count %0d req_ready %b",
                 `CTRL.wait_valid, `CTRL.wait_ready, `CTRL.fill_busy, `CTRL.resp_count, req_ready);
        $display("[DIAG]   holds: ar %b aw %b r %b b %b",
                 ar_hold, aw_hold, r_hold, b_hold);
    endtask

    // Converts a watchdog expiry into a [FAIL] of the current test and
    // ends the run: the system state after a hang is undefined, so later
    // tests could not produce meaningful results.
    task automatic hang(input string what);
        err($sformatf("watchdog: %s", what));
        dump_state();
        $display("[FAIL] %s: hang -- %s", cur_test, what);
        n_fail++;
        print_summary();
        $finish;
    endtask

    function automatic int unsigned n_outstanding();
        int unsigned n;
        n = 0;
        foreach (sb_out[i]) n += sb_out[i];
        return n;
    endfunction

    // The whole system is quiescent: no CPU request outstanding, nothing
    // held in the controller or the MSHR, no AXI transaction in flight.
    function automatic bit sys_idle();
        if (n_outstanding() != 0 || req_valid) return 1'b0;
        if (rd_order.size() != 0 || aw_q.size() != 0 || b_q.size() != 0 || r_cur_valid || b_cur_valid) return 1'b0;
        if (`MSHR.wb_count != 0 || `MSHR.wb_state != 0) return 1'b0;
        for (int i = 0; i < 2 ** MSHR_ID_WIDTH; i++)
            if (`MSHR.fe_state[i] != 0) return 1'b0;
        if (`CTRL.wait_valid != '0 || `CTRL.fill_busy || `CTRL.resp_count != 0 || `CTRL.lookup_q.valid) return 1'b0;
        return 1'b1;
    endfunction

    task automatic wait_idle(input string what);
        int unsigned waited;
        waited = 0;
        while (!sys_idle()) begin
            @(posedge clk);
            #1;
            if (++waited > IDLE_TIMEOUT)
                hang($sformatf("system not idle %0d cycles after %s", IDLE_TIMEOUT, what));
        end
    endtask

    task automatic wait_cycles(input int unsigned n);
        repeat (n) @(posedge clk);
        #1;
    endtask

    // ===================================================================
    // 6. CPU driver
    // ===================================================================
    // Free-id selection: never an id that is still outstanding. Directed
    // tests take the lowest free id (readable traces); the random driver
    // takes a random free id.
    function automatic int pick_free_id(input bit random_pick);
        int unsigned free_ids [$];
        foreach (sb_out[i]) if (!sb_out[i]) free_ids.push_back(i);
        if (free_ids.size() == 0) return -1;
        return random_pick ? free_ids[rnd() % free_ids.size()] : free_ids[0];
    endfunction

    // Presents one request and returns #1 after the edge on which it was
    // accepted. Called #1 after an edge. The request stays valid with an
    // unchanged payload until accepted (valid/ready rule). Acceptance is
    // sampled on the edge (pre-edge req_ready): req_ready depends
    // combinationally on req_addr, so it must not be read in the same
    // time step in which the address is driven.
    task automatic cpu_issue(input  logic [ADDR_WIDTH-1:0] addr,
                             input  logic                  we,
                             input  logic [DATA_WIDTH-1:0] wdata,
                             input  bit                    random_id,
                             output int                    id);
        int unsigned waited;
        bit          acc;

        waited = 0;
        id     = pick_free_id(random_id);
        while (id < 0) begin
            @(posedge clk);
            #1;
            if (++waited > RESP_TIMEOUT)
                hang($sformatf("no CPU id freed within %0d cycles", RESP_TIMEOUT));
            id = pick_free_id(random_id);
        end

        req_addr  = addr;
        req_we    = we;
        req_wdata = wdata;
        req_id    = id;
        req_valid = 1'b1;
        waited    = 0;
        do begin
            @(posedge clk);
            acc = (req_ready === 1'b1);
            #1;
            if (!acc && ++waited > REQ_TIMEOUT)
                hang($sformatf("request id %0d to 0x%08h not accepted within %0d cycles", id, addr, REQ_TIMEOUT));
        end while (!acc);
        req_valid = 1'b0;
    endtask

    // Waits for the response of id; returns its data.
    task automatic cpu_wait(input int id, output logic [DATA_WIDTH-1:0] data);
        int unsigned waited;
        waited = 0;
        while (sb_out[id]) begin
            @(posedge clk);
            #1;
            if (++waited > RESP_TIMEOUT)
                hang($sformatf("no response for id %0d (0x%08h) within %0d cycles", id, sb_addr[id], RESP_TIMEOUT));
        end
        data = sb_got[id];
    endtask

    // One blocking access: issue, then wait for its response.
    task automatic cpu_access(input  logic [ADDR_WIDTH-1:0] addr,
                              input  logic                  we,
                              input  logic [DATA_WIDTH-1:0] wdata,
                              output logic [DATA_WIDTH-1:0] data,
                              output int                    id);
        cpu_issue(addr, we, wdata, 1'b0, id);
        cpu_wait(id, data);
    endtask

    // Convenience forms.
    task automatic load(input logic [ADDR_WIDTH-1:0] addr, output logic [DATA_WIDTH-1:0] data);
        int id;
        cpu_access(addr, 1'b0, '0, data, id);
    endtask

    task automatic store(input logic [ADDR_WIDTH-1:0] addr, input logic [DATA_WIDTH-1:0] wdata);
        logic [DATA_WIDTH-1:0] d;
        int                    id;
        cpu_access(addr, 1'b1, wdata, d, id);
    endtask

    // -------------------------------------------------------------------
    // Constrained-random traffic.
    // Addresses are drawn from rnd_sets x rnd_ntags lines (more lines per
    // set than ways, so evictions, dirty writebacks and re-misses occur),
    // with a locality bias towards the previous line (hits, merges,
    // hit-under-miss). Up to max_out requests are outstanding at once.
    // -------------------------------------------------------------------
    int unsigned rnd_sets [$];
    int unsigned rnd_ntags    = 8;
    int unsigned req_rate_pct = 80;    // probability of presenting a request in a cycle
    int unsigned we_pct       = 40;    // store probability
    int unsigned loc_pct      = 40;    // probability of reusing the previous line
    int unsigned max_out      = NUM_IDS;

    task automatic random_traffic(input int unsigned n, input logic [TAG_WIDTH-1:0] tag_base);
        logic [ADDR_WIDTH-1:0] addr, prev;
        int                    id;
        int unsigned           waited;

        prev = make_addr(tag_base, rnd_sets[0], 0);
        for (int unsigned i = 0; i < n; i++) begin
            // Idle cycles, and the outstanding-request cap.
            waited = 0;
            while (rnd_pct() >= req_rate_pct || n_outstanding() >= max_out) begin
                @(posedge clk);
                #1;
                if (++waited > RESP_TIMEOUT)
                    hang("random driver: outstanding requests never drained below the cap");
            end
            if (rnd_pct() < loc_pct)
                addr = make_addr(prev[ADDR_WIDTH-1:LINE_OFF_WIDTH+SET_IDX_WIDTH],
                                 prev[LINE_OFF_WIDTH +: SET_IDX_WIDTH], rnd() % WORDS_PER_LINE);
            else
                addr = make_addr(tag_base + (rnd() % rnd_ntags), rnd_sets[rnd() % rnd_sets.size()],
                                 rnd() % WORDS_PER_LINE);
            prev = addr;
            cpu_issue(addr, rnd_pct() < we_pct, rnd(), 1'b1, id);
        end
    endtask

    // Draws a memory/CPU timing profile for one phase of the random test.
    // One phase in four starves the write channel so that the writeback
    // queue fills and re-misses wait for slow write responses.
    task automatic draw_profile();
        bit starve;
        starve         = (rnd() % 4) == 0;
        ar_ready_pct   = rnd_range(30, 100);
        aw_ready_pct   = starve ? rnd_range(2, 8) : rnd_range(30, 100);
        w_ready_pct    = rnd_range(40, 100);
        r_gap_pct      = rnd_range(0, 40);
        r_lat_min      = 1;
        r_lat_max      = rnd_range(1, 40);
        b_lat_min      = 1;
        b_lat_max      = starve ? rnd_range(40, 100) : rnd_range(1, 40);
        r_interleave   = rnd() % 2;
        resp_ready_pct = rnd_range(40, 100);
        resp_stall_pct = (rnd() % 3 == 0) ? 1 : 0;
        req_rate_pct   = rnd_range(30, 100);
        we_pct         = rnd_range(20, 60);
        loc_pct        = rnd_range(10, 60);
        max_out        = (rnd() % 4 == 0) ? rnd_range(1, 4) : NUM_IDS;
    endtask

    task automatic default_profile();
        ar_ready_pct   = 100;
        aw_ready_pct   = 100;
        w_ready_pct    = 100;
        r_gap_pct      = 0;
        r_lat_min      = 2;
        r_lat_max      = 2;
        b_lat_min      = 1;
        b_lat_max      = 1;
        r_interleave   = 1'b0;
        resp_ready_pct = 100;
        resp_stall_pct = 0;
        max_out        = NUM_IDS;
    endtask

    // ===================================================================
    // White-box views of the tag and data storage
    // Both arrays are built from sram_sdp banks inside generate blocks,
    // which cannot be selected by a run-time way or word number. These
    // continuous assignments collect the banks into plain arrays that
    // check_consistency can index freely.
    // ===================================================================
    logic [TAG_WIDTH-1:0]  tag_view  [NUM_WAYS][NUM_SETS];
    logic [DATA_WIDTH-1:0] word_view [NUM_WAYS][WORDS_PER_LINE][NUM_SETS];

    for (genvar w = 0; w < NUM_WAYS; w++) begin : g_view
        assign tag_view[w] = dut.u_tag_array.g_way[w].u_tag_bank.mem;
        for (genvar i = 0; i < WORDS_PER_LINE; i++) begin : g_word
            assign word_view[w][i] = dut.u_data_sram.g_way[w].g_word[i].u_bank.mem;
        end
    end

    function automatic logic [LINE_WIDTH-1:0] cached_line(int way, int set);
        for (int i = 0; i < WORDS_PER_LINE; i++)
            cached_line[i*DATA_WIDTH +: DATA_WIDTH] = word_view[way][i][set];
    endfunction

    // ===================================================================
    // End-of-test consistency (white-box)
    // For every line ever accessed: if the cache holds it valid and dirty,
    // the cached copy must equal the reference image; otherwise the
    // backing store must, and a clean cached copy must match too. Also
    // checks that no set holds a tag twice and that every set's LRU ages
    // are a permutation. Called with the system idle.
    // ===================================================================
    task automatic check_consistency(output int unsigned n_lines, output int unsigned n_dirty);
        bit [ADDR_WIDTH-1:0]   lines [bit [ADDR_WIDTH-1:0]];
        logic [SET_IDX_WIDTH-1:0] s;
        logic [TAG_WIDTH-1:0]  t;
        logic [LINE_WIDTH-1:0] exp;
        int                    way;

        n_lines = 0;
        n_dirty = 0;
        foreach (touched[wa]) lines[line_of(wa << BYTE_OFF_WIDTH)] = 1'b1;
        foreach (lines[la]) begin
            s   = la[LINE_OFF_WIDTH +: SET_IDX_WIDTH];
            t   = la[ADDR_WIDTH-1 -: TAG_WIDTH];
            exp = ref_line(la);
            way = -1;
            for (int w = 0; w < NUM_WAYS; w++)
                if (dut.u_valid_array.valid_mem[w][s] && tag_view[w][s] == t) begin
                    if (way >= 0) err($sformatf("consistency: line 0x%08h present in ways %0d and %0d", la, way, w));
                    way = w;
                end
            if (way >= 0 && dut.u_tag_array.dirty_mem[way][s]) begin
                n_dirty++;
                if (cached_line(way, s) !== exp)
                    err($sformatf("consistency: dirty cached line 0x%08h = %h, reference %h",
                                  la, cached_line(way, s), exp));
            end else begin
                if (mem_line(la) !== exp)
                    err($sformatf("consistency: memory line 0x%08h = %h, reference %h (not dirty in the cache)",
                                  la, mem_line(la), exp));
                if (way >= 0 && cached_line(way, s) !== exp)
                    err($sformatf("consistency: clean cached line 0x%08h = %h, reference %h",
                                  la, cached_line(way, s), exp));
            end
            n_lines++;
        end
        for (int si = 0; si < NUM_SETS; si++)
            if (!lru_ok(`CTRL.lru_age[si]))
                err($sformatf("consistency: LRU ages of set %0d are not a permutation", si));
    endtask

    // ===================================================================
    // 7. Tests
    // ===================================================================
    // Global watchdog: a last line of defence should a wait loop itself
    // be defective.
    // The bound grows with the requested random-test length.
    initial begin
        int unsigned nreq, limit;
        if (!$value$plusargs("nreq=%d", nreq)) nreq = 5000;
        limit = GLOBAL_TIMEOUT + 400 * nreq;
        repeat (limit) @(posedge clk);
        cur_test = "global";
        hang($sformatf("global watchdog expired after %0d cycles", limit));
    end

    initial begin
        int unsigned n_random;

        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("nreq=%d", n_random)) n_random = 5000;
        rng_state = seed * 32'h9E37_79B9 + 32'h7F4A_7C15;
        if (rng_state == 0) rng_state = 32'h1;
        $display("[INFO] cache_top_tb: seed %0d, %0d random requests", seed, n_random);

        req_valid  = 1'b0;
        req_addr   = '0;
        req_we     = 1'b0;
        req_wdata  = '0;
        req_id     = '0;
        resp_ready = 1'b1;
        foreach (sb_out[i]) sb_out[i] = 1'b0;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        rst_n = 1'b1;

        // ---------------------------------------------------------------
        // Test 1: reset idle.
        // Concept: right after reset the cache must be ready to accept
        //   work and must not start any memory traffic or produce any
        //   response of its own.
        // Implementation: for 20 cycles after reset, sample the CPU
        //   ready/valid outputs and every master-side AXI valid on the
        //   edge.
        // ---------------------------------------------------------------
        test_begin("test 1");
        begin
            int unsigned bad;
            bad = 0;
            repeat (20) begin
                @(posedge clk);
                if (req_ready !== 1'b1 || resp_valid !== 1'b0 || axi.arvalid !== 1'b0 ||
                    axi.awvalid !== 1'b0 || axi.wvalid !== 1'b0)
                    bad++;
            end
            #1;
            if (bad != 0)
                err($sformatf("%0d of 20 cycles after reset not idle (req_ready 1, no response, no AXI request expected)", bad));
        end
        test_end("idle after reset -- ready, no response, no AXI request");

        // ---------------------------------------------------------------
        // Test 2: load miss -> fill -> hit.
        // Concept: a load to an absent line fetches the line from memory
        //   exactly once and returns the memory word; a later load to
        //   another word of the same line is served from the cache with
        //   the hit latency and without memory traffic.
        // Implementation: blocking load to set 10, word 2; count AR
        //   handshakes and check the address; then a load to word 0 and
        //   check that no AR occurred and that the response came two
        //   cycles after acceptance.
        // ---------------------------------------------------------------
        test_begin("test 2");
        begin
            logic [ADDR_WIDTH-1:0] a;
            logic [DATA_WIDTH-1:0] d;
            int                    id, n_ar;

            a    = make_addr(DIR_TAG_BASE + 1, 10, 2);
            n_ar = ar_log.size();
            cpu_access(a, 1'b0, '0, d, id);
            if (ar_log.size() != n_ar + 1)
                err($sformatf("load miss caused %0d AR(s), expected 1", ar_log.size() - n_ar));
            else if (ar_log[n_ar].addr !== line_of(a))
                err($sformatf("AR address 0x%08h, expected 0x%08h", ar_log[n_ar].addr, line_of(a)));
            if (d !== init_word(a >> 2))
                err($sformatf("miss data 0x%08h, expected memory word 0x%08h", d, init_word(a >> 2)));

            n_ar = ar_log.size();
            a    = make_addr(DIR_TAG_BASE + 1, 10, 0);
            cpu_access(a, 1'b0, '0, d, id);
            if (ar_log.size() != n_ar)
                err("load to a resident line caused memory traffic");
            if (sb_resp_cyc[id] - sb_acc_cyc[id] != 2)
                err($sformatf("hit latency %0d cycles, expected 2", sb_resp_cyc[id] - sb_acc_cyc[id]));
        end
        test_end("load miss filled with one line-aligned AR, then a 2-cycle hit with no memory traffic");

        // ---------------------------------------------------------------
        // Test 3: store miss (write-allocate), then load.
        // Concept: a store to an absent line brings the line into the
        //   cache and modifies only the stored word; the line becomes
        //   dirty but is not written to memory until evicted.
        // Implementation: blocking store to set 11 word 1; check one AR
        //   and a store acknowledge; load the stored word (new value) and
        //   a neighbour word (memory value); check that no AW occurred.
        // ---------------------------------------------------------------
        test_begin("test 3");
        begin
            logic [ADDR_WIDTH-1:0] a;
            logic [DATA_WIDTH-1:0] d;
            int                    id, n_ar, n_aw;

            n_ar = ar_log.size();
            n_aw = aw_log.size();
            a    = make_addr(DIR_TAG_BASE + 1, 11, 1);
            cpu_access(a, 1'b1, 32'hDEAD_BEEF, d, id);
            if (ar_log.size() != n_ar + 1)
                err($sformatf("store miss caused %0d AR(s), expected 1 (write-allocate)", ar_log.size() - n_ar));
            load(a, d);
            if (d !== 32'hDEAD_BEEF)
                err($sformatf("load after store miss returned 0x%08h, expected 0xDEADBEEF", d));
            load(make_addr(DIR_TAG_BASE + 1, 11, 3), d);
            if (d !== init_word(make_addr(DIR_TAG_BASE + 1, 11, 3) >> 2))
                err("neighbour word of the allocated line does not hold the memory value");
            if (aw_log.size() != n_aw)
                err("store caused a memory write (write-back cache must defer it to eviction)");
            if (ar_log.size() != n_ar + 1)
                err("loads to the allocated line caused further reads");
        end
        test_end("store miss allocated the line (one AR, no AW); stored word and memory neighbour read back correctly");

        // ---------------------------------------------------------------
        // Test 4: hit-under-miss.
        // Concept: while one line is being fetched from a slow memory,
        //   requests to a resident line keep completing at full speed.
        // Implementation: install line A (set 12); freeze the read-data
        //   channel; issue a load miss to line B (set 13) without waiting;
        //   then eight blocking loads/stores to A, each of which must
        //   respond with the 2-cycle hit latency while B is still
        //   outstanding; release the channel and wait for B.
        // ---------------------------------------------------------------
        test_begin("test 4");
        begin
            logic [DATA_WIDTH-1:0] d;
            int                    id_b, id;
            int unsigned           hum0;

            load(make_addr(DIR_TAG_BASE + 1, 12, 0), d);
            hum0   = cov_hum;
            r_hold = 1'b1;
            cpu_issue(make_addr(DIR_TAG_BASE + 1, 13, 1), 1'b0, '0, 1'b0, id_b);
            for (int k = 0; k < 8; k++) begin
                cpu_access(make_addr(DIR_TAG_BASE + 1, 12, k % 4), k % 2, 32'h4400_0000 + k, d, id);
                if (sb_resp_cyc[id] - sb_acc_cyc[id] != 2)
                    err($sformatf("hit %0d under a pending miss took %0d cycles, expected 2", k, sb_resp_cyc[id] - sb_acc_cyc[id]));
                if (!sb_out[id_b])
                    err("pending miss completed while the read channel was frozen");
            end
            if (cov_hum - hum0 < 8)
                err($sformatf("only %0d hits recorded while a miss was pending, expected 8", cov_hum - hum0));
            r_hold = 1'b0;
            cpu_wait(id_b, d);
            wait_idle("test 4");
        end
        test_end("8 hits served with 2-cycle latency while a miss was outstanding; the miss then completed correctly");

        // ---------------------------------------------------------------
        // Test 5: secondary-miss merge.
        // Concept: several requests to one missing line, including a
        //   store followed by a load of the same word, share one memory
        //   read and complete in arrival order once the line arrives.
        // Implementation: freeze the read-data channel; issue eight
        //   requests to line C (set 14) back to back without waiting;
        //   check that exactly one AR was issued and that seven of the
        //   misses merged; release; check every response, in particular
        //   the loads that follow stores to the same word.
        // ---------------------------------------------------------------
        test_begin("test 5");
        begin
            logic [DATA_WIDTH-1:0] d;
            int                    ids [8];
            int unsigned           merge0, n_ar;
            logic                  we   [8];
            int                    word [8];
            logic [DATA_WIDTH-1:0] wd   [8];

            // Request k: load/store, word offset, store data. Stores 1, 3
            // and 6 are each followed by a load of the same word.
            we   = '{0, 1, 0, 1, 0, 0, 1, 0};
            word = '{0, 1, 1, 0, 0, 3, 1, 1};
            for (int k = 0; k < 8; k++) wd[k] = 32'h5500_0000 + k;
            merge0 = cov_merge;
            n_ar   = ar_log.size();
            r_hold = 1'b1;
            for (int k = 0; k < 8; k++)
                cpu_issue(make_addr(DIR_TAG_BASE + 1, 14, word[k]), we[k], wd[k], 1'b0, ids[k]);
            wait_cycles(10);
            if (ar_log.size() != n_ar + 1)
                err($sformatf("%0d AR(s) for 8 requests to one missing line, expected 1", ar_log.size() - n_ar));
            if (cov_merge - merge0 != 7)
                err($sformatf("%0d merges, expected 7", cov_merge - merge0));
            r_hold = 1'b0;
            for (int k = 0; k < 8; k++) cpu_wait(ids[k], d);
            if (sb_got[ids[2]] !== wd[1]) err("load of word 1 after a merged store did not return the stored value");
            if (sb_got[ids[4]] !== wd[3]) err("load of word 0 after a merged store did not return the stored value");
            if (sb_got[ids[7]] !== wd[6]) err("load of word 1 after a second merged store did not return the newest value");
            wait_idle("test 5");
        end
        test_end("8 requests to one missing line: 1 AR, 7 merges, replayed in arrival order (store->load forwarding correct)");

        // ---------------------------------------------------------------
        // Test 6: fill into a full set with a dirty victim.
        // Concept: when a set is full, the least recently used line is
        //   replaced; if it was modified, its complete, up-to-date
        //   contents are written back to its own address.
        // Implementation: fill set 15 with four lines; store to line 1
        //   (dirty, most recent); touch lines 2-4 so that line 1 is least
        //   recently used; load a fifth line. Check that exactly one
        //   write burst occurs, to line 1's address, carrying the
        //   reference image of line 1 (memory word + stored word), and
        //   that afterwards memory holds that line.
        // ---------------------------------------------------------------
        test_begin("test 6");
        begin
            logic [DATA_WIDTH-1:0] d;
            logic [ADDR_WIDTH-1:0] victim;
            logic [LINE_WIDTH-1:0] exp;
            int unsigned           n_wl;

            for (int t = 1; t <= 4; t++) load(make_addr(DIR_TAG_BASE + t, 15, 0), d);
            store(make_addr(DIR_TAG_BASE + 1, 15, 2), 32'h6666_0001);
            for (int t = 2; t <= 4; t++) load(make_addr(DIR_TAG_BASE + t, 15, 1), d);
            victim = make_addr(DIR_TAG_BASE + 1, 15, 0);
            exp    = ref_line(victim);
            n_wl   = wl_log.size();
            load(make_addr(DIR_TAG_BASE + 5, 15, 3), d);
            wait_idle("test 6");
            if (wl_log.size() != n_wl + 1) begin
                err($sformatf("%0d write burst(s) after evicting one dirty line, expected 1", wl_log.size() - n_wl));
            end else begin
                if (wl_log[n_wl].addr !== victim)
                    err($sformatf("writeback to 0x%08h, expected the LRU dirty line 0x%08h", wl_log[n_wl].addr, victim));
                if (wl_log[n_wl].data !== exp)
                    err($sformatf("writeback data %h, expected %h", wl_log[n_wl].data, exp));
            end
            if (mem_line(victim) !== exp)
                err("memory does not hold the written-back line after its B response");
        end
        test_end("LRU dirty victim written back once, to its own address, with its full modified contents");

        // ---------------------------------------------------------------
        // Test 7: re-miss to a just-evicted dirty line, write response
        //   delayed.
        // Concept: if a line is evicted dirty and requested again before
        //   memory has confirmed the write, the new read must not overtake
        //   the write; the request must return the written data.
        // Implementation: as in test 6 (set 16), make line 1 dirty and
        //   least recently used; hold all write responses; evict line 1
        //   with a fifth line. Then load line 1 again without waiting:
        //   for 60 cycles no AR to line 1 may appear (the MSHR must hold
        //   it); release the write response and check that the AR follows
        //   the B response and the load returns the stored value.
        // ---------------------------------------------------------------
        test_begin("test 7");
        begin
            logic [DATA_WIDTH-1:0] d;
            logic [ADDR_WIDTH-1:0] l1;
            int                    id;
            int unsigned           n_ar, held0, n_b;
            bit                    found;

            for (int t = 1; t <= 4; t++) load(make_addr(DIR_TAG_BASE + t, 16, 0), d);
            store(make_addr(DIR_TAG_BASE + 1, 16, 3), 32'h7777_0003);
            for (int t = 2; t <= 4; t++) load(make_addr(DIR_TAG_BASE + t, 16, 1), d);
            l1     = make_addr(DIR_TAG_BASE + 1, 16, 0);
            b_hold = 1'b1;
            n_b    = b_log.size();
            load(make_addr(DIR_TAG_BASE + 5, 16, 0), d);      // evicts dirty line 1
            held0  = cov_remiss_held;
            n_ar   = ar_log.size();
            cpu_issue(make_addr(DIR_TAG_BASE + 1, 16, 3), 1'b0, '0, 1'b0, id);
            wait_cycles(60);
            for (int k = n_ar; k < ar_log.size(); k++)
                if (ar_log[k].addr === l1) err("re-miss read issued while the writeback's B response was held");
            if (!sb_out[id]) err("re-miss completed while the writeback was unacknowledged");
            if (cov_remiss_held - held0 != 1)
                err($sformatf("re-miss not recorded as held by the writeback rule (%0d)", cov_remiss_held - held0));
            if (b_log.size() != n_b) err("B response observed while held");
            b_hold = 1'b0;
            cpu_wait(id, d);
            if (d !== 32'h7777_0003)
                err($sformatf("re-miss returned 0x%08h, expected the written-back value 0x77770003", d));
            found = 1'b0;
            for (int k = n_ar; k < ar_log.size(); k++)
                if (ar_log[k].addr === l1) begin
                    found = 1'b1;
                    if (b_log.size() <= n_b || ar_log[k].cyc <= b_log[n_b].cyc)
                        err("re-miss read did not follow the writeback's B response");
                end
            if (!found) err("no read of the re-missed line");
            wait_idle("test 7");
        end
        test_end("re-miss held until the writeback's B response, then returned the written-back data");

        // ---------------------------------------------------------------
        // Test 8: writeback queue full.
        // Concept: when memory stops accepting writes, evictions of dirty
        //   lines accumulate in the writeback queue; once it is full, the
        //   next eviction must wait without losing or corrupting anything,
        //   and the cache must stop accepting new requests meanwhile.
        // Implementation: hold the write-address channel; store to nine
        //   lines of set 17 one after another (each miss allocates and
        //   dirties a line; misses 5-8 evict dirty lines 1-4, filling the
        //   4-entry queue); the ninth miss must stall in its fill (victim
        //   line 5 dirty). Check the stall for 40 cycles: no response,
        //   req_ready low, stall cycles counted. Release; check that five
        //   write bursts go out in eviction order with the right data.
        // ---------------------------------------------------------------
        test_begin("test 8");
        begin
            logic [DATA_WIDTH-1:0] d;
            int                    id;
            int unsigned           n_wl, full0, rdy;

            n_wl    = wl_log.size();
            aw_hold = 1'b1;
            for (int t = 1; t <= 8; t++) store(make_addr(DIR_TAG_BASE + t, 17, t % 4), 32'h8800_0000 + t);
            full0 = cov_wbq_full;
            cpu_issue(make_addr(DIR_TAG_BASE + 9, 17, 1), 1'b1, 32'h8800_0009, 1'b0, id);
            // The stall begins only once the ninth line has been fetched
            // and its fill reaches F1; wait for that point (bounded)
            // before sampling, since the CPU is legitimately accepted
            // while the miss is still in flight.
            begin
                int unsigned waited;
                waited = 0;
                while (cov_wbq_full == full0) begin
                    @(posedge clk);
                    #1;
                    if (++waited > 1000) hang("fill of the ninth line never stalled on the full writeback queue");
                end
            end
            full0 = cov_wbq_full;
            rdy   = 0;
            repeat (40) begin
                @(posedge clk);
                if (req_ready === 1'b1) rdy++;
            end
            #1;
            if (!sb_out[id]) err("the ninth store completed while the writeback queue was full");
            if (cov_wbq_full - full0 < 40)
                err($sformatf("fill stalled on the full writeback queue for only %0d cycles", cov_wbq_full - full0));
            if (rdy != 0) err($sformatf("req_ready high in %0d cycles of the stalled fill", rdy));
            aw_hold = 1'b0;
            cpu_wait(id, d);
            wait_idle("test 8");
            if (wl_log.size() != n_wl + 5) begin
                err($sformatf("%0d write bursts, expected 5", wl_log.size() - n_wl));
            end else begin
                for (int k = 0; k < 5; k++)
                    if (wl_log[n_wl + k].addr !== make_addr(DIR_TAG_BASE + 1 + k, 17, 0))
                        err($sformatf("write burst %0d to 0x%08h, expected line %0d (eviction order)",
                                      k, wl_log[n_wl + k].addr, 1 + k));
            end
        end
        test_end("writeback queue filled (4), fifth eviction stalled with the CPU held off, then 5 writebacks drained in order");

        // ---------------------------------------------------------------
        // Test 9: fill selection change between F0 and F1.
        // Concept: when two lines arrive back to back and the later one
        //   has priority in the MSHR, the fill already started for the
        //   earlier one is abandoned and restarted after the other line;
        //   both must be installed exactly once and serve their requests.
        // Implementation: freeze R; load misses to lines P (set 18) and
        //   Q (set 19) -- with the MSHR idle they receive MSHR ids 0 and
        //   1; script the R beats so that the higher id completes one
        //   cycle before the lower id; check exactly one fill restart,
        //   the fill order (lower id first after the restart) and both
        //   responses.
        // ---------------------------------------------------------------
        test_begin("test 9");
        begin
            logic [DATA_WIDTH-1:0] d;
            int                    id_p, id_q;
            int unsigned           rs0, n_fill, n_ar, lo, hi;

            wait_idle("test 9 setup");
            rs0    = cov_restart;
            n_fill = fill_log.size();
            n_ar   = ar_log.size();
            r_hold = 1'b1;
            cpu_issue(make_addr(DIR_TAG_BASE + 1, 18, 0), 1'b0, '0, 1'b0, id_p);
            cpu_issue(make_addr(DIR_TAG_BASE + 1, 19, 0), 1'b0, '0, 1'b0, id_q);
            wait_cycles(10);
            if (ar_log.size() != n_ar + 2) begin
                err("expected two ARs before scripting the R channel");
            end else begin
                lo = (ar_log[n_ar].id < ar_log[n_ar + 1].id) ? ar_log[n_ar].id : ar_log[n_ar + 1].id;
                hi = (ar_log[n_ar].id < ar_log[n_ar + 1].id) ? ar_log[n_ar + 1].id : ar_log[n_ar].id;
                r_script = '{lo, lo, lo, hi, hi, hi, hi, lo};
            end
            r_hold = 1'b0;
            cpu_wait(id_p, d);
            cpu_wait(id_q, d);
            wait_idle("test 9");
            if (cov_restart - rs0 != 1)
                err($sformatf("%0d fill restart(s), expected 1", cov_restart - rs0));
            if (fill_log.size() != n_fill + 2)
                err($sformatf("%0d fills, expected 2", fill_log.size() - n_fill));
            else if (fill_log[n_fill].id != lo || fill_log[n_fill + 1].id != hi)
                err($sformatf("fill order ids %0d, %0d, expected %0d then %0d",
                              fill_log[n_fill].id, fill_log[n_fill + 1].id, lo, hi));
        end
        test_end("higher-id fill displaced in F1 by a lower-id fill completing one cycle later; both installed once, in priority order");

        // ---------------------------------------------------------------
        // Test 10: CPU response back-pressure during misses.
        // Concept: a CPU that is slow to take responses must not cause
        //   any response to be lost, duplicated or altered, even while
        //   misses, fills and replays are in progress.
        // Implementation: 400 random requests over two sets (8 lines
        //   each) with resp_ready high only 20 % of the time and random
        //   long stalls; moderate memory latency. Checks are the
        //   scoreboard and the response-stability monitor; coverage
        //   floors make sure the response FIFO actually filled.
        // ---------------------------------------------------------------
        test_begin("test 10");
        begin
            int unsigned bp0, full0, miss0;
            bp0   = cov_resp_bp;
            full0 = cov_resp_full;
            miss0 = cov_miss;
            default_profile();
            r_lat_max      = 12;
            r_interleave   = 1'b1;
            resp_ready_pct = 20;
            resp_stall_pct = 2;
            req_rate_pct   = 90;
            we_pct         = 40;
            loc_pct        = 40;
            rnd_sets       = '{20, 21};
            rnd_ntags      = 8;
            random_traffic(400, DIR_TAG_BASE);
            wait_idle("test 10");
            default_profile();
            if (cov_resp_bp - bp0 < 200)
                err($sformatf("only %0d back-pressured response cycles", cov_resp_bp - bp0));
            if (cov_resp_full - full0 < 20)
                err($sformatf("response FIFO full in only %0d cycles", cov_resp_full - full0));
            if (cov_miss - miss0 < 30)
                err($sformatf("only %0d misses under back-pressure", cov_miss - miss0));
            $display("[INFO] test 10: %0d back-pressured cycles, FIFO full %0d cycles, %0d misses",
                     cov_resp_bp - bp0, cov_resp_full - full0, cov_miss - miss0);
        end
        test_end("400 requests with 20 % resp_ready and long stalls: every response delivered once, correct and stable");

        // ---------------------------------------------------------------
        // Test 11: constrained-random.
        // Concept: long random mixes of loads and stores over a small
        //   footprint (four sets, eight lines each -- twice the
        //   associativity), with randomly varying memory timing and CPU
        //   back-pressure, must always behave like a flat memory, and must
        //   actually exercise every difficult mechanism.
        // Implementation: n_random requests in phases of 250, each with a
        //   freshly drawn timing profile (one in four starves the write
        //   channel); scoreboard, protocol and assertion-mirror checks run
        //   throughout; coverage counters are checked against floors.
        // ---------------------------------------------------------------
        test_begin("test 11");
        begin
            int unsigned c_wb, c_merge, c_held, c_rs, c_rp, c_hum, c_ooo, c_il, c_full, c_miss, c_hit, c_raw;
            int unsigned done, chunk;

            c_wb   = cov_dirty_wb;   c_merge = cov_merge;    c_held = cov_remiss_held;
            c_rs   = cov_restart;    c_rp    = cov_replay;   c_hum  = cov_hum;
            c_ooo  = cov_r_ooo;      c_il    = cov_r_interleave; c_full = cov_wbq_full;
            c_miss = cov_miss;       c_hit   = cov_hit;      c_raw  = cov_raw_stall;

            rnd_sets  = '{0, 1, 2, 3};
            rnd_ntags = 8;
            done      = 0;
            while (done < n_random) begin
                chunk = (n_random - done < 250) ? n_random - done : 250;
                draw_profile();
                random_traffic(chunk, RND_TAG_BASE);
                done += chunk;
            end
            default_profile();
            wait_idle("test 11");

            c_wb   = cov_dirty_wb - c_wb;     c_merge = cov_merge - c_merge;  c_held = cov_remiss_held - c_held;
            c_rs   = cov_restart - c_rs;      c_rp    = cov_replay - c_rp;    c_hum  = cov_hum - c_hum;
            c_ooo  = cov_r_ooo - c_ooo;       c_il    = cov_r_interleave - c_il; c_full = cov_wbq_full - c_full;
            c_miss = cov_miss - c_miss;       c_hit   = cov_hit - c_hit;      c_raw  = cov_raw_stall - c_raw;
            $display("[COV] test 11: requests %0d, hits %0d, misses %0d, merges %0d, replays %0d",
                     n_random, c_hit, c_miss, c_merge, c_rp);
            $display("[COV] test 11: dirty writebacks %0d, re-misses held by writeback %0d, fill restarts %0d, wb-queue-full stall cycles %0d",
                     c_wb, c_held, c_rs, c_full);
            $display("[COV] test 11: hit-under-miss %0d, R out-of-order completions %0d, R interleaved beats %0d, RAW stalls %0d, peak outstanding %0d",
                     c_hum, c_ooo, c_il, c_raw, cov_max_out);

            // Coverage floors per 1000 requests, roughly one third of the
            // minimum observed over seeds 1-30 at 5000 requests (minimum
            // per 1000: dirty writebacks 177, merges 160, held re-misses
            // 32, fill restarts 13, replays 440, hit-under-miss 315,
            // out-of-order R 47, interleaved R beats 83). A floor that
            // is not met means the stimulus, not the design, has
            // regressed. For runs shorter than 1000 requests the floors
            // scale down proportionally.
            begin
                int unsigned k;
                k = n_random;   // floor = per_1000 * k / 1000
                if (c_wb    <  60 * k / 1000) err($sformatf("coverage: dirty writebacks %0d < %0d", c_wb,  60 * k / 1000));
                if (c_merge <  50 * k / 1000) err($sformatf("coverage: merges %0d < %0d",           c_merge, 50 * k / 1000));
                if (c_held  <  10 * k / 1000) err($sformatf("coverage: re-misses held by writeback %0d < %0d", c_held, 10 * k / 1000));
                if (c_rs    <   5 * k / 1000) err($sformatf("coverage: fill restarts %0d < %0d",    c_rs,  5 * k / 1000));
                if (c_rp    < 150 * k / 1000) err($sformatf("coverage: replays %0d < %0d",          c_rp, 150 * k / 1000));
                if (c_hum   < 100 * k / 1000) err($sformatf("coverage: hit-under-miss %0d < %0d",   c_hum, 100 * k / 1000));
                if (c_ooo   <  15 * k / 1000) err($sformatf("coverage: out-of-order R completions %0d < %0d", c_ooo, 15 * k / 1000));
                if (c_il    <  25 * k / 1000) err($sformatf("coverage: interleaved R beats %0d < %0d", c_il, 25 * k / 1000));
                if (n_random >= 1000 && c_full < 1) err("coverage: writeback queue never full");
            end
        end
        test_end($sformatf("%0d constrained-random requests (seed %0d): scoreboard, protocol and mirror checks clean, coverage floors met",
                           n_random, seed));

        // ---------------------------------------------------------------
        // Test 12: end-of-test consistency.
        // Concept: after all traffic has drained, the union of memory and
        //   the modified lines held in the cache must equal the reference
        //   image, and every location ever accessed must read back its
        //   latest value through the cache.
        // Implementation: white-box comparison of every touched line
        //   (dirty cached copy, or memory) against the reference, plus
        //   structural checks (no duplicate tag in a set, LRU
        //   permutations); then a pipelined load of every touched word
        //   through the cache, checked by the scoreboard; then the
        //   white-box comparison again.
        // ---------------------------------------------------------------
        test_begin("test 12");
        begin
            int unsigned n_lines, n_dirty, n_dirty0, n_words;
            int          id;
            bit [ADDR_WIDTH-1:0] words [$];

            wait_idle("test 12 setup");
            check_consistency(n_lines, n_dirty0);
            foreach (touched[wa]) words.push_back(wa);
            n_words = words.size();
            foreach (words[k]) cpu_issue(words[k] << BYTE_OFF_WIDTH, 1'b0, '0, 1'b1, id);
            wait_idle("test 12 read-back");
            check_consistency(n_lines, n_dirty);
            $display("[INFO] test 12: %0d lines checked (%0d dirty in the cache before read-back, %0d after), %0d words read back",
                     n_lines, n_dirty0, n_dirty, n_words);
        end
        test_end("memory + dirty cached lines equal the reference image; every touched word reads back its latest value");

        print_summary();
        $finish;
    end

endmodule : cache_top_tb

`undef CTRL
`undef MSHR

`default_nettype wire
