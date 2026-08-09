# `mshr.sv` — Miss Status Holding Register

## Who it talks to

```
Cache Controller  <---->  MSHR  <---->  Main Memory
```

The MSHR is the *only* thing in this design allowed to talk to memory.
The cache controller never touches AXI directly — it always goes through
the MSHR, for both directions:

- **Reads (misses):** controller tells the MSHR "this line is missing,
  go get it" → MSHR fetches it over AXI and hands the finished line back.
- **Writes (victim writebacks):** controller tells the MSHR "this dirty
  line got evicted, flush it" → MSHR writes it out over AXI.

## How a miss is handled — step by step

The MSHR never makes the hit/miss decision itself — the controller
already did the tag compare and only calls the MSHR once it knows it's a
miss. From there:

**Read miss:**
1. Controller asserts `alloc_valid` + `alloc_addr` (`alloc_is_write = 0`).
2. MSHR checks: is any entry already fetching this exact address?
   - **Yes** → merge into it (`alloc_id` = that entry's index). No new
     AXI traffic — this is the hit-under-miss case.
   - **No, and a slot is free** → open a new entry, issue an AXI read
     burst (`AR`/`R`) for the line.
   - **No slot free either** → `alloc_ready = 0`, controller stalls.
3. Memory streams back 4 beats on `R`; the MSHR reassembles them.
4. `fill_valid` + `fill_data` are presented to the controller, which
   writes the line into the data array. Every access that had merged
   into this entry is now satisfied by simply re-checking the cache.

**Write miss:** identical flow, except `alloc_is_write = 1`. The MSHR
doesn't do anything differently for a store — it just remembers the flag
and hands it back as `fill_is_write`, so the *controller* knows to merge
the pending store data into the line and mark it dirty once it arrives.
(If a read and a write both merge into the same entry, `fill_is_write`
ends up `1` — a store anywhere in the merge chain means the line must
come back dirty.)

**Eviction (runs alongside a miss, not instead of it):** if the
controller had to kick out a dirty line to make room for the incoming
one, it *also* asserts `wb_valid`/`wb_addr`/`wb_data` that same cycle.
This is entirely independent of the miss's `AR`/`R` traffic — see the
writeback section below.

## What data moves where, and on which AXI channel

| Step | Direction | Signals | AXI channel |
|---|---|---|---|
| Miss reported | Controller → MSHR | `alloc_valid/addr/is_write` | *(none — internal handshake)* |
| Fetch issued | MSHR → Memory | line address | `AR` |
| Line returned | Memory → MSHR | 4 data beats | `R` |
| Fill handed off | MSHR → Controller | `fill_valid/id/addr/data/is_write` | *(none — internal handshake)* |
| Victim handed to MSHR | Controller → MSHR | `wb_valid/addr/data` | *(none — internal handshake)* |
| Victim address sent | MSHR → Memory | victim address | `AW` |
| Victim data sent | MSHR → Memory | 4 data beats | `W` |
| Write confirmed | Memory → MSHR | response | `B` |
| Writeback confirmed | MSHR → Controller | `wb_done` pulse | *(none — internal handshake)* |

## Writeback: why serialized, not pipelined

A **victim** is the line the replacement policy kicks out to make room
for an incoming miss. If it's dirty (written to since it was fetched),
its data must reach memory before it's gone for good — that's the
writeback. The MSHR queues incoming victims in a small FIFO
(`WB_QUEUE_DEPTH`) and drains them **one at a time**: finish victim #1's
entire `AW → W → B` sequence before starting victim #2.

Why not let several be in flight at once:

- Nothing in the pipeline is stalled waiting on a writeback — the cache
  slot is already free the moment the controller reads the old data out.
  Writebacks are off the latency-critical path.
- AXI4's write-data channel (`W`) carries no ID, so even with multiple
  writes outstanding, their data beats still can't be interleaved — you'd
  only be overlapping the `AW`/`B` round trips, not the actual transfer.
- The gain is small; the cost isn't — pipelining would need its own
  per-slot state array and an ID pool, doubling the amount of logic (and
  verification surface) for a part of the design that isn't performance
  critical.

## The AR arbiter: why round-robin, not fixed-priority

Up to 16 entries can be waiting to issue a read (`AR`) in the same cycle,
but only one `AR` can actually go out. Something has to pick a winner.

- **Fixed-priority** (lowest entry index always wins): a simple
  first-set-bit encoder. **The problem:** if entry 0 happens to be
  requesting on every cycle it gets a chance, entries 1–15 could wait
  behind it indefinitely — there's no guarantee a high-index entry ever
  gets serviced under sustained pressure.
- **Round-robin** (what this design uses): remembers who won last
  (`ar_last_grant`) and always prefers the next-higher index above it,
  wrapping back to the start if nobody higher is asking. Whoever just won
  moves to the back of the line. This guarantees every requesting entry
  is serviced within `NUM_ENTRIES` grants — no entry can be starved out,
  no matter how the others behave.

The fill-completion handoff (which finished entry gets presented to the
controller this cycle) still uses plain fixed-priority — that choice
doesn't gate access to memory bandwidth, it only decides who waits one
extra cycle to be handed off, so starvation isn't a real risk there.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Address width |
| `DATA_WIDTH` | 32 | Width of one word |
| `ID_WIDTH` | 4 | Bits of AXI ID → number of MSHR entries = `2**ID_WIDTH` |
| `LINE_WORDS` | 4 | Words per cache line = AXI burst length |
| `LINE_WIDTH` | `DATA_WIDTH * LINE_WORDS` = 128 | Full cache line width, in bits |
| `NUM_ENTRIES` | `2**ID_WIDTH` = 16 | Number of misses that can be in flight at once |
| `WB_QUEUE_DEPTH` | 4 | Victims that can be queued awaiting the write channel |
