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
2. MSHR checks: does any occupied entry (still fetching, or finished but
   not yet handed back) already hold this exact address?
   - **Yes** → merge into it (`alloc_id` = that entry's index). No new
     AXI traffic — this is a secondary miss (also called an MSHR hit).
   - **No, and a slot is free** → open a new entry, issue an AXI read
     burst (`AR`/`R`) for the line. If that line is still waiting in
     the writeback queue, the read is held until the write completes
     (see "Read-after-write ordering" below).
   - **No slot free either** → `alloc_ready = 0`, controller stalls.
3. Memory streams back 4 beats on `R`; the MSHR reassembles them.
4. `fill_valid` + `fill_data` are presented to the controller; once it
   accepts with `fill_ready`, it writes the line into the data array and
   the entry frees that same cycle (until then it stays parked in
   `FE_DONE`, still occupied). Every access that had merged
   into this entry is now satisfied by simply re-checking the cache.

**Write miss:** identical flow, except `alloc_is_write = 1`. The MSHR
doesn't do anything differently for a store — it just ORs the flag of
every access merged into the entry and reports it as `fill_is_write`.
The controller does **not** use that flag: it installs every fill
clean, keeps the store (its data and word) in its waiting table, and
replays it through the normal hit path once the line is installed,
which writes the word and marks the line dirty. (`fill_is_write` is
kept as a port so a controller that merges stores at fill time could
use it; `cache_controller` takes it as an input and ignores it.)

**Eviction (happens at fill time, not at miss time):** the victim way is
only chosen when the fetched line comes back, so the old line keeps
serving hits while the miss is in flight. If that victim is dirty, the
controller hands it over on `wb_valid`/`wb_addr`/`wb_data` as part of
installing the fill. This writeback is entirely independent of the
`AR`/`R` traffic — see the writeback section below.

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

## Read-after-write ordering: a re-miss waits for its own writeback

**The problem:** a dirty line X is evicted and sits in the writeback
queue. Shortly after, the CPU asks for X again, which is now a miss. AXI
does **not** order a read against an earlier write to the same
address, so the new read of X could reach memory before the write does,
and return the **old** data.

**The fix (hold the read):**
- When a new entry is opened, its line address is compared against
  every busy writeback-queue slot, and against a victim being pushed
  into the queue in that same cycle (4 compares). The matching slots are
  stored in the entry's wait mask (`fe_wb_wait`, one bit per slot).
- An entry with any bit set stays in `FE_REQ` but is **not offered to
  the AR arbiter**.
- When a writeback finishes (its `B` response arrives), that slot's bit
  is cleared in every entry. Once the mask is empty, the read goes out
  normally.

**Why checking once, at allocation, is enough:** a line can only be
evicted while it's in the cache, and while it's in the cache every
access to it hits. So X's writeback is always queued *before* any new
miss to X can exist.

**Why slots, not a counter:** a slot can be freed and reused by an
unrelated writeback. Remembering *which* slots to wait for means a
reused slot is never mistaken for the one being waited on.

**Cost:** 4 address compares plus a 4-bit mask per entry. Only the rare
re-miss to a just-evicted dirty line is delayed, by at most
`WB_QUEUE_DEPTH` writebacks. The miss itself is never stalled, which
matters because the controller can't hold a detected miss.

**Rejected alternative:** forward the line straight from the writeback
queue. It's faster, but needs a 128-bit datapath into the line buffer
and a "newest match" picker, all for a rare case.

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

**Grant lock.** AXI does not let a master change its mind: once `arvalid`
is high, the request (`arid`, `araddr`, ...) must stay exactly the same
until the memory says `arready`. The round-robin pick is recomputed every
cycle, and a new entry can start requesting while another one is waiting
for `arready` — without protection, the pick (and so `arid`/`araddr`)
would jump to the newcomer. So the MSHR remembers "I presented entry N
last cycle and it was not accepted" (`ar_lock`, `ar_lock_idx`) and keeps
presenting entry N until it is accepted; round-robin resumes after that.
This was found by the system testbench (`cache_top_tb`), whose AXI
memory model checks that every request stays stable while it waits.

The fill-completion handoff (which finished entry gets presented to the
controller this cycle) still uses plain fixed-priority — that choice
doesn't gate access to memory bandwidth, it only decides who waits one
extra cycle to be handed off, so starvation isn't a real risk there.

## Interface

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock |
| `rst_n` | 1 | in | Active-low synchronous reset |
| `alloc_valid` | 1 | in | Controller is reporting a miss |
| `alloc_addr` | `ADDR_WIDTH` (32) | in | Line-aligned address that missed |
| `alloc_is_write` | 1 | in | 1 = the access that missed was a store |
| `alloc_ready` | 1 | out | 0 = no free entry and no in-flight entry to merge with |
| `alloc_id` | `ID_WIDTH` (4) | out | Entry index / AXI ID given to this miss (the existing entry on a merge) |
| `wb_valid` | 1 | in | Controller is handing off a dirty victim |
| `wb_addr` | `ADDR_WIDTH` (32) | in | Victim line address |
| `wb_data` | `LINE_WIDTH` (128) | in | Victim line data |
| `wb_ready` | 1 | out | 0 = writeback queue full |
| `wb_done` | 1 | out | One-cycle pulse when a writeback's `B` response arrives |
| `fill_valid` | 1 | out | A completed line is presented |
| `fill_id` | `ID_WIDTH` (4) | out | Entry that completed |
| `fill_addr` | `ADDR_WIDTH` (32) | out | Address of the completed line |
| `fill_data` | `LINE_WIDTH` (128) | out | Reassembled line, all 4 beats |
| `fill_is_write` | 1 | out | OR of `alloc_is_write` over every merged access (unused by `cache_controller`) |
| `fill_ready` | 1 | in | Controller accepts the fill this cycle; the entry frees on that edge |
| `axi` | `axi_if.master` | — | AXI4 master port: `AR`/`R` for fills, `AW`/`W`/`B` for writebacks |

**Caller contract.** A miss must not merge into an entry on the same edge
that entry's fill is accepted (`alloc_valid` matching the entry while
`fill_valid && fill_ready` for it). The entry is freed on that edge, so
the merged access would be lost. The MSHR does not guard against this;
the controller guarantees it, because it accepts a fill only in its F1
cycle, when its lookup stage is empty and no miss can be reported
(asserted in `cache_controller.sv`).

**Error responses.** `rresp` and `bresp` are not checked: an AXI error
response (`SLVERR`/`DECERR`) is treated as success.

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

## Verification

See `tb/mshr_tb.sv` — 14 directed tests, run against an AXI4 memory
model on the same `axi_if`:

1. **Reset sanity** — no entry busy, queue empty, nothing asserted.
2. **Single read miss → fill** — one `AR` burst, 4 beats reassembled, line handed back.
3. **Single write miss → fill** — same flow, `fill_is_write = 1`.
4. **Secondary-miss merge** — a second miss to an in-flight line joins its entry; no second `AR`.
5. **Single victim writeback** — `AW`/`W`/`B` sequence with the right address and data; `wb_done` pulse.
6. **MSHR full** — all 16 entries busy → `alloc_ready = 0` → recovery once one frees.
7. **Round-robin AR arbitration** — piled-up requests granted in round-robin order, with the grant lock held while `arready` is low.
8. **Writeback queue full** — `wb_ready = 0` at 4 queued victims → recovery.
9. **Fill-completion mux order** — several finished entries handed back in fixed-priority order.
10. **Concurrent fill + writeback** — read and write engines progress independently on their own channels.
11. **Multi-way merge** — four accesses (load/store/load/load) share one entry; the dirty flag set mid-sequence survives.
12. **Entry reuse** — a freed entry's new, unrelated miss does not inherit the old dirty flag.
13. **Reset mid-fetch** — no stale merge target remains; a fresh miss issues a real burst.
14. **Re-miss behind its own writeback** — the read waits for the write's `B` response and returns the written-back data; an unrelated miss is not held.
