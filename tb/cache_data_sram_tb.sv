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
        // The DUT's write-port always_ff is triggered by this same edge;
        // deasserting wr_en in the same timestep would race that block's
        // "if (wr_en)" evaluation. The #1 pushes the deassertion strictly
        // past the edge, so the DUT is guaranteed to have sampled wr_en
        // high -- mirroring tag_write in cache_tag_array_tb.
        #1;
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

        // ---------------------------------------------------------------
        // Test 2: read/write collision, same (set, way, word) on the
        // same edge. A read issued on the same cycle as a write to the
        // identical location must return the pre-write ("old") value,
        // matching a single-port synchronous SRAM's collision behavior.
        // A follow-up read (no collision) must then show the new value,
        // confirming the write itself was not lost -- only not forwarded.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [DATA_WIDTH-1:0]    old_word;
            logic [DATA_WIDTH-1:0]    new_word;
            logic [LINE_WIDTH-1:0]    old_line_buf;
            logic [LINE_WIDTH-1:0]    new_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];

            test_set = 6'd10;
            test_way = 2'd2;
            old_word = 32'hDEAD_0001;
            new_word = 32'hBEEF_0002;

            old_line_buf = '0;
            old_line_buf[0*DATA_WIDTH +: DATA_WIDTH] = old_word; // word offset 0

            new_line_buf = '0;
            new_line_buf[0*DATA_WIDTH +: DATA_WIDTH] = new_word; // word offset 0

            // Preload the location with the "old" value.
            sram_write(test_set, test_way, 4'b0001, old_line_buf);

            // Drive a write of the "new" value and a read of the same
            // set on the identical edge.
            rd_set_idx = test_set;
            wr_set_idx = test_set;
            wr_way_sel = test_way;
            wr_word_en = 4'b0001;
            wr_data    = new_line_buf;
            wr_en      = 1'b1;
            @(posedge clk);
            // Deassert only after #1, for the same reason as in
            // sram_write: wr_en must not change within the edge's timestep.
            #1;
            wr_en    = 1'b0;
            got_line = rd_line;

            if (got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH] !== old_word)
                $error("[FAIL] test 2: collision read = %h, expected old value %h", got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH], old_word);
            else
                $display("[PASS] test 2: collision read returned pre-write (old) data");

            // Follow-up read, no collision this time: the write must
            // have actually completed.
            sram_read(test_set, got_line);

            if (got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH] !== new_word)
                $error("[FAIL] test 2: post-collision read = %h, expected new value %h", got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH], new_word);
            else
                $display("[PASS] test 2: write completed correctly despite not being forwarded");
        end

        // ---------------------------------------------------------------
        // Test 3: fill-write, all four words in one cycle.
        // Plants a stale value in one word first, then fill-writes the
        // whole line (word_en = all-ones) with four distinct patterns
        // and checks the entire line reads back exactly as written --
        // proving the fill path truly overwrites every word, including
        // one that already held stale data, not just the empty ones.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [LINE_WIDTH-1:0]    stale_line_buf;
            logic [LINE_WIDTH-1:0]    fill_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];

            test_set = 6'd20;
            test_way = 2'd3;

            stale_line_buf = '0;
            stale_line_buf[1*DATA_WIDTH +: DATA_WIDTH] = 32'hFFFF_FFFF; // stale word at offset 1

            fill_line_buf = '0;
            for (int i = 0; i < WORDS_PER_LINE; i++) begin
                fill_line_buf[i*DATA_WIDTH +: DATA_WIDTH] = 32'hC0DE_0000 + i;
            end

            // Plant stale data in one word first.
            sram_write(test_set, test_way, 4'b0010, stale_line_buf);

            // Fill-write the entire line.
            sram_write(test_set, test_way, 4'b1111, fill_line_buf);
            sram_read(test_set, got_line);

            if (got_line[test_way] !== fill_line_buf)
                $error("[FAIL] test 3: fill read = %h, expected %h", got_line[test_way], fill_line_buf);
            else
                $display("[PASS] test 3: fill-write overwrote all four words correctly");
        end

        // ---------------------------------------------------------------
        // Test 4: way isolation. Preloads all four ways of one set with
        // four distinct lines, then overwrites only one way. Confirms
        // the write landed exclusively in the targeted way -- the other
        // three ways, modeled as independent banks, must be completely
        // unaffected by a write to a different way of the same set.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     target_way;
            logic [LINE_WIDTH-1:0]    expected_line [NUM_WAYS];
            logic [LINE_WIDTH-1:0]    new_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];
            logic                     way_ok;

            test_set   = 6'd30;
            target_way = 2'd1;

            // Preload each way with its own distinct, way-indexed line.
            for (int w = 0; w < NUM_WAYS; w++) begin
                for (int i = 0; i < WORDS_PER_LINE; i++) begin
                    expected_line[w][i*DATA_WIDTH +: DATA_WIDTH] = 32'h1000_0000 * (w + 1) + i;
                end
                sram_write(test_set, w, 4'b1111, expected_line[w]);
            end

            // Overwrite only the target way with a new, unrelated pattern.
            new_line_buf = '0;
            for (int i = 0; i < WORDS_PER_LINE; i++) begin
                new_line_buf[i*DATA_WIDTH +: DATA_WIDTH] = 32'hF00D_0000 + i;
            end
            sram_write(test_set, target_way, 4'b1111, new_line_buf);
            expected_line[target_way] = new_line_buf; // update the expectation for the targeted way

            sram_read(test_set, got_line);

            way_ok = 1'b1;
            for (int w = 0; w < NUM_WAYS; w++) begin
                if (got_line[w] !== expected_line[w]) begin
                    way_ok = 1'b0;
                    $error("[FAIL] test 4: way %0d = %h, expected %h", w, got_line[w], expected_line[w]);
                end
            end

            if (way_ok)
                $display("[PASS] test 4: write to one way left the other three ways untouched");
        end

        // ---------------------------------------------------------------
        // Test 5: wr_en gating. Presents a complete, otherwise-valid
        // write request (address, way, word mask, data) with wr_en held
        // low, and confirms the location is unchanged. Every earlier
        // test always asserted wr_en alongside a write, so none of them
        // would catch a bug that removed or broke this gate -- this
        // test exists purely to close that coverage hole.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [DATA_WIDTH-1:0]    original_word;
            logic [DATA_WIDTH-1:0]    attempted_word;
            logic [LINE_WIDTH-1:0]    original_line_buf;
            logic [LINE_WIDTH-1:0]    attempted_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];

            test_set       = 6'd40;
            test_way       = 2'd0;
            original_word  = 32'h1111_2222;
            attempted_word = 32'h9999_8888;

            original_line_buf = '0;
            original_line_buf[0*DATA_WIDTH +: DATA_WIDTH] = original_word;

            attempted_line_buf = '0;
            attempted_line_buf[0*DATA_WIDTH +: DATA_WIDTH] = attempted_word;

            // Preload the location with the original value.
            sram_write(test_set, test_way, 4'b0001, original_line_buf);

            // Present a complete write request, but hold wr_en low.
            wr_set_idx = test_set;
            wr_way_sel = test_way;
            wr_word_en = 4'b0001;
            wr_data    = attempted_line_buf;
            wr_en      = 1'b0;
            @(posedge clk);

            sram_read(test_set, got_line);

            if (got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH] !== original_word)
                $error("[FAIL] test 5: read = %h, expected unchanged original value %h", got_line[test_way][0*DATA_WIDTH +: DATA_WIDTH], original_word);
            else
                $display("[PASS] test 5: write request with wr_en low did not modify memory");
        end

        // ---------------------------------------------------------------
        // Test 6: set isolation. Preloads several sets (including both
        // edges of the address range) in one way with distinct lines,
        // then overwrites only one set. Confirms the write landed
        // exclusively in the targeted set -- mem[] is indexed
        // [way][set], so a wiring bug on wr_set_idx (off-by-one, wrong
        // width) could corrupt a different set without any earlier
        // test noticing, since tests 1/2/3/5 each only ever touch one
        // set at a time.
        // ---------------------------------------------------------------
        begin
            logic [WAY_WIDTH-1:0]     test_way;
            logic [SET_IDX_WIDTH-1:0] test_sets     [3];
            logic [LINE_WIDTH-1:0]    expected_line [3];
            logic [LINE_WIDTH-1:0]    new_line_buf;
            logic [LINE_WIDTH-1:0]    got_line [NUM_WAYS];
            int                       target_idx;
            logic                     set_ok;

            test_way     = 2'd2;
            test_sets[0] = '0;             // low edge of the address range
            test_sets[1] = NUM_SETS / 2;   // an interior set
            test_sets[2] = NUM_SETS - 1;   // high edge of the address range
            target_idx   = 1;              // overwrite the interior set only

            // Preload each set with its own distinct, index-tagged line.
            for (int s = 0; s < 3; s++) begin
                for (int i = 0; i < WORDS_PER_LINE; i++) begin
                    expected_line[s][i*DATA_WIDTH +: DATA_WIDTH] = 32'h2000_0000 + s*32'h0000_1000 + i;
                end
                sram_write(test_sets[s], test_way, 4'b1111, expected_line[s]);
            end

            // Overwrite only the target set with a new, unrelated pattern.
            new_line_buf = '0;
            for (int i = 0; i < WORDS_PER_LINE; i++) begin
                new_line_buf[i*DATA_WIDTH +: DATA_WIDTH] = 32'hBAAD_0000 + i;
            end
            sram_write(test_sets[target_idx], test_way, 4'b1111, new_line_buf);
            expected_line[target_idx] = new_line_buf;

            set_ok = 1'b1;
            for (int s = 0; s < 3; s++) begin
                sram_read(test_sets[s], got_line);
                if (got_line[test_way] !== expected_line[s]) begin
                    set_ok = 1'b0;
                    $error("[FAIL] test 6: set %0d = %h, expected %h", test_sets[s], got_line[test_way], expected_line[s]);
                end
            end

            if (set_ok)
                $display("[PASS] test 6: write to one set left the other sets untouched");
        end

        $finish;
    end

endmodule : cache_data_sram_tb

`default_nettype wire
