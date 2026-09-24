# axi-non-blocking-cache

A non-blocking L1 data cache with AXI4 memory access, built around a
Miss Status Holding Register (MSHR) that supports hit-under-miss
merging and out-of-order fill completion. SystemVerilog RTL, with a
self-checking, directed testbench per module.

## Architecture

| Aspect | Choice |
|---|---|
| Associativity | 4-way set-associative |
| Line size | 4 words (128 bits), matching the AXI burst length |
| Write policy | Write-back, write-allocate |
| Miss handling | Non-blocking via a fully-associative MSHR, up to 16 outstanding misses, with hit-under-miss merging |
| Replacement policy | Not yet decided (LRU vs. pseudo-LRU) — pending the cache-controller module |

The cache and the MSHR use two different addressing schemes on purpose:
the cache is indexed (`[TAG | SET | OFFSET]`) for fast, single-row
lookup; the MSHR is fully associative (every entry compared in
parallel) so any in-flight miss can be found regardless of arrival
order. See [`docs/STRUCTURE_README.md`](docs/STRUCTURE_README.md) for
why that split exists and how addresses flow between the two.

```
CPU  <->  Cache Controller  <->  MSHR  <->  Main Memory (AXI4)
```

The MSHR is the only block that ever touches the AXI bus. The cache
controller hands it complete misses and dirty victims; the MSHR turns
those into AXI bursts and hands back completed lines. On the cache side,
the tag array, valid array, and data SRAM are three separate,
identically-indexed arrays — the controller ANDs the tag array's raw
compare against the valid array's per-way valid bits to get a real hit,
then reads the matching way out of the data SRAM in the same cycle.
Only the valid array has a reset; the tag and data arrays are modeled
as reset-less SRAM macros whose contents are ignored until a way is
marked valid. Full protocol and rationale:
[`docs/MSHR_README.md`](docs/MSHR_README.md),
[`docs/AXI_IF_README.md`](docs/AXI_IF_README.md),
[`docs/CACHE_TAG_ARRAY_README.md`](docs/CACHE_TAG_ARRAY_README.md),
[`docs/CACHE_VALID_ARRAY_README.md`](docs/CACHE_VALID_ARRAY_README.md),
[`docs/CACHE_DATA_SRAM_README.md`](docs/CACHE_DATA_SRAM_README.md).

For a step-by-step visual walkthrough before reading the RTL, see
[`visual_flow/`](visual_flow/) (static dataflow diagrams for the MSHR
and the data SRAM — conceptual, not cycle-accurate).

## Status

| Module | RTL | Testbench |
|---|---|---|
| `axi_if.sv` — AXI4 interface | Done | — (exercised via `mshr_tb`) |
| `mshr.sv` — miss handling + writeback | Done | 13 directed tests, all passing |
| `cache_tag_array.sv` — tag + dirty bit, 4-way | Done | 8 directed tests, all passing |
| `cache_valid_array.sv` — valid bit, 4-way, sync reset | Done | 8 directed tests, all passing |
| `cache_data_sram.sv` — line data, 4-way | Done | 6 directed tests, all passing |
| Cache controller | Not started (next up) | — |
| Top-level cache integration | Not started | — |

`mshr.sv` currently covers: single read/write miss fill, hit-under-miss
merge, single victim writeback, MSHR-full stall and recovery,
round-robin fairness of the AXI read-address arbiter, writeback-queue-full
stall and recovery, fixed-priority ordering of the fill-completion mux,
concurrent fill + writeback traffic, multi-way merge with an
out-of-order dirty flag, entry reuse not leaking a stale dirty flag, and
reset mid-fetch not leaving a stale merge target.

`cache_tag_array.sv` currently covers: fill-write with a matching
lookup, a non-matching tag correctly reporting no hit, a same-cycle
read/write collision returning the pre-write value, independent gating
of the tag vs. dirty write-enables (each checked with a deliberately
mismatched value on the other field, to catch a broken gate), way
isolation, set isolation, and `wr_en` gating.

`cache_valid_array.sv` currently covers: reset clearing a previously
written entry (with the output shown as `X` before the first clocked
reset edge), fill-write with a matching lookup, explicit invalidate, a
same-cycle read/write collision returning the pre-write value, way
isolation, set isolation, `wr_en` gating, and reset clearing the output
register directly without a lookup.

`cache_data_sram.sv` currently covers: single-word hit-write readback,
a same-cycle read/write collision, a fill-write overwriting stale data
across all four words, way isolation, `wr_en` gating, and set isolation.

## Running the testbenches

**`mshr_tb`** — requires Questa (path configured in `tools/sim/run.sh`):

```bash
./tools/sim/run.sh
```

Compiles `rtl/axi_if.sv`, `rtl/mshr.sv`, and `tb/mshr_tb.sv` into
`tools/sim/work/`, then runs all directed tests to completion, printing
a `[PASS]`/`[FAIL]` line per test.

**`cache_tag_array_tb`** and **`cache_valid_array_tb`** — verified
with `iverilog`/`vvp` (Icarus Verilog):

```bash
iverilog -g2012 -o tag_tb.vvp rtl/cache_tag_array.sv tb/cache_tag_array_tb.sv && vvp tag_tb.vvp
iverilog -g2012 -o valid_tb.vvp rtl/cache_valid_array.sv tb/cache_valid_array_tb.sv && vvp valid_tb.vvp
```

**`cache_data_sram_tb`** — requires Questa; its unpacked-array task
ports aren't supported by Icarus Verilog's current SystemVerilog
elaboration.

## Repo layout

```
rtl/          Synthesizable SystemVerilog modules
tb/           Testbenches
docs/         Per-module design docs (architecture, interface, rationale)
visual_flow/  Conceptual diagrams / interactive teaching aid
tools/sim/    Simulation runner
```
