// -----------------------------------------------------------------------------
// ACAP-100T : TLP stream conversion and transmit arbitration
//
// The Xilinx 7-series PCIe hard block exposes a 64-bit AXI4-Stream TLP port.
// Internally the design uses 128-bit beats so that a complete 4-DW TLP header
// fits in one beat.  These two converters are the well-tested pcileech
// modules (c) Ulf Frisk, used here under their original BSD-style licence.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

// -----------------------------------------------------------------------------
// 64-bit PCIe core receive stream -> 128-bit internal TLP stream
// -----------------------------------------------------------------------------
module acap_tlps128_src64 (
    input                   rst,
    input                   clk_pcie,
    input  [63:0]           rx_tdata,
    input  [7:0]            rx_tkeep,
    input                   rx_tlast,
    input  [21:0]           rx_tuser,
    input                   rx_tvalid,
    output                  rx_tready,
    IfAXIS128.source_lite   tlps_out
);

    bit [127:0] tdata;
    bit         first       = 1;
    bit         tlast       = 0;
    bit [3:0]   len         = 0;
    bit [6:0]   bar_hit     = 0;
    wire        tvalid      = tlast || (len > 2);

    assign rx_tready        = 1'b1;
    assign tlps_out.tdata   = tdata;
    assign tlps_out.tkeepdw = {(len > 3), (len > 2), (len > 1), 1'b1};
    assign tlps_out.tlast   = tlast;
    assign tlps_out.tvalid  = tvalid;
    assign tlps_out.tuser[0]   = first;
    assign tlps_out.tuser[1]   = tlast;
    assign tlps_out.tuser[8:2] = bar_hit;

    wire [3:0]  next_base   = (tlast || tvalid) ? 0 : len;
    wire [3:0]  next_len    = next_base + 1 + rx_tkeep[4];

    always @ ( posedge clk_pcie )
        if ( rst ) begin
            first   <= 1;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end
        else if ( rx_tvalid ) begin
            tdata[(32*next_base)+:64] <= rx_tdata;
            first   <= tvalid ? tlast : first;
            tlast   <= rx_tlast;
            len     <= next_len;
            bar_hit <= rx_tuser[8:2];
        end
        else if ( tvalid ) begin
            first   <= tlast;
            tlast   <= 0;
            len     <= 0;
            bar_hit <= 0;
        end

endmodule


// -----------------------------------------------------------------------------
// 128-bit internal TLP stream -> 64-bit PCIe core transmit stream
// -----------------------------------------------------------------------------
module acap_tlps128_dst64 (
    input                   rst,
    input                   clk_pcie,
    IfAXIS128.sink          tlps_in,
    output [63:0]           tx_tdata,
    output [7:0]            tx_tkeep,
    output                  tx_tlast,
    output                  tx_tvalid,
    input                   tx_tready
);

    bit [63:0]  d1_tdata;
    bit         d1_tkeepdw2;
    bit         d1_tlast;
    bit         d1_tvalid = 0;

    assign tlps_in.tready = tx_tready && !(tlps_in.tvalid && tlps_in.tkeepdw[2]);

    wire tkeepdw2       = d1_tvalid ? d1_tkeepdw2 : tlps_in.tkeepdw[1];
    assign tx_tdata     = d1_tvalid ? d1_tdata : tlps_in.tdata[63:0];
    assign tx_tlast     = d1_tvalid ? d1_tlast : (tlps_in.tlast && !tlps_in.tkeepdw[2]);
    assign tx_tkeep     = tkeepdw2 ? 8'hff : 8'h0f;
    assign tx_tvalid    = d1_tvalid || tlps_in.tvalid;

    always @ ( posedge clk_pcie ) begin
        d1_tvalid    <= !rst && tlps_in.tvalid && tlps_in.tkeepdw[2];
        d1_tdata     <= tlps_in.tdata[127:64];
        d1_tlast     <= tlps_in.tlast;
        d1_tkeepdw2  <= tlps_in.tkeepdw[3];
    end

endmodule


// -----------------------------------------------------------------------------
// Three-input TLP transmit arbiter.
// Priority: configuration responses (1), BAR responses (2), DMA/MSI (3).
// Arbitration only changes at TLP boundaries, so packets are never split.
// -----------------------------------------------------------------------------
module acap_tlps128_mux3 (
    input                   clk_pcie,
    input                   rst,
    IfAXIS128.source        tlps_out,
    IfAXIS128.sink          tlps_in1,
    IfAXIS128.sink          tlps_in2,
    IfAXIS128.sink          tlps_in3
);

    bit [1:0] id = 0;

    assign tlps_out.has_data = tlps_in1.has_data || tlps_in2.has_data || tlps_in3.has_data;

    assign tlps_out.tdata    = (id == 1) ? tlps_in1.tdata :
                               (id == 2) ? tlps_in2.tdata :
                               (id == 3) ? tlps_in3.tdata : 128'h0;

    assign tlps_out.tkeepdw  = (id == 1) ? tlps_in1.tkeepdw :
                               (id == 2) ? tlps_in2.tkeepdw :
                               (id == 3) ? tlps_in3.tkeepdw : 4'h0;

    assign tlps_out.tlast    = (id == 1) ? tlps_in1.tlast :
                               (id == 2) ? tlps_in2.tlast :
                               (id == 3) ? tlps_in3.tlast : 1'b0;

    assign tlps_out.tuser    = (id == 1) ? tlps_in1.tuser :
                               (id == 2) ? tlps_in2.tuser :
                               (id == 3) ? tlps_in3.tuser : 9'h0;

    assign tlps_out.tvalid   = (id == 1) ? tlps_in1.tvalid :
                               (id == 2) ? tlps_in2.tvalid :
                               (id == 3) ? tlps_in3.tvalid : 1'b0;

    wire [1:0] id_next_newsel = tlps_in1.has_data ? 2'd1 :
                                tlps_in2.has_data ? 2'd2 :
                                tlps_in3.has_data ? 2'd3 : 2'd0;

    wire [1:0] id_next = ((id == 0) || (tlps_out.tvalid && tlps_out.tlast)) ? id_next_newsel : id;

    assign tlps_in1.tready = tlps_out.tready && (id_next == 1);
    assign tlps_in2.tready = tlps_out.tready && (id_next == 2);
    assign tlps_in3.tready = tlps_out.tready && (id_next == 3);

    always @ ( posedge clk_pcie ) begin
        id <= rst ? 2'd0 : id_next;
    end

endmodule
