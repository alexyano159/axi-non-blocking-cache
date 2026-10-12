// -----------------------------------------------------------------------
// Synthesis wrapper for cache_top
// -----------------------------------------------------------------------
// cache_top exposes its memory side as an axi_if.master interface port.
// FPGA tools cannot assign device pins (or virtual pins) to an interface
// port on the top-level entity, so this wrapper instantiates the
// interface internally and presents every AXI4 signal as a plain port,
// using the conventional m_axi_* naming of an AXI master. It contains no
// logic; the synthesized netlist is that of cache_top.
//
// Used only by the synthesis flow in syn/ (run_synth.tcl); simulation
// instantiates cache_top directly.
// -----------------------------------------------------------------------
`default_nettype none

module cache_top_syn #(
    parameter int ADDR_WIDTH     = 32,
    parameter int DATA_WIDTH     = 32,
    parameter int NUM_WAYS       = 4,
    parameter int WORDS_PER_LINE = 4,
    parameter int NUM_SETS       = 64,
    parameter int MSHR_ID_WIDTH  = 4,
    parameter int TXN_ID_WIDTH   = 4,
    parameter int WB_QUEUE_DEPTH = 4,
    parameter int STRB_WIDTH     = DATA_WIDTH / 8
) (
    input  wire logic                     clk,
    input  wire logic                     rst_n,

    // CPU request / response
    input  wire logic                     req_valid,
    output      logic                     req_ready,
    input  wire logic [ADDR_WIDTH-1:0]    req_addr,
    input  wire logic                     req_we,
    input  wire logic [DATA_WIDTH-1:0]    req_wdata,
    input  wire logic [TXN_ID_WIDTH-1:0]  req_id,

    output      logic                     resp_valid,
    input  wire logic                     resp_ready,
    output      logic [TXN_ID_WIDTH-1:0]  resp_id,
    output      logic [DATA_WIDTH-1:0]    resp_data,
    output      logic                     resp_we,

    // AXI4 master: write address channel
    output      logic [MSHR_ID_WIDTH-1:0] m_axi_awid,
    output      logic [ADDR_WIDTH-1:0]    m_axi_awaddr,
    output      logic [7:0]               m_axi_awlen,
    output      logic [2:0]               m_axi_awsize,
    output      logic [1:0]               m_axi_awburst,
    output      logic                     m_axi_awvalid,
    input  wire logic                     m_axi_awready,

    // AXI4 master: write data channel
    output      logic [DATA_WIDTH-1:0]    m_axi_wdata,
    output      logic [STRB_WIDTH-1:0]    m_axi_wstrb,
    output      logic                     m_axi_wlast,
    output      logic                     m_axi_wvalid,
    input  wire logic                     m_axi_wready,

    // AXI4 master: write response channel
    input  wire logic [MSHR_ID_WIDTH-1:0] m_axi_bid,
    input  wire logic [1:0]               m_axi_bresp,
    input  wire logic                     m_axi_bvalid,
    output      logic                     m_axi_bready,

    // AXI4 master: read address channel
    output      logic [MSHR_ID_WIDTH-1:0] m_axi_arid,
    output      logic [ADDR_WIDTH-1:0]    m_axi_araddr,
    output      logic [7:0]               m_axi_arlen,
    output      logic [2:0]               m_axi_arsize,
    output      logic [1:0]               m_axi_arburst,
    output      logic                     m_axi_arvalid,
    input  wire logic                     m_axi_arready,

    // AXI4 master: read data channel
    input  wire logic [MSHR_ID_WIDTH-1:0] m_axi_rid,
    input  wire logic [DATA_WIDTH-1:0]    m_axi_rdata,
    input  wire logic [1:0]               m_axi_rresp,
    input  wire logic                     m_axi_rlast,
    input  wire logic                     m_axi_rvalid,
    output      logic                     m_axi_rready
);

    axi_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ID_WIDTH  (MSHR_ID_WIDTH)
    ) axi ();

    cache_top #(
        .ADDR_WIDTH    (ADDR_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .NUM_WAYS      (NUM_WAYS),
        .WORDS_PER_LINE(WORDS_PER_LINE),
        .NUM_SETS      (NUM_SETS),
        .MSHR_ID_WIDTH (MSHR_ID_WIDTH),
        .TXN_ID_WIDTH  (TXN_ID_WIDTH),
        .WB_QUEUE_DEPTH(WB_QUEUE_DEPTH)
    ) u_cache (
        .clk       (clk),
        .rst_n     (rst_n),
        .req_valid (req_valid),
        .req_ready (req_ready),
        .req_addr  (req_addr),
        .req_we    (req_we),
        .req_wdata (req_wdata),
        .req_id    (req_id),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .resp_id   (resp_id),
        .resp_data (resp_data),
        .resp_we   (resp_we),
        .axi       (axi)
    );

    // Interface <-> flat ports. Master outputs are read from the
    // interface; slave-driven inputs are written into it.
    assign m_axi_awid    = axi.awid;
    assign m_axi_awaddr  = axi.awaddr;
    assign m_axi_awlen   = axi.awlen;
    assign m_axi_awsize  = axi.awsize;
    assign m_axi_awburst = axi.awburst;
    assign m_axi_awvalid = axi.awvalid;
    assign axi.awready   = m_axi_awready;

    assign m_axi_wdata   = axi.wdata;
    assign m_axi_wstrb   = axi.wstrb;
    assign m_axi_wlast   = axi.wlast;
    assign m_axi_wvalid  = axi.wvalid;
    assign axi.wready    = m_axi_wready;

    assign axi.bid       = m_axi_bid;
    assign axi.bresp     = m_axi_bresp;
    assign axi.bvalid    = m_axi_bvalid;
    assign m_axi_bready  = axi.bready;

    assign m_axi_arid    = axi.arid;
    assign m_axi_araddr  = axi.araddr;
    assign m_axi_arlen   = axi.arlen;
    assign m_axi_arsize  = axi.arsize;
    assign m_axi_arburst = axi.arburst;
    assign m_axi_arvalid = axi.arvalid;
    assign axi.arready   = m_axi_arready;

    assign axi.rid       = m_axi_rid;
    assign axi.rdata     = m_axi_rdata;
    assign axi.rresp     = m_axi_rresp;
    assign axi.rlast     = m_axi_rlast;
    assign axi.rvalid    = m_axi_rvalid;
    assign m_axi_rready  = axi.rready;

endmodule : cache_top_syn

`default_nettype wire
