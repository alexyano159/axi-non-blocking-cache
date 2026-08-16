// -----------------------------------------------------------------------
// Testbench for the cache tag array (rtl/cache_tag_array.sv).
//
// This module has no reset and no valid bits of its own (see
// rtl/cache_tag_array.sv header) -- a write is a guarantee, and a
// tag_match result is only ever a raw compare, never a qualified hit.
// Every test here follows the same shape -- write via the port, then
// look up the same (or a deliberately different) location and check
// the registered compare/dirty result -- since a subsequent lookup is
// the only way to confirm a write actually took effect.
//
// See private_notes/DESIGN_DECISIONS.txt for the rationale behind the
// module's registered-compare / no-reset / single-write-port choices
// being verified here.
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module cache_tag_array_tb;

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

    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------
    // Clock generation. No reset: the DUT has no rst_n (see module
    // header comment -- correctness after reset is the valid array's
    // job, not this module's).
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
    logic [TAG_WIDTH-1:0]     lookup_tag;
    logic [NUM_WAYS-1:0]      tag_match;
    logic [NUM_WAYS-1:0]      dirty_out;

    logic                     wr_en;
    logic [SET_IDX_WIDTH-1:0] wr_set_idx;
    logic [WAY_WIDTH-1:0]     wr_way_sel;
    logic [TAG_WIDTH-1:0]     wr_tag;
    logic                     wr_tag_en;
    logic                     wr_dirty;
    logic                     wr_dirty_en;

    // -------------------------------------------------------------------
    // DUT instantiation.
    // -------------------------------------------------------------------
    cache_tag_array #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) dut (
        .clk        (clk),

        .rd_set_idx (rd_set_idx),
        .lookup_tag (lookup_tag),
        .tag_match  (tag_match),
        .dirty_out  (dirty_out),

        .wr_en      (wr_en),
        .wr_set_idx (wr_set_idx),
        .wr_way_sel (wr_way_sel),
        .wr_tag     (wr_tag),
        .wr_tag_en  (wr_tag_en),
        .wr_dirty   (wr_dirty),
        .wr_dirty_en(wr_dirty_en)
    );

    // -------------------------------------------------------------------
    // Idle values for every TB-driven signal.
    // -------------------------------------------------------------------
    initial begin
        rd_set_idx  = '0;
        lookup_tag  = '0;
        wr_en       = 1'b0;
        wr_set_idx  = '0;
        wr_way_sel  = '0;
        wr_tag      = '0;
        wr_tag_en   = 1'b0;
        wr_dirty    = 1'b0;
        wr_dirty_en = 1'b0;
    end

    // -------------------------------------------------------------------
    // Driver tasks.
    // -------------------------------------------------------------------

    // Drives one write for exactly one clock edge, then returns to idle.
    // tag_en/dirty_en independently gate the two fields, mirroring the
    // DUT's own hit-write (tag_en=0) vs. fill-write (tag_en=1) split.
    task automatic tag_write(input logic [SET_IDX_WIDTH-1:0] set_idx,
                              input logic [WAY_WIDTH-1:0]     way,
                              input logic [TAG_WIDTH-1:0]     tag,
                              input logic                     tag_en,
                              input logic                     dirty,
                              input logic                     dirty_en);
        wr_set_idx  = set_idx;
        wr_way_sel  = way;
        wr_tag      = tag;
        wr_tag_en   = tag_en;
        wr_dirty    = dirty;
        wr_dirty_en = dirty_en;
        wr_en       = 1'b1;
        @(posedge clk);
        // The DUT's own write-port always_ff is triggered by this same
        // edge. Clearing wr_en/*_en here, at the identical simulation
        // instant, would race that block's "if (wr_en)" evaluation --
        // the #1 pushes the deassertion strictly past this edge so the
        // DUT is guaranteed to have already sampled wr_en/*_en high.
        #1;
        wr_en       = 1'b0;
        wr_tag_en   = 1'b0;
        wr_dirty_en = 1'b0;
    endtask

    // Presents a lookup address for one clock edge and returns the
    // registered compare/dirty result the following cycle -- the #1
    // pushes past the same-timestep NBA update region so the returned
    // values reflect the DUT's just-updated output, not a stale
    // pre-edge value.
    task automatic tag_lookup(input  logic [SET_IDX_WIDTH-1:0] set_idx,
                               input  logic [TAG_WIDTH-1:0]     tag,
                               output logic [NUM_WAYS-1:0]      match_out,
                               output logic [NUM_WAYS-1:0]      dirty_result);
        rd_set_idx = set_idx;
        lookup_tag = tag;
        @(posedge clk);
        #1;
        match_out     = tag_match;
        dirty_result  = dirty_out;
    endtask

    // ===================================================================
    // Test sequence. Directed tests run in order inside one initial
    // block, each reporting its own PASS/FAIL, with a single $finish
    // once every test has run.
    // ===================================================================
    initial begin
        repeat (2) @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: fill-write, matching lookup.
        // Fill-writes one way of one set with a known tag and dirty
        // value, then looks up that same set with that same tag.
        // Confirms the most basic contract: a way that was filled with
        // a given tag reports a match on a lookup carrying that tag,
        // and the dirty bit written alongside it reads back correctly.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [TAG_WIDTH-1:0]     test_tag;
            logic                    test_dirty;
            logic [NUM_WAYS-1:0]     got_match;
            logic [NUM_WAYS-1:0]     got_dirty;

            test_set   = 6'd5;
            test_way   = 2'd1;
            test_tag   = 22'h1_2345;
            test_dirty = 1'b1;

            tag_write(test_set, test_way, test_tag, 1'b1, test_dirty, 1'b1);
            tag_lookup(test_set, test_tag, got_match, got_dirty);

            if (got_match[test_way] !== 1'b1)
                $error("[FAIL] test 1: tag_match[%0d] = %b, expected 1", test_way, got_match[test_way]);
            else if (got_dirty[test_way] !== test_dirty)
                $error("[FAIL] test 1: dirty_out[%0d] = %b, expected %b", test_way, got_dirty[test_way], test_dirty);
            else
                $display("[PASS] test 1: fill-write, matching lookup reports hit with correct dirty bit");
        end

        // ---------------------------------------------------------------
        // Test 2: non-matching tag, lookup reports no hit.
        // Fill-writes one way of one set with a known tag, then looks
        // up that same set with a deliberately different tag. Confirms
        // the comparator actually discriminates -- without this test, a
        // comparator broken to report a match unconditionally would
        // have passed test 1 and gone completely undetected.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [TAG_WIDTH-1:0]     stored_tag;
            logic [TAG_WIDTH-1:0]     lookup_tag_val;
            logic [NUM_WAYS-1:0]     got_match;
            logic [NUM_WAYS-1:0]     got_dirty;

            test_set       = 6'd15;
            test_way       = 2'd2;
            stored_tag     = 22'h0_ABCD;
            lookup_tag_val = 22'h1_5678; // deliberately different from stored_tag

            tag_write(test_set, test_way, stored_tag, 1'b1, 1'b0, 1'b1);
            tag_lookup(test_set, lookup_tag_val, got_match, got_dirty);

            if (got_match[test_way] !== 1'b0)
                $error("[FAIL] test 2: tag_match[%0d] = %b, expected 0 (non-matching tag)", test_way, got_match[test_way]);
            else
                $display("[PASS] test 2: non-matching tag correctly reports no hit");
        end

        // ---------------------------------------------------------------
        // Test 3: read/compare-write collision, same (set, way) on the
        // same edge. A lookup issued on the same cycle as a write to
        // the identical location must compare against the pre-write
        // ("old") tag/dirty, matching a single-port synchronous SRAM's
        // collision behavior. A follow-up lookup (no collision) must
        // then show the new tag/dirty, confirming the write itself was
        // not lost -- only not forwarded.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [TAG_WIDTH-1:0]     old_tag;
            logic                    old_dirty;
            logic [TAG_WIDTH-1:0]     new_tag;
            logic                    new_dirty;
            logic [NUM_WAYS-1:0]     got_match;
            logic [NUM_WAYS-1:0]     got_dirty;

            test_set  = 6'd25;
            test_way  = 2'd3;
            old_tag   = 22'h0_1111;
            old_dirty = 1'b0;
            new_tag   = 22'h0_2222;
            new_dirty = 1'b1;

            // Preload the location with the "old" value.
            tag_write(test_set, test_way, old_tag, 1'b1, old_dirty, 1'b1);

            // Drive a write of the "new" value and a lookup of the same
            // (set, way) on the identical edge.
            rd_set_idx  = test_set;
            lookup_tag  = old_tag;
            wr_set_idx  = test_set;
            wr_way_sel  = test_way;
            wr_tag      = new_tag;
            wr_tag_en   = 1'b1;
            wr_dirty    = new_dirty;
            wr_dirty_en = 1'b1;
            wr_en       = 1'b1;
            @(posedge clk);
            #1;
            got_match   = tag_match;
            got_dirty   = dirty_out;
            wr_en       = 1'b0;
            wr_tag_en   = 1'b0;
            wr_dirty_en = 1'b0;

            if (got_match[test_way] !== 1'b1)
                $error("[FAIL] test 3: collision tag_match[%0d] = %b, expected 1 (old tag)", test_way, got_match[test_way]);
            else if (got_dirty[test_way] !== old_dirty)
                $error("[FAIL] test 3: collision dirty_out[%0d] = %b, expected old value %b", test_way, got_dirty[test_way], old_dirty);
            else
                $display("[PASS] test 3: collision lookup returned pre-write (old) tag/dirty");

            // Follow-up lookup, no collision this time: the write must
            // have actually completed.
            tag_lookup(test_set, new_tag, got_match, got_dirty);

            if (got_match[test_way] !== 1'b1)
                $error("[FAIL] test 3: post-collision tag_match[%0d] = %b, expected 1 (new tag)", test_way, got_match[test_way]);
            else if (got_dirty[test_way] !== new_dirty)
                $error("[FAIL] test 3: post-collision dirty_out[%0d] = %b, expected new value %b", test_way, got_dirty[test_way], new_dirty);
            else
                $display("[PASS] test 3: write completed correctly despite not being forwarded");
        end

        // ---------------------------------------------------------------
        // Test 4: hit-write (wr_tag_en=0) touches only the dirty bit.
        // Fill-writes a way with a known tag, then hit-writes the same
        // location with wr_tag_en=0 -- but with a deliberately
        // different, "poisoned" tag value on the write bus, so that a
        // broken wr_tag_en gate (one that lets the tag through anyway)
        // would be caught. A lookup with the *original* tag must still
        // match, and dirty_out must reflect the hit-write's update.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [TAG_WIDTH-1:0]     original_tag;
            logic [TAG_WIDTH-1:0]     poisoned_tag;
            logic [NUM_WAYS-1:0]     got_match;
            logic [NUM_WAYS-1:0]     got_dirty;

            test_set     = 6'd45;
            test_way     = 2'd0;
            original_tag = 22'h0_3333;
            poisoned_tag = 22'h0_FFFF; // must never actually be written, since wr_tag_en=0

            // Fill-write: establish the baseline, dirty=0.
            tag_write(test_set, test_way, original_tag, 1'b1, 1'b0, 1'b1);

            // Hit-write: tag_en=0 (poisoned_tag must be ignored), dirty_en=1, dirty=1.
            tag_write(test_set, test_way, poisoned_tag, 1'b0, 1'b1, 1'b1);

            tag_lookup(test_set, original_tag, got_match, got_dirty);

            if (got_match[test_way] !== 1'b1)
                $error("[FAIL] test 4: tag_match[%0d] = %b, expected 1 (tag unchanged by hit-write)", test_way, got_match[test_way]);
            else if (got_dirty[test_way] !== 1'b1)
                $error("[FAIL] test 4: dirty_out[%0d] = %b, expected 1 (hit-write updated dirty)", test_way, got_dirty[test_way]);
            else
                $display("[PASS] test 4: hit-write updated dirty only, tag left untouched");
        end

        $finish;
    end

endmodule : cache_tag_array_tb

`default_nettype wire
