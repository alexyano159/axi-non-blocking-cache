// -----------------------------------------------------------------------
// Cache Data SRAM
// -----------------------------------------------------------------------
// Stores the raw data of every cache line: 4-way set-associative, 4 KB
// total capacity. Holds ONLY line data -- no tags, valid bits, or dirty
// bits. Tag and dirty live in cache_tag_array; valid bits live in
// cache_valid_array.
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
// of a real SRAM macro (address sampled on the clock edge, data
// available the following edge). Storage is built from sram_sdp
// banks, one per (way, word), so that synthesis maps it onto block
// RAM rather than flip-flops. Which way holds the
// requested line is not known until the controller combines the tag
// array's tag_match with the valid array's valid_out (both read in
// parallel, with matching latency) into the hit way.
//
// No reset: a physical SRAM macro has no reset pin, and clearing this
// array synchronously in one cycle is not representative of real
// hardware. Line data is undefined until written; correctness after
// reset is guaranteed by cache_valid_array's valid bits being cleared
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
    //                 wr_data carries the store word (the controller
    //                 replicates it into every 32-bit lane).
    //   - Fill write: wr_word_en = all-ones, wr_data is the full line
    //                 returned by the MSHR.
    // -----------------------------------------------------------------
    input  wire logic                        wr_en,
    input  wire logic [SET_IDX_WIDTH-1:0]    wr_set_idx,
    input  wire logic [WAY_WIDTH-1:0]        wr_way_sel,
    input  wire logic [WORDS_PER_LINE-1:0]   wr_word_en,
    input  wire logic [LINE_WIDTH-1:0]       wr_data
);

    // Storage: NUM_WAYS x WORDS_PER_LINE independent banks, each a
    // NUM_SETS-deep, DATA_WIDTH-wide sram_sdp (16 banks of 64 x 32 by
    // default). Every bank sees the same read address, so one read
    // returns all ways of the set in parallel, as a real 4-way data
    // array of four memories sharing an address bus does.
    //
    // Splitting each way further into one bank per word turns the
    // per-word write mask into a plain per-bank write enable: bank
    // (w, i) is written only when way w is selected and word i is
    // enabled. A single wide array written through a variable way index
    // and a per-word mask does not match the block-RAM inference
    // template and is implemented in flip-flops (32 Kbit of registers
    // at the default size); see sram_sdp.
    //
    // Read-during-write to the same (way, set) on the same edge returns
    // the pre-write contents (sram_sdp's old-data behavior).
    logic [DATA_WIDTH-1:0] rd_word [NUM_WAYS][WORDS_PER_LINE];

    genvar gw, gi;
    generate
    for (gw = 0; gw < NUM_WAYS; gw = gw + 1) begin : g_way
        for (gi = 0; gi < WORDS_PER_LINE; gi = gi + 1) begin : g_word
            sram_sdp #(
                .WIDTH (DATA_WIDTH),
                .DEPTH (NUM_SETS)
            ) u_bank (
                .clk     (clk),
                .rd_addr (rd_set_idx),
                .rd_data (rd_word[gw][gi]),
                .wr_en   (wr_en && (wr_way_sel == WAY_WIDTH'(gw)) && wr_word_en[gi]),
                .wr_addr (wr_set_idx),
                .wr_data (wr_data[gi*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    end
    endgenerate

    // Reassemble each way's line from its word banks (wiring only).
    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            for (int i = 0; i < WORDS_PER_LINE; i++) begin
                rd_line[w][i*DATA_WIDTH +: DATA_WIDTH] = rd_word[w][i];
            end
        end
    end

endmodule : cache_data_sram

`default_nettype wire
