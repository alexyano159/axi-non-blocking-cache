# Cache & MSHR Structure Reference

## Module hierarchy

```
cache_top                      (rtl/cache_top.sv -- structural only)
├── u_controller   cache_controller   lookup, hit path, LRU ages, waiting table, miss/fill/replay sequencing
├── u_tag_array    cache_tag_array    tag + dirty bit, 4-way compare
│                    └── g_way[0..3].u_tag_bank          sram_sdp 64 x 22
├── u_valid_array  cache_valid_array  valid bit (only array with reset)
├── u_data_sram    cache_data_sram    128-bit line data
│                    └── g_way[0..3].g_word[0..3].u_bank sram_sdp 64 x 32
└── u_mshr         mshr               miss table + writeback FIFO + AR arbiter, AXI4 master
                     └── axi_if.master  (port of cache_top, to memory)
```

`sram_sdp` is a generic simple dual-port RAM (one read port, one write
port, registered read); after synthesis each instance is one block RAM.

The controller is the only client of the three arrays and of the MSHR;
the MSHR is the only block on the AXI bus. Wiring and port-group details:
[`CACHE_TOP_README.md`](CACHE_TOP_README.md).

---

## How does the MSHR know which memory block a miss/fill/writeback belongs to?

Short answer: **it never has to figure this out itself** — the cache
controller always hands it a complete, already-assembled address. The
MSHR just stores and forwards that address; it never receives a "tag
byte" on its own and never has to reconstruct one.

**Splitting an address into `[ TAG | SET | OFFSET ]` is purely an
internal trick the cache's tag array uses to organize its own storage for
fast lookup.** It doesn't change what the address *is* — those bits,
put back together, are still just the address of a block in main memory.

**On a miss** (`alloc_addr`): the controller already did the
tag/set/offset split to detect the miss in the first place. It just
drops the offset bits (rounding down to the start of the line) and hands
the MSHR that resulting full address. The MSHR stores it as-is in the
entry's `addr` field and later returns the exact same value, unchanged,
as `fill_addr`. No reconstruction needed — it was never taken apart.

**On a writeback** (`wb_addr`): when the replacement policy picks a way
to evict, the cache's tag array *already has that line's tag sitting
right there* — storing the tag is precisely what lets the array
reconstruct the original address later. The controller rebuilds the full
address as:

```
full_address = [ tag stored in that way's tag array entry ]
             + [ that line's set index ]
             + [ offset = 0, since a whole line is being written back ]
```

That reconstructed, complete address is what gets passed to the MSHR as
`wb_addr`. Again — a full address, not a fragment.

**Bottom line:** the MSHR only ever deals in complete addresses. Tag/set
decomposition happens entirely inside the cache controller/tag array,
both before a miss is sent to the MSHR and before a writeback is sent to
the MSHR — never inside the MSHR itself.

---

## Cache array structure (4-way set-associative)

Each entry (one "way" within one "set") holds:

| Field | Width | Purpose |
|---|---|---|
| `V` (valid) | 1 bit | Does this way currently hold real data? |
| `D` (dirty) | 1 bit | Has this line been written since it was fetched? Must be written back before eviction if set. |
| `Tag` | 22 bits* | The upper address bits — compared against the incoming tag to detect HIT/MISS. |
| `Data` | 128 bits | The actual cache line (4 × 32-bit words). |

*The real design uses **64 sets** (4 KB / 4 ways / 16 B per line), so
the address splits as `[ TAG: 22 | SET: 6 | OFFSET: 4 ]`. The matrix
below shrinks it to **8 sets** (`[ TAG: 25 | SET: 3 | OFFSET: 4 ]`) only
to keep it small enough to draw:

```
Address (32 bits) = [ TAG: 25 bits | SET: 3 bits | OFFSET: 4 bits ]
                                                    (4 bits -> 16 bytes/line)
```

The array as a matrix — rows are sets (selected directly by `SET INDEX`),
columns are ways (compared in parallel against `TAG`):

| Set \ Way | Way 0 | Way 1 | Way 2 | Way 3 |
|---|---|---|---|---|
| **Set 0** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 1** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 2** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 3** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 4** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 5** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 6** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |
| **Set 7** | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data | V,D,Tag,Data |

A lookup jumps straight to **one row** (via `SET INDEX`), then compares
`TAG` against the 4 cells in that row **in parallel**. That's the whole
mechanism — indexed across rows, associative (parallel) across columns.

Where each field physically lives:

| Field | Module | Storage |
|---|---|---|
| `V` | `cache_valid_array` | flip-flops (needs a reset) |
| `D` | `cache_tag_array` | flip-flops (256 bits) |
| `Tag` | `cache_tag_array` | 4 `sram_sdp` banks, one per way |
| `Data` | `cache_data_sram` | 16 `sram_sdp` banks, one per (way, word) |

### State held in the controller

| Structure | Size | Purpose |
|---|---|---|
| LRU ages (`lru_age`) | 4 × 2 bits per set = 8 bits × 64 sets, flip-flops | True-LRU rank of each way (0 = most recent, 3 = victim); read-modify-written in one cycle |
| Waiting table (`wait_mem`) | 16 slots × 73 bits (address 32, store flag 1, store data 32, CPU id 4, MSHR id 4) + a valid bit per slot | Requests that missed, parked until their line's fill, then replayed through the hit path |
| Age matrix (`wait_older`) | 16 × 16 bits | `wait_older[i][j] = 1` if slot j was parked before slot i, so replays go out oldest first even when slots are reused |

---

## MSHR structure (fully associative, 16 entries)

Unlike the cache, there's no set/way split here — every entry is
addressed directly by its own index (which doubles as the AXI ID), and a
lookup compares the incoming address against **every row at once**.

| Field | Width | Purpose |
|---|---|---|
| `Addr` | 32 bits | Full line address being fetched (compared against every new miss to detect a merge; only occupied entries, i.e. not `FE_IDLE`, can match). |
| `IsWrite` | 1 bit | Was any access to this line (the original miss or any merged one) a store? Returned as `fill_is_write`. |
| `State` | 2 bits | `FE_IDLE` → `FE_REQ` → `FE_DATA` → `FE_DONE` → back to `FE_IDLE`. `FE_REQ` → `FE_DATA` happens only when the entry's `AR` is accepted, and an entry whose `WbWait` is non-zero is not offered to the AR arbiter. `FE_IDLE` doubles as the "entry free" flag, so no separate valid bit is stored. |
| `BeatCnt` | 2 bits | How many of the 4 burst beats have arrived. |
| `LineBuf` | 128 bits | The line being assembled beat-by-beat; becomes `fill_data`. |
| `WbWait` (`fe_wb_wait`) | 4 bits | Writeback-queue slots this entry's read must wait for (a re-miss to a line still being written back). |

The table as a matrix — rows are entries (= AXI IDs), columns are the
fields above:

| Entry (= AXI ID) | Addr | IsWrite | State | BeatCnt | LineBuf |
|---|---|---|---|---|---|
| 0 | | | | | |
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| ... | | | | | |
| 15 | | | | | |

A lookup on a new miss address compares it against the `Addr` column of
**all 16 rows simultaneously** — there is no indexing step at all, which
is exactly what makes it "fully associative" rather than "set-associative."

### Other MSHR state

| Structure | Size | Purpose |
|---|---|---|
| Writeback FIFO | 4 slots × (32-bit address + 128-bit line), head/tail pointers, count | Dirty victims waiting for the write channel |
| Writeback FSM | `WB_IDLE` → `WB_AW` → `WB_DATA` → `WB_WAIT_B` | Drains the FIFO one victim at a time (`AW`, 4 `W` beats, then `B`) |
| AR round-robin pointer (`ar_last_grant`) | 4 bits | Last entry granted the read-address channel |
| AR grant lock (`ar_lock`, `ar_lock_idx`) | 1 + 4 bits | Keeps presenting the same entry while `arvalid` waits for `arready` (AXI request stability) |

Details and rationale: [`MSHR_README.md`](MSHR_README.md).
