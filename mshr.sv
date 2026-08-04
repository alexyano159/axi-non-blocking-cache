// MSHR (Miss Status Holding Register) for the non-blocking cache.
//
// Tracks cache misses that are currently in flight to main memory. Each
// entry corresponds to one outstanding line fetch and is indexed by its
// AXI transaction ID. A miss whose address matches an entry already in
// flight is merged into that entry instead of issuing a duplicate AXI
// request (secondary miss / hit-under-miss). This is the sole AXI4
// master in the design: it issues read bursts to service misses and
// write bursts to evict dirty victim lines.
`default_nettype none

module mshr #(
    parameter int ADDR_WIDTH  = 32,
    parameter int DATA_WIDTH  = 32,
    parameter int ID_WIDTH    = 4,
    parameter int LINE_WORDS  = 4,                      // words per cache line, equal to the AXI burst length
    parameter int LINE_WIDTH  = DATA_WIDTH * LINE_WORDS, // full cache line width, in bits
    parameter int NUM_ENTRIES = (1 << ID_WIDTH)          // one entry per AXI ID value
) (
    input  logic clk,
    input  logic rst_n,  // active-low, synchronous

    // -----------------------------------------------------------------
    // Miss allocation: cache controller -> MSHR
    // Asserted the cycle a tag-compare miss is detected.
    // -----------------------------------------------------------------
    input  logic                  alloc_valid,     // request to allocate or merge a miss
    input  logic [ADDR_WIDTH-1:0] alloc_addr,      // line-aligned address that missed
    input  logic                  alloc_is_write,  // 1 = the missing access was a store
    output logic                  alloc_ready,     // deasserted only when no entry is free and alloc_addr matches no pending entry
    output logic [ID_WIDTH-1:0]   alloc_id,        // entry index / AXI ID assigned to this miss

    // -----------------------------------------------------------------
    // Victim writeback: cache controller -> MSHR
    // Asserted when a dirty line is evicted and must be flushed to
    // memory before the incoming line can take its place.
    // -----------------------------------------------------------------
    input  logic                    wb_valid,  // request to write back a dirty victim line
    input  logic [ADDR_WIDTH-1:0]   wb_addr,   // victim line address
    input  logic [LINE_WIDTH-1:0]   wb_data,   // victim line data
    output logic                    wb_ready,  // deasserted when the writeback queue is full
    output logic                    wb_done,   // asserted for one cycle once the AXI B response confirms completion

    // -----------------------------------------------------------------
    // Fill completion: MSHR -> cache controller / data array
    // Asserted once an AXI read burst has been fully reassembled into
    // a line.
    // -----------------------------------------------------------------
    output logic                  fill_valid,     // a completed line is being presented this cycle
    output logic [ID_WIDTH-1:0]   fill_id,        // entry that completed
    output logic [ADDR_WIDTH-1:0] fill_addr,      // address of the completed line
    output logic [LINE_WIDTH-1:0] fill_data,      // reassembled line data, all beats concatenated
    output logic                  fill_is_write,  // forwarded from alloc_is_write, tells the controller to merge the pending store and mark the line dirty
    input  logic                  fill_ready,      // 1 = the data array can accept the fill this cycle

    // -----------------------------------------------------------------
    // Memory side: AXI4 master port. Drives AR/R to service misses and
    // AW/W/B to write back evicted dirty lines.
    // -----------------------------------------------------------------
    axi_if.master axi
);

endmodule : mshr

`default_nettype wire
