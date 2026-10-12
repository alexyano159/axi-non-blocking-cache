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

## Verification

System testbench: [`tb/cache_top_tb.sv`](../tb/cache_top_tb.sv). It
drives the real `cache_top` (nothing stubbed) from a CPU model and
serves its AXI port from a memory model; internal signals are only
*read* (white-box checks and coverage).

### Methodology

- **Pass criterion — the cache must look like plain memory.** Every
  request takes effect at the moment it is accepted
  (`req_valid && req_ready`), in acceptance order. The scoreboard keeps a
  reference memory image: a store updates it at acceptance, a load's
  expected data is read from it at acceptance. Responses may come back in
  any order; each is matched by `resp_id`, exactly once, and `resp_we`
  is checked.
- **AXI memory model (TB only).** Random, independent back-pressure on
  `arready`, `awready`, `wready`; random read latency and gaps between
  `R` beats; random `B` delay. Reads with different IDs complete **out of
  order** and their beats may **interleave**. A write lands in memory
  only at its `B` response, and reads are never ordered against writes —
  so a read that overtook the writeback of the same line would return
  stale data. Directed tests can freeze any channel or script the exact
  order of `R` beats.
- **Protocol checks on the master side.** Every burst is INCR, 4 beats,
  full width, line-aligned; `wstrb` all ones; `wlast` exactly on beat 4;
  `arvalid`/`awvalid`/`wvalid` and their payload stay stable until
  accepted; no ID reused while outstanding; no second read of a line
  already being read (a missed merge); no read of a line whose writeback
  has not yet received `B`; every `W` burst carries exactly the victim the
  controller handed to the MSHR, in hand-off order.
- **White-box checks.** Every victim handed to the writeback queue must
  equal the reference image of that line. ModelSim 18.1 does not evaluate
  `assert property`, so the controller's assertions are re-checked
  procedurally every cycle (MSHR never refuses an allocation, a replay
  never misses, no duplicate line after a fill, no multi-way hit, waiting
  table and response FIFO never overflow, fill/replay/lookup exclusion,
  one-hot replay selection, LRU ages stay a permutation).
- **End-of-test consistency.** For every line ever touched: dirty copy
  in the cache, or else memory, must equal the reference; then every
  touched word is read back through the cache.
- **No hangs.** Every wait is bounded; a timeout prints a diagnostic dump
  (outstanding ids, MSHR entries, queues) and a `[FAIL]`, then ends the
  run. A global watchdog backs this up.

### Tests

| # | Test | What it shows |
|---|---|---|
| 1 | Reset idle | Ready, no response, no AXI traffic after reset |
| 2 | Load miss → fill → hit | One line-aligned `AR`, memory data returned; next word hits in 2 cycles with no traffic |
| 3 | Store miss, then load | Write-allocate (one `AR`), stored word and neighbour read back, no `AW` before eviction |
| 4 | Hit-under-miss | 8 hits complete in 2 cycles each while a miss is frozen in memory |
| 5 | Secondary-miss merge | 8 requests to one missing line → 1 `AR`, 7 merges; loads after stores to the same word see the stores |
| 6 | Dirty victim | Full set, LRU line dirty → exactly one writeback, to its own address, with its full modified data |
| 7 | Re-miss during delayed `B` | Re-read of a just-evicted dirty line is held until `B`, then returns the written data |
| 8 | Writeback queue full | `awready` held low: 4 victims queue up, the 5th eviction stalls with the CPU held off, then 5 writebacks drain in order |
| 9 | Fill restart (F0/F1) | Scripted `R` beats: higher-ID line finishes one cycle before a lower-ID line → exactly one restart, both installed once |
| 10 | CPU back-pressure | 400 random requests with `resp_ready` 20 % and long stalls: no response lost, duplicated, or changed while held |
| 11 | Constrained random | 5000 requests (`+nreq`), `+seed`, 4 sets × 8 lines, timing profile redrawn every 250 requests; coverage floors |
| 12 | Consistency | Memory + dirty lines equal the reference; every touched word reads back correctly |

### Coverage (test 11, seed 1, 5000 requests)

| Event | Count | Floor |
|---|---|---|
| Dirty writebacks | 1038 | 300 |
| Merged misses | 931 | 250 |
| Re-misses held by the read-after-write rule | 208 | 50 |
| Fill restarts (F0/F1 selection change) | 100 | 25 |
| Replays | 2375 | 750 |
| Hit-under-miss responses | 1921 | 500 |
| Out-of-order `R` completions | 261 | 75 |
| Interleaved `R` beats | 461 | 125 |
| Cycles stalled on a full writeback queue | 15464 | > 0 |

Floors are about one third of the lowest value seen over seeds 1–30.
All 30 seeds pass, as do two 50 000-request runs.

### Mutation testing — can the testbench fail?

Each mutant is a copy of the RTL with one deliberate bug, simulated in a
scratch directory. All 12 are caught; none hangs the simulator.

| Mutant | Caught by |
|---|---|
| MSHR without the read-after-write hold | `AR` before `B` check (test 7), stale data in tests 7/10/11/12 |
| Replay by slot index instead of age | Scoreboard data mismatches (test 11) |
| Wrong victim data (neighbouring way) | Victim-vs-reference check (test 6 on), `W` data, memory consistency |
| Fill ignores `wb_ready` | Test 8 (no stall), scoreboard and consistency in test 11 |
| Merge disabled in the MSHR | "second read of a line" `AR` check (test 5 on) |
| No `AR` grant lock (the bug fixed below) | `AR` payload stability check (test 11) |
| Fill restart ignored (`fill_id` not compared) | Test 9 restart count, victim checks in test 11 |
| `wlast` one beat early | `wlast` check, then idle watchdog (test 6) |
| No same-set read-after-write stall | Scoreboard data mismatches (tests 10, 11) |
| LRU victim always way 0 | Writeback order in test 8 |
| Fill allowed while replays are pending | Duplicate-line and lookup-during-F1 mirrors (test 9), driver watchdog |
| Store hit does not set the dirty bit | No writeback in test 6, stale data in test 7, test 8 watchdog |

### Bug found

`mshr.sv`: the `AR` arbiter re-arbitrated every cycle, so when a new
entry started requesting while a request was waiting for `arready`,
`arid`/`araddr` switched to the newcomer — forbidden by AXI. Found by
the stability check in test 11; fixed with a grant lock (see
[`MSHR_README.md`](MSHR_README.md#the-ar-arbiter-why-round-robin-not-fixed-priority)).

### Known limitations

- AXI error responses (`SLVERR`/`DECERR`) are never generated; the cache
  ignores `rresp`/`bresp`.
- The memory model always takes write data after its `AW` (AXI also
  allows `W` first); the MSHR never sends `W` first, so this is not
  exercised.
- One configuration only (the default parameters).
- No reset in the middle of traffic at system level (covered for the
  MSHR alone in `mshr_tb` test 13).
- LRU order is checked only indirectly (test 8 and the permutation
  invariant), not against a reference model of recency.

### Running

```bash
vlib work
vlog -sv rtl/axi_if.sv rtl/cache_controller.sv rtl/cache_data_sram.sv \
     rtl/cache_tag_array.sv rtl/cache_valid_array.sv rtl/cache_top.sv rtl/mshr.sv \
     tb/cache_top_tb.sv
vsim -c cache_top_tb +seed=7 +nreq=5000 -do "run -all; quit -f"
```

`./tools/sim/run.sh cache_top_tb` also works (default seed 1, 5000
requests). Each test prints `[PASS]`/`[FAIL]`; the last line is a
`[SUMMARY]`.
