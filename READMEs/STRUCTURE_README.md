# Cache & MSHR Structure Reference

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
| `Tag` | 25 bits* | The upper address bits — compared against the incoming tag to detect HIT/MISS. |
| `Data` | 128 bits | The actual cache line (4 × 32-bit words). |

*Example only — actual tag width depends on the final number of sets,
which isn't decided yet. The example below uses **8 sets** just to make
the matrix concrete:

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

---

## MSHR structure (fully associative, 16 entries)

Unlike the cache, there's no set/way split here — every entry is
addressed directly by its own index (which doubles as the AXI ID), and a
lookup compares the incoming address against **every row at once**.

| Field | Width | Purpose |
|---|---|---|
| `Valid` | 1 bit | Is this entry currently tracking an in-flight miss? |
| `Addr` | 32 bits | Full line address being fetched (compared against every new miss to detect a merge). |
| `IsWrite` | 1 bit | Was the original miss a store? |
| `State` | ~3 bits | `WAIT_WB` → `REQ` → `DATA` → `DONE` |
| `BeatCnt` | 2 bits | How many of the 4 burst beats have arrived. |
| `LineBuf` | 128 bits | The line being assembled beat-by-beat; becomes `fill_data`. |

The table as a matrix — rows are entries (= AXI IDs), columns are the
fields above:

| Entry (= AXI ID) | Valid | Addr | IsWrite | State | BeatCnt | LineBuf |
|---|---|---|---|---|---|---|
| 0 | | | | | | |
| 1 | | | | | | |
| 2 | | | | | | |
| 3 | | | | | | |
| ... | | | | | | |
| 15 | | | | | | |

A lookup on a new miss address compares it against the `Addr` column of
**all 16 rows simultaneously** — there is no indexing step at all, which
is exactly what makes it "fully associative" rather than "set-associative."
