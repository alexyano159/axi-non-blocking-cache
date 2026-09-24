# `cache_tag_array.sv` — Cache Tag Array

## What it stores

4-way set-associative. Holds **only** the tag and dirty bit of every
cache line -- no valid bits, and no line data. Line data lives in the
separate `cache_data_sram`; valid bits live in the separate
`cache_valid_array`.

```
tag_mem[NUM_WAYS][NUM_SETS]     -- one TAG_WIDTH-bit tag per (way, set)
dirty_mem[NUM_WAYS][NUM_SETS]   -- one dirty bit per (way, set)
```

Modeled as two separate arrays, both banked by way, rather than one
combined struct-like array -- mirroring `cache_data_sram`'s per-way
bank layout so both arrays are indexed identically and read together
with matching latency.

## Who it talks to

```
Cache Controller  <---->  Cache Tag Array
```

The cache controller (not yet built) is the **only** client. It is
responsible for:
- ANDing this module's raw `tag_match` with the (separate) valid
  array's output to obtain the real hit/hit_way -- `tag_match` alone
  is meaningless for an entry that was never validly filled.
- Merging its two write sources (hit-write, fill-write) onto this
  module's single write port -- this module has no arbitration logic
  of its own.
- No direct connection to the MSHR -- fill data reaches this module
  only via the controller.

## Interface

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock. No reset pin -- see rationale below. |
| `rd_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to look up, presented every lookup cycle (load or store). |
| `lookup_tag` | `TAG_WIDTH` (22) | in | Tag to compare against all `NUM_WAYS` ways of the addressed set. |
| `tag_match` | `NUM_WAYS` (4), one bit per way | out | Raw, valid-agnostic per-way compare result, registered -- valid one cycle after `rd_set_idx`/`lookup_tag`. |
| `dirty_out` | `NUM_WAYS` (4), one bit per way | out | Each way's dirty bit, registered alongside `tag_match`. |
| `wr_en` | 1 | in | Master write enable. With this low, nothing changes regardless of the other write signals. |
| `wr_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to write. |
| `wr_way_sel` | `WAY_WIDTH` (2) | in | Way to write. |
| `wr_tag` | `TAG_WIDTH` (22) | in | New tag value; written only if `wr_tag_en` is also set. |
| `wr_tag_en` | 1 | in | Gates the tag field write independently of the dirty field. |
| `wr_dirty` | 1 | in | New dirty value; written only if `wr_dirty_en` is also set. |
| `wr_dirty_en` | 1 | in | Gates the dirty field write independently of the tag field. |

## Two write sources, one port

| Source | `wr_tag_en` | `wr_dirty_en` | When |
|---|---|---|---|
| Hit write | 0 | 1 | A store hits an already-resident line; only its dirty bit changes. |
| Fill write | 1 | 1 | The MSHR returns a line after a miss; tag and dirty are both set for the freshly allocated way. |

## Timing: registered compare, read-old-data on collision

Both the compare and write ports are synchronous (`always_ff`):
- **Compare:** `rd_set_idx`/`lookup_tag` are sampled on the clock edge;
  `tag_match`/`dirty_out` are valid the *following* edge -- matching
  `cache_data_sram`'s `rd_line` latency, so the controller can combine
  both arrays' results in the same cycle.
- **Collision:** a write to the same (way, set) on the same edge as a
  lookup is **not forwarded** -- the compare uses the pre-write
  (old) tag/dirty, matching typical single-port synchronous SRAM
  behavior. The write itself is never lost, only not visible until the
  next lookup.

## No reset

There is no `rst_n` on this module, for the same reason as
`cache_data_sram`: a real SRAM macro has no reset pin. Garbage tag/dirty
content in a never-filled entry is harmless, because the (separate)
valid array's reset guarantees that entry is never trusted until it is
written -- correctness after reset is that array's job, not this one's.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Full address width |
| `DATA_WIDTH` | 32 | Width of one word |
| `NUM_WAYS` | 4 | Set associativity |
| `WORDS_PER_LINE` | 4 | Words per cache line = AXI burst length (`LINE_WORDS` in `mshr.sv`) |
| `NUM_SETS` | 64 | 4 KB total / 4 ways / 16 B line |
| `SET_IDX_WIDTH` | `$clog2(NUM_SETS)` = 6 | Bits needed to index a set |
| `WAY_WIDTH` | `$clog2(NUM_WAYS)` = 2 | Bits needed to select a way |
| `TAG_WIDTH` | `ADDR_WIDTH - SET_IDX_WIDTH - WORD_OFF_WIDTH - BYTE_OFF_WIDTH` = 22 | Bits of address stored as the tag |

## Verification

See `tb/cache_tag_array_tb.sv` -- 8 directed tests, verified with
`iverilog`:

1. **Fill-write, matching lookup** -- the basic contract: a filled way
   reports a match with the correct dirty bit.
2. **Non-matching tag** -- a lookup with a different tag reports no
   hit, proving the comparator discriminates rather than always
   reporting a hit.
3. **Read/compare-write collision** -- a lookup issued on the same edge
   as a write to the identical (way, set) sees the pre-write tag/dirty;
   a follow-up lookup confirms the write completed, just wasn't
   forwarded.
4. **Hit-write gating (`wr_tag_en=0`)** -- a hit-write drives a
   deliberately mismatched, "poisoned" tag on the write bus; the
   follow-up lookup confirms the tag was never overwritten while dirty
   was updated.
5. **Tag-only write gating (`wr_dirty_en=0`)** -- the mirror image of
   test 4: a tag-only write drives a poisoned dirty value, confirming
   `wr_dirty_en` independently gates the dirty field.
6. **Way isolation** -- all four ways of a set are preloaded with
   distinct tags, only one is overwritten, and every way's own tag is
   looked up individually to confirm a one-hot `tag_match` -- proving
   both way isolation and genuine 4-way parallel compare.
7. **Set isolation** -- three sets (both edges of the address range,
   plus an interior set) are preloaded, only the interior one is
   overwritten, confirming the edges are untouched.
8. **`wr_en` gating** -- a fully-formed write request held with
   `wr_en=0` leaves the target location completely unchanged, closing
   the coverage hole every other test leaves open by always asserting
   `wr_en` when writing.

See `private_notes/VERIFICATION_PROBLEMS.txt` for a same-edge
`wr_en`-deassertion race hit while bringing test 1 up, and how it was
diagnosed and fixed.
