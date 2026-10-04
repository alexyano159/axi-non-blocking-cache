// -----------------------------------------------------------------------
// Cache Controller
// -----------------------------------------------------------------------
// Top-level control logic of the cache: the only client of cache_tag_array,
// cache_valid_array, cache_data_sram, and the MSHR. Owns address
// decomposition (tag/set/offset), hit/miss detection, write-port muxing
// into the two shared-write arrays, replacement-victim selection, and the
// miss/fill/eviction sequencing against the MSHR.
//
// This module does not instantiate its four collaborators -- it exposes
// ports that mirror each of their existing interfaces one-for-one, so a
// separate top-level module wires the five together. Port groups are
// prefixed (tag_/valid_/data_/mshr_) since each collaborator's generic
// port names (wr_en, rd_set_idx, ...) would otherwise collide here.
//
// CPU-facing interface: tagged, multi-outstanding. req_id/resp_id let
// several CPU requests be in flight at once and be answered out of
// order -- this is what actually exercises the MSHR's hit-under-miss /
// 16-entry non-blocking design; a single-outstanding interface would
// leave that capability unused, since the CPU would stall on every miss
// regardless of how many MSHR entries exist.
//
// Work in progress: address decomposition, the lookup shadow register,
// hit/miss detection and the hit completion path (load-hit response,
// store-hit write, read-after-write stall, response FIFO) are
// implemented; miss handling via the MSHR, the replacement policy and
// fill/eviction sequencing are added in later steps.
// -----------------------------------------------------------------------
`default_nettype none

module cache_controller #(
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
                                    - WORD_OFF_WIDTH - BYTE_OFF_WIDTH, // 22
    parameter int LINE_WIDTH     = DATA_WIDTH * WORDS_PER_LINE, // 128
    parameter int MSHR_ID_WIDTH  = 4,                          // matches mshr.sv ID_WIDTH
    parameter int TXN_ID_WIDTH   = 4                           // width of the CPU-side transaction tag
) (
    input  wire logic clk,
    input  wire logic rst_n,  // active-low, synchronous reset

    // -----------------------------------------------------------------
    // CPU-facing request / response (tagged, multi-outstanding)
    // req_id tags each request; resp_id echoes which request a response
    // belongs to, since responses may return out of order (a hit behind
    // an earlier miss completes first).
    // -----------------------------------------------------------------
    input  wire logic                     req_valid,
    output      logic                     req_ready,
    input  wire logic [ADDR_WIDTH-1:0]    req_addr,
    input  wire logic                     req_we,      // 1 = store
    input  wire logic [DATA_WIDTH-1:0]    req_wdata,
    input  wire logic [TXN_ID_WIDTH-1:0]  req_id,

    output      logic                     resp_valid,
    input  wire logic                     resp_ready,
    output      logic [TXN_ID_WIDTH-1:0]  resp_id,
    output      logic [DATA_WIDTH-1:0]    resp_data,   // load data (don't-care on a store ack)
    output      logic                     resp_we,     // echoes req_we, for the requester's bookkeeping

    // -----------------------------------------------------------------
    // Tag array port (cache_controller -> cache_tag_array)
    // -----------------------------------------------------------------
    output      logic [SET_IDX_WIDTH-1:0] tag_rd_set_idx,
    output      logic [TAG_WIDTH-1:0]     tag_lookup_tag,
    input  wire logic [NUM_WAYS-1:0]      tag_match,
    input  wire logic [NUM_WAYS-1:0]      tag_dirty_out,

    output      logic                     tag_wr_en,
    output      logic [SET_IDX_WIDTH-1:0] tag_wr_set_idx,
    output      logic [WAY_WIDTH-1:0]     tag_wr_way_sel,
    output      logic [TAG_WIDTH-1:0]     tag_wr_tag,
    output      logic                     tag_wr_tag_en,
    output      logic                     tag_wr_dirty,
    output      logic                     tag_wr_dirty_en,

    // -----------------------------------------------------------------
    // Valid array port (cache_controller -> cache_valid_array)
    // -----------------------------------------------------------------
    output      logic [SET_IDX_WIDTH-1:0] valid_rd_set_idx,
    input  wire logic [NUM_WAYS-1:0]      valid_out,

    output      logic                     valid_wr_en,
    output      logic [SET_IDX_WIDTH-1:0] valid_wr_set_idx,
    output      logic [WAY_WIDTH-1:0]     valid_wr_way_sel,
    output      logic                     valid_wr_valid,

    // -----------------------------------------------------------------
    // Data SRAM port (cache_controller -> cache_data_sram)
    // -----------------------------------------------------------------
    output      logic [SET_IDX_WIDTH-1:0]  data_rd_set_idx,
    input  wire logic [LINE_WIDTH-1:0]     data_rd_line [NUM_WAYS],

    output      logic                      data_wr_en,
    output      logic [SET_IDX_WIDTH-1:0]  data_wr_set_idx,
    output      logic [WAY_WIDTH-1:0]      data_wr_way_sel,
    output      logic [WORDS_PER_LINE-1:0] data_wr_word_en,
    output      logic [LINE_WIDTH-1:0]     data_wr_data,

    // -----------------------------------------------------------------
    // MSHR port (cache_controller -> mshr)
    // -----------------------------------------------------------------
    output      logic                     mshr_alloc_valid,
    output      logic [ADDR_WIDTH-1:0]    mshr_alloc_addr,
    output      logic                     mshr_alloc_is_write,
    input  wire logic                     mshr_alloc_ready,
    input  wire logic [MSHR_ID_WIDTH-1:0] mshr_alloc_id,

    output      logic                     mshr_wb_valid,
    output      logic [ADDR_WIDTH-1:0]    mshr_wb_addr,
    output      logic [LINE_WIDTH-1:0]    mshr_wb_data,
    input  wire logic                     mshr_wb_ready,
    input  wire logic                     mshr_wb_done,

    input  wire logic                     mshr_fill_valid,
    input  wire logic [MSHR_ID_WIDTH-1:0] mshr_fill_id,
    input  wire logic [ADDR_WIDTH-1:0]    mshr_fill_addr,
    input  wire logic [LINE_WIDTH-1:0]    mshr_fill_data,
    input  wire logic                     mshr_fill_is_write,
    output      logic                     mshr_fill_ready
);

    // -------------------------------------------------------------------
    // Address decomposition
    // Splits an incoming request address into the fields the tag array
    // was built to index on. Word/byte offset are not needed for the
    // lookup itself, but are decomposed here since the word offset is
    // needed later to select/mask the correct word within the hit line.
    // -------------------------------------------------------------------
    logic [SET_IDX_WIDTH-1:0]  req_set_idx;
    logic [TAG_WIDTH-1:0]      req_tag;
    logic [WORD_OFF_WIDTH-1:0] req_word_off;

    assign req_word_off = req_addr[BYTE_OFF_WIDTH +: WORD_OFF_WIDTH];
    assign req_set_idx  = req_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH +: SET_IDX_WIDTH];
    assign req_tag      = req_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH + SET_IDX_WIDTH +: TAG_WIDTH];

    // Drive the same decomposed address into all three arrays every
    // cycle a request is accepted -- their registered outputs return
    // together, one cycle later, so the controller can combine them.
    assign tag_rd_set_idx   = req_set_idx;
    assign tag_lookup_tag   = req_tag;
    assign valid_rd_set_idx = req_set_idx;
    assign data_rd_set_idx  = req_set_idx;

    // -------------------------------------------------------------------
    // Lookup shadow register
    // The tag/valid/data arrays register their read result one cycle
    // after the address is presented. This carries the request's own
    // metadata forward by that same one cycle, so it lines up with
    // tag_match/valid_out/data_rd_line on the cycle they become valid.
    // -------------------------------------------------------------------
    typedef struct packed {
        logic                      valid;     // this slot holds a real request looked up last cycle
        logic [ADDR_WIDTH-1:0]     addr;
        logic [SET_IDX_WIDTH-1:0]  set_idx;
        logic [TAG_WIDTH-1:0]      tag;
        logic [WORD_OFF_WIDTH-1:0] word_off;
        logic                      we;
        logic [DATA_WIDTH-1:0]     wdata;
        logic [TXN_ID_WIDTH-1:0]   id;
    } lookup_meta_t;

    lookup_meta_t lookup_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lookup_q.valid <= 1'b0;
        end else begin
            lookup_q.valid    <= req_valid && req_ready;
            lookup_q.addr     <= req_addr;
            lookup_q.set_idx  <= req_set_idx;
            lookup_q.tag      <= req_tag;
            lookup_q.word_off <= req_word_off;
            lookup_q.we       <= req_we;
            lookup_q.wdata    <= req_wdata;
            lookup_q.id       <= req_id;
        end
    end

    // -------------------------------------------------------------------
    // Hit / miss detection (lookup stage, cycle N+1)
    // A way hits only when its stored tag matches AND its line is valid:
    // tag_match alone is insufficient, since an invalid way may retain a
    // stale (or post-reset uninitialised) tag that coincidentally matches.
    // -------------------------------------------------------------------
    logic [NUM_WAYS-1:0]  hit_vec;      // one-hot (or zero) per-way hit
    logic                 hit_any;
    logic [WAY_WIDTH-1:0] hit_way;      // binary index of the hitting way
    logic                 lookup_hit;   // real request, and it hit
    logic                 lookup_miss;  // real request, and it missed

    assign hit_vec     = tag_match & valid_out;
    assign hit_any     = |hit_vec;
    assign lookup_hit  = lookup_q.valid &&  hit_any;
    assign lookup_miss = lookup_q.valid && !hit_any;

    // One-hot to binary encoder. The allocation policy never places the
    // same tag in two ways of one set, so at most one bit of hit_vec is
    // set; the loop therefore acts as a plain encoder rather than a
    // priority selector.
    always_comb begin
        hit_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (hit_vec[w]) hit_way = WAY_WIDTH'(w);
        end
    end

    // Word select: extract the requested 32-bit word from the hitting
    // way's 128-bit line, using the word offset carried in lookup_q.
    logic [LINE_WIDTH-1:0] hit_line;
    logic [DATA_WIDTH-1:0] hit_word;

    assign hit_line = data_rd_line[hit_way];
    assign hit_word = hit_line[lookup_q.word_off * DATA_WIDTH +: DATA_WIDTH];

`ifndef SYNTHESIS
    // Invariant check: a duplicated tag within a set would indicate an
    // allocation bug, and would make hit_way ambiguous.
    assert property (@(posedge clk) disable iff (!rst_n)
                     lookup_q.valid |-> $onehot0(hit_vec))
        else $error("cache_controller: multiple ways hit in set %0d (hit_vec=%b)",
                    lookup_q.set_idx, hit_vec);
`endif

    // -------------------------------------------------------------------
    // Store-hit write (lookup stage, cycle N+1)
    // A store that hits updates only the addressed word of the hitting
    // way, and marks the line dirty so that a later eviction writes it
    // back (write-back policy). The tag field is left untouched.
    // -------------------------------------------------------------------
    logic store_hit_wr;

    assign store_hit_wr = lookup_hit && lookup_q.we;

    // Data SRAM: one-hot word enable at the store's word offset. The
    // store word is replicated across all word lanes; wr_word_en alone
    // determines which lane is committed, which avoids a variable shifter.
    assign data_wr_en      = store_hit_wr;
    assign data_wr_set_idx = lookup_q.set_idx;
    assign data_wr_way_sel = hit_way;
    assign data_wr_word_en = WORDS_PER_LINE'(1) << lookup_q.word_off;
    assign data_wr_data    = {WORDS_PER_LINE{lookup_q.wdata}};

    // Tag array: dirty-only update (wr_tag_en = 0).
    assign tag_wr_en       = store_hit_wr;
    assign tag_wr_set_idx  = lookup_q.set_idx;
    assign tag_wr_way_sel  = hit_way;
    assign tag_wr_tag      = lookup_q.tag;   // don't-care while tag_wr_tag_en = 0
    assign tag_wr_tag_en   = 1'b0;
    assign tag_wr_dirty    = 1'b1;
    assign tag_wr_dirty_en = 1'b1;

    // Valid array: no writer yet -- lines become valid only via the fill
    // path, which is added together with miss handling.
    assign valid_wr_en      = 1'b0;
    assign valid_wr_set_idx = '0;
    assign valid_wr_way_sel = '0;
    assign valid_wr_valid   = 1'b0;

    // -------------------------------------------------------------------
    // Read-after-write hazard stall
    // The arrays perform a same-edge read and write without forwarding:
    // a read issued on the edge that commits a write returns the
    // pre-write contents. A request to the set being written this cycle
    // would therefore observe a stale line and a stale dirty bit. Such a
    // request is held off for one cycle, after which the write has been
    // committed and the re-issued read observes it.
    //
    // The comparison is at set granularity (not way/word), since the
    // requested way is not yet known at issue time. Every future array
    // writer (fill, eviction) is to be OR-ed into arr_wr_active so that a
    // single rule covers all read-after-write cases.
    //
    // Note: this term depends combinationally on req_addr. This is
    // permitted by valid/ready semantics (a source must not make its
    // payload depend on ready, so no loop can form) and is a short
    // SET_IDX_WIDTH-bit compare.
    // -------------------------------------------------------------------
    logic                     arr_wr_active;
    logic [SET_IDX_WIDTH-1:0] arr_wr_set_idx;
    logic                     raw_hazard;

    assign arr_wr_active  = store_hit_wr;
    assign arr_wr_set_idx = lookup_q.set_idx;
    assign raw_hazard     = arr_wr_active && (req_set_idx == arr_wr_set_idx);

    // -------------------------------------------------------------------
    // Response FIFO (3 entries, synchronous)
    // The arrays cannot hold a lookup result: their outputs are
    // overwritten by the next cycle's read. Every lookup result must
    // therefore be captured the cycle it appears, even if the CPU is
    // back-pressuring resp_ready.
    //
    // Depth derivation, with req_ready computed from internal state only
    // (no combinational path from resp_ready to req_ready):
    //   1 entry  -- head response, held while resp_ready = 0
    //   1 entry  -- request in the lookup stage; its result is produced
    //               next cycle regardless of back-pressure
    //   1 entry  -- request accepted in the current cycle, since
    //               req_ready cannot react to a same-cycle resp_ready drop
    // Three entries sustain one response per cycle; two would be correct
    // but would halve throughput.
    // -------------------------------------------------------------------
    localparam int RESP_FIFO_DEPTH = 3;
    localparam int RESP_PTR_WIDTH  = $clog2(RESP_FIFO_DEPTH);      // 2
    localparam int RESP_CNT_WIDTH  = $clog2(RESP_FIFO_DEPTH + 1);  // 2 (0..3)

    typedef struct packed {
        logic [TXN_ID_WIDTH-1:0] id;
        logic [DATA_WIDTH-1:0]   data;
        logic                    we;
    } resp_entry_t;

    resp_entry_t               resp_mem [RESP_FIFO_DEPTH];
    logic [RESP_PTR_WIDTH-1:0] resp_wr_ptr;
    logic [RESP_PTR_WIDTH-1:0] resp_rd_ptr;
    logic [RESP_CNT_WIDTH-1:0] resp_count;
    logic                      resp_push;
    logic                      resp_pop;

    // Every hit produces a response: load data, or a store acknowledge.
    // Misses are answered later, from the fill path.
    assign resp_push = lookup_hit;
    assign resp_pop  = resp_valid && resp_ready;

    // Circular-buffer pointer advance. DEPTH is not a power of two, so
    // the wrap is explicit rather than relying on pointer overflow.
    function automatic logic [RESP_PTR_WIDTH-1:0] resp_ptr_inc(input logic [RESP_PTR_WIDTH-1:0] ptr);
        return (ptr == RESP_PTR_WIDTH'(RESP_FIFO_DEPTH - 1)) ? '0 : ptr + 1'b1;
    endfunction

    // Storage: no reset, since entries are only observed while
    // resp_count marks them occupied.
    always_ff @(posedge clk) begin
        if (resp_push) begin
            resp_mem[resp_wr_ptr] <= '{id: lookup_q.id, data: hit_word, we: lookup_q.we};
        end
    end

    // Control: pointers and occupancy count.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            resp_wr_ptr <= '0;
            resp_rd_ptr <= '0;
            resp_count  <= '0;
        end else begin
            if (resp_push) begin
                resp_wr_ptr <= resp_ptr_inc(resp_wr_ptr);
            end
            if (resp_pop) begin
                resp_rd_ptr <= resp_ptr_inc(resp_rd_ptr);
            end
            // Simultaneous push and pop leave the occupancy unchanged.
            case ({resp_push, resp_pop})
                2'b10:   resp_count <= resp_count + 1'b1;
                2'b01:   resp_count <= resp_count - 1'b1;
                default: resp_count <= resp_count;
            endcase
        end
    end

    assign resp_valid = (resp_count != '0);
    assign resp_id    = resp_mem[resp_rd_ptr].id;
    assign resp_data  = resp_mem[resp_rd_ptr].data;
    assign resp_we    = resp_mem[resp_rd_ptr].we;

    // -------------------------------------------------------------------
    // Request acceptance
    // Accept only when (a) the FIFO is guaranteed a free slot for this
    // request's result, assuming no pops occur in the meantime, and
    // (b) the request does not collide with a same-cycle array write.
    // (a) counts the stored entries plus the one result already in the
    // lookup stage; the new request needs one further slot.
    // -------------------------------------------------------------------
    logic resp_space;

    // Evaluated one bit wider than resp_count so the sum cannot wrap.
    assign resp_space = ({1'b0, resp_count} + (RESP_CNT_WIDTH+1)'(lookup_q.valid))
                        < (RESP_CNT_WIDTH+1)'(RESP_FIFO_DEPTH);
    assign req_ready  = resp_space && !raw_hazard;

    // -------------------------------------------------------------------
    // MSHR port tie-offs
    // Miss allocation, writeback and fill handling are added in the next
    // steps; until then the controller issues nothing to the MSHR and
    // accepts no fills (none can occur, since no miss is allocated).
    // -------------------------------------------------------------------
    assign mshr_alloc_valid    = 1'b0;
    assign mshr_alloc_addr     = '0;
    assign mshr_alloc_is_write = 1'b0;
    assign mshr_wb_valid       = 1'b0;
    assign mshr_wb_addr        = '0;
    assign mshr_wb_data        = '0;
    assign mshr_fill_ready     = 1'b0;

`ifndef SYNTHESIS
    // The acceptance rule must guarantee that a lookup result never finds
    // the FIFO full; a violation would silently drop a CPU response.
    assert property (@(posedge clk) disable iff (!rst_n)
                     resp_push |-> (resp_count < RESP_CNT_WIDTH'(RESP_FIFO_DEPTH)))
        else $error("cache_controller: response FIFO overflow");
`endif

    // -------------------------------------------------------------------
    // PROGRESS MARKER -- steps 1-4 implemented (2026-09-29).
    // The hit path (step 4) is being verified in tb/cache_controller_tb.sv
    // before further RTL is added; test 1 passes, tests 2-9 pending.
    //
    // Next RTL step (5), miss handling -- plan proposed, not yet approved:
    //   - on lookup_miss: drive mshr_alloc_* with the line-aligned address
    //     and is_write; record the returned mshr_alloc_id.
    //   - pending-request (replay) table, 16 entries (bounded by the 4-bit
    //     CPU id): each holds the missed request (addr, we, wdata, id)
    //     and the MSHR entry it waits on.
    //   - req_ready additionally requires (pending count + lookup_q.valid)
    //     < 16, which also guarantees mshr_alloc_ready (every busy MSHR
    //     entry has at least one waiting request); assert this.
    // Then: step 6 true-LRU replacement (age counters), step 7 fill/eviction
    // with replay of pending requests through the hit path (see
    // DESIGN_DECISIONS.txt).
    // -------------------------------------------------------------------

endmodule : cache_controller

`default_nettype wire
