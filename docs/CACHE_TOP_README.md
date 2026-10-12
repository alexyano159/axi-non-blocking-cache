# `cache_top.sv` — Cache Top Level

## What it is

The complete cache as one block: a 4-way set-associative, write-back /
write-allocate, non-blocking L1 data cache. On one side it talks to a
CPU (tagged requests and responses); on the other side it is an AXI4
master to main memory.

`cache_top` has **no logic of its own**. It only:
- instantiates the five verified building blocks,
- connects them with named wires,
- checks at elaboration time that the parameters make sense (see
  [Elaboration checks](#elaboration-checks)).

All the behaviour lives in the submodules; this file is the wiring
diagram, written in SystemVerilog.

## Block diagram

```
                   +-----------------------------------------------------+
                   |                      cache_top                      |
                   |                                                     |
  CPU request ---->|  +------------------+  tag_*    +-----------------+ |
  req_valid/ready  |  |                  |<--------->| cache_tag_array | |
  req_addr/we      |  |                  |           +-----------------+ |
  req_wdata/id     |  |                  |  valid_*  +-----------------+ |
                   |  | cache_controller |<--------->|cache_valid_array| |
  CPU response <---|  |                  |           +-----------------+ |
  resp_valid/ready |  |                  |  data_*   +-----------------+ |
  resp_id/data/we  |  |                  |<--------->| cache_data_sram | |
                   |  +------------------+           +-----------------+ |
                   |        ^  mshr_alloc_*  (miss, id returned)         |
                   |        |  mshr_wb_*     (dirty victim handoff)      |
                   |        v  mshr_fill_*   (completed line)            |
                   |  +------------------+                               |
                   |  |       mshr       |======== axi (master) =========|===> memory
                   |  +------------------+  AR/R  : line fills           |    (AXI4 slave)
                   |                        AW/W/B: victim writebacks    |
                   +-----------------------------------------------------+
```

Two rules shape the whole picture:
- The **controller is the only client** of the three arrays and of the
  MSHR. The arrays never talk to each other or to the MSHR.
- The **MSHR is the only block on the AXI bus**. The controller never
  touches memory directly.

| Instance | Module | Role |
|---|---|---|
| `u_controller` | `cache_controller` | Address split, hit/miss, hit path + response FIFO, true LRU, MSHR allocation, waiting table, fill installation, dirty-victim handoff, replay |
| `u_tag_array` | `cache_tag_array` | Tag + dirty bit per (way, set); registered 4-way compare; stored-tag read-out. No reset |
| `u_valid_array` | `cache_valid_array` | Valid bit per (way, set); synchronous reset to all-invalid |
| `u_data_sram` | `cache_data_sram` | 128-bit line per (way, set); registered read of all 4 ways; word-masked write. No reset |
| `u_mshr` | `mshr` | Up to 16 outstanding misses with merging; victim writeback queue; AXI4 master |

## Interface

All signals are synchronous to `clk`.

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock |
| `rst_n` | 1 | in | Active-low **synchronous** reset |
| `req_valid` | 1 | in | CPU presents a request |
| `req_ready` | 1 | out | Cache accepts the request this cycle (`req_valid && req_ready` = accepted) |
| `req_addr` | `ADDR_WIDTH` (32) | in | Byte address; split as `[ tag 22 \| set 6 \| word 2 \| byte 2 ]` |
| `req_we` | 1 | in | 1 = store, 0 = load |
| `req_wdata` | `DATA_WIDTH` (32) | in | Store data (ignored for a load) |
| `req_id` | `TXN_ID_WIDTH` (4) | in | Transaction tag, echoed on the response |
| `resp_valid` | 1 | out | A response is available |
| `resp_ready` | 1 | in | CPU takes the response this cycle |
| `resp_id` | `TXN_ID_WIDTH` (4) | out | Which request this response answers (responses can be out of order) |
| `resp_data` | `DATA_WIDTH` (32) | out | Load data (don't-care for a store acknowledge) |
| `resp_we` | 1 | out | Echo of `req_we` of the answered request |
| `axi` | `axi_if.master` | modport | AXI4 master port to memory. The connected `axi_if` instance must use `ADDR_WIDTH`, `DATA_WIDTH` and `ID_WIDTH = MSHR_ID_WIDTH` |

AXI usage by the MSHR (see [`MSHR_README.md`](MSHR_README.md)):
- `AR`/`R`: one INCR burst of `WORDS_PER_LINE` beats per miss
  (`arlen = 3`, `arsize = 2`), up to 16 in flight with distinct
  `arid`s. `rready` is always 1; R beats may come back out of order
  or interleaved across IDs.
- `AW`/`W`/`B`: one full-line burst per dirty victim, one at a time,
  `awid = 0`, `wstrb` all ones.
- `rresp`/`bresp` are not checked (no error handling).

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Address width |
| `DATA_WIDTH` | 32 | Word width = AXI data bus width |
| `NUM_WAYS` | 4 | Associativity |
| `WORDS_PER_LINE` | 4 | Words per line = AXI burst length (MSHR `LINE_WORDS`) |
| `NUM_SETS` | 64 | Sets (4 KB / 4 ways / 16 B line) |
| `MSHR_ID_WIDTH` | 4 | MSHR `ID_WIDTH` = AXI ID width; `2**MSHR_ID_WIDTH` = 16 MSHR entries |
| `TXN_ID_WIDTH` | 4 | CPU transaction tag width; waiting table has `2**TXN_ID_WIDTH` = 16 slots |
| `WB_QUEUE_DEPTH` | 4 | Dirty victims the MSHR can queue for writeback |

Derived inside (`localparam`, same formulas as the submodules):
`SET_IDX_WIDTH = 6`, `WAY_WIDTH = 2`, `WORD_OFF_WIDTH = 2`,
`BYTE_OFF_WIDTH = 2`, `TAG_WIDTH = 22`, `LINE_WIDTH = 128`.

Only the primary parameters are passed to each submodule; each one
derives the same widths from them, exactly as in the per-module
testbenches.

## How the submodules are connected

| Port group | Between | Handshake |
|---|---|---|
| `tag_rd_*`, `tag_match`, `tag_dirty_out`, `tag_tag_out` | controller ↔ tag array | None. Address in cycle N, registered result in N+1 |
| `tag_wr_*` | controller → tag array | `wr_en` strobe; `wr_tag_en` / `wr_dirty_en` pick the fields |
| `valid_rd_*`, `valid_out` | controller ↔ valid array | None. Same 1-cycle latency as the tag array |
| `valid_wr_*` | controller → valid array | `wr_en` strobe (fills only) |
| `data_rd_*`, `data_rd_line` | controller ↔ data SRAM | None. Same 1-cycle latency; all 4 ways returned |
| `data_wr_*` | controller → data SRAM | `wr_en` strobe; `wr_word_en` one-hot (store hit) or all-ones (fill) |
| `mshr_alloc_*` | controller → MSHR | `alloc_valid` for one cycle; **never waits** on `alloc_ready` (the controller's acceptance rule guarantees it, and asserts it). `alloc_id` comes back in the same cycle |
| `mshr_wb_*` | controller → MSHR | valid/ready; the victim is queued on `wb_valid && wb_ready` |
| `mshr_fill_*` | MSHR → controller | valid/ready; the MSHR holds a finished line until `fill_ready` |

The three arrays all get the **same set index** every cycle and answer
together one cycle later, so the controller sees tag, valid, dirty and
data for one set at the same time. Same-edge read and write to one set
returns the old data (no forwarding); the controller stalls one cycle
around that.

### Two MSHR outputs the controller does not use

Both are connected to the controller's matching input ports (so nothing
is left dangling), on named wires with a comment, but the controller's
logic ignores them:

- **`mshr_fill_is_write`** — "some merged access was a store". Not
  needed: every line is installed **clean**, and each waiting store is
  then **replayed** through the normal hit path, which writes the word
  and sets the dirty bit. The waiting table already holds the store data
  and word offset, which this one flag could not provide.
- **`mshr_wb_done`** — "a writeback got its B response". Not needed: the
  victim leaves the cache the moment it is handed to the queue, and the
  only hazard (a re-miss to that line reading stale memory) is solved
  inside the MSHR, which holds that read until the write completes.

## Transaction walkthroughs

Cycle N = the cycle the CPU request is accepted.

### Load hit
1. **N** — the controller drives the request's set onto all three arrays.
2. **N+1** — `tag_match & valid_out` gives the hit way; the word is
   picked from that way's line and pushed into the response FIFO. The
   set's LRU order is updated (hit way becomes youngest).
3. **N+2** — `resp_valid` with the load data and `resp_id`.

### Store hit
Same as the load hit, but in **N+1** the controller also writes the one
word into the data SRAM (`wr_word_en` one-hot) and sets the dirty bit in
the tag array (`wr_tag_en = 0`). The response in N+2 is an acknowledge.
A request to the same set in N+1 is held one cycle so it does not read
the old line.

### Load miss, clean victim
1. **N+1** — no valid way matches. The controller sends the
   line-aligned address on `mshr_alloc_*` and parks the request (address,
   id, MSHR id) in its waiting table. Later requests keep being served
   (hit-under-miss).
2. The MSHR issues `AR` (4 beats), collects the `R` beats, and raises
   `fill_valid` with the full line.
3. **F0** — the controller holds off the CPU and reads the fill's set.
4. **F1** — victim = lowest invalid way, else the LRU way. It is clean
   (or invalid), so nothing goes to the writeback queue. Tag, valid bit
   and line are written, the LRU order updated, and `fill_ready`
   completes the handoff. The MSHR entry is free again.
5. **Replay** — the waiting load is marked ready, re-enters the lookup,
   hits, and its response comes back with its own `resp_id`.

### Store miss that evicts a dirty line
1. **N+1** — the store misses; `alloc_is_write = 1`; the store (with its
   data) is parked in the waiting table.
2. The fill arrives as above. **F1** finds the LRU victim valid and
   dirty: on the **same edge** the controller hands it to the MSHR
   (`wb_valid`, address = `{stored tag, set, 0}`, data = the old line)
   and overwrites the way with the new, **clean** line. If the writeback
   queue is full, F1 simply repeats until there is room.
3. **Replay** — the store re-runs through the hit path: it writes its
   word and sets the dirty bit, and the CPU gets its acknowledge.
4. In the background the MSHR sends the victim out on `AW`/`W`, gets
   `B`, and pulses `wb_done` (unused, see above).

### Re-miss to a line that was just evicted dirty
1. Line X was evicted dirty and is still waiting in the writeback queue.
2. The CPU asks for X again — it is no longer in the cache, so it misses
   and gets an MSHR entry like any other miss.
3. At allocation the MSHR sees X in the writeback queue and **holds that
   entry's `AR`** until X's write gets its `B` response.
4. The read then goes out and returns the data that was just written
   back, not the stale memory contents. Unrelated misses are not delayed.

## Elaboration checks

Run once at elaboration (inside `` `ifndef SYNTHESIS ``); any failure
stops the simulation with `$fatal`:

| Check | Why |
|---|---|
| `NUM_WAYS`, `NUM_SETS` are powers of two, ≥ 2 | Set index and way index are plain bit fields (`$clog2`) |
| `DATA_WIDTH` is a power of two in 8..1024 | Byte offset field and legal AXI data bus width / `arsize` |
| `TAG_WIDTH ≥ 1` | `ADDR_WIDTH` must leave tag bits above set + offset |
| `WORDS_PER_LINE` is a power of two in 2..256 | One line = one INCR burst; AXI4 allows at most 256 beats; word offset is a bit field |
| Line size ≤ 4 KB | A line-aligned burst then never crosses a 4 KB boundary |
| `MSHR_ID_WIDTH ≥ 1`, `WB_QUEUE_DEPTH ≥ 1` | MSHR needs at least one entry and one queue slot |
| `axi_if` `ID_WIDTH == MSHR_ID_WIDTH` | The MSHR drives `arid` from an entry number and uses `rid` to index its entries |
| `axi_if` `ADDR_WIDTH`, `DATA_WIDTH` match the cache | The bus must carry the cache's addresses and words |

**Not repeated here:** the waiting table must not have more slots than
the MSHR has entries (`2**TXN_ID_WIDTH ≤ 2**MSHR_ID_WIDTH`). That check
lives inside `cache_controller`, next to the argument that depends on it
(every miss is guaranteed a free or matching MSHR entry).

## Verification status

Compiles and elaborates under ModelSim 18.1 with no warnings other than
the known "SVA only supported in Questa" notes, and a smoke run (one
load miss reaching the `AR` channel) behaves as expected. A system-level
testbench with an AXI memory model is the next step.
