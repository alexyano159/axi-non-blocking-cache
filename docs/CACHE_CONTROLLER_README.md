# `cache_controller.sv` — Cache Controller

## What it does

The cache controller is the control logic of the L1 cache. It is the
**only** client of the three cache arrays and of the MSHR, and it owns
everything that decides what the cache does with a request:

- splitting an address into `[ TAG | SET | WORD | BYTE ]`;
- hit/miss detection (tag compare AND valid bit);
- the hit path — returning a load word, writing a store word and
  setting the dirty bit;
- the true-LRU replacement state and victim choice;
- the miss side — reporting a miss to the MSHR and parking the request
  in a **waiting table**;
- installing a returned line (the **fill**), including handing a dirty
  victim to the MSHR for writeback;
- **replaying** every parked request through the hit path once its line
  is installed.

The CPU side is **tagged and multi-outstanding**: every request carries
an id (`req_id`), every response echoes it (`resp_id`), and responses
can return out of order. That is what makes the cache non-blocking from
the CPU's point of view — a hit behind a pending miss is answered first
(hit-under-miss). A single-outstanding interface would stall the CPU on
every miss and leave the MSHR's 16 entries unused.

## Who it talks to

```
                    +------------------> cache_tag_array   (tag_*)
                    |
CPU  <--req/resp--> cache_controller ---> cache_valid_array (valid_*)
                    |
                    +------------------> cache_data_sram   (data_*)
                    |
                    +<-----------------> mshr  <----> AXI4 memory
                       alloc / wb / fill
```

The controller does **not** instantiate any of these. It exposes four
port groups that mirror each collaborator's interface one-for-one, and a
separate top-level module, `rtl/cache_top.sv`, wires the five blocks
together. The groups are prefixed (`tag_`, `valid_`, `data_`, `mshr_`)
because the collaborators share generic port names (`wr_en`,
`rd_set_idx`, ...) that would otherwise collide.

| Collaborator | Port group | What flows |
|---|---|---|
| CPU | `req_*`, `resp_*` | Loads/stores in, load data / store acks out, both valid/ready |
| `cache_tag_array` | `tag_*` | Set + lookup tag in, per-way match / dirty / stored tag out; one write port (tag and/or dirty) |
| `cache_valid_array` | `valid_*` | Set in, per-way valid out; one write port |
| `cache_data_sram` | `data_*` | Set in, all four ways' lines out; one write port with a per-word mask |
| `mshr` | `mshr_alloc_*`, `mshr_wb_*`, `mshr_fill_*` | Misses out, dirty victims out, completed lines in |

All three arrays have a **registered read** (result one cycle after the
address) and **no forwarding** (a read on the same edge as a write
returns the old contents). Most of the hazards below follow from those
two facts.

## Address split (default parameters)

```
 31                      10 9        4 3    2 1    0
+--------------------------+----------+------+------+
|        TAG (22)          | SET (6)  | WORD | BYTE |
+--------------------------+----------+------+------+
```

64 sets x 4 ways x 16-byte lines = 4 KB. The word offset selects one of
the four 32-bit words in a 128-bit line.

---

## The pipeline

Every request — from the CPU or a replay — goes through the same
two-stage pipe:

```
 cycle N   : ISSUE                      cycle N+1 : LOOKUP (lookup_q)
 ---------------------------------      --------------------------------------------
 address -> read ports of all 3 arrays  arrays return tag_match, valid_out,
 request metadata -> lookup_q           dirty, tags, 4 lines of the set
                         | edge |       hit_vec = tag_match & valid_out
                                        hit  -> push response; store also writes
                                        miss -> MSHR alloc + waiting-table slot
```

- **Issue (cycle N).** The issue source is a pending replay if there is
  one, otherwise the CPU. Its address drives the read ports of all three
  arrays together.
- **Lookup shadow register (`lookup_q`).** The arrays only return their
  result one cycle later, so the request's own metadata (valid, replay
  flag, address, set, tag, word offset, load/store, store data, id) is
  registered alongside, and lines up with the array outputs in cycle N+1.
- **Lookup (cycle N+1).** A way hits only if its tag matches **and** it
  is valid: an invalid way can hold a stale or uninitialised tag that
  happens to match. The hitting way is one-hot encoded to binary (the
  fill never installs a duplicate line, so at most one way can hit —
  asserted), and the requested word is sliced out of that way's line.

The lookup stage **cannot hold** a request: the arrays overwrite their
outputs with the next read. Whatever happens to a lookup result — a
response, an array write, an MSHR allocation — must happen in that one
cycle. This is the root of the acceptance rule further down.

### Hit — load

The word is pushed into the **response FIFO** with the request's id.
Latency: accepted on edge *e*, result in the FIFO on *e+1*, response
handshake at the earliest on *e+2*. The LRU order of the set is updated.

### Hit — store

In the same lookup cycle the controller writes:

- **data SRAM:** only the addressed word — a one-hot word enable, with
  the store word replicated across all four lanes so the enable alone
  picks the lane (no variable shifter);
- **tag array:** dirty bit only (`wr_tag_en = 0`, `wr_dirty = 1`) —
  write-back policy, the line is flushed only when evicted;
- **valid array:** nothing.

A store acknowledgement (`resp_we = 1`, data don't-care) is pushed into
the FIFO, and the LRU order is updated.

### Miss

In the same lookup cycle:

1. **MSHR allocation.** `mshr_alloc_valid` is raised with the
   **line-aligned** address (word and byte offset cleared), so two
   misses to different words of one line present the same address and
   merge into one MSHR entry. The MSHR returns the entry id
   combinationally (`mshr_alloc_id`) in the same cycle. The controller
   does **not** wait on `mshr_alloc_ready` — it cannot, since the lookup
   stage cannot stall — so the acceptance rule guarantees it (asserted).
2. **Waiting table.** The MSHR tracks *lines*, not requests (on a merge
   it keeps only the address and an OR-ed store flag). So the request
   itself — full address, load/store, store data, CPU id, and the MSHR id
   it waits on — is parked in the lowest-indexed free waiting-table
   slot, to be replayed later.

No response is produced. A miss does not change the LRU order (its line
is not present yet).

### Fill

When the MSHR presents a completed line (`mshr_fill_valid`), the
controller installs it in **two cycles**, because the victim can only be
chosen after the target set's valid/dirty bits have been read from the
registered arrays:

```
              F0 (read)                       F1 (write)
 read port :  fill's set                      fill's set
 CPU       :  held off                        held off (lookup stage empty)
 arrays out:  (previous read)                 fill set: valid, dirty, tags, lines
 decision  :  --                              victim = lowest invalid way,
                                                       else the LRU way
 writes    :  none                            tag (clean) + valid + full line
                                              + LRU (victim -> most recent)
 MSHR      :  --                              dirty victim -> mshr_wb_* ;
                                              mshr_fill_ready = 1
```

- **Victim choice.** An invalid way is always used first; the LRU order
  only decides in a full set. The victim is chosen at **fill** time, not
  at miss time, so the old line keeps serving hits while the miss is in
  flight.
- **Dirty victim writeback.** A valid, dirty victim is the only copy of
  its data. Its address is rebuilt as `{stored tag, fill set, 0}` from
  `tag_tag_out`, its data is the line the data SRAM returned for the
  fill set. It is handed over on `mshr_wb_*` on the **same edge** the new
  line is written — the MSHR captures it from the array outputs before
  the write commits.
- **Writeback queue full.** If a dirty victim meets
  `mshr_wb_ready = 0`, F1 simply repeats with nothing written. The
  victim cannot change meanwhile: the read port stays on the fill's set,
  the CPU is held off (no hit can write the set or reorder its LRU), and
  no other fill can be installed.
- **Fill selection change (restart).** The MSHR always presents its
  lowest-indexed completed entry, so an entry completing during F0 can
  displace the one whose set was read. The presented id is registered
  every cycle (`fill_id_q`); F1 writes only if it is unchanged. If not,
  nothing is written and the cycle acts as F0 for the new fill — whose
  set is already on the read port. A displaced fill cannot be displaced
  again by the same entry, so restarts are bounded by the entry count.
- **F0 deferral.** If a store hit in the lookup stage is writing the
  fill's set during F0, the read would return stale contents (no
  forwarding), so F0 waits one cycle. The CPU is already held off, so
  the lookup stage is empty next cycle and the deferral cannot repeat.

A store that missed is **not** merged into the fill: the fill always
writes a clean line, and the store is replayed through the normal hit
path, which writes the word and sets the dirty bit. (`mshr_fill_is_write`
is therefore not used.)

### Replay

On the fill's write edge, every occupied waiting-table slot whose MSHR id
equals the filled id is marked **ready** (`wait_ready`). Ready requests
are then re-issued one per cycle into the lookup stage, oldest first,
where they hit like any CPU request: a load returns its word, a store
writes its word and sets the dirty bit, the LRU order is updated, and
the response carries the request's own CPU id. The slot is freed at
issue — a replay is guaranteed to hit, so it can never return to the
table.

Example (test 17): three requests wait on line X — a store to word 1, a
load of word 1, a load of word 3 — and one on line Y. D = the edge X's
fill is accepted.

```
 edge  D+1  D+2  D+3  D+4  D+5  D+6  D+7  D+8
       R1   --   R2   R3   F0Y  F1Y  RY   CPU
       |         |    |              |
       |         |    +- load w3, filled data
       |         +------ load w1, sees R1's store
       +---------------- store w1 (writes set X at D+2 -> bubble)
```

- The bubble at D+2 is the read-after-write rule applied to replays: the
  replayed store writes set X in that cycle, so the next replay to set X
  waits.
- Y's fill waits until all of X's replays are issued (priority
  replay > fill), and the CPU waits for both.

---

## Internal structures and their cost

Default parameters; costs are flip-flop bits.

| Structure | Size | Purpose |
|---|---|---|
| Lookup shadow register `lookup_q` | 1 entry, ~101 bits | Carries the request's metadata alongside the registered array read |
| Response FIFO | 3 x 37 bits (id 4 + data 32 + we 1), plus pointers/count | Captures every hit result the cycle it appears |
| True-LRU ages `lru_age` | 64 sets x 4 ways x 2 bits = **512** | Recency order per set; victim choice |
| Waiting table `wait_mem` + `wait_valid` | 16 x 73 bits + 16 valid bits | Parks every missed request for replay |
| Age matrix `wait_older` | 16 x 16 = **256** | Arrival order of live waiting-table slots |
| `wait_ready` | 16 | Slot's line is installed; request awaits replay |
| Fill state `fill_busy`, `fill_id_q` | 1 + 4 | F0/F1 tracking and restart detection |

### Response FIFO — why 3 entries

The arrays cannot hold a result, so every hit must be captured the cycle
it appears, even while the CPU holds `resp_ready` low. `req_ready` is
computed from internal state only (no combinational path from
`resp_ready` to `req_ready`), so the depth must cover:

| Entry | Why it is needed |
|---|---|
| 1 | The head response, held while `resp_ready = 0` |
| 1 | The request already in the lookup stage — its result arrives next cycle regardless |
| 1 | The request accepted this cycle — `req_ready` cannot react to a same-cycle `resp_ready` drop |

Three entries sustain one response per cycle. Two would be correct but
insert a bubble after every second request (2/3 throughput); one would
reach 1/3.

### True LRU — age counters in flip-flops

Each way holds a 2-bit age (0 = most recently used, 3 = least). The four
ages of a set are always a permutation of 0..3. On an access to way W
with age `a_W`: W becomes 0, every way younger than W ages by one, the
rest are unchanged. The victim is the way with age 3. Reset sets the
order way 0 (youngest) .. way 3 (oldest); since invalid ways are filled
first, the initial order never matters.

Because the ages are flip-flops (not a registered-read array), the
read-modify-write finishes in the lookup cycle: a hit to the same set on
the next cycle already sees the update, so back-to-back same-set hits
need no stall. Updates come from a hit or from a fill (F1) — never both
in one cycle. The fill updates the order so a second fill to the same
set picks a different victim. A permutation check is asserted on every
update.

### Waiting table and age matrix

Each slot stores `{addr, we, wdata, id, mshr_id}`. It is built from
flip-flops because on a fill **every** slot must be compared against the
filling MSHR id in parallel, and several may match (merged requests).
`WAIT_DEPTH` defaults to `2**TXN_ID_WIDTH` = 16 — the maximum number of
distinct outstanding CPU requests — so the table never limits a CPU that
does not reuse an outstanding id.

Requests merged onto one line must replay in **arrival order** (a load
behind a store to the same word must see the store). Slot index is not
age — slots are freed and reused out of order — and a per-slot
timestamp could wrap, since one slot may wait indefinitely while others
turn over. The age matrix stores only the relative order of live slots:

- `wait_older[i][j] = 1` means slot j was allocated before slot i;
- on allocating slot i: row i ← `wait_valid` (everything live now is
  older), and column i is cleared in every row (the new occupant is
  younger than everything).

Bits involving free slots are stale but every reader masks them. The
replay selector picks the ready slot with no older ready slot — exactly
one exists (asserted one-hot).

---

## Request acceptance and priority

`req_ready` is high only when all of these hold:

| | Condition | Why |
|---|---|---|
| (a) | Response FIFO has room: `occupied + (lookup stage busy ? 1 : 0) < 3` | The lookup result cannot be held; it must find a free FIFO slot |
| (b) | Waiting table has room: `occupied + (lookup stage busy ? 1 : 0) < 16` | The request might miss, and a miss must find a free slot the same cycle |
| (c) | No read-after-write collision (see Hazards) | A same-set read on the store-hit write edge would return stale data |
| (d) | `mshr_fill_valid = 0` | A fill owns the array read ports, and in F1 the write ports and LRU update |
| (e) | No replay pending | Replays own the issue slot |

(a) and (b) count the request in the lookup stage as if it will consume
an entry, since its outcome is not yet known. This is conservative: with
15 slots occupied, a request behind an in-flight lookup waits one cycle
even if that lookup hits.

(b) also guarantees the **MSHR** can accept every miss: an MSHR entry is
busy only while some waiting-table slot refers to it (slots outlive their
entry — they are freed at replay, after the fill), so busy entries never
outnumber occupied slots. When a miss is allocated, at most 15 other
slots are occupied, so an MSHR entry is free. This needs
`WAIT_DEPTH <= 2**MSHR_ID_WIDTH`, which is checked at elaboration.

**Priority: replay > fill > CPU.**

- A pending replay drives the read port and blocks both a new fill
  (`fill_start`) and the CPU.
- Otherwise a presented fill owns the read port and blocks the CPU.
- Because no fill can start while replays are pending, nothing can evict
  a just-installed line before its waiters replay — which is why a
  replay always hits (asserted). Consecutive fills complete back to back,
  one per two cycles, and the CPU resumes once the MSHR has none left
  and no replays remain.

`req_ready` depends combinationally on `req_addr` (term c) and on
`mshr_fill_valid` (term d). Neither forms a loop: a valid/ready source
must not make its payload depend on ready, and the MSHR derives
`fill_valid` from its own entry state. Term (e) is registered state.

---

## Hazards and how each is handled

| Hazard | Handling |
|---|---|
| **Read-after-write** — a request reads the set a store hit is writing on the same edge, and would see the old line/dirty bit | The request is held one cycle (term c). Compared at **set** granularity, since the way is not known at issue. The same rule applies to replays (`replay_hazard`) and to the fill's F0 read (deferral). |
| **Fill vs. store hit** — both use the single write port of each array and the LRU update | Mutually exclusive by construction: the CPU is held while a fill is presented, so the lookup stage is empty in F1 (asserted). |
| **Fill read vs. pending store hit** — F0 would read stale contents | F0 deferred one cycle; cannot repeat. |
| **Fill selection change** — a lower MSHR entry completes during F0 | `fill_id_q` check; F1 writes nothing and restarts as F0 of the new fill. |
| **Victim stability during a writeback stall** | F1 repeats; read port fixed on the fill's set, CPU held, no other fill, so valid/dirty/LRU/victim cannot change. If the fill selection changes while waiting, `mshr_wb_valid` is withdrawn without a handshake — harmless, since the queue acts only on valid && ready. |
| **Replay ordering** — a load must see an earlier store to the same word | Oldest-first selection through the age matrix. Ready slots always belong to one line (no fill starts while any are pending), so this is that line's arrival order. |
| **MSHR id reuse** — the MSHR frees an entry on the fill-accept edge and may hand the same id to a new miss immediately | Waiters are marked ready **at fill time**, not by comparing ids later, so the old waiters cannot be confused with a new one. A request merged during F0 is already in the table; none can arrive in F1. |
| **Duplicate line in a set** | Prevented by allocation (a missing line is installed only by its own fill); asserted at fill time (fill tag must not already hit) and at every lookup (`hit_vec` one-hot). |
| **Re-miss to a line still queued for writeback** | Handled in the MSHR, not here: the re-miss's AXI read is held until the writeback's `B` response (see [`MSHR_README.md`](MSHR_README.md)). |

---

## Interface

`clk` and `rst_n` (active-low, **synchronous**) are inputs. Widths below
are at the default parameters.

### CPU

| Signal | Width | Dir | Meaning |
|---|---|---|---|
| `req_valid` | 1 | in | Request present |
| `req_ready` | 1 | out | Request accepted this edge if `req_valid` (see acceptance rule) |
| `req_addr` | 32 | in | Byte address |
| `req_we` | 1 | in | 1 = store, 0 = load |
| `req_wdata` | 32 | in | Store data |
| `req_id` | 4 | in | Transaction tag, echoed in the response |
| `resp_valid` | 1 | out | Response FIFO not empty |
| `resp_ready` | 1 | in | CPU accepts the head response |
| `resp_id` | 4 | out | Id of the request being answered (may be out of order) |
| `resp_data` | 32 | out | Load data (don't-care for a store ack) |
| `resp_we` | 1 | out | Echoes `req_we` |

### Tag array (`cache_tag_array`)

| Signal | Width | Dir | Meaning |
|---|---|---|---|
| `tag_rd_set_idx` | 6 | out | Set to read (issue source, or the fill's set) |
| `tag_lookup_tag` | 22 | out | Tag to compare (during a fill: the fill's own tag) |
| `tag_match` | 4 | in | Per-way raw tag match, one cycle later |
| `tag_dirty_out` | 4 | in | Per-way dirty bit, one cycle later |
| `tag_tag_out` | 22 x 4 | in | Per-way stored tag (dirty victim's writeback address) |
| `tag_wr_en` | 1 | out | Write: store hit or fill F1 |
| `tag_wr_set_idx` | 6 | out | Set to write |
| `tag_wr_way_sel` | 2 | out | Way to write (hit way or victim) |
| `tag_wr_tag` | 22 | out | Fill's tag (ignored on a store hit) |
| `tag_wr_tag_en` | 1 | out | 1 on a fill only |
| `tag_wr_dirty` | 1 | out | 1 on a store hit, 0 on a fill |
| `tag_wr_dirty_en` | 1 | out | Always 1 (both writers set the dirty bit) |

### Valid array (`cache_valid_array`)

| Signal | Width | Dir | Meaning |
|---|---|---|---|
| `valid_rd_set_idx` | 6 | out | Same set as the tag array |
| `valid_out` | 4 | in | Per-way valid bit, one cycle later |
| `valid_wr_en` | 1 | out | Fill F1 only |
| `valid_wr_set_idx` | 6 | out | Fill's set |
| `valid_wr_way_sel` | 2 | out | Victim way |
| `valid_wr_valid` | 1 | out | Always 1 — no path invalidates a line (an evicted way is refilled at once) |

### Data SRAM (`cache_data_sram`)

| Signal | Width | Dir | Meaning |
|---|---|---|---|
| `data_rd_set_idx` | 6 | out | Same set as the tag array |
| `data_rd_line` | 128 x 4 | in | All four ways' lines, one cycle later |
| `data_wr_en` | 1 | out | Store hit or fill F1 |
| `data_wr_set_idx` | 6 | out | Set to write |
| `data_wr_way_sel` | 2 | out | Way to write |
| `data_wr_word_en` | 4 | out | One-hot at the word (store hit) or all-ones (fill) |
| `data_wr_data` | 128 | out | Store word replicated x4, or the fill line |

### MSHR (`mshr`)

| Signal | Width | Dir | Meaning |
|---|---|---|---|
| `mshr_alloc_valid` | 1 | out | A miss is in the lookup stage this cycle |
| `mshr_alloc_addr` | 32 | out | Line-aligned miss address |
| `mshr_alloc_is_write` | 1 | out | The missing request is a store |
| `mshr_alloc_ready` | 1 | in | Entry free or matching — guaranteed by acceptance, only asserted |
| `mshr_alloc_id` | 4 | in | Entry id (new or merged), combinational, same cycle |
| `mshr_wb_valid` | 1 | out | Dirty victim presented (F1) |
| `mshr_wb_addr` | 32 | out | `{stored tag, fill set, 0}` |
| `mshr_wb_data` | 128 | out | Victim line from the data SRAM |
| `mshr_wb_ready` | 1 | in | Writeback queue has space |
| `mshr_wb_done` | 1 | in | Writeback completed — **currently unused** by the controller |
| `mshr_fill_valid` | 1 | in | A completed line is presented |
| `mshr_fill_id` | 4 | in | Entry id of the presented line |
| `mshr_fill_addr` | 32 | in | Line address (gives fill set and tag) |
| `mshr_fill_data` | 128 | in | The line |
| `mshr_fill_is_write` | 1 | in | OR of the merged requests' store flags — **unused**: stores are replayed, not merged into the fill |
| `mshr_fill_ready` | 1 | out | The line is written this edge (F1 completes) |

### Handshake rules

- **CPU:** standard valid/ready on both channels; a transfer happens on
  an edge where both are high. The payload of a held request must not
  depend on `req_ready`.
- **Arrays:** no handshake. Read address every cycle, result one cycle
  later; a write commits on the edge, a same-edge read sees the old
  value.
- **MSHR allocation:** `alloc_valid` is a single-cycle pulse per miss;
  the id is sampled on the same edge. No retry exists.
- **MSHR writeback:** valid/ready; `wb_valid` may be withdrawn without a
  transfer only on a fill restart.
- **MSHR fill:** valid/ready; the MSHR must keep a fill presented until
  `mshr_fill_ready` (asserted while in F1). `mshr_fill_ready` depends
  combinationally on `mshr_wb_ready`, which the MSHR derives from its
  queue occupancy alone, so no loop forms.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Address width |
| `DATA_WIDTH` | 32 | Word width |
| `NUM_WAYS` | 4 | Associativity |
| `WORDS_PER_LINE` | 4 | Words per line = AXI burst length |
| `NUM_SETS` | 64 | 4 KB / 4 ways / 16 B |
| `SET_IDX_WIDTH` | 6 | Set index bits |
| `WAY_WIDTH` | 2 | Way index bits |
| `WORD_OFF_WIDTH` | 2 | Word-within-line bits |
| `BYTE_OFF_WIDTH` | 2 | Byte-within-word bits |
| `TAG_WIDTH` | 22 | Tag bits |
| `LINE_WIDTH` | 128 | Line width |
| `MSHR_ID_WIDTH` | 4 | Matches `mshr.sv` `ID_WIDTH` (16 entries) |
| `TXN_ID_WIDTH` | 4 | CPU transaction-tag width |
| `WAIT_DEPTH` | 16 | Waiting-table slots (`2**TXN_ID_WIDTH`); must be `<= 2**MSHR_ID_WIDTH` |
| `WAIT_IDX_WIDTH` | 4 | Slot index bits |

---

## Key design decisions

| Decision | Why | Rejected alternative |
|---|---|---|
| Tagged, multi-outstanding CPU interface | Enables hit-under-miss and uses the MSHR's 16 entries | Single outstanding request — CPU stalls on every miss |
| One-cycle, set-granular read-after-write stall | Arrays do not forward; way is unknown at issue | Way/word-granular compare (not possible at issue time) |
| 3-entry response FIFO, `req_ready` from internal state only | Full throughput with no `resp_ready -> req_ready` path | 2 entries (2/3 throughput), 1 entry (1/3) |
| Store word replicated across lanes + one-hot word enable | No variable shifter on the write data path | Shifting the word into position |
| True LRU, age counters in flip-flops (512 bits) | Exact, simple, same-cycle update — no stall on back-to-back same-set hits | Ages in a registered-read array (would need a RAW stall); tree pseudo-LRU (only approximates LRU) |
| Invalid way first, then LRU | Never evict a valid line while a free way exists | LRU over all ways |
| Victim chosen at fill time | Old line keeps serving hits while the miss is in flight | Reserving the victim at miss time |
| MSHR allocation guaranteed by the acceptance rule, not by waiting on `alloc_ready` | The lookup stage cannot hold a request | Stalling the lookup stage on `alloc_ready` |
| Line-aligned allocation address | Misses to different words of a line merge in the MSHR | Full address (no merge) |
| Waiting table in flip-flops, 16 slots | Parallel compare of every slot on a fill, multiple matches | RAM-based table (one slot per cycle) |
| Age matrix (256 bits) for replay order | Exact arrival order of live slots; never wraps | Slot-index order (slots reused out of order); timestamps (wrap) |
| Ready marking at fill time | MSHR id may be reused on the fill-accept edge | Comparing ids at replay time |
| Store miss replayed through the hit path; fill writes a clean line | One store path for every store; dirty bit set by the hit path | Merging store data into the fill line |
| Priority replay > fill > CPU | Nothing can evict a line before its waiters replay, so a replay always hits | Fill or CPU ahead of replays (replay could miss) |
| Fill restart on selection change | Never writes a line using another set's read | Writing in F1 regardless of the presented id |
| Slot released at replay issue | A replay always hits, so it can never return to the table | Holding the slot until the replay's lookup completes |
| Conservative acceptance (count the in-flight lookup as consuming an entry) | Its outcome is not known when the next request is accepted; costs one cycle only near capacity | Exact accounting (not available at acceptance time) |

## Assertions in the RTL

Simulation-only (`ifndef SYNTHESIS`) checks: at most one way hits; LRU
ages stay a permutation; every MSHR allocation is accepted; a miss always
finds a free waiting-table slot; `WAIT_DEPTH <= 2**MSHR_ID_WIDTH`
(elaboration); a fill is not withdrawn during F1; the lookup stage is
empty in F1; a fill never duplicates a resident line; the response FIFO
never overflows; replay selection is one-hot; a replay always hits; no
replay is pending during F1.

---

## Verification

See `tb/cache_controller_tb.sv` — 19 tests (17 directed + 2
constrained-random), run under Questa (`./tools/sim/run.sh
cache_controller_tb`) or ModelSim ASE 18.1. The controller is also
verified together with the real MSHR by the system testbench
(`tb/cache_top_tb.sv`, see `docs/CACHE_TOP_README.md`).

### Methodology

- **Real arrays.** The DUT is wired to the already-verified
  `cache_tag_array`, `cache_valid_array` and `cache_data_sram`, so a
  failure points at the controller. A TB **preload mux** in front of
  each array's write port lets tests install lines directly.
- **MSHR stub and fill model.** The MSHR is not instantiated. An
  allocation stub returns the ids the real MSHR would (new id per line,
  same id on a merge, released when the fill is accepted; ids start at 5
  so an MSHR id cannot coincide with a slot index by accident). Fills are
  driven by an `mshr_fill` task or cycle by cycle, modelling the MSHR's
  lowest-index-first selection; `mshr_wb_ready` is TB-driven to model a
  full writeback queue. For test 19, an **automatic MSHR fill model**
  completes every new entry after a random delay from a golden memory
  image, presents the lowest-numbered completed entry (so restarts
  occur), writes handed-off dirty victims back to that memory, and drops
  `mshr_wb_ready` at random.
- **Scoreboard.** A reference model of every (set, way) — line, tag,
  valid, dirty and LRU ages — predicts each access, fill victim and
  replay; expected responses are compared against the logged ones.
- **Monitors.** Response, fill and writeback logs with edge indices;
  rule checks on every edge (no `fill_ready` without a fill, no CPU
  acceptance during a fill, a held writeback stays stable); a white-box
  miss counter cross-checked against the logged MSHR allocations; FIFO
  peak and held-response stability checks.
- **Out-of-order checker (test 19).** Each request's expected result is
  computed at acceptance from a flat reference memory, in acceptance
  order, and responses are matched by id, each exactly once. This is the
  CPU-visible contract: requests to a missing line all park and replay
  oldest-first, and nothing can overtake or evict the line before its
  replays.
- **Coverage and reproducibility.** The random tests enforce minimum
  counts of the events they exist for (read-after-write stalls; for
  test 19 also fills, restarts, clean and dirty evictions, writeback
  stalls, re-misses, merges, replays and replay holds) and print their
  seed (`+seed=<n>`).
- **Mutation testing.** Each group of tests was also run against
  deliberately broken RTL (for example: no read-after-write stall, fill
  and fill-restart mutants, four writeback mutants, six replay mutants)
  to confirm the tests fail — rather than pass or hang — on a broken
  design.

### Tests

| # | Test | What it shows |
|---|---|---|
| 1 | Reset sanity | Idle and ready after reset: no response, no array write, no MSHR request — checked every cycle of a window |
| 2 | Single load hit | Correct way/word, id and `we` echoed, exactly 2-cycle latency, no side effects |
| 3 | Every way x word of a full set | All 16 (way, word) loads hit with correct data among three valid competitors |
| 4 | Valid gating | Matching tag with valid = 0 misses (one line-aligned MSHR allocation); re-validated line hits with original data |
| 5 | Store hit | Ack, single masked word write, tag array dirty-only write, dirty 0 -> 1, neighbours untouched |
| 6 | Read-after-write stall | Same-set request behind a store waits exactly 1 cycle and sees the new data; no stall for other sets or load->load |
| 7 | Full throughput | 16 back-to-back hits accepted and answered one per cycle, all 16 ids |
| 8 | Response back-pressure | FIFO fills to 3 (incl. the request accepted in the drop cycle), held response stable, drains one per cycle |
| 9 | Constrained random, hits only | 500 loads/stores to resident lines with random back-pressure, in-order exact checks, RAW coverage floor, reproducible seed |
| 10 | LRU recency order | Hand-computed ages after each hit kind, back-to-back burst without stall, unchanged by a miss, victim = oldest way |
| 11 | Waiting-table contents | Every slot's fields (incl. merged MSHR ids) and the age matrix match issue order |
| 12 | Hit-under-miss | Eight hits served at full rate and exact latency among four pending misses, incl. same-set hits behind a store miss |
| 13 | Waiting table full | Conservative 1-cycle hold at 15 slots; 16th miss parked; full table holds off even a would-be hit |
| 14 | Fill into free ways, then LRU way | Two cycles per fill, tag/valid/line written together, free ways lowest-first, LRU way 2 replaced, CPU held during a fill |
| 15 | Fill restart | Fill displaced between F0 and F1 writes nothing; displacing fill installed next, displaced one after |
| 16 | Dirty-victim writeback | Clean victim not written back; dirty victim sent with own address and modified data on the fill edge; full queue holds F1 stable |
| 17 | Replay of one line's waiters | Arrival order (store, then load seeing it), 1-cycle bubble after a replayed store, own ids, only that line's waiters released, fills and CPU held |
| 18 | Slot reuse / age matrix | A reused lower slot replays after an older higher slot; the newer load returns the stored data |
| 19 | End-to-end random with automatic fills | ~3000 requests over 12 lines competing for 4 ways: hits, misses, merges, fills with restarts, clean and dirty evictions, writeback stalls, replays, back-pressure; results checked by id against a flat reference memory, every event above a coverage floor, readback of the whole footprint at the end; 30 seeds, 10 mutants |

### Not covered here

- Interaction with the real MSHR and AXI timing (out-of-order read
  data, a re-miss held behind its own writeback, AXI request stability)
  is verified at system level by `tb/cache_top_tb.sv`.
- Only the default parameter set is simulated.
