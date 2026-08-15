// -----------------------------------------------------------------------
// Cache Tag Array
// -----------------------------------------------------------------------
// Stores the tag and dirty bit of every cache line: 4-way set-associative,
// one (tag, dirty) pair per (way, set). Holds NO valid bits -- those live
// in a separate, dedicated valid-bit array (not yet built), which is the
// only piece of tag-side state that requires a synchronous reset. Keeping
// this array reset-free means the comparator below can never be trusted
// on its own: a "match" against garbage tag data in an invalid entry is
// meaningless until gated by that valid bit, which the cache controller
// (this module's only client) is responsible for combining in.
//
// Performs its own 4-way parallel tag compare on every lookup and reports
// a raw, valid-agnostic match vector -- one bit per way. This is *not*
// a hit signal by itself; the controller ANDs tag_match with the valid
// array's output (read in parallel, same latency) to obtain the real
// hit / hit_way. The controller needs the valid bits directly anyway,
// for replacement and allocation decisions, so the gating naturally
// belongs there rather than being duplicated inside this module.
//
// Two write sources are merged onto a single shared write port by the
// cache controller, exactly as in cache_data_sram:
//   1. Hit write : a store hit sets the dirty bit of an already-resident
//                  line. The tag itself does not change.
//   2. Fill write: after a miss, the controller writes the new line's tag
//                  into the freshly allocated way, and sets/clears dirty
//                  according to whether the fill is completing a load
//                  (clean) or a store (dirty).
// wr_tag_en / wr_dirty_en let a fill-write update both fields in the same
// cycle while a hit-write updates only dirty, without needing a separate
// write port or an implicit "mode" signal.
//
// Read port latency matches cache_data_sram: the tag compare result and
// dirty bit are registered, valid one cycle after rd_set_idx/lookup_tag
// are presented -- so the controller can combine this array's hit
// information with the data array's line contents in the same cycle.
//
// No reset: see rationale above. Garbage tag/dirty content in an entry
// that has never been filled is harmless, because the valid array's
// reset guarantees that entry is never trusted until it is written.
// -----------------------------------------------------------------------
`default_nettype none

module cache_tag_array #(
    parameter int ADDR_WIDTH     = 32,
    parameter int DATA_WIDTH     = 32,
    parameter int NUM_WAYS       = 4,
    parameter int WORDS_PER_LINE = 4,                          // AXI burst length (LINE_WORDS in mshr.sv)
    parameter int NUM_SETS       = 64,                         // 4KB total / 4 ways / 16B line
    parameter int SET_IDX_WIDTH  = $clog2(NUM_SETS),            // 6
    parameter int WAY_WIDTH      = $clog2(NUM_WAYS),            // 2
    parameter int WORD_OFF_WIDTH = $clog2(WORDS_PER_LINE),      // 2 -- word-within-line offset
    parameter int BYTE_OFF_WIDTH = $clog2(DATA_WIDTH / 8),      // 2 -- byte-within-word offset
    parameter int TAG_WIDTH      = ADDR_WIDTH - SET_IDX_WIDTH
                                    - WORD_OFF_WIDTH - BYTE_OFF_WIDTH // 22
) (
    input  logic clk,

    // -----------------------------------------------------------------
    // Read / compare port (cache controller -> tag array)
    // Driven every cycle a lookup is performed (load or store). Compares
    // lookup_tag against all NUM_WAYS tags of the addressed set and
    // returns a raw per-way match vector plus each way's dirty bit, one
    // cycle later; the controller ANDs tag_match with the valid array's
    // output to determine the real hit/hit_way.
    // -----------------------------------------------------------------
    input  logic [SET_IDX_WIDTH-1:0] rd_set_idx,
    input  logic [TAG_WIDTH-1:0]     lookup_tag,
    output logic [NUM_WAYS-1:0]      tag_match,
    output logic [NUM_WAYS-1:0]      dirty_out,

    // -----------------------------------------------------------------
    // Write port (cache controller -> tag array)
    // Single shared port for both write sources. wr_tag_en/wr_dirty_en
    // independently gate the two fields so a hit-write (dirty only) and
    // a fill-write (tag + dirty) can share the same port without a
    // separate mode signal:
    //   - Hit write : wr_tag_en = 0, wr_dirty_en = 1, wr_dirty = 1.
    //   - Fill write: wr_tag_en = 1, wr_tag = new line's tag,
    //                 wr_dirty_en = 1, wr_dirty = fill_is_write.
    // -----------------------------------------------------------------
    input  logic                     wr_en,
    input  logic [SET_IDX_WIDTH-1:0] wr_set_idx,
    input  logic [WAY_WIDTH-1:0]     wr_way_sel,
    input  logic [TAG_WIDTH-1:0]     wr_tag,
    input  logic                     wr_tag_en,
    input  logic                     wr_dirty,
    input  logic                     wr_dirty_en
);

    // Storage: one (tag, dirty) pair per (way, set), modeled as
    // NUM_WAYS independent banks -- matching cache_data_sram's bank
    // layout so both arrays are indexed identically and read together.
    logic [TAG_WIDTH-1:0] tag_mem   [NUM_WAYS][NUM_SETS];
    logic                 dirty_mem [NUM_WAYS][NUM_SETS];

    // Registered compare: the tag stored at the addressed set is
    // compared against lookup_tag combinationally, and only the
    // 1-bit result (not the tag itself) is registered. This keeps
    // tag_match/dirty_out latency identical to cache_data_sram's
    // rd_line -- both are valid the cycle after the address is
    // presented.
    always_ff @(posedge clk) begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            tag_match[w] <= (tag_mem[w][rd_set_idx] == lookup_tag);
            dirty_out[w] <= dirty_mem[w][rd_set_idx];
        end
    end

    // Write: tag and dirty are gated independently so a hit-write can
    // touch only the dirty bit while a fill-write updates both fields
    // in the same cycle.
    always_ff @(posedge clk) begin
        if (wr_en) begin
            if (wr_tag_en) begin
                tag_mem[wr_way_sel][wr_set_idx] <= wr_tag;
            end
            if (wr_dirty_en) begin
                dirty_mem[wr_way_sel][wr_set_idx] <= wr_dirty;
            end
        end
    end

endmodule : cache_tag_array

`default_nettype wire
