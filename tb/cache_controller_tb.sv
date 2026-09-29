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

        $finish;
    end

endmodule : cache_controller_tb

`default_nettype wire
