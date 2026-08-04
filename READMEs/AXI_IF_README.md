# `axi_if.sv` — AXI4 Full Bus Interface

## What this file is

`axi_if` is a SystemVerilog `interface` — a bundle of wires shared between
the cache side (Master) and main memory (Slave), so a module doesn't need
to declare and connect 20+ individual signals by hand. It implements the
full AXI4 protocol: separate address/data/response channels, burst
transfers, and transaction IDs so multiple requests can be in flight at
once.

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `ADDR_WIDTH` | 32 | Width of an address |
| `DATA_WIDTH` | 32 | Width of one beat of data (one word) |
| `ID_WIDTH` | 4 | Width of the transaction ID → supports up to 16 outstanding transactions |
| `STRB_WIDTH` | `DATA_WIDTH/8` = 4 | Byte-lane write mask width |

## The one rule that governs every channel

A transfer happens on any channel **only** on a clock edge where both
sides agree at once:

```
valid == 1   AND   ready == 1
```

- `valid = 1`: the sender says "the data on the wires is ready."
- `ready = 1`: the receiver says "I can accept it this cycle."

If only one side is asserted, nothing moves — the data just sits there
until both agree.

## The 5 channels (from the Master's point of view)

### 1. Write Address (AW) — request to write
| Signal | Dir | Meaning |
|---|---|---|
| `awaddr` | out | address to write to |
| `awvalid` | out | "I have a write request" |
| `awready` | in | "request accepted" |
| `awlen` | out | burst length − 1 (e.g. 3 → 4 beats) |
| `awsize` | out | bytes per beat = `2**awsize` |
| `awburst` | out | address progression; `2'b01` = INCR (sequential +size each beat) |
| `awid` | out | transaction ID, so the response can later be matched back |

### 2. Write Data (W) — the actual bytes being written
| Signal | Dir | Meaning |
|---|---|---|
| `wdata` | out | data for this beat |
| `wstrb` | out | which bytes of `wdata` are actually valid |
| `wvalid` | out | "this beat is valid" |
| `wready` | in | "beat accepted" |
| `wlast` | out | "this is the last beat of the burst" |

### 3. Write Response (B) — memory confirms the write finished
| Signal | Dir | Meaning |
|---|---|---|
| `bvalid` | in | "the write completed" |
| `bready` | out | "I acknowledge the completion" |
| `bid` | in | which transaction this response belongs to (matches `awid`) |
| `bresp` | in | completion status (OKAY / error) |

### 4. Read Address (AR) — request to read
| Signal | Dir | Meaning |
|---|---|---|
| `araddr` | out | address to read from |
| `arvalid` | out | "I have a read request" |
| `arready` | in | "request accepted" |
| `arlen` / `arsize` / `arburst` | out | same meaning as their AW counterparts |
| `arid` | out | transaction ID |

### 5. Read Data (R) — memory returns the bytes
| Signal | Dir | Meaning |
|---|---|---|
| `rdata` | in | data for this beat |
| `rvalid` | in | "this beat is valid" |
| `rready` | out | "beat accepted" |
| `rlast` | in | "this is the last beat of the burst" |
| `rid` | in | which transaction this beat belongs to (matches `arid`) |
| `rresp` | in | status of this beat |

## Modports (which side drives what)

- **`master`** — used by anything that *initiates* a transaction (the
  MSHR). Drives requests, samples the `ready`/response signals.
- **`slave`** — used by main memory. Samples requests, drives the
  `ready`/response signals.
- **`monitor`** — every signal is an input. Used by testbenches/scoreboards
  to observe the bus without ever driving it.
