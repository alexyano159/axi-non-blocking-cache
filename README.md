# axi-non-blocking-cache

A non-blocking L1 data cache with AXI4 memory access, built around a
Miss Status Holding Register (MSHR) that supports hit-under-miss
merging and out-of-order fill completion. SystemVerilog RTL, with a
self-checking testbench per module (directed tests, plus a
constrained-random test for the cache controller).

## Architecture

| Aspect | Choice |
|---|---|
| Associativity | 4-way set-associative |
| Line size | 4 words (128 bits), matching the AXI burst length |
| Write policy | Write-back, write-allocate |
| Miss handling | Non-blocking via a fully-associative MSHR, up to 16 outstanding misses, with hit-under-miss merging |
| Replacement policy | True LRU (2-bit age per way, 8 bits per set); invalid ways filled first; victim chosen at fill time |

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
| `cache_controller.sv` — lookup, hit path, true-LRU state | Hit path + LRU done; miss handling (MSHR allocation, replay, fill/eviction) in progress | 10 tests (9 directed + 1 constrained-random), all passing |
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

`cache_controller.sv` currently covers (hit path; the three real arrays
are instantiated, lines are installed through a TB preload mux, and the
MSHR ports are tied idle): reset idle state, a single load hit with
exact 2-cycle latency, a load hit on every way x word of a full set,
valid gating (matching tag with valid = 0 misses), a store hit with a
single masked word write and dirty 0 -> 1, the 1-cycle same-set
read-after-write stall (and its absence otherwise), full one-per-cycle
throughput, response back-pressure filling the 3-entry FIFO with a
stable held response, a 500-request constrained-random load/store mix
under random back-pressure (scoreboard-checked, with a read-after-write
coverage floor and a reproducible `+seed`), and the true-LRU recency
order after every kind of hit, including back-to-back same-set hits
and the reported victim.

## Running the testbenches

All testbenches run under Questa (Intel/Altera FPGA Starter Edition,
installed under `C:\altera_lite\<release>\`, license `.dat` in `tools/`):

```bash
./tools/sim/run.sh [tb_name]     # default: mshr_tb
./tools/sim/run.sh cache_tag_array_tb
```

Compiles every file in `rtl/` plus `tb/<tb_name>.sv`, then runs all
directed tests to completion, printing a `[PASS]`/`[FAIL]` line per
test. Questa cannot handle non-ASCII paths, so if the project lives
under one the script transparently simulates from an ASCII staging copy
in `%LOCALAPPDATA%\axi-non-blocking-cache-sim\`; otherwise it runs in
`tools/sim/`.

**`cache_tag_array_tb`** and **`cache_valid_array_tb`** — verified
with `iverilog`/`vvp` (Icarus Verilog):

```bash
iverilog -g2012 -o tag_tb.vvp rtl/cache_tag_array.sv tb/cache_tag_array_tb.sv && vvp tag_tb.vvp
iverilog -g2012 -o valid_tb.vvp rtl/cache_valid_array.sv tb/cache_valid_array_tb.sv && vvp valid_tb.vvp
```

**`cache_data_sram_tb`** — requires Questa; its unpacked-array task
ports aren't supported by Icarus Verilog's current SystemVerilog
elaboration.

**`cache_controller_tb`** — requires Questa (concurrent assertions,
queues, `process::self().srandom`). The random test's seed can be set
with `+seed=<n>` when invoking `vsim` directly (`run.sh` does not forward
plusargs).

## Repo layout

```
rtl/          Synthesizable SystemVerilog modules
tb/           Testbenches
docs/         Per-module design docs (architecture, interface, rationale)
visual_flow/  Conceptual diagrams / interactive teaching aid
tools/sim/    Simulation runner
```
