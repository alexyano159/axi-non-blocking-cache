// -----------------------------------------------------------------------
// Cache Data SRAM
// -----------------------------------------------------------------------
// Stores the raw data of every cache line: 4-way set-associative, 4 KB
// total capacity. Holds ONLY line data -- no tags, valid bits, or dirty
// bits, which live in the (separate) tag array.
//
// Two write sources are merged onto a single shared write port by the
// cache controller, which is the only client of this module:
//   1. Hit write : a store hit overwrites one word of an already-resident
//                  line, in place, same set/way.
//   2. Fill write: after a miss, the MSHR returns a full line, which the
//                  controller writes into a freshly allocated way.
// This module has no direct connection to the MSHR -- the controller
// mediates both paths.
//
// Read port returns all 4 ways of the addressed set, one cycle after
// rd_set_idx is presented -- a registered read, matching the latency
// of a real single-port SRAM macro (address sampled on the clock
// edge, data available the following edge). Which way holds the
// requested line is not known until the tag array (read in parallel,
// elsewhere, with matching latency) reports the hit way.
//
// No reset: a physical SRAM macro has no reset pin, and clearing this
// array synchronously in one cycle is not representative of real
// hardware. Line data is undefined until written; correctness after
// reset is guaranteed by the tag array's valid bits being cleared
// there, not by this module.
// -----------------------------------------------------------------------
`default_nettype none

module cache_data_sram #(
    parameter int DATA_WIDTH     = 32,
    parameter int NUM_WAYS       = 4,
    parameter int WORDS_PER_LINE = 4,                          // AXI burst length (LINE_WORDS in mshr.sv)
    parameter int NUM_SETS       = 64,                         // 4KB total / 4 ways / 16B line
    parameter int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE, // 128
    parameter int SET_IDX_WIDTH  = $clog2(NUM_SETS),            // 6
    parameter int WAY_WIDTH      = $clog2(NUM_WAYS)             // 2
) (
    input  wire logic clk,

    // -----------------------------------------------------------------
    // Read port (cache controller -> SRAM)
    // Driven every cycle a lookup is performed (load or store). Returns
    // all NUM_WAYS lines of the addressed set, one cycle later; the
    // controller combines this with the tag array's hit-way result
    // (read with matching latency) to select data or a write target.
    // -----------------------------------------------------------------
    input  wire logic [SET_IDX_WIDTH-1:0] rd_set_idx,
    output      logic [LINE_WIDTH-1:0]    rd_line [NUM_WAYS],

    // -----------------------------------------------------------------
    // Write port (cache controller -> SRAM)
    // Single shared port for both write sources. The controller
    // arbitrates hit-writes vs. fill-writes and presents one merged
    // request per cycle:
    //   - Hit write : wr_word_en = one-hot at the target word offset,
    //                 wr_data carries the store word at its correct
    //                 32-bit slice.
    //   - Fill write: wr_word_en = all-ones, wr_data is the full line
    //                 returned by the MSHR.
    // -----------------------------------------------------------------
    input  wire logic                        wr_en,
    input  wire logic [SET_IDX_WIDTH-1:0]    wr_set_idx,
    input  wire logic [WAY_WIDTH-1:0]        wr_way_sel,
    input  wire logic [WORDS_PER_LINE-1:0]   wr_word_en,
    input  wire logic [LINE_WIDTH-1:0]       wr_data
);

    // Storage: one line per (way, set) pair. Modeled as four independent
    // banks rather than a single flat array, reflecting that a real
    // 4-way SRAM is four parallel memories sharing an address bus, not
    // one wide memory with an extra address bit.
    logic [LINE_WIDTH-1:0] mem [NUM_WAYS][NUM_SETS];

    // Registered read: samples rd_set_idx on the clock edge and presents
    // all NUM_WAYS lines of that set the following cycle. A write to the
    // same (way, set) on the same edge is not forwarded -- the read
    // returns the pre-write contents, matching the read-old-data
    // collision behavior of a typical single-port synchronous SRAM.
    always_ff @(posedge clk) begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            rd_line[w] <= mem[w][rd_set_idx];
        end
    end

    // Write: gated per-word by wr_word_en, so the same port serves both
    // a narrow store-hit write (one bit set) and a full-line fill write
    // (all bits set) without a separate mode signal.
    always_ff @(posedge clk) begin
        if (wr_en) begin
            for (int i = 0; i < WORDS_PER_LINE; i++) begin
                if (wr_word_en[i]) begin
                    mem[wr_way_sel][wr_set_idx][i*DATA_WIDTH +: DATA_WIDTH] <= wr_data[i*DATA_WIDTH +: DATA_WIDTH];
                end
            end
        end
    end

endmodule : cache_data_sram

`default_nettype wire
