// -----------------------------------------------------------------------
// Simple Dual-Port SRAM
// -----------------------------------------------------------------------
// Generic storage primitive: one read port and one write port sharing a
// single clock, registered read, no reset. Both cache arrays that hold
// bulk state (cache_data_sram, cache_tag_array) are built from instances
// of this module, one instance per independently written field.
//
// The body is written in the canonical inference template: a single
// one-dimensional array, one write address with one write enable, and a
// read address sampled on the clock edge with the read data taken
// directly from the array into the output register. FPGA synthesis tools
// map exactly this pattern onto embedded block RAM (e.g. Intel M10K);
// in an ASIC flow the module is the natural point at which to substitute
// a compiled SRAM macro. Any logic between the array and the output
// register (a compare, a mux across several arrays, a partial-word
// write) defeats inference and implements the array in flip-flops,
// which is why such logic is kept in the parent modules instead.
//
// Read-during-write to the same address on the same edge returns the
// pre-write contents (old data), as in a typical synchronous SRAM.
//
// No reset: a physical SRAM has no reset pin. Contents are undefined
// until written; the owning module is responsible for never trusting an
// entry before it is written (see cache_valid_array).
// -----------------------------------------------------------------------
`default_nettype none

module sram_sdp #(
    parameter int WIDTH      = 32,
    parameter int DEPTH      = 64,
    parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
    input  wire logic                  clk,

    // Read port: rd_addr is sampled on the clock edge; rd_data holds the
    // addressed word from the following cycle until the next edge.
    input  wire logic [ADDR_WIDTH-1:0] rd_addr,
    output      logic [WIDTH-1:0]      rd_data,

    // Write port: one full-width word per cycle, gated by wr_en.
    input  wire logic                  wr_en,
    input  wire logic [ADDR_WIDTH-1:0] wr_addr,
    input  wire logic [WIDTH-1:0]      wr_data
);

    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (wr_en) begin
            mem[wr_addr] <= wr_data;
        end
        rd_data <= mem[rd_addr];
    end

endmodule : sram_sdp

`default_nettype wire
