# `mshr.sv` — Miss Status Holding Register

## What this file is, and why a non-blocking cache needs it

**MSHR = Miss Status Holding Register.**

It's the "ledger" that tracks which cache misses are currently being
fetched from main memory. Without it, the moment a miss happens the
whole pipeline would have to stop and wait for memory to answer before
it could do anything else — that's a **blocking cache**.

With an MSHR, the cache can be **non-blocking**: it can keep accepting
new requests while an earlier miss is still in flight, and — critically —
it can recognize when two different requests are actually asking for the
*same* cache line, and avoid sending memory two copies of the same
request.

The MSHR is also the only AXI master in this design: it is the module
that actually talks to memory over `axi_if`, both to fetch a missing
line and to write back a dirty line that got evicted.

## Where the MSHR sits in the HIT/MISS path

The MSHR does **not** decode the address into tag/set/offset itself —
that decoding is the cache controller's job, and it happens *before* the
MSHR is ever involved:

```
CPU address
    |
    v
Cache Controller: splits the address into [ tag | set index | offset ]
    |
    v
Tag array lookup for that set, compare against the stored tag
    |
    +-- HIT  --> done immediately. The MSHR is never touched.
    |
    +-- MISS --> controller hands the MSHR the full line address
                 (offset bits dropped -- misses are tracked per
                 cache line, not per byte)
```

So by the time `alloc_addr` reaches the MSHR, the hit/miss decision has
already been made. The MSHR only ever sees addresses that already
missed.

## Why the MSHR is fully associative, while the cache is set-associative

The cache's tag array is **set-indexed**: a given address can only ever
live in one specific set, so the hardware only ever checks the tags in
that one set. This keeps the tag compare cheap.

The MSHR cannot do that. A new miss can arrive for *any* address, so to
answer "is this line already being fetched?" the MSHR must compare the
new address against **every** valid entry at once (parallel comparators,
i.e. a small content-addressable table), not just one indexed slot. This
is the reason the MSHR entry count is tied to `ID_WIDTH` (16 entries)
rather than to the number of cache sets.

## What each MSHR entry actually stores

There is one entry per possible AXI ID (`NUM_ENTRIES = 2**ID_WIDTH` =
16 by default). The entry's index **is** its AXI ID — no separate ID
field is needed.

| Field | Width | Purpose |
|---|---|---|
| `valid` | 1 bit | Is this entry currently tracking an in-flight miss? |
| `addr` | `ADDR_WIDTH` = 32 bits | Line address being fetched. Compared against every new `alloc_addr` to detect a secondary miss to the same line. |
| `is_write` | 1 bit | Was the original miss caused by a store? Forwarded later as `fill_is_write`. |
| `state` | ~3 bits | Small per-entry FSM: waiting on a victim writeback → AXI read request outstanding → burst data arriving → line complete, ready to present. |
| `line_buf` | `LINE_WIDTH` = 128 bits | Accumulates the incoming AXI burst beats (`rdata`) one at a time until the full line has arrived. Becomes `fill_data` once complete. |
| `beat_cnt` | 2 bits | Counts how many of the 4 burst beats have arrived so far (equivalently, waits for `rlast`). |

**Per-entry overhead:** roughly 1 + 32 + 1 + 3 + 128 + 2 = **167 bits**.
**Total table overhead:** 167 bits × 16 entries ≈ **2,672 bits (≈ 334 bytes)**
of storage dedicated purely to miss tracking — the price paid for turning
a blocking cache into a non-blocking one.

> Note: the MSHR does **not** store *who* asked for the line (e.g. which
> pipeline register or load-queue entry). Once `fill_valid` fires and the
> line lands in the data array, any instruction that was stalled on it
> simply re-checks the cache and gets a normal hit. Tracking individual
> requesters is the cache controller/load-queue's job, not the MSHR's —
> this keeps the MSHR itself simple: a tracker of in-flight *lines*, not
> a queue of individual *requests*.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Address width |
| `DATA_WIDTH` | 32 | Width of one word |
| `ID_WIDTH` | 4 | Bits of AXI ID → number of MSHR entries = `2**ID_WIDTH` |
| `LINE_WORDS` | 4 | Words per cache line = AXI burst length |
| `LINE_WIDTH` | `DATA_WIDTH * LINE_WORDS` = 128 | Full cache line width, in bits |
| `NUM_ENTRIES` | `2**ID_WIDTH` = 16 | Number of misses that can be in flight at once |

## Ports, grouped by who talks to whom

### Group 1 — Miss allocation (Cache Controller → MSHR)
Fires the cycle the controller detects a MISS.

| Signal | Dir | Meaning |
|---|---|---|
| `alloc_valid` | in | "This address just missed, track it." |
| `alloc_addr` | in | The line address that missed. |
| `alloc_is_write` | in | 1 = the miss was caused by a store, 0 = a load. |
| `alloc_ready` | out | 0 only when every entry is full **and** the address doesn't match any pending entry — controller must stall. |
| `alloc_id` | out | Entry index assigned to this miss (also the AXI ID used on the bus). |

### Group 2 — Victim writeback (Cache Controller → MSHR)
Fires when a dirty line is evicted and must be flushed to memory.

| Signal | Dir | Meaning |
|---|---|---|
| `wb_valid` | in | "Here's a dirty line, write it back." |
| `wb_addr` | in | Victim line address. |
| `wb_data` | in | Victim line's full data. |
| `wb_ready` | out | 0 when the writeback queue is full — controller must stall the eviction. |
| `wb_done` | out | Pulses once the AXI `B` response confirms the write landed. |

### Group 3 — Fill completion (MSHR → Cache Controller / data array)
Fires once an AXI read burst has been fully reassembled into a line.

| Signal | Dir | Meaning |
|---|---|---|
| `fill_valid` | out | "Here is a completed line." |
| `fill_id` | out | Which entry completed (matches the earlier `alloc_id`). |
| `fill_addr` | out | Address of the completed line. |
| `fill_data` | out | The reassembled line (all 4 beats concatenated). |
| `fill_is_write` | out | Pass-through of `alloc_is_write` — tells the controller to merge the pending store data and mark the line dirty. |
| `fill_ready` | in | 1 = the data array can accept the fill this cycle. |

### Group 4 — Memory side
| Signal | Dir | Meaning |
|---|---|---|
| `axi` (`axi_if.master`) | — | All five AXI channels bundled together. The MSHR drives this to fetch new lines (AR/R) and to write back evicted dirty lines (AW/W/B). |

## Full workflow, start to finish

1. A **MISS** is detected by the cache controller → `alloc_valid` +
   `alloc_addr` are asserted.
2. The MSHR checks: does an entry already track this exact line?
   - Yes → **merge** into that entry (secondary miss / hit-under-miss).
   - No, and a slot is free → open a **new** entry, return `alloc_id`.
   - No free slot and no match → `alloc_ready = 0`, controller stalls.
3. If the line being replaced is dirty, the controller issues
   `wb_valid`/`wb_addr`/`wb_data`; the MSHR writes it back over AXI
   (AW/W) and confirms with `wb_done` once the `B` response returns.
4. The MSHR issues an AXI read request (AR) for the new line.
5. Memory returns the 4 burst beats over the R channel (`rlast` marks
   the final beat).
6. The MSHR reassembles the beats into `line_buf` and asserts
   `fill_valid` + `fill_data`.
7. The controller accepts (`fill_ready = 1`) and writes the line into
   the data array. Every request that had been merged into this entry —
   primary and secondary alike — is now satisfied by a normal re-check
   of the cache.
8. The entry is freed and can service the next miss.
