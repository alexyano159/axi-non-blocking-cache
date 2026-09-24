// -----------------------------------------------------------------------
// Cache Valid Array
// -----------------------------------------------------------------------
// Stores the valid bit of every cache line: 4-way set-associative, one
// bit per (way, set). Holds NOTHING else -- tag and dirty live in
// cache_tag_array, line data lives in cache_data_sram.
//
// This is the only synchronously-reset piece of tag-side state. Both
// cache_tag_array and cache_data_sram are deliberately built with no
// reset pin, on the grounds that a real SRAM macro doesn't have one --
// so a "match" reported by the tag array's comparator against a
// never-filled entry is meaningless until it is gated by this array's
// valid bit. That gating is what makes the whole cache correct out of
// reset: this module clears every entry to invalid, and the cache
// controller (this module's only client) is responsible for ANDing
// tag_match with valid_out to obtain the real hit/hit_way.
//
// Read port latency matches cache_tag_array/cache_data_sram: valid_out
// is registered, valid one cycle after rd_set_idx is presented, so the
// controller can combine all three arrays' results in the same cycle.
//
// Single shared write port, set by the controller for two purposes:
//   1. Fill write : after a miss, the controller sets the newly
//                   allocated way's valid bit (wr_valid = 1).
//   2. Invalidate  : an explicit invalidation clears a way's valid bit
//                    (wr_valid = 0) without touching tag/dirty/data --
//                    those become don't-care until the way is refilled.
// No wr_valid_en is needed: unlike cache_tag_array's independent
// tag/dirty fields, this module stores only one bit, so wr_en alone
// gates the write.
//
// Synchronous reset: on rst_n deassertion, every (way, set) entry is
// cleared to invalid in a single cycle. This is only feasible because
// this array is small enough (NUM_WAYS * NUM_SETS bits) to be built
// from flip-flops rather than a real SRAM macro -- unlike the tag/data
// arrays, which are sized to map onto real SRAM and so forgo reset
// entirely.
// -----------------------------------------------------------------------
`default_nettype none

module cache_valid_array #(
    parameter int NUM_WAYS      = 4,
    parameter int NUM_SETS      = 64,                        // 4KB total / 4 ways / 16B line
    parameter int SET_IDX_WIDTH = $clog2(NUM_SETS),          // 6
    parameter int WAY_WIDTH     = $clog2(NUM_WAYS)           // 2
) (
    input  wire logic clk,
    input  wire logic rst_n,

    // -----------------------------------------------------------------
    // Read port (cache controller -> valid array)
    // Driven every cycle a lookup is performed (load or store), in
    // parallel with the identical rd_set_idx presented to the tag
    // array. Returns each way's valid bit for the addressed set, one
    // cycle later -- the controller ANDs this with tag_match to get
    // the real hit/hit_way.
    // -----------------------------------------------------------------
    input  wire logic [SET_IDX_WIDTH-1:0] rd_set_idx,
    output      logic [NUM_WAYS-1:0]      valid_out,

    // -----------------------------------------------------------------
    // Write port (cache controller -> valid array)
    // Single shared port for both write sources:
    //   - Fill write  : wr_valid = 1, marking a freshly allocated way
    //                   resident.
    //   - Invalidate  : wr_valid = 0, marking a way no longer resident.
    // -----------------------------------------------------------------
    input  wire logic                     wr_en,
    input  wire logic [SET_IDX_WIDTH-1:0] wr_set_idx,
    input  wire logic [WAY_WIDTH-1:0]     wr_way_sel,
    input  wire logic                     wr_valid
);

    // Storage: one valid bit per (way, set), modeled as NUM_WAYS
    // independent banks -- matching cache_tag_array's and
    // cache_data_sram's per-way bank layout so all three arrays are
    // indexed identically and read together.
    logic valid_mem [NUM_WAYS][NUM_SETS];

    // Registered read: mirrors cache_tag_array's registered compare --
    // valid_out is sampled combinationally from valid_mem and latched,
    // so it is valid the cycle after rd_set_idx is presented. A write
    // to the same (way, set) on the same edge as a read is not
    // forwarded -- the read returns the pre-write value, matching the
    // read-old-data collision behavior of the tag array and data SRAM.
    //
    // Synchronous reset clears every entry to invalid; this is the
    // only one of the three cache arrays that needs to, since it is
    // the sole guarantee of correctness out of reset.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_out <= '0;
        end else begin
            for (int w = 0; w < NUM_WAYS; w++) begin
                valid_out[w] <= valid_mem[w][rd_set_idx];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int w = 0; w < NUM_WAYS; w++) begin
                for (int s = 0; s < NUM_SETS; s++) begin
                    valid_mem[w][s] <= 1'b0;
                end
            end
        end else if (wr_en) begin
            valid_mem[wr_way_sel][wr_set_idx] <= wr_valid;
        end
    end

endmodule : cache_valid_array

`default_nettype wire
