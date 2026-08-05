// -----------------------------------------------------------------------
// MSHR (Miss Status Holding Register)
// -----------------------------------------------------------------------
// Sits between the cache controller and main memory, and is the only
// block in this design that drives the AXI4 master port. It has two
// responsibilities:
//
//   1. Non-blocking miss handling: when the controller detects a cache
//      miss it hands the address to the MSHR instead of stalling. The
//      MSHR fetches the line over an AXI read burst and, if a second
//      miss to the same in-flight address arrives before the first
//      completes, merges it into the same entry rather than issuing a
//      redundant request ("hit-under-miss"). Up to NUM_ENTRIES misses
//      can be outstanding simultaneously, one per AXI transaction ID.
//
//   2. Victim writeback: when the controller evicts a dirty line to make
//      room for an incoming fill, it hands the evicted line to the MSHR,
//      which queues it and writes it back to memory over an AXI write
//      burst.
//
// These two responsibilities are implemented as two independent engines
// that share the same AXI port:
//   - Fill engine   : one small FSM per entry, arbitrated onto the AR
//                     channel; reassembles R beats into a full line.
//   - Writeback engine: a FIFO of evicted lines, drained one at a time
//                     onto the AW/W/B channels.
//
// Full design rationale (why round-robin arbitration, why the writeback
// path is serialized rather than pipelined) is in
// private_notes/MSHR_README.md.
// -----------------------------------------------------------------------
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
    input  logic rst_n,  // active-low, synchronous reset

    // -----------------------------------------------------------------
    // Miss allocation (cache controller -> MSHR)
    // Driven the cycle the controller's tag compare detects a miss.
    // -----------------------------------------------------------------
    input  logic                  alloc_valid,     // controller is reporting a miss
    input  logic [ADDR_WIDTH-1:0] alloc_addr,      // line-aligned address that missed
    input  logic                  alloc_is_write,  // 1 = the access that missed was a store
    output logic                  alloc_ready,     // 0 = no free entry and no in-flight entry to merge with; controller must stall
    output logic [ID_WIDTH-1:0]   alloc_id,        // entry index / AXI ID assigned to this miss

    // -----------------------------------------------------------------
    // Victim writeback (cache controller -> MSHR)
    // Driven when the controller evicts a dirty line and needs it
    // flushed to memory.
    // -----------------------------------------------------------------
    input  logic                    wb_valid,  // controller is handing off a dirty victim line
    input  logic [ADDR_WIDTH-1:0]   wb_addr,   // victim line address
    input  logic [LINE_WIDTH-1:0]   wb_data,   // victim line data
    output logic                    wb_ready,  // 0 = writeback queue is full
    output logic                    wb_done,   // pulses for one cycle once the AXI write is confirmed by a B response

    // -----------------------------------------------------------------
    // Fill completion (MSHR -> cache controller)
    // Driven once an outstanding read miss has been fully serviced.
    // -----------------------------------------------------------------
    output logic                  fill_valid,     // a completed line is available this cycle
    output logic [ID_WIDTH-1:0]   fill_id,        // entry that completed
    output logic [ADDR_WIDTH-1:0] fill_addr,      // address of the completed line
    output logic [LINE_WIDTH-1:0] fill_data,      // reassembled line data, all beats concatenated
    output logic                  fill_is_write,  // 1 = controller must merge the pending store and mark the line dirty
    input  logic                  fill_ready,     // 1 = the data array can accept the fill this cycle

    // -----------------------------------------------------------------
    // AXI4 master port to main memory.
    // Read channels (AR/R) service misses; write channels (AW/W/B)
    // perform victim writebacks.
    // -----------------------------------------------------------------
    axi_if.master axi
);

    // -------------------------------------------------------------------
    // Burst parameters shared by both engines: every transaction this
    // module issues is a fixed-length INCR burst covering exactly one
    // cache line.
    // -------------------------------------------------------------------
    localparam int              BEAT_CNT_WIDTH = $clog2(LINE_WORDS);
    localparam logic [7:0]      BURST_LEN      = LINE_WORDS - 1;            // AxLEN = beats - 1
    localparam logic [2:0]      BURST_SIZE     = $clog2(DATA_WIDTH / 8);    // AxSIZE = log2(bytes/beat)
    localparam logic [1:0]      BURST_INCR     = 2'b01;

    // Fixed-priority encoder: returns the lowest set bit index in `vec`.
    // Used both to pick a free/matching MSHR entry and, elsewhere, as the
    // fallback path of the AR arbiter. Result is meaningless when `vec`
    // is all zero; callers always gate on a separate "any bit set" signal.
    function automatic logic [ID_WIDTH-1:0] pick_lowest(input logic [NUM_ENTRIES-1:0] vec);
        pick_lowest = '0;
        for (int i = NUM_ENTRIES - 1; i >= 0; i--) begin
            if (vec[i]) pick_lowest = i[ID_WIDTH-1:0];
        end
    endfunction

    // ===================================================================
    // Fill engine
    // One FSM instance per AXI ID, tracking a single outstanding read
    // miss from allocation through data return.
    // ===================================================================
    typedef enum logic [1:0] {
        FE_IDLE,  // entry unused, available for allocation
        FE_REQ,   // address latched, waiting to win the AR arbiter
        FE_DATA,  // AR accepted, collecting R beats for this line
        FE_DONE   // all beats received, waiting to be handed to the controller
    } fe_state_e;

    fe_state_e                    fe_state   [NUM_ENTRIES];  // per-entry FSM state
    logic [ADDR_WIDTH-1:0]        fe_addr    [NUM_ENTRIES];  // line address owned by each entry
    logic                         fe_is_write[NUM_ENTRIES];  // set if any merged access was a store
    logic [BEAT_CNT_WIDTH-1:0]    fe_beat_cnt[NUM_ENTRIES];  // R beats received so far for this entry
    logic [LINE_WIDTH-1:0]        fe_line_buf[NUM_ENTRIES];  // reassembled line data, filled beat by beat

    // Per-entry status vectors, recomputed combinationally every cycle
    // from the current state array. Each bit position corresponds to one
    // entry / AXI ID.
    logic [NUM_ENTRIES-1:0] fe_match_vec;  // entries in flight whose address matches the incoming miss (merge candidates)
    logic [NUM_ENTRIES-1:0] fe_free_vec;   // entries available for a new allocation
    logic [NUM_ENTRIES-1:0] fe_req_vec;    // entries currently requesting the AR channel
    logic [NUM_ENTRIES-1:0] fe_done_vec;   // entries holding a completed line, waiting to be presented

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

    // Allocation decision, combinational: a merge into an in-flight entry
    // is always preferred over opening a new one (hit-under-miss). The
    // controller stalls only when there is neither a match nor a free
    // entry.
    assign alloc_ready = fe_any_match | fe_any_free;
    assign alloc_id    = fe_any_match ? fe_match_idx : fe_free_idx;

    // -------------------------------------------------------------------
    // AR-channel arbiter
    // Selects, among all entries in FE_REQ, which one is granted the
    // shared read-address channel this cycle. Uses round-robin priority:
    // requests above the last-granted index are preferred, wrapping back
    // to a plain low-index scan only if none are pending. This guarantees
    // every requesting entry is serviced within NUM_ENTRIES grants, so no
    // entry can be starved indefinitely by lower-index neighbors.
    // -------------------------------------------------------------------
    logic [ID_WIDTH-1:0]    ar_last_grant;   // index granted on the previous arbitration
    logic [NUM_ENTRIES-1:0] ar_hi_mask;      // entries with index strictly above ar_last_grant
    logic [NUM_ENTRIES-1:0] ar_req_hi;       // requesting entries within ar_hi_mask
    logic                   ar_grant_valid;  // at least one entry is requesting the AR channel
    logic [ID_WIDTH-1:0]    ar_grant_idx;    // entry granted the AR channel this cycle

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

    // Read-data channel is always ready: an incoming beat is simply
    // latched into the owning entry's line buffer, so there is nothing
    // that can force a stall.
    assign axi.rready = 1'b1;

    // -------------------------------------------------------------------
    // Fill-completion mux
    // Selects which completed (FE_DONE) entry is presented to the cache
    // controller this cycle. Only one entry can be handed off per cycle,
    // so plain fixed-priority (lowest index first) is used -- unlike the
    // AR arbiter, this choice does not affect memory bandwidth, only how
    // long a finished entry waits to be handed off.
    // -------------------------------------------------------------------
    logic [ID_WIDTH-1:0] fe_done_sel;
    assign fe_done_sel   = pick_lowest(fe_done_vec);
    assign fill_valid    = |fe_done_vec;
    assign fill_id       = fe_done_sel;
    assign fill_addr     = fe_addr[fe_done_sel];
    assign fill_data     = fe_line_buf[fe_done_sel];
    assign fill_is_write = fe_is_write[fe_done_sel];

    // Fill-engine sequential logic: advances every per-entry FSM and
    // records new state (allocation, AR grant, R-beat capture, fill
    // handoff).
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_ENTRIES; i++) fe_state[i] <= FE_IDLE;
            ar_last_grant <= '0;
        end else begin
            // Allocation: open a new entry, or merge into an existing one.
            // On a merge, only the is_write flag needs updating -- if any
            // access that merged into this entry was a store, the line
            // must come back marked dirty, regardless of whether the
            // first (primary) access was a load.
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

            // AR arbiter grant: REQ -> DATA, and remember who just won so
            // the round-robin pointer advances.
            if (ar_grant_valid && axi.arvalid && axi.arready) begin
                fe_state[ar_grant_idx] <= FE_DATA;
                ar_last_grant          <= ar_grant_idx;
            end

            // R beat capture, demultiplexed by rid: each beat is written
            // into the owning entry's line buffer; DATA -> DONE on the
            // last beat of the burst.
            if (axi.rvalid && axi.rready) begin
                fe_line_buf[axi.rid][fe_beat_cnt[axi.rid] * DATA_WIDTH +: DATA_WIDTH] <= axi.rdata;
                fe_beat_cnt[axi.rid] <= fe_beat_cnt[axi.rid] + 1'b1;
                if (axi.rlast) fe_state[axi.rid] <= FE_DONE;
            end

            // Fill handoff accepted by the controller: DONE -> IDLE, entry
            // becomes available for reuse by a future miss.
            if (fill_valid && fill_ready) begin
                fe_state[fe_done_sel] <= FE_IDLE;
            end
        end
    end

    // ===================================================================
    // Writeback engine
    // A small FIFO of evicted dirty lines, drained one at a time onto the
    // AW/W/B channels. Writes are serialized rather than pipelined: they
    // are off the latency-critical path (the cache slot is already free
    // once the controller hands the victim over) and AXI4's write-data
    // channel carries no ID, so concurrent writes could not interleave
    // their data beats anyway. See private_notes/MSHR_README.md for the
    // full comparison against a pipelined design.
    // ===================================================================
    typedef enum logic [1:0] {
        WB_IDLE,    // queue empty, nothing to write back
        WB_AW,      // driving the write address, waiting for awready
        WB_DATA,    // streaming the LINE_WORDS write-data beats
        WB_WAIT_B   // write issued, waiting for the B response
    } wb_state_e;

    localparam int WB_PTR_WIDTH = (WB_QUEUE_DEPTH > 1) ? $clog2(WB_QUEUE_DEPTH) : 1;

    wb_state_e                       wb_state;                          // drain FSM state
    logic [WB_PTR_WIDTH-1:0]         wb_head, wb_tail;                  // FIFO read/write pointers
    logic [$clog2(WB_QUEUE_DEPTH+1)-1:0] wb_count;                      // number of victims currently queued
    logic [BEAT_CNT_WIDTH-1:0]       wb_beat_cnt;                       // write-data beats sent for the current victim
    logic [ADDR_WIDTH-1:0]           wb_queue_addr[WB_QUEUE_DEPTH];      // queued victim addresses
    logic [LINE_WIDTH-1:0]           wb_queue_data[WB_QUEUE_DEPTH];      // queued victim line data

    logic wb_push, wb_pop;
    assign wb_push  = wb_valid && wb_ready;                              // a new victim is accepted into the queue
    assign wb_pop   = (wb_state == WB_WAIT_B) && axi.bvalid && axi.bready; // the head-of-queue victim's write completes
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

    // Writeback-engine sequential logic: manages the FIFO occupancy and
    // advances the drain FSM through address, data, and response phases.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wb_state    <= WB_IDLE;
            wb_head     <= '0;
            wb_tail     <= '0;
            wb_count    <= '0;
            wb_beat_cnt <= '0;
        end else begin
            // Enqueue a newly evicted victim line.
            if (wb_push) begin
                wb_queue_addr[wb_tail] <= wb_addr;
                wb_queue_data[wb_tail] <= wb_data;
                wb_tail <= (wb_tail == WB_QUEUE_DEPTH - 1) ? '0 : wb_tail + 1'b1;
            end

            // Track queue occupancy; a simultaneous push and pop leaves
            // the count unchanged.
            case ({wb_push, wb_pop})
                2'b10: wb_count <= wb_count + 1'b1;
                2'b01: wb_count <= wb_count - 1'b1;
                default: wb_count <= wb_count;
            endcase

            // Drain FSM: issues one full AW -> W -> B sequence per queued
            // victim before advancing to the next.
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
