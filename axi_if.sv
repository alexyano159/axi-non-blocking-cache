// AXI4 (full) bus interface: adds ID, burst-length/size/burst-type, and
// last-beat signals on top of the address/data/response channels so a
// single transaction can move a whole cache line in one burst.
interface axi_if #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int ID_WIDTH   = 4
);

    localparam int STRB_WIDTH = DATA_WIDTH / 8;

    // Write address channel
    logic [ID_WIDTH-1:0]   awid;
    logic [ADDR_WIDTH-1:0] awaddr;
    logic [7:0]            awlen;    // burst length = awlen + 1 beats
    logic [2:0]             awsize;   // bytes per beat = 2**awsize
    logic [1:0]             awburst;  // 2'b01 = INCR
    logic [2:0]             awprot;
    logic                   awvalid;
    logic                   awready;

    // Write data channel
    logic [DATA_WIDTH-1:0] wdata;
    logic [STRB_WIDTH-1:0] wstrb;
    logic                  wlast;
    logic                  wvalid;
    logic                  wready;

    // Write response channel
    logic [ID_WIDTH-1:0] bid;
    logic [1:0]          bresp;
    logic                bvalid;
    logic                bready;

    // Read address channel
    logic [ID_WIDTH-1:0]   arid;
    logic [ADDR_WIDTH-1:0] araddr;
    logic [7:0]            arlen;    // burst length = arlen + 1 beats
    logic [2:0]             arsize;   // bytes per beat = 2**arsize
    logic [1:0]             arburst;  // 2'b01 = INCR
    logic [2:0]             arprot;
    logic                   arvalid;
    logic                   arready;

    // Read data channel
    logic [ID_WIDTH-1:0]   rid;
    logic [DATA_WIDTH-1:0] rdata;
    logic [1:0]            rresp;
    logic                  rlast;
    logic                  rvalid;
    logic                  rready;

    // Master: drives requests (addr/burst/data/valid), samples readys and
    // responses. Use on any module that initiates transactions (MSHR,
    // cache controller writeback path, etc).
    modport master (
        output awid, awaddr, awlen, awsize, awburst, awprot, awvalid,
        input  awready,
        output wdata, wstrb, wlast, wvalid,
        input  wready,
        input  bid, bresp, bvalid,
        output bready,
        output arid, araddr, arlen, arsize, arburst, arprot, arvalid,
        input  arready,
        input  rid, rdata, rresp, rlast, rvalid,
        output rready
    );

    // Slave: samples requests, drives readys and responses. Use on the
    // memory/peripheral side of the bus.
    modport slave (
        input  awid, awaddr, awlen, awsize, awburst, awprot, awvalid,
        output awready,
        input  wdata, wstrb, wlast, wvalid,
        output wready,
        output bid, bresp, bvalid,
        input  bready,
        input  arid, araddr, arlen, arsize, arburst, arprot, arvalid,
        output arready,
        output rid, rdata, rresp, rlast, rvalid,
        input  rready
    );

    // Monitor: read-only view of every signal, for testbenches, scoreboards,
    // or waveform probes that must not drive the bus.
    modport monitor (
        input awid, awaddr, awlen, awsize, awburst, awprot, awvalid, awready,
        input wdata, wstrb, wlast, wvalid, wready,
        input bid, bresp, bvalid, bready,
        input arid, araddr, arlen, arsize, arburst, arprot, arvalid, arready,
        input rid, rdata, rresp, rlast, rvalid, rready
    );

endinterface : axi_if
