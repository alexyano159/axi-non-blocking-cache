# `cache_tag_array.sv` — Cache Tag Array

## What it stores

4-way set-associative. Holds **only** the tag and dirty bit of every
cache line -- no valid bits, and no line data. Line data lives in the
separate `cache_data_sram`; valid bits live in the separate
`cache_valid_array`.

```
g_way[w].u_tag_bank             -- 4 sram_sdp banks, each NUM_SETS x TAG_WIDTH (64 x 22)
dirty_mem[NUM_WAYS][NUM_SETS]   -- one dirty bit per (way, set), in flip-flops
```

- **Tags** live in one `rtl/sram_sdp.sv` bank per way, all sharing the
  read address -- the same per-way layout as `cache_data_sram`, so both
  arrays are indexed identically and read together with matching
  latency. After synthesis each bank is one M10K block.
- **Dirty bits** stay in flip-flops: 256 bits in total, not worth four
  block RAMs. They are also written on their own (by every store hit),
  without the tag.

## Who it talks to

```
Cache Controller  <---->  Cache Tag Array
```

The cache controller (`rtl/cache_controller.sv`) is the **only**
client; it reaches this module through its `tag_`-prefixed port group.
It is responsible for:
- ANDing this module's raw `tag_match` with the (separate) valid
  array's output to obtain the real hit/hit_way -- `tag_match` alone
  is meaningless for an entry that was never validly filled.
- Merging its two write sources onto this module's single write port:
  the hit-write (dirty only) and the fill-write (tag + dirty). The two
  never coincide -- the CPU is held off while a fill is installed -- and
  this module has no arbitration logic of its own.
- Reading `tag_out` when it evicts a dirty line: the victim's
  writeback address is `{stored tag, set index, zero offset}`, and
  this array is the only place that tag is kept.
- No direct connection to the MSHR -- fill data reaches this module
  only via the controller.

## Interface

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock. No reset pin -- see rationale below. |
| `rd_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to look up, presented every lookup cycle (load or store). |
| `lookup_tag` | `TAG_WIDTH` (22) | in | Tag to compare against all `NUM_WAYS` ways of the addressed set. |
| `tag_match` | `NUM_WAYS` (4), one bit per way | out | Raw, valid-agnostic per-way compare result -- valid one cycle after `rd_set_idx`/`lookup_tag` (compare of the registered stored tags against a registered `lookup_tag`). |
| `dirty_out` | `NUM_WAYS` (4), one bit per way | out | Each way's dirty bit, registered alongside `tag_match`. |
| `tag_out` | `TAG_WIDTH` (22) x `NUM_WAYS` (4), unpacked | out | Each way's stored tag, registered alongside `tag_match`. Used to form a dirty victim's writeback address. |
| `wr_en` | 1 | in | Master write enable. With this low, nothing changes regardless of the other write signals. |
| `wr_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to write. |
| `wr_way_sel` | `WAY_WIDTH` (2) | in | Way to write. |
| `wr_tag` | `TAG_WIDTH` (22) | in | New tag value; written only if `wr_tag_en` is also set. |
| `wr_tag_en` | 1 | in | Gates the tag field write independently of the dirty field. |
| `wr_dirty` | 1 | in | New dirty value; written only if `wr_dirty_en` is also set. |
| `wr_dirty_en` | 1 | in | Gates the dirty field write independently of the tag field. |

## Two write sources, one port

The controller drives both sources (see `docs/CACHE_CONTROLLER_README.md`,
"Fill"). A fill always installs the line clean; a store that missed is
replayed afterwards through the hit path, which sets the dirty bit.

| Source | `wr_tag_en` | `wr_dirty_en` | When |
|---|---|---|---|
| Hit write | 0 | 1 | A store hits an already-resident line; only its dirty bit changes. |
| Fill write | 1 | 1 | The MSHR returns a line after a miss; the victim way gets the new tag, with dirty = 0. |

## Timing: compare after the read register, read-old-data on collision

- **Read:** `rd_set_idx` is sampled on the clock edge; `tag_out` (each
  tag bank's registered output) and `dirty_out` are valid the
  *following* edge -- matching `cache_data_sram`'s `rd_line` latency,
  so the controller can combine both arrays' results in the same cycle.
- **Compare:** `lookup_tag` is registered on the same edge, and
  `tag_match[w] = (tag_out[w] == lookup_tag_q)` is computed
  combinationally *after* the registers. So `tag_match` is still valid
  one cycle after `rd_set_idx`/`lookup_tag` are presented.
- **Why the compare is after the register:** a block RAM can only give
  back registered read data. An earlier version compared first and
  registered the 1-bit result (`tag_match <= (mem[set] == lookup_tag)`);
  that put logic between the array and its register, so synthesis could
  not use block RAM and built the tags from flip-flops. The cost of the
  fix is one 22-bit compare moved into the cycle that uses `tag_match`.
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
| `WORD_OFF_WIDTH` | `$clog2(WORDS_PER_LINE)` = 2 | Word-within-line offset bits |
| `BYTE_OFF_WIDTH` | `$clog2(DATA_WIDTH / 8)` = 2 | Byte-within-word offset bits |
| `TAG_WIDTH` | `ADDR_WIDTH - SET_IDX_WIDTH - WORD_OFF_WIDTH - BYTE_OFF_WIDTH` = 22 | Bits of address stored as the tag |

## Verification

See `tb/cache_tag_array_tb.sv` -- 9 directed tests:

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
9. **Stored-tag read-out (`tag_out`)** -- all four ways of two adjacent
   sets hold distinct, full-width tags; reading the sets back-to-back
   must return each way's own tag for whichever set was addressed.
   Catches way-ordering, off-by-one set index and truncation errors,
   any of which would send an evicted dirty line to the wrong address.
