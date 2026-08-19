# `cache_valid_array.sv` — Cache Valid Array

## What it stores

4-way set-associative. Holds **only** the valid bit of every cache
line -- no tag, no dirty bit, no line data. Tag and dirty live in the
separate `cache_tag_array`; line data lives in the separate
`cache_data_sram`.

```
valid_mem[NUM_WAYS][NUM_SETS]   -- one valid bit per (way, set)
```

Modeled as one array banked by way, mirroring `cache_tag_array`'s and
`cache_data_sram`'s per-way bank layout so all three arrays are indexed
identically and read together with matching latency.

## Who it talks to

```
Cache Controller  <---->  Cache Valid Array
```

The cache controller (not yet built) is the **only** client. It is
responsible for:
- ANDing this module's `valid_out` with `cache_tag_array`'s raw
  `tag_match` to obtain the real hit/hit_way -- `tag_match` alone is
  meaningless for an entry that was never validly filled.
- Driving this module's write port on a fill (mark the newly allocated
  way valid) or an explicit invalidate (mark a way no longer resident).
- No direct connection to the MSHR -- fill/invalidate requests reach
  this module only via the controller.

## Interface

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock. |
| `rst_n` | 1 | in | Active-low synchronous reset. Clears every `(way, set)` entry to invalid. |
| `rd_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to look up, presented every lookup cycle (load or store), in parallel with the identical index sent to `cache_tag_array`. |
| `valid_out` | `NUM_WAYS` (4), one bit per way | out | Each way's valid bit for the addressed set, registered -- valid one cycle after `rd_set_idx` is presented. |
| `wr_en` | 1 | in | Master write enable. With this low, nothing changes regardless of the other write signals. |
| `wr_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to write. |
| `wr_way_sel` | `WAY_WIDTH` (2) | in | Way to write. |
| `wr_valid` | 1 | in | New valid value: `1` on a fill, `0` on an explicit invalidate. |

## Two write sources, one port

| Source | `wr_valid` | When |
|---|---|---|
| Fill write | 1 | The MSHR returns a line after a miss; the controller marks the freshly allocated way valid. |
| Invalidate | 0 | The controller clears a way's valid bit without touching its tag/dirty/data -- those become don't-care until the way is refilled. |

Unlike `cache_tag_array`, there is no `wr_valid_en`: this module stores
only one field, so `wr_en` alone gates the write -- no separate enable
is needed to distinguish "write this field" from "don't."

## Timing: registered read, read-old-data on collision

Both the read and write ports are synchronous (`always_ff`):
- **Read:** `rd_set_idx` is sampled on the clock edge; `valid_out` is
  valid the *following* edge -- matching `cache_tag_array`'s registered
  compare and `cache_data_sram`'s registered read, so the controller
  can combine all three arrays' results in the same cycle.
- **Collision:** a write to the same `(way, set)` on the same edge as a
  read is **not forwarded** -- the read returns the pre-write (old)
  valid bit, matching the read-old-data collision behavior of the tag
  array and data SRAM. The write itself is never lost, only not visible
  until the next lookup.

## Synchronous reset

This is the only one of the three cache arrays (`cache_valid_array`,
`cache_tag_array`, `cache_data_sram`) that has a reset pin. The other
two are deliberately built without one, on the grounds that a real
SRAM macro has no reset pin -- garbage tag/dirty/data content in a
never-filled entry is harmless *only because* this array's reset
guarantees that entry is never trusted until it is written. Correctness
after reset is entirely this module's responsibility.

This is feasible because the valid array is small enough
(`NUM_WAYS * NUM_SETS` = 256 bits) to be built from flip-flops rather
than mapped onto a real SRAM macro, so a synchronous reset that clears
every entry in a single cycle is realistic to synthesize.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `NUM_WAYS` | 4 | Set associativity |
| `NUM_SETS` | 64 | 4 KB total / 4 ways / 16 B line |
| `SET_IDX_WIDTH` | `$clog2(NUM_SETS)` = 6 | Bits needed to index a set |
| `WAY_WIDTH` | `$clog2(NUM_WAYS)` = 2 | Bits needed to select a way |

## Verification

Not yet written -- see `tb/cache_valid_array_tb.sv` once it exists.
