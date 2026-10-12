// -----------------------------------------------------------------------
// Cache Top Level
// -----------------------------------------------------------------------
// Structural top level of the non-blocking L1 data cache: a 4-way
// set-associative, write-back / write-allocate cache with a tagged,
// multi-outstanding CPU interface and a single AXI4 master port to main
// memory. This module contains no behavioural logic of its own -- it
// instantiates the five verified building blocks, connects them through
// named nets, and checks at elaboration time that the parameter set they
// share is one the design actually supports.
//
// Block diagram (every array port group is driven solely by the
// controller; the MSHR is the only block on the AXI bus):
//
//                    +-----------------------------------------------------+
//                    |                      cache_top                      |
//                    |                                                     |
//   CPU request ---->|  +------------------+  tag_*    +-----------------+ |
//   req_valid/ready  |  |                  |<--------->| cache_tag_array | |
//   req_addr/we      |  |                  |           +-----------------+ |
//   req_wdata/id     |  |                  |  valid_*  +-----------------+ |
//                    |  | cache_controller |<--------->|cache_valid_array| |
//   CPU response <---|  |                  |           +-----------------+ |
//   resp_valid/ready |  |                  |  data_*   +-----------------+ |
//   resp_id/data/we  |  |                  |<--------->| cache_data_sram | |
//                    |  +------------------+           +-----------------+ |
//                    |        ^  mshr_alloc_*  (miss, id returned)         |
//                    |        |  mshr_wb_*     (dirty victim handoff)      |
//                    |        v  mshr_fill_*   (completed line)            |
//                    |  +------------------+                               |
//                    |  |       mshr       |======== axi (master) =========|===> memory
//                    |  +------------------+  AR/R  : line fills           |    (AXI4 slave)
//                    |                        AW/W/B: victim writebacks    |
//                    +-----------------------------------------------------+
//
// Submodule roles:
//   cache_controller  : address decomposition, hit/miss detection, the
//                       hit path and response FIFO, true-LRU replacement,
//                       MSHR allocation, the waiting table of missed
//                       requests, two-cycle fill installation with
//                       dirty-victim handoff, and replay of waiting
//                       requests. Sole client of the other four blocks.
//   cache_tag_array   : per-(way, set) tag and dirty bit; registered
//                       four-way tag compare and stored-tag read-out. No
//                       reset.
//   cache_valid_array : per-(way, set) valid bit; registered read;
//                       synchronous reset to all-invalid. The only array
//                       whose reset makes the cache correct after reset.
//   cache_data_sram   : per-(way, set) 128-bit line; registered read of
//                       all four ways; word-masked write. No reset.
//   mshr              : up to 2**MSHR_ID_WIDTH outstanding line misses,
//                       with secondary-miss merging, one AXI ID per entry;
//                       a WB_QUEUE_DEPTH-entry victim writeback queue;
//                       read-after-write ordering of a re-miss behind the
//                       writeback of the same line.
//
// Transaction flow through the hierarchy (cycle N = request accepted):
//   Hit    : N   -- the controller drives the request's set index onto
//                   all three array read ports.
//            N+1 -- the registered tag match is ANDed with the valid
//                   bits; a load pushes the selected word into the
//                   response FIFO, a store writes one word of the data
//                   SRAM and sets the dirty bit in the tag array. The LRU
//                   order of the set is updated. The response is visible
//                   on resp_* from N+2.
//   Miss   : N+1 -- no valid way matches. The controller allocates (or
//                   merges into) an MSHR entry with the line-aligned
//                   address and parks the full request in its waiting
//                   table, tagged with the returned MSHR id. Later
//                   requests continue to be served (hit-under-miss). The
//                   MSHR issues an AR burst of WORDS_PER_LINE beats and
//                   reassembles the R beats into a line.
//   Fill   : the MSHR presents the completed line on mshr_fill_*. The
//            controller holds off the CPU, reads the fill's set (F0),
//            then in F1 selects the victim (lowest invalid way, else the
//            LRU way), hands a valid dirty victim to the MSHR writeback
//            queue on the same edge on which it writes the new tag, valid
//            bit and line, and completes the handshake with
//            mshr_fill_ready. The MSHR drains queued victims over
//            AW/W/B, one line at a time.
//   Replay : the fill marks every waiting request of that MSHR entry
//            ready. Those requests re-enter the lookup stage in arrival
//            order, ahead of further fills and CPU requests, and complete
//            through the hit path: loads return data, stores write their
//            word and dirty the line. A store miss is therefore never
//            merged into the line at fill time.
//   Re-miss: a miss to a line whose dirty copy is still queued for
//            writeback is allocated normally; the MSHR withholds its AR
//            until that writeback's B response, so the fill returns the
//            written-back data rather than stale memory contents.
// -----------------------------------------------------------------------
`default_nettype none

module cache_top #(
    parameter int ADDR_WIDTH     = 32,
    parameter int DATA_WIDTH     = 32,
    parameter int NUM_WAYS       = 4,
    parameter int WORDS_PER_LINE = 4,    // words per line = AXI burst length (MSHR LINE_WORDS)
    parameter int NUM_SETS       = 64,   // 4 KB total / 4 ways / 16 B line
    parameter int MSHR_ID_WIDTH  = 4,    // MSHR ID_WIDTH = AXI ID width; 2**MSHR_ID_WIDTH MSHR entries
    parameter int TXN_ID_WIDTH   = 4,    // CPU-side transaction tag width
    parameter int WB_QUEUE_DEPTH = 4     // MSHR victim writeback queue depth
) (
    input  wire logic clk,
    input  wire logic rst_n,   // active-low, synchronous reset

    // -----------------------------------------------------------------
    // CPU-facing request (valid/ready). A request is accepted on a cycle
    // with req_valid && req_ready. req_id tags the request; it is echoed
    // on the matching response.
    // -----------------------------------------------------------------
    input  wire logic                    req_valid,
    output      logic                    req_ready,
    input  wire logic [ADDR_WIDTH-1:0]   req_addr,
    input  wire logic                    req_we,      // 1 = store, 0 = load
    input  wire logic [DATA_WIDTH-1:0]   req_wdata,   // store data (ignored for a load)
    input  wire logic [TXN_ID_WIDTH-1:0] req_id,

    // -----------------------------------------------------------------
    // CPU-facing response (valid/ready). Responses may return out of
    // request order (a hit behind a pending miss completes first);
    // resp_id identifies the request each one answers.
    // -----------------------------------------------------------------
    output      logic                    resp_valid,
    input  wire logic                    resp_ready,
    output      logic [TXN_ID_WIDTH-1:0] resp_id,
    output      logic [DATA_WIDTH-1:0]   resp_data,   // load data (don't-care on a store acknowledge)
    output      logic                    resp_we,     // echoes req_we of the answered request

    // -----------------------------------------------------------------
    // AXI4 master port to main memory, driven exclusively by the MSHR.
    // The connected interface instance must use ADDR_WIDTH, DATA_WIDTH
    // and ID_WIDTH = MSHR_ID_WIDTH (checked below).
    // -----------------------------------------------------------------
    axi_if.master axi
);

    // -------------------------------------------------------------------
    // Derived parameters
    // Computed with the same expressions the submodules use for their own
    // defaults. Only the primary parameters are passed down, so every
    // submodule derives identical widths from them; the localparams here
    // size the interconnect nets.
    // -------------------------------------------------------------------
    localparam int SET_IDX_WIDTH  = $clog2(NUM_SETS);              // 6
    localparam int WAY_WIDTH      = $clog2(NUM_WAYS);              // 2
    localparam int WORD_OFF_WIDTH = $clog2(WORDS_PER_LINE);        // 2
    localparam int BYTE_OFF_WIDTH = $clog2(DATA_WIDTH / 8);        // 2
    localparam int TAG_WIDTH      = ADDR_WIDTH - SET_IDX_WIDTH
                                    - WORD_OFF_WIDTH - BYTE_OFF_WIDTH; // 22
    localparam int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE;   // 128

    // ===================================================================
    // Interconnect: controller <-> cache_tag_array
    // ===================================================================
    logic [SET_IDX_WIDTH-1:0] tag_rd_set_idx;
    logic [TAG_WIDTH-1:0]     tag_lookup_tag;
    logic [NUM_WAYS-1:0]      tag_match;          // raw per-way compare, not yet gated by valid
    logic [NUM_WAYS-1:0]      tag_dirty_out;
    logic [TAG_WIDTH-1:0]     tag_tag_out [NUM_WAYS];  // stored tags, used for the victim writeback address

    logic                     tag_wr_en;
    logic [SET_IDX_WIDTH-1:0] tag_wr_set_idx;
    logic [WAY_WIDTH-1:0]     tag_wr_way_sel;
    logic [TAG_WIDTH-1:0]     tag_wr_tag;
    logic                     tag_wr_tag_en;
    logic                     tag_wr_dirty;
    logic                     tag_wr_dirty_en;

    // ===================================================================
    // Interconnect: controller <-> cache_valid_array
    // ===================================================================
    logic [SET_IDX_WIDTH-1:0] valid_rd_set_idx;
    logic [NUM_WAYS-1:0]      valid_out;

    logic                     valid_wr_en;
    logic [SET_IDX_WIDTH-1:0] valid_wr_set_idx;
    logic [WAY_WIDTH-1:0]     valid_wr_way_sel;
    logic                     valid_wr_valid;

    // ===================================================================
    // Interconnect: controller <-> cache_data_sram
    // ===================================================================
    logic [SET_IDX_WIDTH-1:0]  data_rd_set_idx;
    logic [LINE_WIDTH-1:0]     data_rd_line [NUM_WAYS];

    logic                      data_wr_en;
    logic [SET_IDX_WIDTH-1:0]  data_wr_set_idx;
    logic [WAY_WIDTH-1:0]      data_wr_way_sel;
    logic [WORDS_PER_LINE-1:0] data_wr_word_en;
    logic [LINE_WIDTH-1:0]     data_wr_data;

    // ===================================================================
    // Interconnect: controller <-> mshr
    // ===================================================================
    // Miss allocation (controller -> MSHR, MSHR id returned in the same
    // cycle).
    logic                     mshr_alloc_valid;
    logic [ADDR_WIDTH-1:0]    mshr_alloc_addr;
    logic                     mshr_alloc_is_write;
    logic                     mshr_alloc_ready;
    logic [MSHR_ID_WIDTH-1:0] mshr_alloc_id;

    // Dirty-victim handoff (controller -> MSHR writeback queue).
    logic                     mshr_wb_valid;
    logic [ADDR_WIDTH-1:0]    mshr_wb_addr;
    logic [LINE_WIDTH-1:0]    mshr_wb_data;
    logic                     mshr_wb_ready;

    // Fill completion (MSHR -> controller).
    logic                     mshr_fill_valid;
    logic [MSHR_ID_WIDTH-1:0] mshr_fill_id;
    logic [ADDR_WIDTH-1:0]    mshr_fill_addr;
    logic [LINE_WIDTH-1:0]    mshr_fill_data;
    logic                     mshr_fill_ready;

    // -------------------------------------------------------------------
    // MSHR outputs that the controller does not consume.
    // Both are routed to the controller's matching input ports, which
    // exist so that the controller mirrors the MSHR interface one-for-one,
    // but the controller's logic does not read them. They are carried on
    // explicitly named nets so that no port is left unconnected and the
    // signals remain observable for system-level checks.
    //
    // mshr_fill_is_write: the MSHR reports whether any access merged into
    //   the entry was a store, so that a design merging stores at fill
    //   time could install the line dirty. This controller does not merge
    //   at fill time: it installs every line clean and replays each
    //   parked store through the hit path, which writes the word and sets
    //   the dirty bit. The per-request waiting table already holds the
    //   store data and word offset that the flag alone could not supply.
    //
    // mshr_wb_done: pulses when a victim writeback receives its B
    //   response. The controller needs no writeback-completion event: the
    //   victim leaves the cache in the same cycle it is handed to the
    //   queue, and the only hazard on a queued victim -- a re-miss to the
    //   same line reading stale memory -- is resolved inside the MSHR,
    //   which holds that miss's AR until the matching writeback completes.
    // -------------------------------------------------------------------
    logic                     mshr_fill_is_write;  // unused by the controller: stores are replayed, not merged at fill
    logic                     mshr_wb_done;        // unused by the controller: re-miss ordering is enforced in the MSHR

    // ===================================================================
    // Cache controller
    // ===================================================================
    cache_controller #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS),
        .MSHR_ID_WIDTH (MSHR_ID_WIDTH),
        .TXN_ID_WIDTH  (TXN_ID_WIDTH)
    ) u_controller (
        .clk                (clk),
        .rst_n              (rst_n),

        .req_valid          (req_valid),
        .req_ready          (req_ready),
        .req_addr           (req_addr),
        .req_we             (req_we),
        .req_wdata          (req_wdata),
        .req_id             (req_id),

        .resp_valid         (resp_valid),
        .resp_ready         (resp_ready),
        .resp_id            (resp_id),
        .resp_data          (resp_data),
        .resp_we            (resp_we),

        .tag_rd_set_idx     (tag_rd_set_idx),
        .tag_lookup_tag     (tag_lookup_tag),
        .tag_match          (tag_match),
        .tag_dirty_out      (tag_dirty_out),
        .tag_tag_out        (tag_tag_out),
        .tag_wr_en          (tag_wr_en),
        .tag_wr_set_idx     (tag_wr_set_idx),
        .tag_wr_way_sel     (tag_wr_way_sel),
        .tag_wr_tag         (tag_wr_tag),
        .tag_wr_tag_en      (tag_wr_tag_en),
        .tag_wr_dirty       (tag_wr_dirty),
        .tag_wr_dirty_en    (tag_wr_dirty_en),

        .valid_rd_set_idx   (valid_rd_set_idx),
        .valid_out          (valid_out),
        .valid_wr_en        (valid_wr_en),
        .valid_wr_set_idx   (valid_wr_set_idx),
        .valid_wr_way_sel   (valid_wr_way_sel),
        .valid_wr_valid     (valid_wr_valid),

        .data_rd_set_idx    (data_rd_set_idx),
        .data_rd_line       (data_rd_line),
        .data_wr_en         (data_wr_en),
        .data_wr_set_idx    (data_wr_set_idx),
        .data_wr_way_sel    (data_wr_way_sel),
        .data_wr_word_en    (data_wr_word_en),
        .data_wr_data       (data_wr_data),

        .mshr_alloc_valid   (mshr_alloc_valid),
        .mshr_alloc_addr    (mshr_alloc_addr),
        .mshr_alloc_is_write(mshr_alloc_is_write),
        .mshr_alloc_ready   (mshr_alloc_ready),
        .mshr_alloc_id      (mshr_alloc_id),
        .mshr_wb_valid      (mshr_wb_valid),
        .mshr_wb_addr       (mshr_wb_addr),
        .mshr_wb_data       (mshr_wb_data),
        .mshr_wb_ready      (mshr_wb_ready),
        .mshr_wb_done       (mshr_wb_done),
        .mshr_fill_valid    (mshr_fill_valid),
        .mshr_fill_id       (mshr_fill_id),
        .mshr_fill_addr     (mshr_fill_addr),
        .mshr_fill_data     (mshr_fill_data),
        .mshr_fill_is_write (mshr_fill_is_write),
        .mshr_fill_ready    (mshr_fill_ready)
    );

    // ===================================================================
    // Tag + dirty array
    // ===================================================================
    cache_tag_array #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) u_tag_array (
        .clk        (clk),
        .rd_set_idx (tag_rd_set_idx),
        .lookup_tag (tag_lookup_tag),
        .tag_match  (tag_match),
        .dirty_out  (tag_dirty_out),
        .tag_out    (tag_tag_out),
        .wr_en      (tag_wr_en),
        .wr_set_idx (tag_wr_set_idx),
        .wr_way_sel (tag_wr_way_sel),
        .wr_tag     (tag_wr_tag),
        .wr_tag_en  (tag_wr_tag_en),
        .wr_dirty   (tag_wr_dirty),
        .wr_dirty_en(tag_wr_dirty_en)
    );

    // ===================================================================
    // Valid-bit array (the only array with a reset)
    // ===================================================================
    cache_valid_array #(
        .NUM_WAYS(NUM_WAYS),
        .NUM_SETS(NUM_SETS)
    ) u_valid_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .rd_set_idx(valid_rd_set_idx),
        .valid_out (valid_out),
        .wr_en     (valid_wr_en),
        .wr_set_idx(valid_wr_set_idx),
        .wr_way_sel(valid_wr_way_sel),
        .wr_valid  (valid_wr_valid)
    );

    // ===================================================================
    // Line data SRAM
    // ===================================================================
    cache_data_sram #(
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS)
    ) u_data_sram (
        .clk       (clk),
        .rd_set_idx(data_rd_set_idx),
        .rd_line   (data_rd_line),
        .wr_en     (data_wr_en),
        .wr_set_idx(data_wr_set_idx),
        .wr_way_sel(data_wr_way_sel),
        .wr_word_en(data_wr_word_en),
        .wr_data   (data_wr_data)
    );

    // ===================================================================
    // MSHR: miss handling, victim writeback, AXI4 master
    // NUM_ENTRIES is left at its default of 2**ID_WIDTH: entries are
    // indexed directly by AXI ID (arid on issue, rid on return), so the
    // two cannot differ.
    // ===================================================================
    mshr #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .ID_WIDTH      (MSHR_ID_WIDTH),
        .LINE_WORDS    (WORDS_PER_LINE),
        .WB_QUEUE_DEPTH(WB_QUEUE_DEPTH)
    ) u_mshr (
        .clk           (clk),
        .rst_n         (rst_n),

        .alloc_valid   (mshr_alloc_valid),
        .alloc_addr    (mshr_alloc_addr),
        .alloc_is_write(mshr_alloc_is_write),
        .alloc_ready   (mshr_alloc_ready),
        .alloc_id      (mshr_alloc_id),

        .wb_valid      (mshr_wb_valid),
        .wb_addr       (mshr_wb_addr),
        .wb_data       (mshr_wb_data),
        .wb_ready      (mshr_wb_ready),
        .wb_done       (mshr_wb_done),

        .fill_valid    (mshr_fill_valid),
        .fill_id       (mshr_fill_id),
        .fill_addr     (mshr_fill_addr),
        .fill_data     (mshr_fill_data),
        .fill_is_write (mshr_fill_is_write),
        .fill_ready    (mshr_fill_ready),

        .axi           (axi)
    );

`ifndef SYNTHESIS
    // -------------------------------------------------------------------
    // Elaboration-time parameter checks
    // The submodules derive every field width with $clog2 and assume the
    // parameter set below; a violation would otherwise elaborate silently
    // into a cache that aliases addresses or mis-sizes AXI bursts.
    //
    // Not repeated here: the requirement that the controller's waiting
    // table (WAIT_DEPTH = 2**TXN_ID_WIDTH) not exceed the MSHR entry count
    // (2**MSHR_ID_WIDTH) is checked inside cache_controller, next to the
    // acceptance argument that depends on it (every miss finds a free or
    // matching MSHR entry, so alloc_ready need not be waited on).
    // -------------------------------------------------------------------
    initial begin
        // Address decomposition: the set index and both offsets are
        // contiguous bit fields, so every count they index must be a power
        // of two, and a way index of at least one bit is assumed.
        if (NUM_WAYS < 2 || (NUM_WAYS & (NUM_WAYS - 1)) != 0)
            $fatal(1, "cache_top: NUM_WAYS (%0d) must be a power of two >= 2", NUM_WAYS);
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0)
            $fatal(1, "cache_top: NUM_SETS (%0d) must be a power of two >= 2", NUM_SETS);
        if (DATA_WIDTH < 8 || DATA_WIDTH > 1024 || (DATA_WIDTH & (DATA_WIDTH - 1)) != 0)
            $fatal(1, "cache_top: DATA_WIDTH (%0d) must be a power of two in 8..1024 (AXI data bus width)",
                   DATA_WIDTH);
        if (TAG_WIDTH < 1)
            $fatal(1, "cache_top: ADDR_WIDTH (%0d) leaves no tag bits above set index and line offset",
                   ADDR_WIDTH);

        // Line size vs. AXI burst: the MSHR moves exactly one line per
        // INCR burst of WORDS_PER_LINE full-width beats (AxLEN =
        // WORDS_PER_LINE - 1, AxSIZE = log2(DATA_WIDTH/8)) and counts
        // beats with a $clog2(WORDS_PER_LINE)-bit counter. AXI4 limits an
        // INCR burst to 256 beats, and a burst must not cross a 4 KB
        // boundary, which a line-aligned burst avoids only if the line
        // itself is at most 4 KB.
        if (WORDS_PER_LINE < 2 || WORDS_PER_LINE > 256 ||
            (WORDS_PER_LINE & (WORDS_PER_LINE - 1)) != 0)
            $fatal(1, "cache_top: WORDS_PER_LINE (%0d) must be a power of two in 2..256 (AXI INCR burst length)",
                   WORDS_PER_LINE);
        if (LINE_WIDTH / 8 > 4096)
            $fatal(1, "cache_top: line size (%0d bytes) exceeds the AXI 4 KB burst boundary",
                   LINE_WIDTH / 8);

        // MSHR configuration.
        if (MSHR_ID_WIDTH < 1)
            $fatal(1, "cache_top: MSHR_ID_WIDTH (%0d) must be >= 1", MSHR_ID_WIDTH);
        if (WB_QUEUE_DEPTH < 1)
            $fatal(1, "cache_top: WB_QUEUE_DEPTH (%0d) must be >= 1", WB_QUEUE_DEPTH);

        // AXI interface instance: the MSHR drives arid from an entry
        // index and demultiplexes R beats by indexing its entry table with
        // rid, so the bus ID width must equal MSHR_ID_WIDTH exactly; the
        // address and data buses must match the cache's own widths.
        if ($bits(axi.arid) != MSHR_ID_WIDTH)
            $fatal(1, "cache_top: axi_if ID_WIDTH (%0d) must equal MSHR_ID_WIDTH (%0d)",
                   $bits(axi.arid), MSHR_ID_WIDTH);
        if ($bits(axi.araddr) != ADDR_WIDTH)
            $fatal(1, "cache_top: axi_if ADDR_WIDTH (%0d) must equal ADDR_WIDTH (%0d)",
                   $bits(axi.araddr), ADDR_WIDTH);
        if ($bits(axi.rdata) != DATA_WIDTH)
            $fatal(1, "cache_top: axi_if DATA_WIDTH (%0d) must equal DATA_WIDTH (%0d)",
                   $bits(axi.rdata), DATA_WIDTH);
    end
`endif

endmodule : cache_top

`default_nettype wire
