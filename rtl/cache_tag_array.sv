// -----------------------------------------------------------------------
// Cache Tag Array
// -----------------------------------------------------------------------
// Stores the tag and dirty bit of every cache line: 4-way set-associative,
// one (tag, dirty) pair per (way, set). Holds NO valid bits -- those live
// in the separate, dedicated valid-bit array (cache_valid_array), which is the
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
//                  into the freshly allocated way and clears its dirty
//                  bit. A line is always installed clean: a store that
//                  missed is replayed after the fill as an ordinary
//                  store hit, which sets dirty through path 1.
// wr_tag_en / wr_dirty_en let a fill-write update both fields in the same
// cycle while a hit-write updates only dirty, without needing a separate
// write port or an implicit "mode" signal.
//
// Read port latency matches cache_data_sram: the tag compare result and
// dirty bit are valid one cycle after rd_set_idx/lookup_tag are
// presented -- so the controller can combine this array's hit
// information with the data array's line contents in the same cycle.
// Tags are stored in sram_sdp banks (block RAM after synthesis); the
// compare is performed on the banks' registered outputs against a
// registered copy of lookup_tag.
//
// The stored tags of the addressed set are also read out (tag_out),
// with the same one-cycle latency. The compare alone is sufficient for
// hit detection, but eviction requires the victim's actual tag: a dirty
// victim's writeback address is {stored tag, set index, zero offset},
// and no other structure retains that tag.
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
    input  wire logic clk,

    // -----------------------------------------------------------------
    // Read / compare port (cache controller -> tag array)
    // Driven every cycle a lookup is performed (load or store). Compares
    // lookup_tag against all NUM_WAYS tags of the addressed set and
    // returns a raw per-way match vector plus each way's dirty bit and
    // stored tag, one cycle later; the controller ANDs tag_match with
    // the valid array's output to determine the real hit/hit_way, and
    // uses tag_out to form a dirty victim's writeback address.
    // -----------------------------------------------------------------
    input  wire logic [SET_IDX_WIDTH-1:0] rd_set_idx,
    input  wire logic [TAG_WIDTH-1:0]     lookup_tag,
    output      logic [NUM_WAYS-1:0]      tag_match,
    output      logic [NUM_WAYS-1:0]      dirty_out,
    output      logic [TAG_WIDTH-1:0]     tag_out [NUM_WAYS],

    // -----------------------------------------------------------------
    // Write port (cache controller -> tag array)
    // Single shared port for both write sources. wr_tag_en/wr_dirty_en
    // independently gate the two fields so a hit-write (dirty only) and
    // a fill-write (tag + dirty) can share the same port without a
    // separate mode signal:
    //   - Hit write : wr_tag_en = 0, wr_dirty_en = 1, wr_dirty = 1.
    //   - Fill write: wr_tag_en = 1, wr_tag = new line's tag,
    //                 wr_dirty_en = 1, wr_dirty = 0 (installed clean).
    // -----------------------------------------------------------------
    input  wire logic                     wr_en,
    input  wire logic [SET_IDX_WIDTH-1:0] wr_set_idx,
    input  wire logic [WAY_WIDTH-1:0]     wr_way_sel,
    input  wire logic [TAG_WIDTH-1:0]     wr_tag,
    input  wire logic                     wr_tag_en,
    input  wire logic                     wr_dirty,
    input  wire logic                     wr_dirty_en
);

    // Tag storage: one NUM_SETS x TAG_WIDTH sram_sdp bank per way, all
    // sharing the read address -- the same bank layout as
    // cache_data_sram, so both arrays are indexed identically and read
    // together. Each bank's registered output is tag_out directly.
    genvar gw;
    generate
    for (gw = 0; gw < NUM_WAYS; gw = gw + 1) begin : g_way
        sram_sdp #(
            .WIDTH (TAG_WIDTH),
            .DEPTH (NUM_SETS)
        ) u_tag_bank (
            .clk     (clk),
            .rd_addr (rd_set_idx),
            .rd_data (tag_out[gw]),
            .wr_en   (wr_en && wr_tag_en && (wr_way_sel == WAY_WIDTH'(gw))),
            .wr_addr (wr_set_idx),
            .wr_data (wr_tag)
        );
    end
    endgenerate

    // Compare after the read register. A block RAM can only present
    // registered read data, so the compare cannot sit between the array
    // and a register (doing so forces the array into flip-flops).
    // Instead lookup_tag is registered alongside the address, and the
    // registered stored tags are compared against it combinationally.
    // tag_match therefore remains valid the cycle after rd_set_idx /
    // lookup_tag are presented, as before; the cost is one 22-bit
    // equality compare moved into the cycle that consumes tag_match.
    logic [TAG_WIDTH-1:0] lookup_tag_q;

    always_ff @(posedge clk) begin
        lookup_tag_q <= lookup_tag;
    end

    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            tag_match[w] = (tag_out[w] == lookup_tag_q);
        end
    end

    // Dirty bits: kept in flip-flops (NUM_WAYS x NUM_SETS = 256 bits by
    // default) rather than in sram_sdp banks. The field is tiny, and
    // four dedicated block RAMs for 64 bits each would waste far more
    // area than the registers. Read and write timing match the tag
    // banks: registered read, written on the same edge as the tag on a
    // fill, written alone on a store hit.
    logic dirty_mem [NUM_WAYS][NUM_SETS];

    always_ff @(posedge clk) begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            dirty_out[w] <= dirty_mem[w][rd_set_idx];
        end
        if (wr_en && wr_dirty_en) begin
            dirty_mem[wr_way_sel][wr_set_idx] <= wr_dirty;
        end
    end

endmodule : cache_tag_array

`default_nettype wire
