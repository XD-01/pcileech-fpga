// -----------------------------------------------------------------------------
// ACAP-100T : common definitions
//
// The capture pipeline is deliberately kept in the PCIe user-clock domain.
// The Xilinx 7-series PCIe core used by the CaptainDMA 100T is configured for
// Gen2 x1 with a 62.5 MHz user clock, so the on-chip 1080p timing generator
// runs at 62.5 MHz and is back-pressured by the DMA engine.  This avoids any
// asynchronous FIFO in the video path and makes the design deterministic.
// -----------------------------------------------------------------------------
`ifndef ACAP_PKG_SVH
`define ACAP_PKG_SVH

`define _bs16(v)   {{v}[7:0], {v}[15:8]}
`define _bs32(v)   {{v}[7:0], {v}[15:8], {v}[23:16], {v}[31:24]}

// 1920x1080p25 / YUYV422, 2200 x 1125 total, 62.5 MHz pixel clock.
`define ACAP_WIDTH          1920
`define ACAP_HEIGHT         1080
`define ACAP_HTOTAL         2200
`define ACAP_VTOTAL         1125
`define ACAP_HFP            88
`define ACAP_HSW            44
`define ACAP_HBP            148
`define ACAP_VFP            4
`define ACAP_VSW            5
`define ACAP_VBP            36
`define ACAP_STRIDE         (`ACAP_WIDTH * 2)
`define ACAP_PAYLOAD_BYTES  (`ACAP_WIDTH * `ACAP_HEIGHT * 2)
`define ACAP_FRAME_BYTES    (128 + ((`ACAP_PAYLOAD_BYTES + 127) & ~127))
`define ACAP_FORMAT_YUYV    8'h00
`define ACAP_MAGIC          32'h4D434150   // "MCAP"
`define ACAP_VERSION        32'h0001_0000

// Frame header (first 32 bytes of every frame buffer):
//   DW0 0x46524D31 ("FRM1")
//   DW1 0x4D434150 ("MCAP")
//   DW2 frame sequence
//   DW3 {height[15:0], width[15:0]}
//   DW4 {16'h0, flags[7:0], format[7:0]}
//   DW5 stride in bytes
//   DW6 timestamp low
//   DW7 timestamp high
//   DW8..DW31 zero
`define ACAP_HDR_MAGIC0     32'h46524D31
`define ACAP_HDR_MAGIC1     32'h4D434150

// -----------------------------------------------------------------------------
// 128-bit TLP AXI4-Stream used by the pcileech-derived PCIe plumbing.
// tuser[0] = first beat, tuser[1] = last beat, tuser[8:2] = BAR hit vector.
// -----------------------------------------------------------------------------
interface IfAXIS128;
    wire [127:0]    tdata;
    wire [3:0]      tkeepdw;
    wire            tvalid;
    wire            tlast;
    wire [8:0]      tuser;
    wire            tready;
    wire            has_data;

    modport source(
        input  tready,
        output tdata, tkeepdw, tvalid, tlast, tuser, has_data
    );

    modport sink(
        output tready,
        input  tdata, tkeepdw, tvalid, tlast, tuser, has_data
    );

    modport source_lite(
        output tdata, tkeepdw, tvalid, tlast, tuser
    );

    modport sink_lite(
        input  tdata, tkeepdw, tvalid, tlast, tuser
    );
endinterface

`endif
