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
// ports that mirror each of their existing interfaces one-for-one, and
// the top-level module (cache_top) wires the five together. Port groups
// are prefixed (tag_/valid_/data_/mshr_) since each collaborator's
// generic port names (wr_en, rd_set_idx, ...) would otherwise collide
// here.
//
// CPU-facing interface: tagged, multi-outstanding. req_id/resp_id let
// several CPU requests be in flight at once and be answered out of
// order -- this is what enables hit-under-miss (later hits served while
// a miss is pending) and exercises the MSHR's 16-entry non-blocking
// design; a single-outstanding interface would leave that capability
// unused, since the CPU would stall on every miss regardless of how
// many MSHR entries exist.
//
// Request flow: issue (CPU or replay) -> registered array read -> lookup
// stage. A hit answers a load or writes a store word (setting dirty); a
// miss is reported to the MSHR and parked in the waiting table. When the
// MSHR returns the line, it is installed in two cycles (F0 read, F1
// write) into an invalid way or the true-LRU way, a dirty victim being
// handed to the MSHR for writeback; the parked requests are then
// replayed through the hit path, oldest first. Priority on the shared
// array ports is replay > fill > CPU. See docs/CACHE_CONTROLLER_README.md.
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
    parameter int TXN_ID_WIDTH   = 4,                          // width of the CPU-side transaction tag
    parameter int WAIT_DEPTH     = 2 ** TXN_ID_WIDTH,          // 16 -- waiting-table slots (one per possible CPU id)
    parameter int WAIT_IDX_WIDTH = $clog2(WAIT_DEPTH)          // 4
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
    input  wire logic [TAG_WIDTH-1:0]     tag_tag_out [NUM_WAYS],   // stored tags of the set read last cycle (victim writeback address)

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
    // Two inputs mirror the MSHR interface but are intentionally not
    // read by this controller:
    //   mshr_wb_done       -- no writeback-completion event is needed: a
    //                         victim leaves the cache when it is handed
    //                         to the queue, and a re-miss to it is held
    //                         inside the MSHR until its write completes.
    //   mshr_fill_is_write -- a filled line is always installed clean;
    //                         each parked store is replayed through the
    //                         hit path, which writes its word and sets
    //                         the dirty bit.
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
    // An address is split into tag, set index and word offset: the set
    // indexes the arrays, the tag is compared, and the word offset
    // selects/masks the word within the line. The lookup itself uses the
    // decomposed issue source (CPU or replay, see below); the CPU's own
    // set index is also needed on its own, for the read-after-write
    // hazard check on an incoming request.
    // -------------------------------------------------------------------
    logic [SET_IDX_WIDTH-1:0]  req_set_idx;

    assign req_set_idx  = req_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH +: SET_IDX_WIDTH];

    // The line presented by the MSHR for installation is decomposed the
    // same way. The fill signals declared here are driven in the Fill
    // sequencing section below; they are declared early because the
    // array read and write ports are shared with the CPU path.
    logic [SET_IDX_WIDTH-1:0] fill_set_idx;
    logic [TAG_WIDTH-1:0]     fill_tag;
    logic                     fill_busy;   // fill in its write cycle (F1); the arrays hold the fill set's contents
    logic                     fill_wr;     // fill is installed into the arrays this cycle
    logic [WAY_WIDTH-1:0]     fill_way;    // way receiving the fill

    assign fill_set_idx = mshr_fill_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH +: SET_IDX_WIDTH];
    assign fill_tag     = mshr_fill_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH + SET_IDX_WIDTH +: TAG_WIDTH];

    // Issue source: a request enters the lookup stage either from the CPU
    // or as a replay of a waiting request whose line has been installed.
    // The replay signals declared here are driven in the Replay section
    // below. While a replay is pending the CPU is held off (see Request
    // acceptance), so the replay's fields can be selected on
    // replay_pending alone.
    logic                      replay_pending;   // a waiting request is ready to replay
    logic                      replay_issue;     // a replay enters the lookup stage this cycle
    logic [WAIT_IDX_WIDTH-1:0] replay_idx;       // waiting-table slot being replayed
    logic [ADDR_WIDTH-1:0]     replay_addr;
    logic                      replay_we;
    logic [DATA_WIDTH-1:0]     replay_wdata;
    logic [TXN_ID_WIDTH-1:0]   replay_id;

    logic [ADDR_WIDTH-1:0]     src_addr;
    logic                      src_we;
    logic [DATA_WIDTH-1:0]     src_wdata;
    logic [TXN_ID_WIDTH-1:0]   src_id;
    logic [SET_IDX_WIDTH-1:0]  src_set_idx;
    logic [TAG_WIDTH-1:0]      src_tag;
    logic [WORD_OFF_WIDTH-1:0] src_word_off;

    assign src_addr     = replay_pending ? replay_addr  : req_addr;
    assign src_we       = replay_pending ? replay_we    : req_we;
    assign src_wdata    = replay_pending ? replay_wdata : req_wdata;
    assign src_id       = replay_pending ? replay_id    : req_id;
    assign src_word_off = src_addr[BYTE_OFF_WIDTH +: WORD_OFF_WIDTH];
    assign src_set_idx  = src_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH +: SET_IDX_WIDTH];
    assign src_tag      = src_addr[BYTE_OFF_WIDTH + WORD_OFF_WIDTH + SET_IDX_WIDTH +: TAG_WIDTH];

    // Array read ports: all three arrays receive the same address every
    // cycle, and their registered outputs return together one cycle
    // later. Priority follows the issue priority, replay > fill > CPU:
    //   - a pending replay drives its own address;
    //   - otherwise, while the MSHR presents a fill, the read port belongs
    //     to the fill's set; during a fill the lookup tag is the fill's
    //     own tag, which lets the duplicate-line invariant below be
    //     checked on tag_match;
    //   - otherwise the CPU's address is driven.
    // The CPU is held off whenever a replay or fill owns the port (see
    // Request acceptance), so no accepted request is ever looked up at
    // the wrong address; a result is consumed only for a request marked
    // by lookup_q.valid.
    logic fill_owns_rd;

    assign fill_owns_rd     = mshr_fill_valid && !replay_pending;
    assign tag_rd_set_idx   = fill_owns_rd ? fill_set_idx : src_set_idx;
    assign tag_lookup_tag   = fill_owns_rd ? fill_tag     : src_tag;
    assign valid_rd_set_idx = tag_rd_set_idx;
    assign data_rd_set_idx  = tag_rd_set_idx;

    // -------------------------------------------------------------------
    // Lookup shadow register
    // The tag/valid/data arrays register their read result one cycle
    // after the address is presented. This carries the request's own
    // metadata forward by that same one cycle, so it lines up with
    // tag_match/valid_out/data_rd_line on the cycle they become valid.
    // -------------------------------------------------------------------
    typedef struct packed {
        logic                      valid;     // this slot holds a real request looked up last cycle
        logic                      replay;    // the request is a replay from the waiting table
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
            lookup_q.valid  <= 1'b0;
            lookup_q.replay <= 1'b0;
        end else begin
            lookup_q.valid    <= (req_valid && req_ready) || replay_issue;
            lookup_q.replay   <= replay_issue;
            lookup_q.addr     <= src_addr;
            lookup_q.set_idx  <= src_set_idx;
            lookup_q.tag      <= src_tag;
            lookup_q.word_off <= src_word_off;
            lookup_q.we       <= src_we;
            lookup_q.wdata    <= src_wdata;
            lookup_q.id       <= src_id;
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

    // A replay always hits (its line was installed just before, and no
    // fill can evict it first -- see Replay); it is excluded here so that
    // a violation, caught by the assertion in Replay, cannot also corrupt
    // the MSHR or the waiting table.
    assign lookup_miss = lookup_q.valid && !hit_any && !lookup_q.replay;

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
    // Array write ports: store hit and fill
    // Two sources share each array's single write port. They are
    // mutually exclusive by construction: the CPU is held off while a
    // fill is presented, so the lookup stage is empty in the fill's write
    // cycle (asserted in Fill sequencing).
    //
    // Store hit (lookup stage, cycle N+1): updates only the addressed
    // word of the hitting way and marks the line dirty, so that a later
    // eviction writes it back (write-back policy). The tag is unchanged.
    //
    // Fill (F1): installs the complete line into the victim way -- new
    // tag, clean, valid. A store that missed is not merged here; it is
    // replayed through the hit path, which then sets the dirty bit.
    // -------------------------------------------------------------------
    logic store_hit_wr;

    assign store_hit_wr = lookup_hit && lookup_q.we;

    // Data SRAM. Store hit: one-hot word enable at the store's word
    // offset, with the store word replicated across all word lanes, so
    // wr_word_en alone selects the committed lane (no variable shifter).
    // Fill: all word lanes enabled.
    assign data_wr_en      = store_hit_wr || fill_wr;
    assign data_wr_set_idx = fill_wr ? fill_set_idx   : lookup_q.set_idx;
    assign data_wr_way_sel = fill_wr ? fill_way       : hit_way;
    assign data_wr_word_en = fill_wr ? '1             : WORDS_PER_LINE'(1) << lookup_q.word_off;
    assign data_wr_data    = fill_wr ? mshr_fill_data : {WORDS_PER_LINE{lookup_q.wdata}};

    // Tag array. Store hit: dirty-only update (wr_tag_en = 0, dirty = 1).
    // Fill: tag and dirty written together (dirty = 0).
    assign tag_wr_en       = store_hit_wr || fill_wr;
    assign tag_wr_set_idx  = fill_wr ? fill_set_idx : lookup_q.set_idx;
    assign tag_wr_way_sel  = fill_wr ? fill_way     : hit_way;
    assign tag_wr_tag      = fill_tag;               // don't-care for a store hit (wr_tag_en = 0)
    assign tag_wr_tag_en   = fill_wr;
    assign tag_wr_dirty    = !fill_wr;
    assign tag_wr_dirty_en = 1'b1;

    // Valid array: lines become valid only through a fill. No path
    // invalidates a line, since an evicted way is immediately refilled.
    assign valid_wr_en      = fill_wr;
    assign valid_wr_set_idx = fill_set_idx;
    assign valid_wr_way_sel = fill_way;
    assign valid_wr_valid   = 1'b1;

    // -------------------------------------------------------------------
    // Replacement state: true LRU, one age counter per way
    // Each way of a set holds a WAY_WIDTH-bit age: 0 = most recently
    // used, NUM_WAYS-1 = least recently used. The ages of a set always
    // form a permutation of 0..NUM_WAYS-1, i.e. a total recency order.
    //
    // Update on an access to way W, whose current age is a_W:
    //   - W                    : age <- 0
    //   - every way with age < a_W (used more recently than W): age + 1
    //   - every way with age > a_W                            : unchanged
    // which moves W to the front of the order and shifts back exactly the
    // ways it overtook, preserving the permutation.
    //
    // Storage is in flip-flops rather than in a registered-read array, so
    // the read-modify-write completes in the lookup cycle: a hit to the
    // same set on the next cycle already observes this update, and no
    // read-after-write stall is required. Cost: NUM_SETS x NUM_WAYS x
    // WAY_WIDTH = 512 flip-flops at the default parameters.
    //
    // Two sources update the order: a hit (lookup stage) and a fill (F1),
    // which are mutually exclusive for the same reason as the array write
    // ports. A miss itself does not update the order, since its line is
    // not yet present; the fill does, so that a second fill to the same
    // set observes the first one and selects a different victim.
    // -------------------------------------------------------------------
    typedef logic [NUM_WAYS-1:0][WAY_WIDTH-1:0] lru_ages_t;   // ages of one set, indexed by way

    lru_ages_t lru_age [NUM_SETS];

    logic                     lru_upd_en;
    logic [SET_IDX_WIDTH-1:0] lru_upd_set;
    logic [WAY_WIDTH-1:0]     lru_upd_way;
    lru_ages_t                lru_cur;    // current ages of the set being updated
    lru_ages_t                lru_nxt;    // ages after the update

    assign lru_upd_en  = lookup_hit || fill_wr;
    assign lru_upd_set = fill_wr ? fill_set_idx : lookup_q.set_idx;
    assign lru_upd_way = fill_wr ? fill_way     : hit_way;
    assign lru_cur     = lru_age[lru_upd_set];

    always_comb begin
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (WAY_WIDTH'(w) == lru_upd_way)
                lru_nxt[w] = '0;
            else if (lru_cur[w] < lru_cur[lru_upd_way])
                lru_nxt[w] = lru_cur[w] + 1'b1;
            else
                lru_nxt[w] = lru_cur[w];
        end
    end

    // Reset establishes the order way 0 (youngest) .. way NUM_WAYS-1
    // (oldest) in every set. Any permutation would serve; this one is the
    // simplest to state. Invalid ways are filled before the order is
    // consulted, so the initial order does not affect behaviour.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++)
                for (int w = 0; w < NUM_WAYS; w++)
                    lru_age[s][w] <= WAY_WIDTH'(w);
        end else if (lru_upd_en) begin
            lru_age[lru_upd_set] <= lru_nxt;
        end
    end

    // Victim lookup: the least recently used way of a set is the one whose
    // age is NUM_WAYS-1. The ages form a permutation, so exactly one way
    // matches. The set is that of the line currently presented for fill.
    logic [SET_IDX_WIDTH-1:0] lru_victim_set;
    logic [WAY_WIDTH-1:0]     lru_victim_way;

    assign lru_victim_set = fill_set_idx;

    always_comb begin
        lru_victim_way = '0;
        for (int w = 0; w < NUM_WAYS; w++) begin
            if (lru_age[lru_victim_set][w] == WAY_WIDTH'(NUM_WAYS - 1))
                lru_victim_way = WAY_WIDTH'(w);
        end
    end

`ifndef SYNTHESIS
    // Returns 1 if the ages of one set are a permutation of 0..NUM_WAYS-1.
    function automatic logic lru_is_permutation(input lru_ages_t ages);
        logic [NUM_WAYS-1:0] seen = '0;
        for (int w = 0; w < NUM_WAYS; w++)
            seen[ages[w]] = 1'b1;
        return &seen;
    endfunction

    // Invariant check: an update must preserve the total recency order. A
    // duplicated or missing age would make the victim ambiguous or absent.
    assert property (@(posedge clk) disable iff (!rst_n)
                     lru_upd_en |-> lru_is_permutation(lru_nxt))
        else $error("cache_controller: LRU ages of set %0d not a permutation after update (%p -> %p)",
                    lru_upd_set, lru_cur, lru_nxt);
`endif

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
    // requested way is not yet known at issue time. The fill write needs
    // no term here: no request is accepted while a fill is presented (see
    // Request acceptance), so none can read a set during its fill write.
    // arr_wr_active is also consulted by the fill itself, which defers
    // its read (F0) past a same-set store hit.
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
    // but would insert a bubble after every second request (2/3
    // throughput), and a single entry would reach only 1/3.
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
    // Miss allocation (lookup stage, cycle N+1)
    // A miss is reported to the MSHR in the same cycle it is detected.
    // The MSHR tracks whole lines, so the address is line-aligned (word
    // and byte offset cleared): two misses to different words of one
    // line then present identical addresses and merge into one entry.
    //
    // The lookup stage cannot hold a request -- the arrays overwrite
    // their outputs on the next cycle -- so the allocation must succeed
    // in the cycle it is issued. alloc_ready is therefore not waited on
    // but guaranteed by the acceptance rule (req_ready), and asserted
    // below. alloc_id is returned combinationally in the same cycle and
    // is recorded together with the missed request.
    // -------------------------------------------------------------------
    localparam int LINE_OFF_WIDTH = WORD_OFF_WIDTH + BYTE_OFF_WIDTH;   // 4 -- byte-within-line offset

    assign mshr_alloc_valid    = lookup_miss;
    assign mshr_alloc_addr     = {lookup_q.addr[ADDR_WIDTH-1:LINE_OFF_WIDTH], LINE_OFF_WIDTH'(0)};
    assign mshr_alloc_is_write = lookup_q.we;

`ifndef SYNTHESIS
    // The acceptance rule must guarantee that a miss is always accepted
    // by the MSHR; a violation would silently lose the miss.
    assert property (@(posedge clk) disable iff (!rst_n)
                     mshr_alloc_valid |-> mshr_alloc_ready)
        else $error("cache_controller: MSHR could not accept miss to 0x%08h (no free or matching entry)",
                    mshr_alloc_addr);
`endif

    // -------------------------------------------------------------------
    // Waiting table (lookup stage, cycle N+1)
    // The MSHR tracks lines, not requests: on a merge it retains only the
    // line address and an OR-ed store flag. Every missed request is
    // therefore parked here with everything needed to re-run it through
    // the hit path once its line is installed (replay): the full address,
    // load/store, store data, CPU id, and the MSHR entry it waits on.
    //
    // Storage is in flip-flops: on a fill, every slot must be compared
    // against the filling MSHR id in parallel, and several slots may
    // match (merged requests). A new miss takes the lowest-indexed free
    // slot. A slot is released when its request is replayed (see Replay).
    //
    // WAIT_DEPTH defaults to 2**TXN_ID_WIDTH, the maximum number of
    // distinct CPU requests that can be outstanding, so the table never
    // limits the CPU in normal operation.
    // -------------------------------------------------------------------
    typedef struct packed {
        logic [ADDR_WIDTH-1:0]    addr;      // full request address (tag, set, word offset)
        logic                     we;        // 1 = store
        logic [DATA_WIDTH-1:0]    wdata;     // store data (don't-care for a load)
        logic [TXN_ID_WIDTH-1:0]  id;        // CPU transaction id, echoed in the response
        logic [MSHR_ID_WIDTH-1:0] mshr_id;   // MSHR entry whose fill this request waits on
    } wait_entry_t;

    wait_entry_t               wait_mem   [WAIT_DEPTH];
    logic [WAIT_DEPTH-1:0]     wait_valid;              // slot occupied
    logic                      wait_alloc;              // park the request in the lookup stage this cycle
    logic                      wait_any_free;
    logic [WAIT_IDX_WIDTH-1:0] wait_free_idx;           // lowest-indexed free slot

    assign wait_alloc    = lookup_miss;
    assign wait_any_free = !(&wait_valid);

    // Lowest-index free-slot encoder. The result is meaningless when no
    // slot is free; the acceptance rule guarantees that a miss never
    // finds the table full (asserted below).
    always_comb begin
        wait_free_idx = '0;
        for (int i = WAIT_DEPTH - 1; i >= 0; i--) begin
            if (!wait_valid[i]) wait_free_idx = WAIT_IDX_WIDTH'(i);
        end
    end

    // -------------------------------------------------------------------
    // Age matrix (replay ordering)
    // Requests merged onto one line must replay in arrival order: a load
    // behind a store to the same word must observe that store. Slot
    // indices do not encode age, since slots are released and reused out
    // of order; a per-slot timestamp would wrap, as a slot may wait for
    // an unbounded time while others turn over.
    //
    // wait_older[i][j] = 1 means slot j was allocated before slot i. Only
    // the relative order of live slots is stored, so nothing can wrap:
    //   - on allocating slot i, row i <- wait_valid: every slot occupied
    //     now is older than the new request;
    //   - column i is cleared in every row at the same time: whatever an
    //     earlier occupant of slot i was older than, the new occupant is
    //     younger than all of them.
    // Bits involving a free slot are stale but harmless, since every
    // reader masks with wait_valid (or with wait_ready, a subset of it).
    // The replay selector picks the ready slot whose row has no ready
    // older slot.
    // Cost: WAIT_DEPTH x WAIT_DEPTH = 256 flip-flops at the default.
    // -------------------------------------------------------------------
    logic [WAIT_DEPTH-1:0] wait_older [WAIT_DEPTH];

    // Payload and age matrix: no reset, since every bit is written at
    // allocation before it can be observed through wait_valid.
    always_ff @(posedge clk) begin
        if (wait_alloc) begin
            wait_mem[wait_free_idx] <= '{addr:    lookup_q.addr,
                                         we:      lookup_q.we,
                                         wdata:   lookup_q.wdata,
                                         id:      lookup_q.id,
                                         mshr_id: mshr_alloc_id};
            for (int k = 0; k < WAIT_DEPTH; k++)
                wait_older[k][wait_free_idx] <= 1'b0;
            wait_older[wait_free_idx] <= wait_valid;   // the slot itself is free, so its own bit is 0
        end
    end

    // Allocation and release never target the same slot (allocation takes
    // a free slot, release an occupied one), so both may apply on one edge.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wait_valid <= '0;
        end else begin
            if (wait_alloc)
                wait_valid[wait_free_idx] <= 1'b1;
            if (replay_issue)
                wait_valid[replay_idx] <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    // Elaboration check: the MSHR-acceptance argument (see Request
    // acceptance) requires at least as many MSHR entries as slots.
    initial begin
        if (WAIT_DEPTH > 2 ** MSHR_ID_WIDTH)
            $fatal(1, "cache_controller: WAIT_DEPTH (%0d) exceeds the MSHR entry count (%0d)",
                   WAIT_DEPTH, 2 ** MSHR_ID_WIDTH);
    end

    // The acceptance rule must guarantee a free slot for every miss; a
    // violation would overwrite a waiting request.
    assert property (@(posedge clk) disable iff (!rst_n)
                     wait_alloc |-> wait_any_free)
        else $error("cache_controller: waiting table full on miss to 0x%08h (id %0d)",
                    lookup_q.addr, lookup_q.id);
`endif

    // -------------------------------------------------------------------
    // Fill sequencing
    // Installs the line presented by the MSHR in two cycles, since the
    // victim can only be chosen once the target set's valid bits are read
    // from the registered-output arrays:
    //   F0 (read) : the fill's set is driven onto the array read ports
    //               (see Array read ports) and the CPU is held off.
    //   F1 (write): victim = lowest-indexed invalid way, else the LRU way.
    //               A dirty victim is handed to the MSHR for writeback.
    //               Tag, valid bit, full line and LRU order are written in
    //               this cycle, and mshr_fill_ready completes the handoff.
    // The victim is chosen at fill time rather than at miss time, so the
    // old line keeps serving hits while the miss is outstanding.
    //
    // F0 is deferred by one cycle if a store hit is writing the fill's set
    // in that cycle, since the arrays do not forward a same-edge write and
    // the read would return stale contents. The CPU is already held off,
    // so the lookup stage is empty in the following cycle and the deferral
    // cannot repeat. With true LRU the stale contents are in fact never
    // used -- the store's way has just become the most recently used, so
    // it cannot be the victim -- but the deferral is kept as a cheap
    // safeguard that remains correct under any replacement policy.
    //
    // Fill selection may change between F0 and F1: the MSHR presents its
    // lowest-indexed completed entry, so an entry completing during F0
    // can displace the one whose set was read. The presented id is
    // registered every cycle (fill_id_q); F1 writes only if it is
    // unchanged. Otherwise nothing is written, and the cycle acts as F0
    // for the newly presented fill, whose set is already on the read
    // port. A displaced fill cannot be displaced again by the same entry,
    // so the number of restarts is bounded by the number of entries.
    //
    // Fills take priority over CPU requests. The CPU is held off while any
    // fill is presented. Each fill takes F0 and F1; when the line has
    // waiting requests, their replays must issue before the next F0, so in
    // the full system consecutive fills take at least three cycles each.
    // The CPU resumes once the MSHR has no fill left.
    // -------------------------------------------------------------------
    logic                     fill_start;      // F0 in this cycle
    logic [MSHR_ID_WIDTH-1:0] fill_id_q;       // id presented in the previous cycle
    logic                     fill_id_same;    // presented fill is the one whose set was read
    logic [NUM_WAYS-1:0]      fill_inv_vec;    // invalid ways of the fill's set
    logic [WAY_WIDTH-1:0]     fill_inv_way;    // lowest-indexed invalid way
    logic                     victim_dirty;    // victim holds modified data that must be written back

    // A fill does not start while a replay is pending (replay > fill):
    // the waiters of the line just installed replay before any other line
    // can evict it.
    assign fill_start   = mshr_fill_valid && !fill_busy && !replay_pending
                          && !(arr_wr_active && (arr_wr_set_idx == fill_set_idx));
    assign fill_id_same = (mshr_fill_id == fill_id_q);

    // The line is written once the victim, if dirty, has been handed to
    // the MSHR's writeback queue in the same cycle (see Victim writeback).
    assign fill_wr      = fill_busy && fill_id_same && (!victim_dirty || mshr_wb_ready);

    // Victim selection (F1): an invalid way is always used before any
    // valid line is displaced; the LRU order decides only for a full set.
    assign fill_inv_vec = ~valid_out;

    always_comb begin
        fill_inv_way = '0;
        for (int w = NUM_WAYS - 1; w >= 0; w--) begin
            if (fill_inv_vec[w]) fill_inv_way = WAY_WIDTH'(w);
        end
    end

    assign fill_way = (|fill_inv_vec) ? fill_inv_way : lru_victim_way;

    // -------------------------------------------------------------------
    // Victim writeback (F1)
    // A valid, dirty victim is the only copy of its modified data, so it
    // is handed to the MSHR's writeback queue before being overwritten.
    // Its address is formed from the stored tag (tag_out) and the fill's
    // set; its data is the line the arrays return for the fill's set. The
    // handoff and the fill write share one edge: the MSHR captures the
    // victim from the array outputs before the write is committed.
    //
    // If the queue is full (mshr_wb_ready = 0), F1 repeats with nothing
    // written. The victim cannot change meanwhile: the read port stays on
    // the fill's set, the CPU is held off (no hit can write the set or
    // reorder its LRU), and no other fill can be installed. If the MSHR's
    // fill selection changes while waiting, mshr_wb_valid is withdrawn
    // without a handshake; the writeback queue acts only on
    // valid && ready, so the withdrawal has no effect there.
    //
    // mshr_fill_ready depends combinationally on mshr_wb_ready, which the
    // MSHR derives from its queue occupancy alone, so no loop forms.
    // -------------------------------------------------------------------
    assign victim_dirty  = valid_out[fill_way] && tag_dirty_out[fill_way];

    assign mshr_wb_valid = fill_busy && fill_id_same && victim_dirty;
    assign mshr_wb_addr  = {tag_tag_out[fill_way], fill_set_idx, LINE_OFF_WIDTH'(0)};
    assign mshr_wb_data  = data_rd_line[fill_way];

    // F0 -> F1; F1 -> F1 on a restart or while the writeback queue is
    // full; F1 -> idle once the line is written.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fill_busy <= 1'b0;
        end else begin
            fill_busy <= (fill_start || fill_busy) && !fill_wr;
        end
    end

    // No reset: fill_id_q is consulted only in F1, which is always
    // preceded by a cycle in which it was loaded.
    always_ff @(posedge clk) begin
        fill_id_q <= mshr_fill_id;
    end

    assign mshr_fill_ready = fill_wr;

`ifndef SYNTHESIS
    // The MSHR holds a completed entry until it is accepted, so a fill
    // cannot be withdrawn while it is being installed.
    assert property (@(posedge clk) disable iff (!rst_n)
                     fill_busy |-> mshr_fill_valid)
        else $error("cache_controller: fill withdrawn by the MSHR during F1");

    // The two writers of the shared array and LRU ports must never
    // coincide: the CPU hold-off leaves the lookup stage empty in F1.
    assert property (@(posedge clk) disable iff (!rst_n)
                     fill_busy |-> !lookup_q.valid)
        else $error("cache_controller: request in the lookup stage during fill F1");

    // A missing line is installed only by its own fill, so the filled
    // line must not already be present in its set; a duplicate would make
    // hit_way ambiguous.
    assert property (@(posedge clk) disable iff (!rst_n)
                     fill_wr |-> !(|(tag_match & valid_out)))
        else $error("cache_controller: fill of 0x%08h duplicates a line already in set %0d",
                    mshr_fill_addr, fill_set_idx);
`endif

    // -------------------------------------------------------------------
    // Request acceptance
    // Accept only when
    //   (a) the FIFO is guaranteed a free slot for this request's result,
    //       assuming no pops occur in the meantime;
    //   (b) the waiting table is guaranteed a free slot, should this
    //       request miss;
    //   (c) the request does not collide with a same-cycle array write;
    //   (d) the MSHR is not presenting a fill, which owns the array read
    //       ports and, in F1, the array write and LRU update ports;
    //   (e) no replay is pending, since replays own the issue slot
    //       (priority replay > fill > CPU).
    // (a) and (b) both count the occupied entries plus the one request
    // already in the lookup stage, whose outcome is not yet known and is
    // therefore assumed to consume an entry; the new request needs one
    // further entry. The rule is conservative: with WAIT_DEPTH-1 slots
    // occupied, a request behind an in-flight lookup waits one cycle even
    // if that lookup turns out to hit.
    //
    // (b) also guarantees that the MSHR can accept every miss: an MSHR
    // entry stays busy only while at least one waiting-table slot refers
    // to it, so busy MSHR entries never outnumber occupied slots. When a
    // miss is allocated, at most WAIT_DEPTH-1 other slots are occupied,
    // leaving an MSHR entry free (WAIT_DEPTH <= 2**MSHR_ID_WIDTH).
    // -------------------------------------------------------------------
    logic                    resp_space;
    logic [WAIT_IDX_WIDTH:0] wait_count;   // occupied slots, 0..WAIT_DEPTH
    logic                    wait_space;

    // Evaluated one bit wider than resp_count so the sum cannot wrap.
    assign resp_space = ({1'b0, resp_count} + (RESP_CNT_WIDTH+1)'(lookup_q.valid))
                        < (RESP_CNT_WIDTH+1)'(RESP_FIFO_DEPTH);

    // wait_count is one bit wider than a slot index, so it holds
    // WAIT_DEPTH itself; the sum with lookup_q.valid is widened once more.
    // The population count is an explicit adder loop rather than
    // $countones, which synthesis tools do not uniformly support (Quartus
    // Prime rejects it); synthesis maps the loop to an adder tree.
    function automatic logic [WAIT_IDX_WIDTH:0] count_occupied(input logic [WAIT_DEPTH-1:0] vec);
        count_occupied = '0;
        for (int i = 0; i < WAIT_DEPTH; i++)
            count_occupied = count_occupied + (WAIT_IDX_WIDTH+1)'(vec[i]);
    endfunction

    assign wait_count = count_occupied(wait_valid);
    assign wait_space = ({1'b0, wait_count} + (WAIT_IDX_WIDTH+2)'(lookup_q.valid))
                        < (WAIT_IDX_WIDTH+2)'(WAIT_DEPTH);

    // (d) depends combinationally on mshr_fill_valid, which the MSHR
    // derives from its entry state alone, so no combinational loop forms.
    // Since a fill write occurs only while mshr_fill_valid is high, (d)
    // also prevents any request from reading a set during its fill write.
    // (e) depends on registered state only (wait_ready).
    assign req_ready  = resp_space && wait_space && !raw_hazard && !mshr_fill_valid
                        && !replay_pending;

`ifndef SYNTHESIS
    // The acceptance rule must guarantee that a lookup result never finds
    // the FIFO full; a violation would silently drop a CPU response.
    assert property (@(posedge clk) disable iff (!rst_n)
                     resp_push |-> (resp_count < RESP_CNT_WIDTH'(RESP_FIFO_DEPTH)))
        else $error("cache_controller: response FIFO overflow");
`endif

    // -------------------------------------------------------------------
    // Replay
    // Re-runs each waiting request through the hit path once its line has
    // been installed. The request then hits: a load returns its word, a
    // store writes its word and marks the line dirty, the LRU order is
    // updated, and the response carries the request's own CPU id.
    //
    // Ready marking: on the fill's write cycle, every occupied slot that
    // waits on the filled MSHR entry is marked ready. The mark is taken at
    // fill time, not by comparing ids later, because the MSHR frees the
    // entry on that same edge and may hand its id to a new miss at once;
    // a later comparison could not tell the old waiters from the new one.
    // A request merged into the entry during F0 is already recorded (the
    // waiting table is written at the end of F0), and none can arrive in
    // F1, since the lookup stage is empty then.
    //
    // Selection: the oldest ready slot, i.e. the one with no older ready
    // slot in the age matrix. The ready slots always belong to a single
    // line (a fill cannot start while any are pending), so this is
    // exactly the line's arrival order, and a load behind a store to the
    // same word observes the store.
    //
    // Issue: a replay takes the lookup stage when the response FIFO has
    // room for its result, and not in a cycle in which a store hit writes
    // its set (the same read-after-write rule as for CPU requests -- a
    // replayed store followed by a further replay to the line costs one
    // bubble). Its slot is released at issue: the replay is guaranteed to
    // hit, so the request cannot return to the table.
    //
    // Priority replay > fill > CPU: while any replay is pending, neither
    // a new fill (fill_start) nor a CPU request (req_ready) is accepted.
    // Between a fill and its replays nothing can therefore evict the
    // installed line, which is why a replay always hits (asserted).
    // -------------------------------------------------------------------
    logic [WAIT_DEPTH-1:0] wait_ready;      // slot's line is installed; request awaits replay
    logic [WAIT_DEPTH-1:0] replay_oldest;   // one-hot: oldest ready slot
    logic                  replay_hazard;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wait_ready <= '0;
        end else begin
            if (fill_wr) begin
                for (int i = 0; i < WAIT_DEPTH; i++)
                    if (wait_valid[i] && wait_mem[i].mshr_id == mshr_fill_id)
                        wait_ready[i] <= 1'b1;
            end
            if (replay_issue)
                wait_ready[replay_idx] <= 1'b0;
        end
    end

    assign replay_pending = |wait_ready;

    // Oldest ready slot. The age matrix orders all occupied slots totally,
    // so exactly one ready slot has no ready slot older than itself.
    always_comb begin
        for (int i = 0; i < WAIT_DEPTH; i++)
            replay_oldest[i] = wait_ready[i] && !(|(wait_older[i] & wait_ready));
    end

    always_comb begin
        replay_idx = '0;
        for (int i = 0; i < WAIT_DEPTH; i++)
            if (replay_oldest[i]) replay_idx = WAIT_IDX_WIDTH'(i);
    end

    assign replay_addr  = wait_mem[replay_idx].addr;
    assign replay_we    = wait_mem[replay_idx].we;
    assign replay_wdata = wait_mem[replay_idx].wdata;
    assign replay_id    = wait_mem[replay_idx].id;

    assign replay_hazard = arr_wr_active && (src_set_idx == arr_wr_set_idx);
    assign replay_issue  = replay_pending && resp_space && !replay_hazard;

`ifndef SYNTHESIS
    // A pending replay always has exactly one oldest candidate.
    assert property (@(posedge clk) disable iff (!rst_n)
                     replay_pending |-> $onehot(replay_oldest))
        else $error("cache_controller: replay selection not one-hot (ready %b, oldest %b)",
                    wait_ready, replay_oldest);

    // A replay must hit: its line was installed just before, and nothing
    // can evict it before the replay (priority replay > fill > CPU).
    assert property (@(posedge clk) disable iff (!rst_n)
                     (lookup_q.valid && lookup_q.replay) |-> hit_any)
        else $error("cache_controller: replay of 0x%08h (id %0d) missed",
                    lookup_q.addr, lookup_q.id);

    // Ready marks are only taken at a fill's completion, which cannot
    // coincide with a pending replay.
    assert property (@(posedge clk) disable iff (!rst_n)
                     fill_busy |-> !replay_pending)
        else $error("cache_controller: replay pending during fill F1");
`endif

    // -------------------------------------------------------------------
    // Verification status
    //   tb/cache_controller_tb.sv -- 19 tests against the real arrays and a
    //     TB model of the MSHR: hit path, LRU, miss side, fill and restart,
    //     dirty-victim writeback, replay order, slot reuse, and an
    //     end-to-end random test with automatic fills (test 19).
    //   tb/cache_top_tb.sv -- the controller integrated with the real MSHR
    //     and arrays, against a randomized AXI4 memory model.
    // The system testbench also re-checks the assertions above
    // procedurally, so they remain effective on simulators that do not
    // evaluate SVA.
    // -------------------------------------------------------------------

endmodule : cache_controller

`default_nettype wire
