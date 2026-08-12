// -----------------------------------------------------------------------
// Testbench for the cache data SRAM (rtl/cache_data_sram.sv).
//
// This module has no ready/valid handshake and no reset: a write is a
// guarantee, not a request (see rtl/cache_data_sram.sv header), so
// there is nothing to negotiate and no reset state to check. Every
// test here therefore follows the same shape -- write via the port,
// then read the same (or a deliberately different) location back and
// compare against a known value -- since a subsequent read is the
// only way to confirm a write actually took effect.
//
// See private_notes/DESIGN_DECISIONS.txt for the rationale behind the
// module's registered-read / no-reset / single-write-port choices
// being verified here.
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module cache_data_sram_tb;

    // -------------------------------------------------------------------
    // Parameters, mirrored from the DUT defaults.
    // -------------------------------------------------------------------
    localparam int DATA_WIDTH     = 32;
    localparam int NUM_WAYS       = 4;
    localparam int WORDS_PER_LINE = 4;
    localparam int NUM_SETS       = 64;
    localparam int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE; // 128
    localparam int SET_IDX_WIDTH  = $clog2(NUM_SETS);            // 6
    localparam int WAY_WIDTH      = $clog2(NUM_WAYS);            // 2

    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------
    // Clock generation. No reset: the DUT has no rst_n (see module
    // header comment for why a real SRAM macro has no reset pin).
    // -------------------------------------------------------------------
    logic clk;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------
    // Controller-side ports: driven by the TB, sampled from the DUT.
    // The TB stands in for the (not yet designed) cache controller --
    // the only client of this module.
    // -------------------------------------------------------------------
    logic [SET_IDX_WIDTH-1:0] rd_set_idx;
    logic [LINE_WIDTH-1:0]    rd_line [NUM_WAYS];

    logic                      wr_en;
    logic [SET_IDX_WIDTH-1:0] wr_set_idx;
    logic [WAY_WIDTH-1:0]     wr_way_sel;
    logic [WORDS_PER_LINE-1:0] wr_word_en;
    logic [LINE_WIDTH-1:0]    wr_data;

    // -------------------------------------------------------------------
    // DUT instantiation.
    // -------------------------------------------------------------------
    cache_data_sram #(
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) dut (
        .clk       (clk),

        .rd_set_idx(rd_set_idx),
        .rd_line   (rd_line),

        .wr_en     (wr_en),
        .wr_set_idx(wr_set_idx),
        .wr_way_sel(wr_way_sel),
        .wr_word_en(wr_word_en),
        .wr_data   (wr_data)
    );

    // -------------------------------------------------------------------
    // Idle values for every TB-driven signal.
    // -------------------------------------------------------------------
    initial begin
        rd_set_idx = '0;
        wr_en      = 1'b0;
        wr_set_idx = '0;
        wr_way_sel = '0;
        wr_word_en = '0;
        wr_data    = '0;
    end

    // -------------------------------------------------------------------
    // Driver tasks.
    // -------------------------------------------------------------------

    // Drives one write for exactly one clock edge, then returns to idle.
    // word_en selects which word slice(s) of data actually get written
    // -- a single set bit for a hit-write, all bits set for a fill-write.
    task automatic sram_write(input logic [SET_IDX_WIDTH-1:0]  set_idx,
                               input logic [WAY_WIDTH-1:0]      way,
                               input logic [WORDS_PER_LINE-1:0] word_en,
                               input logic [LINE_WIDTH-1:0]     data);
        wr_set_idx = set_idx;
        wr_way_sel = way;
        wr_word_en = word_en;
        wr_data    = data;
        wr_en      = 1'b1;
        @(posedge clk);
        wr_en      = 1'b0;
    endtask

    // Presents a read address for one clock edge and returns the
    // registered result the following cycle -- the #1 pushes past the
    // same-timestep NBA update region so the returned line reflects the
    // DUT's just-updated output, not a stale pre-edge value.
    task automatic sram_read(input  logic [SET_IDX_WIDTH-1:0] set_idx,
                              output logic [LINE_WIDTH-1:0]    line_out [NUM_WAYS]);
        rd_set_idx = set_idx;
        @(posedge clk);
        #1;
        line_out = rd_line;
    endtask

    // ===================================================================
    // Test sequence. Directed tests run in order inside one initial
    // block, each reporting its own PASS/FAIL, with a single $finish
    // once every test has run.
    // ===================================================================
    initial begin
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: single-word hit-write, read back.
        // Writes one word into one way of one set (word_en = one-hot),
        // then reads that set back and checks the targeted word slice
        // of the targeted way matches exactly. Proves the most basic
        // contract: a word written through the write port is visible
        // on the read port one cycle later.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [DATA_WIDTH-1:0]    test_word;
            logic [LINE_WIDTH-1:0]    wr_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];

            test_set  = 6'd5;
            test_way  = 2'd1;
            test_word = 32'hA5A5_1234;

            wr_line_buf = '0;
            wr_line_buf[1*DATA_WIDTH +: DATA_WIDTH] = test_word; // word offset 1

            sram_write(test_set, test_way, 4'b0010, wr_line_buf);
            sram_read(test_set, got_line);

            if (got_line[test_way][1*DATA_WIDTH +: DATA_WIDTH] !== test_word)
                $error("[FAIL] test 1: read word = %h, expected %h", got_line[test_way][1*DATA_WIDTH +: DATA_WIDTH], test_word);
            else
                $display("[PASS] test 1: single-word hit-write read back correctly");
        end

        $finish;
    end

endmodule : cache_data_sram_tb

`default_nettype wire
