# `cache_data_sram.sv` — Cache Data SRAM

## What it stores

4-way set-associative, 4 KB total capacity. Holds **only** line data --
no tags, valid bits, or dirty bits. Those live in a separate tag array
(not yet built), which is read in parallel with matching latency.

```
mem[NUM_WAYS][NUM_SETS]   -- one 128-bit line per (way, set) pair
```

Modeled as `NUM_WAYS` independent banks rather than one flat array,
reflecting that a real 4-way SRAM is four parallel memories sharing an
address bus -- not one wide memory with an extra address bit. This lets
all four ways of a set come back in the same cycle, which the
controller needs in order to tag-compare every way in parallel.

## Who it talks to

```
Cache Controller  <---->  Cache Data SRAM
```

The cache controller (not yet built) is the **only** client. It is
responsible for:
- Doing the tag compare (against the separate tag array) to know which
  way holds a hit, or which way to evict on a miss.
- Merging its two write sources onto this module's single write port
  (see below) -- this module has no arbitration logic of its own.
- This module has **no direct connection to the MSHR** -- fill data
  reaches it only via the controller.

## Interface

| Signal | Width | Direction | Meaning |
|---|---|---|---|
| `clk` | 1 | in | Clock. No reset pin -- see rationale below. |
| `rd_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to read, presented every lookup cycle (load or store). |
| `rd_line` | `LINE_WIDTH` (128) x `NUM_WAYS` (4) | out | All 4 ways of the addressed set, registered -- valid one cycle after `rd_set_idx`. |
| `wr_en` | 1 | in | Write enable. Gates the write port; no effect on `rd_*` when low. |
| `wr_set_idx` | `SET_IDX_WIDTH` (6) | in | Set to write. |
| `wr_way_sel` | `WAY_WIDTH` (2) | in | Way to write. |
| `wr_word_en` | `WORDS_PER_LINE` (4), one bit per word | in | Per-word write mask: one-hot for a hit-write, all-ones for a fill-write. |
| `wr_data` | `LINE_WIDTH` (128) | in | Full line; only the words selected by `wr_word_en` are actually written. |

## Two write sources, one port

The controller merges both onto the single write port every cycle:

| Source | `wr_word_en` | When |
|---|---|---|
| Hit write | one-hot at the store's word offset | A store hits an already-resident line; overwrites one word in place. |
| Fill write | all-ones (`4'b1111`) | The MSHR returns a full line after a miss; written into the freshly allocated way. |

## Timing: registered read, read-old-data on collision

Both the read and write ports are synchronous (`always_ff`):
- **Read:** `rd_set_idx` is sampled on the clock edge; `rd_line` is
  valid the *following* edge -- matching the latency of a real
  single-port SRAM macro.
- **Collision:** a write to the same (way, set) on the same edge as a
  read is **not forwarded** -- the read returns the pre-write value,
  matching typical single-port synchronous SRAM behavior. The write
  itself is never lost, only not visible until the next read.

## No reset

There is no `rst_n` on this module -- a real SRAM macro has no reset
pin, and synchronously clearing an array this size in one cycle isn't
representative of real hardware. Line contents are undefined until
written; correctness after reset is guaranteed by the **tag array's**
valid bits being cleared there, not by this module.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 32 | Width of one word |
| `NUM_WAYS` | 4 | Set associativity |
| `WORDS_PER_LINE` | 4 | Words per cache line = AXI burst length (`LINE_WORDS` in `mshr.sv`) |
| `NUM_SETS` | 64 | 4 KB total / 4 ways / 16 B line |
| `LINE_WIDTH` | `DATA_WIDTH * WORDS_PER_LINE` = 128 | Full cache line width, in bits |
| `SET_IDX_WIDTH` | `$clog2(NUM_SETS)` = 6 | Bits needed to index a set |
| `WAY_WIDTH` | `$clog2(NUM_WAYS)` = 2 | Bits needed to select a way |

## Verification

See `tb/cache_data_sram_tb.sv` -- 6 directed tests covering single-word
hit-write readback, read/write collision behavior, fill-write
(overwriting stale data across all 4 words), way isolation, `wr_en`
gating, and set isolation (including both edges of the address range).
