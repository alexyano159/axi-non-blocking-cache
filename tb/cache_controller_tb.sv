// -----------------------------------------------------------------------
// Testbench for the cache controller (rtl/cache_controller.sv) --
// hit-path scope.
//
// The DUT is the controller wired to the real, already-verified
// cache_tag_array, cache_valid_array and cache_data_sram, so any failure
// here is attributable to the controller itself. The MSHR is not
// instantiated: miss handling is not yet implemented, so its ports are
// tied to an idle MSHR's values.
//
// Preload mode: with no fill path yet, lines can only become valid if
// the TB installs them. While tb_preload = 1, a mux in front of each
// array's write port hands that port to the TB instead of the
// controller. Writing the arrays' storage hierarchically is not an
// option -- it is driven by always_ff, which permits no second writer.
//
// Tests are added incrementally, simple to complex; each reports its
// own [PASS]/[FAIL] line.
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module cache_controller_tb;

    // -------------------------------------------------------------------
    // Parameters, mirrored from the DUT defaults.
    // -------------------------------------------------------------------
    localparam int ADDR_WIDTH     = 32;
    localparam int DATA_WIDTH     = 32;
    localparam int NUM_WAYS       = 4;
    localparam int WORDS_PER_LINE = 4;
    localparam int NUM_SETS       = 64;
    localparam int SET_IDX_WIDTH  = $clog2(NUM_SETS);                         // 6
    localparam int WAY_WIDTH      = $clog2(NUM_WAYS);                         // 2
    localparam int WORD_OFF_WIDTH = $clog2(WORDS_PER_LINE);                   // 2
    localparam int BYTE_OFF_WIDTH = $clog2(DATA_WIDTH / 8);                   // 2
    localparam int TAG_WIDTH      = ADDR_WIDTH - SET_IDX_WIDTH
                                     - WORD_OFF_WIDTH - BYTE_OFF_WIDTH;        // 22
    localparam int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE;              // 128
    localparam int MSHR_ID_WIDTH  = 4;
    localparam int TXN_ID_WIDTH   = 4;

    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------
    // Clock and reset.
    // -------------------------------------------------------------------
    logic clk;
    logic rst_n;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------
    // CPU-facing signals (driven by the TB acting as the CPU).
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
    // Controller <-> array read paths (connected directly).
    // -------------------------------------------------------------------
    logic [SET_IDX_WIDTH-1:0] tag_rd_set_idx;
    logic [TAG_WIDTH-1:0]     tag_lookup_tag;
    logic [NUM_WAYS-1:0]      tag_match;
    logic [NUM_WAYS-1:0]      tag_dirty_out;

    logic [SET_IDX_WIDTH-1:0] valid_rd_set_idx;
    logic [NUM_WAYS-1:0]      valid_out;

    logic [SET_IDX_WIDTH-1:0] data_rd_set_idx;
    logic [LINE_WIDTH-1:0]    data_rd_line [NUM_WAYS];

    // -------------------------------------------------------------------
    // Array write ports: three sources per port.
    //   ctrl_* -- driven by the controller (DUT outputs, checked by tests)
    //   pre_*  -- driven by the TB during preload
    //   arr_*  -- what the array actually sees (muxed by tb_preload)
    // -------------------------------------------------------------------
    logic tb_preload;

    // Tag array write port.
    logic                      ctrl_tag_wr_en,      pre_tag_wr_en,      arr_tag_wr_en;
    logic [SET_IDX_WIDTH-1:0]  ctrl_tag_wr_set_idx, pre_tag_wr_set_idx, arr_tag_wr_set_idx;
    logic [WAY_WIDTH-1:0]      ctrl_tag_wr_way_sel, pre_tag_wr_way_sel, arr_tag_wr_way_sel;
    logic [TAG_WIDTH-1:0]      ctrl_tag_wr_tag,     pre_tag_wr_tag,     arr_tag_wr_tag;
    logic                      ctrl_tag_wr_tag_en,  pre_tag_wr_tag_en,  arr_tag_wr_tag_en;
    logic                      ctrl_tag_wr_dirty,   pre_tag_wr_dirty,   arr_tag_wr_dirty;
    logic                      ctrl_tag_wr_dirty_en,pre_tag_wr_dirty_en,arr_tag_wr_dirty_en;

    // Valid array write port.
    logic                      ctrl_valid_wr_en,      pre_valid_wr_en,      arr_valid_wr_en;
    logic [SET_IDX_WIDTH-1:0]  ctrl_valid_wr_set_idx, pre_valid_wr_set_idx, arr_valid_wr_set_idx;
    logic [WAY_WIDTH-1:0]      ctrl_valid_wr_way_sel, pre_valid_wr_way_sel, arr_valid_wr_way_sel;
    logic                      ctrl_valid_wr_valid,   pre_valid_wr_valid,   arr_valid_wr_valid;

    // Data SRAM write port.
    logic                      ctrl_data_wr_en,      pre_data_wr_en,      arr_data_wr_en;
    logic [SET_IDX_WIDTH-1:0]  ctrl_data_wr_set_idx, pre_data_wr_set_idx, arr_data_wr_set_idx;
    logic [WAY_WIDTH-1:0]      ctrl_data_wr_way_sel, pre_data_wr_way_sel, arr_data_wr_way_sel;
    logic [WORDS_PER_LINE-1:0] ctrl_data_wr_word_en, pre_data_wr_word_en, arr_data_wr_word_en;
    logic [LINE_WIDTH-1:0]     ctrl_data_wr_data,    pre_data_wr_data,    arr_data_wr_data;

    // Preload mux: the TB owns every write port while tb_preload = 1.
    assign arr_tag_wr_en        = tb_preload ? pre_tag_wr_en        : ctrl_tag_wr_en;
    assign arr_tag_wr_set_idx   = tb_preload ? pre_tag_wr_set_idx   : ctrl_tag_wr_set_idx;
    assign arr_tag_wr_way_sel   = tb_preload ? pre_tag_wr_way_sel   : ctrl_tag_wr_way_sel;
    assign arr_tag_wr_tag       = tb_preload ? pre_tag_wr_tag       : ctrl_tag_wr_tag;
    assign arr_tag_wr_tag_en    = tb_preload ? pre_tag_wr_tag_en    : ctrl_tag_wr_tag_en;
    assign arr_tag_wr_dirty     = tb_preload ? pre_tag_wr_dirty     : ctrl_tag_wr_dirty;
    assign arr_tag_wr_dirty_en  = tb_preload ? pre_tag_wr_dirty_en  : ctrl_tag_wr_dirty_en;

    assign arr_valid_wr_en      = tb_preload ? pre_valid_wr_en      : ctrl_valid_wr_en;
    assign arr_valid_wr_set_idx = tb_preload ? pre_valid_wr_set_idx : ctrl_valid_wr_set_idx;
    assign arr_valid_wr_way_sel = tb_preload ? pre_valid_wr_way_sel : ctrl_valid_wr_way_sel;
    assign arr_valid_wr_valid   = tb_preload ? pre_valid_wr_valid   : ctrl_valid_wr_valid;

    assign arr_data_wr_en       = tb_preload ? pre_data_wr_en       : ctrl_data_wr_en;
    assign arr_data_wr_set_idx  = tb_preload ? pre_data_wr_set_idx  : ctrl_data_wr_set_idx;
    assign arr_data_wr_way_sel  = tb_preload ? pre_data_wr_way_sel  : ctrl_data_wr_way_sel;
    assign arr_data_wr_word_en  = tb_preload ? pre_data_wr_word_en  : ctrl_data_wr_word_en;
    assign arr_data_wr_data     = tb_preload ? pre_data_wr_data     : ctrl_data_wr_data;

    // -------------------------------------------------------------------
    // MSHR port. Controller outputs are observed (they must stay idle on
    // the hit path); inputs are tied to the values an idle MSHR drives
    // just after reset (free entries, empty writeback queue, no fill).
    // -------------------------------------------------------------------
    logic                     mshr_alloc_valid;
    logic [ADDR_WIDTH-1:0]    mshr_alloc_addr;
    logic                     mshr_alloc_is_write;
    logic                     mshr_wb_valid;
    logic [ADDR_WIDTH-1:0]    mshr_wb_addr;
    logic [LINE_WIDTH-1:0]    mshr_wb_data;
    logic                     mshr_fill_ready;

    wire logic                     mshr_alloc_ready  = 1'b1;
    wire logic [MSHR_ID_WIDTH-1:0] mshr_alloc_id     = '0;
    wire logic                     mshr_wb_ready     = 1'b1;
    wire logic                     mshr_wb_done      = 1'b0;
    wire logic                     mshr_fill_valid   = 1'b0;
    wire logic [MSHR_ID_WIDTH-1:0] mshr_fill_id      = '0;
    wire logic [ADDR_WIDTH-1:0]    mshr_fill_addr    = '0;
    wire logic [LINE_WIDTH-1:0]    mshr_fill_data    = '0;
    wire logic                     mshr_fill_is_write = 1'b0;

    // -------------------------------------------------------------------
    // DUT: cache controller.
    // -------------------------------------------------------------------
    cache_controller #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS),
        .MSHR_ID_WIDTH (MSHR_ID_WIDTH),
        .TXN_ID_WIDTH  (TXN_ID_WIDTH)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),

        .req_valid          (req_valid),
        .req_ready          (req_ready),
        .req_addr           (req_addr),
        .req_we             (req_we),
        .req_wdata          (req_wdata),
        .req_id             (req_id),

        .resp_valid         (resp_valid),
        .resp_ready         (resp_ready),
        .resp_id            (resp_id),
        .resp_data          (resp_data),
        .resp_we            (resp_we),

        .tag_rd_set_idx     (tag_rd_set_idx),
        .tag_lookup_tag     (tag_lookup_tag),
        .tag_match          (tag_match),
        .tag_dirty_out      (tag_dirty_out),
        .tag_wr_en          (ctrl_tag_wr_en),
        .tag_wr_set_idx     (ctrl_tag_wr_set_idx),
        .tag_wr_way_sel     (ctrl_tag_wr_way_sel),
        .tag_wr_tag         (ctrl_tag_wr_tag),
        .tag_wr_tag_en      (ctrl_tag_wr_tag_en),
        .tag_wr_dirty       (ctrl_tag_wr_dirty),
        .tag_wr_dirty_en    (ctrl_tag_wr_dirty_en),

        .valid_rd_set_idx   (valid_rd_set_idx),
        .valid_out          (valid_out),
        .valid_wr_en        (ctrl_valid_wr_en),
        .valid_wr_set_idx   (ctrl_valid_wr_set_idx),
        .valid_wr_way_sel   (ctrl_valid_wr_way_sel),
        .valid_wr_valid     (ctrl_valid_wr_valid),

        .data_rd_set_idx    (data_rd_set_idx),
        .data_rd_line       (data_rd_line),
        .data_wr_en         (ctrl_data_wr_en),
        .data_wr_set_idx    (ctrl_data_wr_set_idx),
        .data_wr_way_sel    (ctrl_data_wr_way_sel),
        .data_wr_word_en    (ctrl_data_wr_word_en),
        .data_wr_data       (ctrl_data_wr_data),

        .mshr_alloc_valid   (mshr_alloc_valid),
        .mshr_alloc_addr    (mshr_alloc_addr),
        .mshr_alloc_is_write(mshr_alloc_is_write),
        .mshr_alloc_ready   (mshr_alloc_ready),
        .mshr_alloc_id      (mshr_alloc_id),
        .mshr_wb_valid      (mshr_wb_valid),
        .mshr_wb_addr       (mshr_wb_addr),
        .mshr_wb_data       (mshr_wb_data),
        .mshr_wb_ready      (mshr_wb_ready),
        .mshr_wb_done       (mshr_wb_done),
        .mshr_fill_valid    (mshr_fill_valid),
        .mshr_fill_id       (mshr_fill_id),
        .mshr_fill_addr     (mshr_fill_addr),
        .mshr_fill_data     (mshr_fill_data),
        .mshr_fill_is_write (mshr_fill_is_write),
        .mshr_fill_ready    (mshr_fill_ready)
    );

    // -------------------------------------------------------------------
    // Collaborators: the three real (already verified) arrays.
    // -------------------------------------------------------------------
    cache_tag_array #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) u_tag_array (
        .clk        (clk),
        .rd_set_idx (tag_rd_set_idx),
        .lookup_tag (tag_lookup_tag),
        .tag_match  (tag_match),
        .dirty_out  (tag_dirty_out),
        .wr_en      (arr_tag_wr_en),
        .wr_set_idx (arr_tag_wr_set_idx),
        .wr_way_sel (arr_tag_wr_way_sel),
        .wr_tag     (arr_tag_wr_tag),
        .wr_tag_en  (arr_tag_wr_tag_en),
        .wr_dirty   (arr_tag_wr_dirty),
        .wr_dirty_en(arr_tag_wr_dirty_en)
    );

    cache_valid_array #(
        .NUM_WAYS(NUM_WAYS),
        .NUM_SETS(NUM_SETS)
    ) u_valid_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .rd_set_idx(valid_rd_set_idx),
        .valid_out (valid_out),
        .wr_en     (arr_valid_wr_en),
        .wr_set_idx(arr_valid_wr_set_idx),
        .wr_way_sel(arr_valid_wr_way_sel),
        .wr_valid  (arr_valid_wr_valid)
    );

    cache_data_sram #(
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) u_data_sram (
        .clk       (clk),
        .rd_set_idx(data_rd_set_idx),
        .rd_line   (data_rd_line),
        .wr_en     (arr_data_wr_en),
        .wr_set_idx(arr_data_wr_set_idx),
        .wr_way_sel(arr_data_wr_way_sel),
        .wr_word_en(arr_data_wr_word_en),
        .wr_data   (arr_data_wr_data)
    );

    // -------------------------------------------------------------------
    // Idle values for every TB-driven signal.
    // -------------------------------------------------------------------
    initial begin
        rst_n      = 1'b0;
        tb_preload = 1'b0;

        req_valid  = 1'b0;
        req_addr   = '0;
        req_we     = 1'b0;
        req_wdata  = '0;
        req_id     = '0;
        resp_ready = 1'b1;

        pre_tag_wr_en        = 1'b0;
        pre_tag_wr_set_idx   = '0;
        pre_tag_wr_way_sel   = '0;
        pre_tag_wr_tag       = '0;
        pre_tag_wr_tag_en    = 1'b0;
        pre_tag_wr_dirty     = 1'b0;
        pre_tag_wr_dirty_en  = 1'b0;

        pre_valid_wr_en      = 1'b0;
        pre_valid_wr_set_idx = '0;
        pre_valid_wr_way_sel = '0;
        pre_valid_wr_valid   = 1'b0;

        pre_data_wr_en       = 1'b0;
        pre_data_wr_set_idx  = '0;
        pre_data_wr_way_sel  = '0;
        pre_data_wr_word_en  = '0;
        pre_data_wr_data     = '0;
    end

    // -------------------------------------------------------------------
    // Cycle counter and response monitor.
    // cycle_cnt holds the index of the most recent rising edge. The
    // monitor runs in the same process, so each logged response carries
    // the index of the edge on which its handshake completed -- directly
    // comparable with cpu_send's accept_cycle. DUT outputs read here are
    // their pre-edge values, since flop updates land in the NBA region.
    // -------------------------------------------------------------------
    typedef struct {
        logic [TXN_ID_WIDTH-1:0] id;
        logic [DATA_WIDTH-1:0]   data;
        logic                    we;
        int unsigned             cycle;
    } resp_rec_t;

    int unsigned cycle_cnt = 0;
    resp_rec_t   resp_log [$];

    always @(posedge clk) begin
        cycle_cnt++;
        if (rst_n && resp_valid && resp_ready)
            resp_log.push_back('{id: resp_id, data: resp_data, we: resp_we, cycle: cycle_cnt});
    end

    // -------------------------------------------------------------------
    // Miss counter (white-box).
    // Until miss handling is implemented, a miss has no externally
    // visible effect: the request is accepted and never answered. The
    // absence of a response alone cannot distinguish a correct miss from
    // a lost request, so the controller's internal lookup classification
    // is probed directly. Once misses allocate MSHR entries, this is
    // replaced by a check on the MSHR allocation port.
    // -------------------------------------------------------------------
    int unsigned miss_cnt = 0;

    always @(posedge clk) begin
        if (rst_n && dut.lookup_miss)
            miss_cnt++;
    end

    // -------------------------------------------------------------------
    // Side-effect watcher.
    // While chk_no_side_effects = 1, any array write or MSHR request
    // issued by the controller is counted. Used by tests whose stimulus
    // must leave the cache contents and the MSHR untouched.
    // -------------------------------------------------------------------
    logic        chk_no_side_effects = 1'b0;
    int unsigned side_effect_cnt     = 0;

    always @(posedge clk) begin
        if (chk_no_side_effects &&
            (ctrl_tag_wr_en || ctrl_valid_wr_en || ctrl_data_wr_en ||
             mshr_alloc_valid || mshr_wb_valid)) begin
            $error("side-effect watcher: unexpected write/request at cycle %0d (tag=%b valid=%b data=%b alloc=%b wb=%b)",
                   cycle_cnt, ctrl_tag_wr_en, ctrl_valid_wr_en, ctrl_data_wr_en,
                   mshr_alloc_valid, mshr_wb_valid);
            side_effect_cnt++;
        end
    end

    // -------------------------------------------------------------------
    // Array write logger.
    // Records every array write the controller commits (tb_preload = 0),
    // one entry per cycle, with the full write-port contents. Allows a
    // test to assert both the number of writes and their exact fields.
    // MSHR requests are counted separately.
    // -------------------------------------------------------------------
    typedef struct {
        logic                      data_en;
        logic [SET_IDX_WIDTH-1:0]  data_set;
        logic [WAY_WIDTH-1:0]      data_way;
        logic [WORDS_PER_LINE-1:0] data_word_en;
        logic [LINE_WIDTH-1:0]     data_data;
        logic                      tag_en;
        logic [SET_IDX_WIDTH-1:0]  tag_set;
        logic [WAY_WIDTH-1:0]      tag_way;
        logic                      tag_tag_en;
        logic                      tag_dirty;
        logic                      tag_dirty_en;
        logic                      valid_en;
    } wr_rec_t;

    wr_rec_t     wr_log [$];
    int unsigned mshr_req_cnt = 0;

    always @(posedge clk) begin
        if (rst_n && !tb_preload &&
            (ctrl_data_wr_en || ctrl_tag_wr_en || ctrl_valid_wr_en)) begin
            wr_log.push_back('{
                data_en:      ctrl_data_wr_en,
                data_set:     ctrl_data_wr_set_idx,
                data_way:     ctrl_data_wr_way_sel,
                data_word_en: ctrl_data_wr_word_en,
                data_data:    ctrl_data_wr_data,
                tag_en:       ctrl_tag_wr_en,
                tag_set:      ctrl_tag_wr_set_idx,
                tag_way:      ctrl_tag_wr_way_sel,
                tag_tag_en:   ctrl_tag_wr_tag_en,
                tag_dirty:    ctrl_tag_wr_dirty,
                tag_dirty_en: ctrl_tag_wr_dirty_en,
                valid_en:     ctrl_valid_wr_en
            });
        end
        if (rst_n && (mshr_alloc_valid || mshr_wb_valid))
            mshr_req_cnt++;
    end

    // -------------------------------------------------------------------
    // Scoreboard: reference model of the cache contents.
    // Mirrors what every (set, way) should hold. preload_line and
    // set_valid keep it in step with the TB's direct array writes;
    // sb_access predicts the outcome of each CPU request from it and
    // updates it for stores. Expected responses are queued in exp_log in
    // issue order -- hits complete in order, since they share one
    // fixed-latency pipeline -- and compared against resp_log by
    // check_responses.
    // -------------------------------------------------------------------
    logic [LINE_WIDTH-1:0] model_line  [NUM_SETS][NUM_WAYS];
    logic [TAG_WIDTH-1:0]  model_tag   [NUM_SETS][NUM_WAYS];
    logic                  model_valid [NUM_SETS][NUM_WAYS];
    logic                  model_dirty [NUM_SETS][NUM_WAYS];

    initial begin
        foreach (model_valid[s, w]) begin
            model_valid[s][w] = 1'b0;
            model_dirty[s][w] = 1'b0;
        end
    end

    resp_rec_t exp_log [$];

    localparam int unsigned HIT_LATENCY = 2;   // accept edge -> response edge

    // -------------------------------------------------------------------
    // Helper tasks.
    // -------------------------------------------------------------------

    // Holds the synchronous reset for a few edges, then releases it.
    // Every TB-side change is applied #1 after the edge, never on it, so
    // the DUT samples a stable value (see VERIFICATION_PROBLEMS.txt,
    // Problem 4).
    task automatic apply_reset();
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;
    endtask

    // Builds a word-aligned request address from its cache fields.
    function automatic logic [ADDR_WIDTH-1:0] make_addr(
        input logic [TAG_WIDTH-1:0]      tag,
        input logic [SET_IDX_WIDTH-1:0]  set_idx,
        input logic [WORD_OFF_WIDTH-1:0] word_off
    );
        return {tag, set_idx, word_off, BYTE_OFF_WIDTH'(0)};
    endfunction

    // Installs one complete, valid, clean line through the preload mux:
    // tag (with dirty = 0), valid bit and all four data words are
    // written on a single edge. Called #1 after an edge, and only while
    // no request is in flight -- during preload the controller's own
    // array writes are disconnected and would be lost.
    task automatic preload_line(
        input logic [SET_IDX_WIDTH-1:0] set_idx,
        input logic [WAY_WIDTH-1:0]     way,
        input logic [TAG_WIDTH-1:0]     tag,
        input logic [LINE_WIDTH-1:0]    line
    );
        tb_preload = 1'b1;

        pre_tag_wr_en        = 1'b1;
        pre_tag_wr_set_idx   = set_idx;
        pre_tag_wr_way_sel   = way;
        pre_tag_wr_tag       = tag;
        pre_tag_wr_tag_en    = 1'b1;
        pre_tag_wr_dirty     = 1'b0;
        pre_tag_wr_dirty_en  = 1'b1;

        pre_valid_wr_en      = 1'b1;
        pre_valid_wr_set_idx = set_idx;
        pre_valid_wr_way_sel = way;
        pre_valid_wr_valid   = 1'b1;

        pre_data_wr_en       = 1'b1;
        pre_data_wr_set_idx  = set_idx;
        pre_data_wr_way_sel  = way;
        pre_data_wr_word_en  = '1;
        pre_data_wr_data     = line;

        @(posedge clk);
        #1;

        pre_tag_wr_en   = 1'b0;
        pre_valid_wr_en = 1'b0;
        pre_data_wr_en  = 1'b0;
        tb_preload      = 1'b0;

        model_line [set_idx][way] = line;
        model_tag  [set_idx][way] = tag;
        model_valid[set_idx][way] = 1'b1;
        model_dirty[set_idx][way] = 1'b0;
    endtask

    // Writes only the valid bit of one (set, way) through the preload
    // mux; the tag and data arrays are left untouched, mirroring a real
    // invalidation. Same calling rules as preload_line.
    task automatic set_valid(
        input logic [SET_IDX_WIDTH-1:0] set_idx,
        input logic [WAY_WIDTH-1:0]     way,
        input logic                     valid
    );
        tb_preload = 1'b1;

        pre_valid_wr_en      = 1'b1;
        pre_valid_wr_set_idx = set_idx;
        pre_valid_wr_way_sel = way;
        pre_valid_wr_valid   = valid;

        @(posedge clk);
        #1;

        pre_valid_wr_en = 1'b0;
        tb_preload      = 1'b0;

        model_valid[set_idx][way] = valid;
    endtask

    // CPU bus-functional model: presents one request and holds it until
    // the handshake completes. accept_cycle returns the index of the
    // edge on which req_valid && req_ready was sampled.
    //
    // req_ready is read #1 after the preceding edge, where it is stable:
    // it depends only on state registered at that edge and on the
    // TB-held request fields. If it is high, the next edge completes the
    // handshake. A bounded wait turns a permanently stalled controller
    // into a clear failure rather than a hung simulation.
    localparam int unsigned REQ_TIMEOUT_CYCLES = 100;

    task automatic cpu_send(
        input  logic [ADDR_WIDTH-1:0]   addr,
        input  logic                    we,
        input  logic [DATA_WIDTH-1:0]   wdata,
        input  logic [TXN_ID_WIDTH-1:0] id,
        output int unsigned             accept_cycle
    );
        logic        accepted;
        int unsigned waited;

        req_valid = 1'b1;
        req_addr  = addr;
        req_we    = we;
        req_wdata = wdata;
        req_id    = id;

        waited = 0;
        do begin
            accepted = req_ready;
            @(posedge clk);
            #1;
            if (++waited > REQ_TIMEOUT_CYCLES)
                $fatal(1, "cpu_send: request id %0d not accepted within %0d cycles",
                       id, REQ_TIMEOUT_CYCLES);
        end while (!accepted);

        accept_cycle = cycle_cnt;
        req_valid    = 1'b0;
    endtask

    // Scoreboard-checked CPU access. Predicts the outcome from the
    // reference model, issues the request through cpu_send, and queues
    // the expected response. A store hit also updates the model word and
    // marks the line dirty. A predicted miss queues nothing, since miss
    // handling is not implemented. Returns #1 after the acceptance edge,
    // with no further delay, so the caller can sample the arrays' lookup
    // outputs for this request immediately.
    task automatic sb_access(
        input logic [ADDR_WIDTH-1:0]   addr,
        input logic                    we,
        input logic [DATA_WIDTH-1:0]   wdata,
        input logic [TXN_ID_WIDTH-1:0] id
    );
        logic [SET_IDX_WIDTH-1:0]  s;
        logic [TAG_WIDTH-1:0]      t;
        logic [WORD_OFF_WIDTH-1:0] d;
        logic                      hit;
        int                        way;
        int unsigned               accept_cycle;
        resp_rec_t                 exp;

        {t, s, d} = addr[ADDR_WIDTH-1:BYTE_OFF_WIDTH];

        hit = 1'b0;
        way = 0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (model_valid[s][w] && model_tag[s][w] == t) begin
                hit = 1'b1;
                way = w;
            end
        end

        // Expected response. A store acknowledge carries no meaningful
        // data; check_responses does not compare data when we = 1.
        exp.id   = id;
        exp.we   = we;
        exp.data = model_line[s][way][d * DATA_WIDTH +: DATA_WIDTH];

        if (hit && we) begin
            model_line [s][way][d * DATA_WIDTH +: DATA_WIDTH] = wdata;
            model_dirty[s][way] = 1'b1;
        end

        cpu_send(addr, we, wdata, id, accept_cycle);

        if (hit) begin
            exp.cycle = accept_cycle + HIT_LATENCY;
            exp_log.push_back(exp);
        end
    endtask

    // Compares every logged response against the scoreboard's expected
    // responses, in order: id, we, data (loads only) and arrival cycle.
    // Adds the number of mismatches found to errors.
    task automatic check_responses(input string test_name, inout int unsigned errors);
        if (resp_log.size() != exp_log.size()) begin
            $error("[FAIL] %s: %0d responses received, expected %0d",
                   test_name, resp_log.size(), exp_log.size());
            foreach (resp_log[i])
                $display("         received %0d: id %0d we %b data 0x%08h cycle %0d",
                         i, resp_log[i].id, resp_log[i].we, resp_log[i].data, resp_log[i].cycle);
            errors++;
            return;
        end

        foreach (exp_log[i]) begin
            if (resp_log[i].id !== exp_log[i].id) begin
                $error("[FAIL] %s: response %0d has id %0d, expected %0d",
                       test_name, i, resp_log[i].id, exp_log[i].id);
                errors++;
            end
            if (resp_log[i].we !== exp_log[i].we) begin
                $error("[FAIL] %s: id %0d: resp_we = %b, expected %b",
                       test_name, exp_log[i].id, resp_log[i].we, exp_log[i].we);
                errors++;
            end
            if (!exp_log[i].we && resp_log[i].data !== exp_log[i].data) begin
                $error("[FAIL] %s: id %0d: resp_data = 0x%08h, expected 0x%08h",
                       test_name, exp_log[i].id, resp_log[i].data, exp_log[i].data);
                errors++;
            end
            if (resp_log[i].cycle !== exp_log[i].cycle) begin
                $error("[FAIL] %s: id %0d: response at cycle %0d, expected %0d",
                       test_name, exp_log[i].id, resp_log[i].cycle, exp_log[i].cycle);
                errors++;
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Test sequence.
    // -------------------------------------------------------------------
    initial begin
        apply_reset();

        // ---------------------------------------------------------------
        // Test 1: reset sanity.
        // With no request presented, the controller must be idle and
        // ready: accepting requests, issuing no response, writing none
        // of the arrays, and making no request of the MSHR. Checked on
        // every cycle of a short idle window, not just once, so that a
        // signal which asserts spuriously a few cycles after reset is
        // also caught.
        // ---------------------------------------------------------------
        begin
            int unsigned errors;
            errors = 0;

            repeat (5) begin
                @(posedge clk);
                #1;
                if (req_ready !== 1'b1) begin
                    $error("[FAIL] test 1: req_ready = %b, expected 1", req_ready);
                    errors++;
                end
                if (resp_valid !== 1'b0) begin
                    $error("[FAIL] test 1: resp_valid = %b, expected 0", resp_valid);
                    errors++;
                end
                if ({ctrl_tag_wr_en, ctrl_valid_wr_en, ctrl_data_wr_en} !== 3'b000) begin
                    $error("[FAIL] test 1: array write enable asserted (tag=%b valid=%b data=%b), expected none",
                           ctrl_tag_wr_en, ctrl_valid_wr_en, ctrl_data_wr_en);
                    errors++;
                end
                if ({mshr_alloc_valid, mshr_wb_valid} !== 2'b00) begin
                    $error("[FAIL] test 1: MSHR request asserted (alloc=%b wb=%b), expected none",
                           mshr_alloc_valid, mshr_wb_valid);
                    errors++;
                end
            end

            if (errors == 0)
                $display("[PASS] test 1: idle after reset -- ready, no response, no array writes, no MSHR requests");
        end

        // ---------------------------------------------------------------
        // Test 2: single load hit.
        // One line with four distinct words is installed in a non-zero
        // way, and one load to a middle word of that line is issued.
        // Miss handling is not implemented, so any response at all
        // implies the lookup hit. The checks then prove the rest of the
        // hit path: the correct way and word were selected (data), the
        // request metadata travelled with it (id, we), the pipeline has
        // the designed depth (accept -> response = 2 edges), and a load
        // hit neither writes the arrays nor involves the MSHR.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0]  t_set;
            logic [WAY_WIDTH-1:0]      t_way;
            logic [TAG_WIDTH-1:0]      t_tag;
            logic [WORD_OFF_WIDTH-1:0] t_word;
            logic [TXN_ID_WIDTH-1:0]   t_id;
            logic [LINE_WIDTH-1:0]     t_line;
            logic [DATA_WIDTH-1:0]     exp_data;
            int unsigned               accept_cycle;
            int unsigned               errors;

            t_set  = 6'd5;
            t_way  = 2'd2;       // non-zero: catches a hit-way encoder stuck at 0
            t_tag  = 22'h15A5A5;
            t_word = 2'd1;       // interior word: catches an off-by-one word select
            t_id   = 4'd7;
            // Word 0 occupies the least-significant 32 bits of the line.
            t_line = {32'hDDDD_0003, 32'hCCCC_0002, 32'hBBBB_0001, 32'hAAAA_0000};
            exp_data = t_line[t_word * DATA_WIDTH +: DATA_WIDTH];
            errors   = 0;

            preload_line(t_set, t_way, t_tag, t_line);

            resp_log.delete();
            side_effect_cnt     = 0;
            chk_no_side_effects = 1'b1;

            cpu_send(make_addr(t_tag, t_set, t_word), 1'b0, '0, t_id, accept_cycle);

            // Drain window, comfortably longer than the expected latency,
            // so that a late or duplicated response is also observed.
            repeat (6) @(posedge clk);
            #1;
            chk_no_side_effects = 1'b0;

            if (resp_log.size() != 1) begin
                $error("[FAIL] test 2: %0d responses received, expected exactly 1", resp_log.size());
                errors++;
            end else begin
                if (resp_log[0].id !== t_id) begin
                    $error("[FAIL] test 2: resp_id = %0d, expected %0d", resp_log[0].id, t_id);
                    errors++;
                end
                if (resp_log[0].we !== 1'b0) begin
                    $error("[FAIL] test 2: resp_we = %b, expected 0 (load)", resp_log[0].we);
                    errors++;
                end
                if (resp_log[0].data !== exp_data) begin
                    $error("[FAIL] test 2: resp_data = 0x%08h, expected 0x%08h", resp_log[0].data, exp_data);
                    errors++;
                end
                if (resp_log[0].cycle - accept_cycle != 2) begin
                    $error("[FAIL] test 2: response %0d cycles after acceptance, expected 2",
                           resp_log[0].cycle - accept_cycle);
                    errors++;
                end
            end
            if (side_effect_cnt != 0) begin
                $error("[FAIL] test 2: %0d cycles with an array write or MSHR request, expected none",
                       side_effect_cnt);
                errors++;
            end

            if (errors == 0)
                $display("[PASS] test 2: load hit (set %0d, way %0d, word %0d) -> id %0d, data 0x%08h, 2-cycle latency, no side effects",
                         t_set, t_way, t_word, t_id, exp_data);
        end

        // ---------------------------------------------------------------
        // Test 3: load hit on every way x every word of one full set.
        // Test 2 covered a single (way, word) point; an encoder or word
        // select defect confined to another way or to the top word lane
        // would pass it. Here all four ways of one set are valid at
        // once, and each of the 16 words is loaded in turn, so every
        // lookup also has three valid, non-matching ways as competitors.
        //
        // - Set 42 (6'b101010) differs from test 2's set and toggles
        //   alternate index bits.
        // - The four tags differ only in their least- and most-
        //   significant bits, so a tag field sliced one bit off in
        //   either direction aliases two ways and is detected.
        // - Each word encodes its own location (A<way>0<word>_<set>),
        //   so a mismatch identifies the (way, word) actually returned.
        // - Loads are issued one at a time and each is allowed to
        //   complete, isolating selection correctness from pipelining
        //   (back-to-back issue is covered by the throughput test).
        // - The id of each load is way*4 + word, using all 16 ids.
        // ---------------------------------------------------------------
        begin
            localparam int unsigned N_LOADS = NUM_WAYS * WORDS_PER_LINE;   // 16

            logic [SET_IDX_WIDTH-1:0] t_set;
            logic [TAG_WIDTH-1:0]     t_tags [NUM_WAYS];
            logic [LINE_WIDTH-1:0]    t_line;
            logic [DATA_WIDTH-1:0]    exp_data [N_LOADS];   // indexed by id
            int unsigned              accept_cycles [N_LOADS];
            int unsigned              id;
            int unsigned              errors;

            t_set     = 6'd42;
            t_tags[0] = 22'h0A5A5A;
            t_tags[1] = 22'h0A5A5A ^ 22'h000001;   // differs in tag bit 0
            t_tags[2] = 22'h0A5A5A ^ 22'h200000;   // differs in tag bit 21
            t_tags[3] = 22'h0A5A5A ^ 22'h200001;   // differs in both
            errors    = 0;

            // Build and install the four lines; record each word's
            // expected value under the id of the load that will read it.
            for (int w = 0; w < NUM_WAYS; w++) begin
                for (int d = 0; d < WORDS_PER_LINE; d++) begin
                    id = w * WORDS_PER_LINE + d;
                    exp_data[id] = {4'hA, 4'(w), 4'h0, 4'(d), 16'(t_set)};
                    t_line[d * DATA_WIDTH +: DATA_WIDTH] = exp_data[id];
                end
                preload_line(t_set, WAY_WIDTH'(w), t_tags[w], t_line);
            end

            resp_log.delete();
            side_effect_cnt     = 0;
            chk_no_side_effects = 1'b1;

            // Issue the 16 loads in (way, word) order. Three edges after
            // acceptance cover the expected 2-edge latency with margin.
            for (int w = 0; w < NUM_WAYS; w++) begin
                for (int d = 0; d < WORDS_PER_LINE; d++) begin
                    id = w * WORDS_PER_LINE + d;
                    cpu_send(make_addr(t_tags[w], t_set, WORD_OFF_WIDTH'(d)),
                             1'b0, '0, TXN_ID_WIDTH'(id), accept_cycles[id]);
                    repeat (3) @(posedge clk);
                    #1;
                end
            end

            // Additional idle window, so a late or duplicated response
            // is still captured before the log is checked.
            repeat (3) @(posedge clk);
            #1;
            chk_no_side_effects = 1'b0;

            // Loads were serialised, so responses must arrive in issue
            // order: the i-th logged response belongs to id i.
            if (resp_log.size() != N_LOADS) begin
                $error("[FAIL] test 3: %0d responses received, expected %0d",
                       resp_log.size(), N_LOADS);
                errors++;
            end else begin
                for (int i = 0; i < N_LOADS; i++) begin
                    if (resp_log[i].id !== TXN_ID_WIDTH'(i)) begin
                        $error("[FAIL] test 3: response %0d has id %0d, expected %0d",
                               i, resp_log[i].id, i);
                        errors++;
                    end
                    if (resp_log[i].we !== 1'b0) begin
                        $error("[FAIL] test 3: id %0d: resp_we = %b, expected 0 (load)",
                               i, resp_log[i].we);
                        errors++;
                    end
                    if (resp_log[i].data !== exp_data[i]) begin
                        $error("[FAIL] test 3: way %0d word %0d (id %0d): resp_data = 0x%08h, expected 0x%08h",
                               i / WORDS_PER_LINE, i % WORDS_PER_LINE, i,
                               resp_log[i].data, exp_data[i]);
                        errors++;
                    end
                    if (resp_log[i].cycle - accept_cycles[i] != 2) begin
                        $error("[FAIL] test 3: id %0d: response %0d cycles after acceptance, expected 2",
                               i, resp_log[i].cycle - accept_cycles[i]);
                        errors++;
                    end
                end
            end
            if (side_effect_cnt != 0) begin
                $error("[FAIL] test 3: %0d cycles with an array write or MSHR request, expected none",
                       side_effect_cnt);
                errors++;
            end

            if (errors == 0)
                $display("[PASS] test 3: all %0d (way, word) loads of full set %0d hit with correct data, id and 2-cycle latency",
                         N_LOADS, t_set);
        end

        // ---------------------------------------------------------------
        // Test 4: valid gating.
        // A way whose stored tag matches but whose valid bit is clear
        // must not hit. The same line is observed in four phases in
        // which only its valid bit changes:
        //   1. valid        -> load hits   (positive control: address
        //                                   and preload are correct)
        //   2. invalidate the valid bit only; tag and data remain
        //   3. invalid      -> load misses; a valid line in another way
        //                      of the same set still hits
        //   4. re-validate  -> load hits with the original data, proving
        //                      tag and data were intact throughout, so
        //                      the miss in phase 3 was due to valid alone
        // A miss is evidenced by the absence of a response together with
        // exactly one internal miss classification (miss counter).
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] t_set;
            logic [WAY_WIDTH-1:0]     way_a, way_b;
            logic [TAG_WIDTH-1:0]     tag_a, tag_b;
            logic [LINE_WIDTH-1:0]    line_a, line_b;
            logic [DATA_WIDTH-1:0]    exp_a, exp_b;
            logic [TXN_ID_WIDTH-1:0]  exp_id  [3];  // expected responses, in order
            logic [DATA_WIDTH-1:0]    exp_dat [3];
            int unsigned              exp_acc [3];
            int unsigned              acc [4];      // accept cycle, per load
            int unsigned              errors;

            t_set  = 6'd17;
            way_a  = 2'd1;
            way_b  = 2'd3;
            tag_a  = 22'h3C3C3C;
            tag_b  = 22'h0C3C3C;
            line_a = {32'hA1A1_0003, 32'hA1A1_0002, 32'hA1A1_0001, 32'hA1A1_0000};
            line_b = {32'hB3B3_0003, 32'hB3B3_0002, 32'hB3B3_0001, 32'hB3B3_0000};
            exp_a  = line_a[2 * DATA_WIDTH +: DATA_WIDTH];   // line A is read at word 2
            exp_b  = line_b[0 * DATA_WIDTH +: DATA_WIDTH];   // line B is read at word 0
            errors = 0;

            preload_line(t_set, way_a, tag_a, line_a);
            preload_line(t_set, way_b, tag_b, line_b);

            resp_log.delete();
            miss_cnt            = 0;
            side_effect_cnt     = 0;
            chk_no_side_effects = 1'b1;

            // Phase 1: line A valid -> hit (id 1).
            cpu_send(make_addr(tag_a, t_set, 2'd2), 1'b0, '0, 4'd1, acc[0]);
            repeat (3) @(posedge clk);
            #1;

            // Phase 2: clear line A's valid bit only.
            set_valid(t_set, way_a, 1'b0);

            // Phase 3: line A invalid -> miss (id 2, no response);
            // line B in the same set still valid -> hit (id 3).
            cpu_send(make_addr(tag_a, t_set, 2'd2), 1'b0, '0, 4'd2, acc[1]);
            repeat (3) @(posedge clk);
            #1;
            cpu_send(make_addr(tag_b, t_set, 2'd0), 1'b0, '0, 4'd3, acc[2]);
            repeat (3) @(posedge clk);
            #1;

            // Phase 4: re-validate line A -> hit with original data (id 4).
            set_valid(t_set, way_a, 1'b1);
            cpu_send(make_addr(tag_a, t_set, 2'd2), 1'b0, '0, 4'd4, acc[3]);
            repeat (3) @(posedge clk);
            #1;
            chk_no_side_effects = 1'b0;

            // Expected: ids 1, 3, 4 answered in that order; id 2 never.
            exp_id  = '{4'd1, 4'd3, 4'd4};
            exp_dat = '{exp_a, exp_b, exp_a};
            exp_acc = '{acc[0], acc[2], acc[3]};

            if (resp_log.size() != 3) begin
                $error("[FAIL] test 4: %0d responses received, expected 3 (ids 1, 3, 4)",
                       resp_log.size());
                foreach (resp_log[i])
                    $display("         response %0d: id %0d data 0x%08h",
                             i, resp_log[i].id, resp_log[i].data);
                errors++;
            end else begin
                for (int i = 0; i < 3; i++) begin
                    if (resp_log[i].id !== exp_id[i]) begin
                        $error("[FAIL] test 4: response %0d has id %0d, expected %0d",
                               i, resp_log[i].id, exp_id[i]);
                        errors++;
                    end
                    if (resp_log[i].we !== 1'b0) begin
                        $error("[FAIL] test 4: id %0d: resp_we = %b, expected 0 (load)",
                               exp_id[i], resp_log[i].we);
                        errors++;
                    end
                    if (resp_log[i].data !== exp_dat[i]) begin
                        $error("[FAIL] test 4: id %0d: resp_data = 0x%08h, expected 0x%08h",
                               exp_id[i], resp_log[i].data, exp_dat[i]);
                        errors++;
                    end
                    if (resp_log[i].cycle - exp_acc[i] != 2) begin
                        $error("[FAIL] test 4: id %0d: response %0d cycles after acceptance, expected 2",
                               exp_id[i], resp_log[i].cycle - exp_acc[i]);
                        errors++;
                    end
                end
            end
            if (miss_cnt != 1) begin
                $error("[FAIL] test 4: %0d lookups classified as miss, expected exactly 1 (id 2)",
                       miss_cnt);
                errors++;
            end
            if (side_effect_cnt != 0) begin
                $error("[FAIL] test 4: %0d cycles with an array write or MSHR request, expected none",
                       side_effect_cnt);
                errors++;
            end

            if (errors == 0)
                $display("[PASS] test 4: matching tag with valid = 0 misses; neighbour way and re-validated line hit with original data");
        end

        // ---------------------------------------------------------------
        // Test 5: store hit, readback, dirty bit.
        // The first test in which the cache changes state. Two clean
        // lines are installed in one set; one word of the first is
        // stored to. Verified:
        //   - the store is acknowledged (id, we = 1, 2-cycle latency);
        //   - exactly one array write results: the data SRAM, with a
        //     one-hot word enable at the stored word, and the tag array,
        //     dirty-only (tag field untouched); no valid-array write and
        //     no MSHR request;
        //   - readback of all four words returns the new value only in
        //     the stored word (no over-write of neighbouring words);
        //   - the dirty bit of the stored line transitions 0 -> 1, while
        //     the other line in the same set remains clean and intact.
        // Expected responses come from the scoreboard (sb_access).
        //
        // Dirty-bit observation: sb_access returns #1 after the
        // acceptance edge, on which the tag array registered its lookup
        // of the request's set; tag_dirty_out then holds that set's
        // dirty bits, and is sampled directly at the array boundary.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0]  t_set;
            logic [TAG_WIDTH-1:0]      tag_0, tag_2;
            logic [LINE_WIDTH-1:0]     line_0, line_2;
            logic [WORD_OFF_WIDTH-1:0] st_word;
            logic [DATA_WIDTH-1:0]     st_data;
            logic [NUM_WAYS-1:0]       dirty_before, dirty_after;
            int unsigned               errors;

            t_set   = 6'd9;
            tag_0   = 22'h111111;
            tag_2   = 22'h222222;
            line_0  = {32'h5050_0003, 32'h5050_0002, 32'h5050_0001, 32'h5050_0000};
            line_2  = {32'h5252_0003, 32'h5252_0002, 32'h5252_0001, 32'h5252_0000};
            st_word = 2'd2;
            st_data = 32'hC0FF_EE00;
            errors  = 0;

            preload_line(t_set, 2'd0, tag_0, line_0);
            preload_line(t_set, 2'd2, tag_2, line_2);

            resp_log.delete();
            exp_log.delete();
            wr_log.delete();
            mshr_req_cnt = 0;

            // Store to way 0, word 2 (id 1). The store's own lookup still
            // observes the line before the write: dirty must be 0 here.
            sb_access(make_addr(tag_0, t_set, st_word), 1'b1, st_data, 4'd1);
            dirty_before = tag_dirty_out;
            repeat (3) @(posedge clk);
            #1;

            // Readback of every word of way 0 (ids 2-5); the first lookup
            // after the store observes the committed dirty bit.
            for (int d = 0; d < WORDS_PER_LINE; d++) begin
                sb_access(make_addr(tag_0, t_set, WORD_OFF_WIDTH'(d)), 1'b0, '0,
                          TXN_ID_WIDTH'(2 + d));
                if (d == 0)
                    dirty_after = tag_dirty_out;
                repeat (3) @(posedge clk);
                #1;
            end

            // The other line of the set, at the same word offset (id 6).
            sb_access(make_addr(tag_2, t_set, st_word), 1'b0, '0, 4'd6);
            repeat (3) @(posedge clk);
            #1;

            // Responses: store ack, then five loads, all against the model.
            check_responses("test 5", errors);

            // Dirty bit: way 0 clean before, dirty after; way 2 clean.
            if (dirty_before[0] !== 1'b0 || dirty_before[2] !== 1'b0) begin
                $error("[FAIL] test 5: dirty before store = way0 %b way2 %b, expected 0 0",
                       dirty_before[0], dirty_before[2]);
                errors++;
            end
            if (dirty_after[0] !== 1'b1 || dirty_after[2] !== 1'b0) begin
                $error("[FAIL] test 5: dirty after store = way0 %b way2 %b, expected 1 0",
                       dirty_after[0], dirty_after[2]);
                errors++;
            end

            // Exactly one array write, with the expected fields.
            if (wr_log.size() != 1) begin
                $error("[FAIL] test 5: %0d cycles with array writes, expected exactly 1",
                       wr_log.size());
                errors++;
            end else begin
                wr_rec_t r;
                r = wr_log[0];
                if (!(r.data_en && r.data_set == t_set && r.data_way == 2'd0 &&
                      r.data_word_en == (WORDS_PER_LINE'(1) << st_word) &&
                      r.data_data[st_word * DATA_WIDTH +: DATA_WIDTH] == st_data)) begin
                    $error("[FAIL] test 5: data write en %b set %0d way %0d word_en %b word 0x%08h, expected 1 %0d 0 %b 0x%08h",
                           r.data_en, r.data_set, r.data_way, r.data_word_en,
                           r.data_data[st_word * DATA_WIDTH +: DATA_WIDTH],
                           t_set, WORDS_PER_LINE'(1) << st_word, st_data);
                    errors++;
                end
                if (!(r.tag_en && r.tag_set == t_set && r.tag_way == 2'd0 &&
                      !r.tag_tag_en && r.tag_dirty && r.tag_dirty_en)) begin
                    $error("[FAIL] test 5: tag write en %b set %0d way %0d tag_en %b dirty %b dirty_en %b, expected 1 %0d 0 0 1 1",
                           r.tag_en, r.tag_set, r.tag_way, r.tag_tag_en,
                           r.tag_dirty, r.tag_dirty_en, t_set);
                    errors++;
                end
                if (r.valid_en) begin
                    $error("[FAIL] test 5: valid array written by a store hit");
                    errors++;
                end
            end
            if (mshr_req_cnt != 0) begin
                $error("[FAIL] test 5: %0d cycles with an MSHR request, expected none",
                       mshr_req_cnt);
                errors++;
            end

            if (errors == 0)
                $display("[PASS] test 5: store hit acked, single masked write, readback correct, dirty 0 -> 1, neighbour way untouched");
        end

        // ---------------------------------------------------------------
        // PROGRESS MARKER -- tests 1-5 implemented and passing (2026-09-30).
        // Test infrastructure now available: make_addr, preload_line,
        // set_valid, cpu_send, sb_access + check_responses (scoreboard),
        // response monitor (resp_log), array write logger (wr_log),
        // miss counter, side-effect watcher.
        //
        // Remaining hit-path tests (see plan):
        // 6 back-to-back store->load same set (RAW stall, 1 cycle only),
        // 7 full throughput, 8 back-pressure (FIFO fills to 3, drains),
        // 9 random load/store mix with random resp_ready.
        // ---------------------------------------------------------------

        $finish;
    end

endmodule : cache_controller_tb

`default_nettype wire
