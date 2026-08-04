// MSHR (Miss Status Holding Register) for the non-blocking cache.
//
// Tracks cache misses that are currently in flight to main memory. Each
// entry corresponds to one outstanding line fetch and is indexed by its
// AXI transaction ID. A miss whose address matches an entry already in
// flight is merged into that entry instead of issuing a duplicate AXI
// request (secondary miss / hit-under-miss). This is the sole AXI4
// master in the design: it issues read bursts to service misses and
// write bursts to evict dirty victim lines.
//
// Internally this module is two independent engines sharing the axi
// port:
//   - Fill engine: one FSM per entry (IDLE -> REQ -> DATA -> DONE),
//     arbitrated onto the shared AR channel with round-robin fairness.
//     See private_notes/MSHR_README.md for the full rationale.
//   - Writeback engine: a small FIFO of evicted dirty lines drained one
//     at a time (IDLE -> AW -> DATA -> WAIT_B) onto the shared AW/W/B
//     channels.
`default_nettype none

module mshr #(
    parameter int ADDR_WIDTH    = 32,
    parameter int DATA_WIDTH    = 32,
    parameter int ID_WIDTH      = 4,
    parameter int LINE_WORDS    = 4,                      // words per cache line, equal to the AXI burst length
    parameter int LINE_WIDTH    = DATA_WIDTH * LINE_WORDS, // full cache line width, in bits
    parameter int NUM_ENTRIES   = (1 << ID_WIDTH),         // one entry per AXI ID value
    parameter int WB_QUEUE_DEPTH = 4                       // victim writebacks that can be queued awaiting the AXI write channel
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

    // -------------------------------------------------------------------
    // Shared constants: every burst this module issues is a fixed-length
    // INCR burst covering exactly one cache line.
    // -------------------------------------------------------------------
    localparam int              BEAT_CNT_WIDTH = $clog2(LINE_WORDS);
    localparam logic [7:0]      BURST_LEN      = LINE_WORDS - 1;            // AxLEN = beats - 1
    localparam logic [2:0]      BURST_SIZE     = $clog2(DATA_WIDTH / 8);    // AxSIZE = log2(bytes/beat)
    localparam logic [1:0]      BURST_INCR     = 2'b01;

    // Returns the index of the lowest set bit in `vec`, or 0 if `vec` is
    // all zero (callers must gate on a separate "any bit set" signal
    // before trusting the result). Scanning high-to-low and overwriting
    // on every '1' found leaves the *lowest* set index as the final
    // value -- a standard fixed-priority encoder.
    function automatic logic [ID_WIDTH-1:0] pick_lowest(input logic [NUM_ENTRIES-1:0] vec);
        pick_lowest = '0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (vec[i]) pick_lowest = i[ID_WIDTH-1:0];
        end
    endfunction

    // ===================================================================
    // Fill engine: one entry per AXI ID, tracking an in-flight read miss.
    // ===================================================================
    typedef enum logic [1:0] {
        FE_IDLE,  // entry free
        FE_REQ,   // address known, waiting to win the AR arbiter
        FE_DATA,  // AR accepted, collecting R beats
        FE_DONE   // line complete, waiting for fill_ready
    } fe_state_e;

    fe_state_e                    fe_state   [NUM_ENTRIES];
    logic [ADDR_WIDTH-1:0]        fe_addr    [NUM_ENTRIES];
    logic                         fe_is_write[NUM_ENTRIES];
    logic [BEAT_CNT_WIDTH-1:0]    fe_beat_cnt[NUM_ENTRIES];
    logic [LINE_WIDTH-1:0]        fe_line_buf[NUM_ENTRIES];

    // Per-entry status vectors, recomputed every cycle from current state.
    logic [NUM_ENTRIES-1:0] fe_match_vec;  // valid entries whose addr == alloc_addr (merge candidates)
    logic [NUM_ENTRIES-1:0] fe_free_vec;   // entries available for a brand-new allocation
    logic [NUM_ENTRIES-1:0] fe_req_vec;    // entries wanting the AR channel this cycle
    logic [NUM_ENTRIES-1:0] fe_done_vec;   // entries with a completed line waiting to be presented

    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            fe_match_vec[i] = (fe_state[i] != FE_IDLE) && (fe_addr[i] == alloc_addr);
            fe_free_vec[i]  = (fe_state[i] == FE_IDLE);
            fe_req_vec[i]   = (fe_state[i] == FE_REQ);
            fe_done_vec[i]  = (fe_state[i] == FE_DONE);
        end
    end

    logic                  fe_any_match, fe_any_free;
    logic [ID_WIDTH-1:0]   fe_match_idx, fe_free_idx;

    assign fe_any_match = |fe_match_vec;
    assign fe_any_free  = |fe_free_vec;
    assign fe_match_idx = pick_lowest(fe_match_vec);
    assign fe_free_idx  = pick_lowest(fe_free_vec);

    // Allocation: a hit against an in-flight entry always wins over
    // opening a new one (secondary miss / hit-under-miss merge).
    assign alloc_ready = fe_any_match | fe_any_free;
    assign alloc_id    = fe_any_match ? fe_match_idx : fe_free_idx;

    // -------------------------------------------------------------------
    // AR-channel arbiter: round-robin over entries in FE_REQ. Masking the
    // request vector to indices strictly above the last grant and
    // preferring that masked set (falling back to a plain low-index scan
    // only when nothing higher is asking) rotates priority after every
    // grant, so no entry can be starved by lower-index neighbors that
    // keep re-requesting. See private_notes/MSHR_README.md for why this
    // was chosen over a plain fixed-priority encoder.
    // -------------------------------------------------------------------
    logic [ID_WIDTH-1:0]    ar_last_grant;
    logic [NUM_ENTRIES-1:0] ar_hi_mask;
    logic [NUM_ENTRIES-1:0] ar_req_hi;
    logic                   ar_grant_valid;
    logic [ID_WIDTH-1:0]    ar_grant_idx;

    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            ar_hi_mask[i] = (i[ID_WIDTH-1:0] > ar_last_grant);
        end
    end

    assign ar_req_hi      = fe_req_vec & ar_hi_mask;
    assign ar_grant_valid = |fe_req_vec;
    assign ar_grant_idx   = (|ar_req_hi) ? pick_lowest(ar_req_hi) : pick_lowest(fe_req_vec);

    assign axi.arvalid = ar_grant_valid;
    assign axi.arid    = ar_grant_idx;
    assign axi.araddr  = fe_addr[ar_grant_idx];
    assign axi.arlen   = BURST_LEN;
    assign axi.arsize  = BURST_SIZE;
    assign axi.arburst = BURST_INCR;

    // Always able to sink an R beat into the entry array the instant it
    // arrives -- capture is a plain register write, nothing to stall on.
    assign axi.rready = 1'b1;

    // -------------------------------------------------------------------
    // Fill-completion mux: only one entry can be presented to the
    // controller per cycle. Fixed low-index priority is enough here --
    // unlike the AR arbiter, this doesn't gate access to memory
    // bandwidth, it only decides who waits one extra cycle to be handed
    // off, so starvation risk is negligible.
    // -------------------------------------------------------------------
    logic [ID_WIDTH-1:0] fe_done_sel;
    assign fe_done_sel   = pick_lowest(fe_done_vec);
    assign fill_valid    = |fe_done_vec;
    assign fill_id       = fe_done_sel;
    assign fill_addr     = fe_addr[fe_done_sel];
    assign fill_data     = fe_line_buf[fe_done_sel];
    assign fill_is_write = fe_is_write[fe_done_sel];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) fe_state[i] <= FE_IDLE;
            ar_last_grant <= '0;
        end else begin
            // Allocation: open a new entry, or merge into an existing one.
            // A merge only needs to OR the is_write flag in -- if *any*
            // merged access was a store the line must come back marked
            // dirty, even if the primary (first) access was a load.
            if (alloc_valid && alloc_ready) begin
                if (fe_any_match) begin
                    fe_is_write[fe_match_idx] <= fe_is_write[fe_match_idx] | alloc_is_write;
                end else begin
                    fe_state[fe_free_idx]    <= FE_REQ;
                    fe_addr[fe_free_idx]     <= alloc_addr;
                    fe_is_write[fe_free_idx] <= alloc_is_write;
                    fe_beat_cnt[fe_free_idx] <= '0;
                end
            end

            // AR arbiter grant: REQ -> DATA, and remember who just won.
            if (ar_grant_valid && axi.arvalid && axi.arready) begin
                fe_state[ar_grant_idx] <= FE_DATA;
                ar_last_grant          <= ar_grant_idx;
            end

            // R beat capture, demuxed by rid: DATA -> DONE on the last beat.
            if (axi.rvalid && axi.rready) begin
                fe_line_buf[axi.rid][fe_beat_cnt[axi.rid] * DATA_WIDTH +: DATA_WIDTH] <= axi.rdata;
                fe_beat_cnt[axi.rid] <= fe_beat_cnt[axi.rid] + 1'b1;
                if (axi.rlast) fe_state[axi.rid] <= FE_DONE;
            end

            // Fill handoff accepted: DONE -> IDLE, entry free for reuse.
            if (fill_valid && fill_ready) begin
                fe_state[fe_done_sel] <= FE_IDLE;
            end
        end
    end

    // ===================================================================
    // Writeback engine: a small FIFO of evicted dirty lines, drained one
    // at a time onto the AW/W/B channels. Kept serialized rather than
    // pipelined -- writebacks are off the latency-critical path (the
    // cache slot is already free the moment the controller hands the
    // data over) and AXI4's write-data channel carries no ID, so
    // concurrent writes still can't interleave their data beats. The
    // only gain pipelining would buy is overlapping AW/B round trips,
    // at the cost of per-slot state and ID bookkeeping; not worth it
    // for this design. See private_notes/MSHR_README.md for the full
    // comparison.
    // ===================================================================
    typedef enum logic [1:0] {
        WB_IDLE,    // nothing queued
        WB_AW,      // driving the write address, waiting for awready
        WB_DATA,    // streaming the LINE_WORDS write-data beats
        WB_WAIT_B   // waiting for the write response
    } wb_state_e;

    localparam int WB_PTR_WIDTH = (WB_QUEUE_DEPTH > 1) ? $clog2(WB_QUEUE_DEPTH) : 1;

    wb_state_e                       wb_state;
    logic [WB_PTR_WIDTH-1:0]         wb_head, wb_tail;
    logic [$clog2(WB_QUEUE_DEPTH+1)-1:0] wb_count;
    logic [BEAT_CNT_WIDTH-1:0]       wb_beat_cnt;
    logic [ADDR_WIDTH-1:0]           wb_queue_addr[WB_QUEUE_DEPTH];
    logic [LINE_WIDTH-1:0]           wb_queue_data[WB_QUEUE_DEPTH];

    logic wb_push, wb_pop;
    assign wb_push  = wb_valid && wb_ready;
    assign wb_pop   = (wb_state == WB_WAIT_B) && axi.bvalid && axi.bready;
    assign wb_ready = (wb_count < WB_QUEUE_DEPTH);
    assign wb_done  = wb_pop;

    assign axi.awvalid = (wb_state == WB_AW);
    assign axi.awid    = '0;  // only one write is ever outstanding, so no ID ambiguity is possible
    assign axi.awaddr  = wb_queue_addr[wb_head];
    assign axi.awlen   = BURST_LEN;
    assign axi.awsize  = BURST_SIZE;
    assign axi.awburst = BURST_INCR;

    assign axi.wvalid = (wb_state == WB_DATA);
    assign axi.wdata  = wb_queue_data[wb_head][wb_beat_cnt * DATA_WIDTH +: DATA_WIDTH];
    assign axi.wstrb  = '1;  // always a full-line write, no partial-beat masking needed
    assign axi.wlast  = (wb_beat_cnt == LINE_WORDS - 1);

    assign axi.bready = (wb_state == WB_WAIT_B);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_state    <= WB_IDLE;
            wb_head     <= '0;
            wb_tail     <= '0;
            wb_count    <= '0;
            wb_beat_cnt <= '0;
        end else begin
            // Queue a newly evicted victim.
            if (wb_push) begin
                wb_queue_addr[wb_tail] <= wb_addr;
                wb_queue_data[wb_tail] <= wb_data;
                wb_tail <= (wb_tail == WB_QUEUE_DEPTH - 1) ? '0 : wb_tail + 1'b1;
            end

            // Track how many victims are queued (push and pop can happen
            // the same cycle, leaving the count unchanged).
            case ({wb_push, wb_pop})
                2'b10: wb_count <= wb_count + 1'b1;
                2'b01: wb_count <= wb_count - 1'b1;
                default: wb_count <= wb_count;
            endcase

            // Drain FSM.
            unique case (wb_state)
                WB_IDLE: begin
                    if (wb_count > 0) wb_state <= WB_AW;
                end
                WB_AW: begin
                    if (axi.awvalid && axi.awready) begin
                        wb_state    <= WB_DATA;
                        wb_beat_cnt <= '0;
                    end
                end
                WB_DATA: begin
                    if (axi.wvalid && axi.wready) begin
                        if (axi.wlast) wb_state <= WB_WAIT_B;
                        else wb_beat_cnt <= wb_beat_cnt + 1'b1;
                    end
                end
                WB_WAIT_B: begin
                    if (axi.bvalid && axi.bready) begin
                        wb_state <= WB_IDLE;
                        wb_head  <= (wb_head == WB_QUEUE_DEPTH - 1) ? '0 : wb_head + 1'b1;
                    end
                end
                default: wb_state <= WB_IDLE;
            endcase
        end
    end

endmodule : mshr

`default_nettype wire
