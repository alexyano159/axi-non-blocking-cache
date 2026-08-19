// -----------------------------------------------------------------------
// Testbench for the cache valid array (rtl/cache_valid_array.sv).
//
// Unlike cache_tag_array/cache_data_sram, this module has a synchronous
// reset and stores a single field (no independent write-enables to
// gate) -- so alongside the same write/lookup/collision/isolation
// contract verified for the tag array, this TB specifically targets
// reset behavior: that it clears stored entries, and that it drives
// the registered output directly rather than only being visible after
// a subsequent lookup (see rtl/cache_valid_array.sv header for why
// both matter).
// -----------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module cache_valid_array_tb;

    // -------------------------------------------------------------------
    // Parameters, mirrored from the DUT defaults.
    // -------------------------------------------------------------------
    localparam int NUM_WAYS      = 4;
    localparam int NUM_SETS      = 64;
    localparam int SET_IDX_WIDTH = $clog2(NUM_SETS); // 6
    localparam int WAY_WIDTH     = $clog2(NUM_WAYS); // 2

    localparam time CLK_PERIOD = 10ns;

    // -------------------------------------------------------------------
    // Clock generation.
    // -------------------------------------------------------------------
    logic clk;

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // -------------------------------------------------------------------
    // Controller-side ports: driven by the TB, sampled from the DUT.
    // The TB stands in for the (not yet designed) cache controller --
    // the only client of this module.
    // -------------------------------------------------------------------
    logic                     rst_n;
    logic [SET_IDX_WIDTH-1:0] rd_set_idx;
    logic [NUM_WAYS-1:0]      valid_out;

    logic                     wr_en;
    logic [SET_IDX_WIDTH-1:0] wr_set_idx;
    logic [WAY_WIDTH-1:0]     wr_way_sel;
    logic                     wr_valid;

    // -------------------------------------------------------------------
    // DUT instantiation.
    // -------------------------------------------------------------------
    cache_valid_array #(
        .NUM_WAYS(NUM_WAYS),
        .NUM_SETS(NUM_SETS)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),

        .rd_set_idx(rd_set_idx),
        .valid_out (valid_out),

        .wr_en     (wr_en),
        .wr_set_idx(wr_set_idx),
        .wr_way_sel(wr_way_sel),
        .wr_valid  (wr_valid)
    );

    // -------------------------------------------------------------------
    // Idle values for every TB-driven signal. rst_n starts asserted low
    // -- deasserted explicitly by the initial test sequence below, not
    // here, so the very first thing every simulation does is exercise
    // the DUT's reset path.
    // -------------------------------------------------------------------
    initial begin
        rst_n      = 1'b0;
        rd_set_idx = '0;
        wr_en      = 1'b0;
        wr_set_idx = '0;
        wr_way_sel = '0;
        wr_valid   = 1'b0;
    end

    // -------------------------------------------------------------------
    // Driver tasks.
    // -------------------------------------------------------------------

    // Drives one write for exactly one clock edge, then returns to idle.
    task automatic valid_write(input logic [SET_IDX_WIDTH-1:0] set_idx,
                                input logic [WAY_WIDTH-1:0]     way,
                                input logic                     valid);
        wr_set_idx = set_idx;
        wr_way_sel = way;
        wr_valid   = valid;
        wr_en      = 1'b1;
        @(posedge clk);
        // #1 pushes the deassertion strictly past this edge, so the DUT
        // is guaranteed to have already sampled wr_en high -- mirrors
        // cache_tag_array_tb's tag_write task.
        #1;
        wr_en      = 1'b0;
    endtask

    // Presents a lookup address for one clock edge and returns the
    // registered result the following cycle -- the #1 pushes past the
    // same-timestep NBA update region so the returned value reflects
    // the DUT's just-updated output, not a stale pre-edge value.
    task automatic valid_lookup(input  logic [SET_IDX_WIDTH-1:0] set_idx,
                                 output logic [NUM_WAYS-1:0]      valid_result);
        rd_set_idx = set_idx;
        @(posedge clk);
        #1;
        valid_result = valid_out;
    endtask

    // ===================================================================
    // Test sequence. Directed tests run in order inside one initial
    // block, each reporting its own PASS/FAIL, with a single $finish
    // once every test has run.
    // ===================================================================
    initial begin
        // No settle period here: test 1 itself needs to observe the
        // very first instant of simulation, before any clock edge has
        // occurred, so nothing may run ahead of it.

        // ---------------------------------------------------------------
        // Test 1: reset actually clears the array.
        // Every later test depends on starting from a known "nothing is
        // resident" state, so this must be verified first, standalone,
        // rather than assumed. Four checks:
        //   (a) at time 0, before any clock edge, valid_out is
        //       unknown (X) -- this reset is synchronous, not
        //       asynchronous, so the register hasn't sampled rst_n yet
        //       and holds whatever an uninitialized flip-flop holds.
        //   (b) after exactly one clock edge with rst_n still low,
        //       valid_out becomes a defined all-0 -- reset has now
        //       actually been clocked in.
        //   (c)/(d) reset must also erase state that was demonstrably
        //       written valid moments earlier -- proving the clear is a
        //       real effect of reset, not a coincidence of an
        //       already-blank starting condition.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [NUM_WAYS-1:0]      got_valid;

            test_set = 6'd10;
            test_way = 2'd2;

            // (a) Before the first clock edge: sync reset has not yet
            // been sampled, so the register is genuinely undefined.
            if (!$isunknown(valid_out)) begin
                $error("[FAIL] test 1a: valid_out = %b before first clock edge, expected X (reset not yet clocked in)", valid_out);
            end else begin
                // (b) First clock edge samples rst_n=0: now defined 0.
                @(posedge clk);
                #1;
                if (valid_out !== '0) begin
                    $error("[FAIL] test 1b: valid_out = %b after first clock edge in reset, expected all-0", valid_out);
                end else begin
                    // (c) Leave reset, write valid, confirm it landed, then
                    // (d) re-assert reset and confirm the write was erased.
                    rst_n = 1'b1;
                    @(posedge clk);

                    valid_write(test_set, test_way, 1'b1);
                    valid_lookup(test_set, got_valid);

                    if (got_valid[test_way] !== 1'b1) begin
                        $error("[FAIL] test 1c: valid_out[%0d] = %b before reset, expected 1 (precondition)", test_way, got_valid[test_way]);
                    end else begin
                        rst_n = 1'b0;
                        @(posedge clk);
                        #1;
                        rst_n = 1'b1;
                        @(posedge clk);

                        valid_lookup(test_set, got_valid);
                        if (got_valid[test_way] !== 1'b0)
                            $error("[FAIL] test 1d: valid_out[%0d] = %b after reset, expected 0 (write must be erased)", test_way, got_valid[test_way]);
                        else
                            $display("[PASS] test 1: valid_out is X pre-clock, then defined 0 post-clock, and reset correctly erases a prior write");
                    end
                end
            end
        end

        // ---------------------------------------------------------------
        // Test 2: fill-write, matching lookup.
        // Marks one (way, set) valid, then looks up that same location.
        // Confirms the most basic contract: a way that was written valid
        // reports valid on a subsequent lookup.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [NUM_WAYS-1:0]      got_valid;
            logic [NUM_WAYS-1:0]      expected_valid;

            test_set = 6'd5;
            test_way = 2'd1;

            valid_write(test_set, test_way, 1'b1);
            valid_lookup(test_set, got_valid);

            expected_valid = '0;
            expected_valid[test_way] = 1'b1;

            if (got_valid !== expected_valid)
                $error("[FAIL] test 2: valid_out = %b, expected one-hot at bit %0d (all-0 elsewhere)", got_valid, test_way);
            else
                $display("[PASS] test 2: fill-write, matching lookup reports valid with all other ways still reset");
        end

        // ---------------------------------------------------------------
        // Test 3: explicit invalidate.
        // Marks one (way, set) valid, confirms it, then explicitly
        // writes it invalid and confirms the array now reports it
        // absent. Proves the write port can represent both states --
        // not just "write once and it's permanently valid" -- since
        // test 2 alone couldn't distinguish a real valid bit from one
        // that's stuck at 1 after any write.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [NUM_WAYS-1:0]      got_valid;

            test_set = 6'd20;
            test_way = 2'd3;

            valid_write(test_set, test_way, 1'b1);
            valid_lookup(test_set, got_valid);

            if (got_valid[test_way] !== 1'b1) begin
                $error("[FAIL] test 3: valid_out[%0d] = %b before invalidate, expected 1 (precondition)", test_way, got_valid[test_way]);
            end else begin
                valid_write(test_set, test_way, 1'b0);
                valid_lookup(test_set, got_valid);

                if (got_valid !== '0)
                    $error("[FAIL] test 3: valid_out = %b after invalidate, expected all-0", got_valid);
                else
                    $display("[PASS] test 3: explicit invalidate correctly clears a previously-valid way");
            end
        end

        // ---------------------------------------------------------------
        // Test 4: read/write collision, same (way, set) on the same
        // edge. A lookup issued on the same cycle as a write to the
        // identical location must see the pre-write ("old") value,
        // matching a single-port synchronous SRAM's collision behavior.
        // A follow-up lookup (no collision) must then show the new
        // value, confirming the write itself was not lost -- only not
        // forwarded.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic                     old_valid;
            logic                     new_valid;
            logic [NUM_WAYS-1:0]      got_valid;
            logic [NUM_WAYS-1:0]      expected_valid;

            test_set  = 6'd25;
            test_way  = 2'd0;
            old_valid = 1'b1;
            new_valid = 1'b0;

            // Preload the location with the "old" value.
            valid_write(test_set, test_way, old_valid);

            // Drive a write of the "new" value and a lookup of the same
            // (way, set) on the identical edge.
            rd_set_idx = test_set;
            wr_set_idx = test_set;
            wr_way_sel = test_way;
            wr_valid   = new_valid;
            wr_en      = 1'b1;
            @(posedge clk);
            #1;
            got_valid = valid_out;
            wr_en      = 1'b0;

            expected_valid = '0;
            expected_valid[test_way] = old_valid;

            if (got_valid !== expected_valid)
                $error("[FAIL] test 4: collision valid_out = %b, expected %b (old value)", got_valid, expected_valid);
            else
                $display("[PASS] test 4: collision lookup returned pre-write (old) value");

            // Follow-up lookup, no collision this time: the write must
            // have actually completed.
            valid_lookup(test_set, got_valid);

            expected_valid = '0;
            expected_valid[test_way] = new_valid;

            if (got_valid !== expected_valid)
                $error("[FAIL] test 4: post-collision valid_out = %b, expected %b (new value)", got_valid, expected_valid);
            else
                $display("[PASS] test 4: write completed correctly despite not being forwarded");
        end

        // ---------------------------------------------------------------
        // Test 5: way isolation. Preloads all four ways of one set with
        // an alternating valid pattern, then overwrites only one way.
        // Confirms the write landed exclusively in the targeted way --
        // the other three ways, modeled as independent banks, must be
        // completely unaffected.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     target_way;
            logic                     way_valid [NUM_WAYS];
            logic [NUM_WAYS-1:0]      got_valid;
            logic [NUM_WAYS-1:0]      expected_valid;

            test_set   = 6'd30;
            target_way = 2'd2;

            // Preload each way with an alternating pattern: 0, 1, 0, 1.
            for (int w = 0; w < NUM_WAYS; w++) begin
                way_valid[w] = w[0];
                valid_write(test_set, w[WAY_WIDTH-1:0], way_valid[w]);
            end

            // Overwrite only the target way with the inverted value.
            way_valid[target_way] = ~way_valid[target_way];
            valid_write(test_set, target_way, way_valid[target_way]);

            valid_lookup(test_set, got_valid);

            expected_valid = '0;
            for (int w = 0; w < NUM_WAYS; w++) begin
                expected_valid[w] = way_valid[w];
            end

            if (got_valid !== expected_valid)
                $error("[FAIL] test 5: valid_out = %b, expected %b (only way %0d changed)", got_valid, expected_valid, target_way);
            else
                $display("[PASS] test 5: write to one way left the other ways untouched");
        end

        // ---------------------------------------------------------------
        // Test 6: set isolation. Preloads three sets (both edges of the
        // address range, plus an interior set) in one way with distinct
        // values, then overwrites only the interior set. Confirms the
        // write landed exclusively in the targeted set -- testing the
        // edges specifically targets off-by-one bugs, which concentrate
        // at the boundaries of an address range.
        // ---------------------------------------------------------------
        begin
            logic [WAY_WIDTH-1:0]     test_way;
            logic [SET_IDX_WIDTH-1:0] test_sets [3];
            logic                     set_valid  [3];
            logic [NUM_WAYS-1:0]      got_valid;
            logic [NUM_WAYS-1:0]      expected_valid;
            int                       target_idx;
            logic                     set_ok;

            test_way     = 2'd1;
            test_sets[0] = '0;             // low edge of the address range
            test_sets[1] = NUM_SETS / 2;   // an interior set
            test_sets[2] = NUM_SETS - 1;   // high edge of the address range
            target_idx   = 1;              // overwrite the interior set only

            // Preload each set with an alternating pattern: 0, 1, 0.
            for (int s = 0; s < 3; s++) begin
                set_valid[s] = s[0];
                valid_write(test_sets[s], test_way, set_valid[s]);
            end

            // Overwrite only the target set with the inverted value.
            set_valid[target_idx] = ~set_valid[target_idx];
            valid_write(test_sets[target_idx], test_way, set_valid[target_idx]);

            set_ok = 1'b1;
            for (int s = 0; s < 3; s++) begin
                valid_lookup(test_sets[s], got_valid);

                expected_valid = '0;
                expected_valid[test_way] = set_valid[s];

                if (got_valid !== expected_valid) begin
                    set_ok = 1'b0;
                    $error("[FAIL] test 6: set %0d valid_out = %b, expected %b", test_sets[s], got_valid, expected_valid);
                end
            end

            if (set_ok)
                $display("[PASS] test 6: write to one set left the other sets untouched");
        end

        // ---------------------------------------------------------------
        // Test 7: wr_en gating. Presents a complete, otherwise-valid
        // write request (set, way, new value) with wr_en held low, and
        // confirms the location is unchanged. Every earlier test always
        // asserted wr_en alongside a write, so none of them would catch
        // a bug that removed or broke this master gate.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic                     original_valid;
            logic                     attempted_valid;
            logic [NUM_WAYS-1:0]      got_valid;
            logic [NUM_WAYS-1:0]      expected_valid;

            test_set        = 6'd40;
            test_way        = 2'd2;
            original_valid  = 1'b1;
            attempted_valid = 1'b0;

            // Preload the location with the original value.
            valid_write(test_set, test_way, original_valid);

            // Present a complete write request, but hold wr_en low.
            wr_set_idx = test_set;
            wr_way_sel = test_way;
            wr_valid   = attempted_valid;
            wr_en      = 1'b0;
            @(posedge clk);
            #1;

            valid_lookup(test_set, got_valid);

            expected_valid = '0;
            expected_valid[test_way] = original_valid;

            if (got_valid !== expected_valid)
                $error("[FAIL] test 7: valid_out = %b, expected %b (write with wr_en=0 must not change memory)", got_valid, expected_valid);
            else
                $display("[PASS] test 7: write request with wr_en low did not modify memory");
        end

        // ---------------------------------------------------------------
        // Test 8: reset clears valid_out directly, without needing a
        // fresh lookup. Test 1 already proved reset clears the
        // underlying storage (observable via a lookup performed after
        // reset). This test isolates the other reset mechanism: the
        // output register itself is forced to 0 the instant reset is
        // asserted, even with no lookup performed at all -- so a stale,
        // non-zero valid_out left over from before reset can never be
        // observed, even for one cycle.
        // ---------------------------------------------------------------
        begin
            logic [SET_IDX_WIDTH-1:0] test_set;
            logic [WAY_WIDTH-1:0]     test_way;
            logic [NUM_WAYS-1:0]      got_valid;

            test_set = 6'd45;
            test_way = 2'd3;

            // Leave valid_out showing a non-zero (one-hot) value.
            valid_write(test_set, test_way, 1'b1);
            valid_lookup(test_set, got_valid);

            if (got_valid[test_way] !== 1'b1) begin
                $error("[FAIL] test 8: valid_out[%0d] = %b before reset, expected 1 (precondition)", test_way, got_valid[test_way]);
            end else begin
                // Assert reset for exactly one edge -- no valid_lookup
                // call here, so this samples the output register
                // directly rather than going through another read.
                rst_n = 1'b0;
                @(posedge clk);
                #1;

                if (valid_out !== '0)
                    $error("[FAIL] test 8: valid_out = %b one cycle into reset, expected all-0 with no lookup performed", valid_out);
                else
                    $display("[PASS] test 8: reset drove valid_out to 0 directly, without a lookup");

                rst_n = 1'b1;
            end
        end

        $finish;
    end

endmodule : cache_valid_array_tb

`default_nettype wire
