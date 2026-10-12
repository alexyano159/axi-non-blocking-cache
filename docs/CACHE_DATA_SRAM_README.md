# `cache_data_sram.sv` — Cache Data SRAM

## What it stores

4-way set-associative, 4 KB total capacity. Holds **only** line data --
no tags, valid bits, or dirty bits. Tag and dirty bits live in the
separate `cache_tag_array`, and valid bits in the separate
`cache_valid_array`; both are read in parallel with matching latency.

```
g_way[w].g_word[i].u_bank   -- 16 sram_sdp banks, each NUM_SETS x DATA_WIDTH (64 x 32)
                               bank (w, i) holds word i of every line in way w
```

Built from `NUM_WAYS x WORDS_PER_LINE` instances of the generic RAM
`rtl/sram_sdp.sv`, all sharing the read address. Two reasons:
- **Parallel ways.** A real 4-way data array is several memories side
  by side, not one wide memory with an extra address bit. All four ways
  of a set come back in the same cycle, in parallel with the tag/valid
  lookup, so the controller selects the hitting way's line the moment
  the hit is resolved -- without a second access.
- **Block-RAM inference.** One bank per word turns the per-word write
  mask into a plain write enable per bank: bank (w, i) is written when
  `wr_en`, `wr_way_sel == w` and `wr_word_en[i]` are all set. A single
  2-D array written through a variable way index with a per-word mask
  does not match the RAM template, and synthesis builds it from
  flip-flops instead (32 Kbit of registers; the design then did not fit
  the FPGA). With banks, each maps onto one M10K block.

## Who it talks to

```
Cache Controller  <---->  Cache Data SRAM
```

The cache controller (`rtl/cache_controller.sv`) is the **only**
client; it reaches this module through its `data_`-prefixed port
group. It is responsible for:
- Forming the hit by ANDing the tag array's raw `tag_match` with the
  valid array's `valid_out`, then selecting the hitting way's line from
  `rd_line`, and, on a fill, choosing the victim way (an invalid way
  first, else the true-LRU way) and reading the victim's line from
  `rd_line` for a dirty writeback.
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
| `wr_data` | `LINE_WIDTH` (128) | in | Full line; only the words selected by `wr_word_en` are actually written. (For a hit-write the controller copies the store word into all four lanes.) |

## Two write sources, one port

The port is shared by two sources, both driven by the controller and
muxed onto the same port (they never coincide: the CPU is held off
while a fill is installed):

| Source | `wr_word_en` | When |
|---|---|---|
| Hit write | one-hot at the store's word offset | A store hits an already-resident line; overwrites one word in place. |
| Fill write | all-ones (`4'b1111`) | The MSHR returns a full line after a miss; written into the freshly allocated way. |

## Timing: registered read, read-old-data on collision

Both ports are synchronous (inside each `sram_sdp` bank):
- **Read:** `rd_set_idx` is sampled on the clock edge; `rd_line` is
  valid the *following* edge -- matching the latency of a real SRAM
  macro. `rd_line` is only the banks' outputs wired together; there is
  no logic after the read register.
- **Collision:** a write to the same (way, set) on the same edge as a
  read is **not forwarded** -- the read returns the pre-write value,
  matching typical synchronous SRAM behavior. The write itself is
  never lost, only not visible until the next read.

## No reset

There is no `rst_n` on this module -- a real SRAM macro has no reset
pin, and synchronously clearing an array this size in one cycle isn't
representative of real hardware. Line contents are undefined until
written; correctness after reset is guaranteed by the **valid array's**
(`cache_valid_array`) bits being cleared there, not by this module.

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
