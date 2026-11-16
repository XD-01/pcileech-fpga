// -----------------------------------------------------------------------------
// ACAP-100T : PCIe configuration space shadow
//
// The 7-series PCIe hard block in AXI4-Stream mode forwards host CfgRd/CfgWr
// TLPs to the user logic.  This module answers them from a 4 kB BRAM which is
// initialised with ip/pcileech_cfgspace.coe.  The write mask comes from the
// distributed ROM initialised with ip/pcileech_cfgspace_writemask.coe.
//
// It also snoops the MSI capability registers so the DMA engine can emit MSI
// memory-write TLPs without a separate MSI controller in the hard block.
//
// Based on the pcileech configuration-space shadow (c) Ulf Frisk, with the
// byte-enable lane order corrected and the USB path removed.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_cfgspace (
    input                   rst,
    input                   clk,
    IfAXIS128.sink_lite     tlps_in,
    input [15:0]            pcie_id,
    IfAXIS128.source        tlps_cfg_rsp,

    // Every host configuration write is exported to acap_core_cfg so that
    // BAR0 and the command register can be mirrored into the hard block.
    output                  cfg_wr_valid,
    output [9:0]            cfg_wr_addr,
    output [31:0]           cfg_wr_data,
    output [3:0]            cfg_wr_be,

    // MSI programming performed by the operating system.
    output [63:0]           msi_addr,
    output [31:0]           msi_data,
    output                  msi_en
);

    // -------------------------------------------------------------------------
    // 1. Decode host configuration accesses
    // -------------------------------------------------------------------------
    wire        pcie_rx_rden = tlps_in.tvalid && tlps_in.tuser[0] &&
                               (tlps_in.tdata[31:25] == 7'b0000010);  // CfgRd0/1
    wire        pcie_rx_wren = tlps_in.tvalid && tlps_in.tuser[0] &&
                               (tlps_in.tdata[31:25] == 7'b0100010);  // CfgWr0/1
    wire [9:0]  pcie_rx_addr = tlps_in.tdata[75:66];
    wire [31:0] pcie_rx_data = tlps_in.tdata[127:96];
    wire [7:0]  pcie_rx_tag  = tlps_in.tdata[47:40];
    // First DW BE lives in header bits [35:32].  Bit 0 of the header field is
    // byte lane 0, which is the natural mapping required by the BRAM.
    wire [3:0]  pcie_rx_be   = tlps_in.tdata[35:32];
    wire [15:0] pcie_rx_reqid= tlps_in.tdata[63:48];

    assign cfg_wr_valid = pcie_rx_wren;
    assign cfg_wr_addr  = pcie_rx_addr;
    assign cfg_wr_data  = pcie_rx_data;
    assign cfg_wr_be    = pcie_rx_be;

    // -------------------------------------------------------------------------
    // 2. BRAM access
    // -------------------------------------------------------------------------
    wire            bram_wr_tlp = pcie_rx_wren;
    wire            bram_rd_tlp = pcie_rx_rden;
    wire [3:0]      bram_wr_be  = pcie_rx_be;
    wire [31:0]     bram_wr_data= pcie_rx_data;

    wire [15:0]     bram_rd_reqid;
    wire [1:0]      bram_rd_tp;
    wire [7:0]      bram_rd_tag;
    wire [9:0]      bram_rd_addr;
    wire [31:0]     bram_rd_data;
    wire            bram_rd_valid = (bram_rd_tp == 2'b01);
    wire            bram_rd_tlpwr;

    pcileech_mem_wrap i_pcileech_mem_wrap(
        .clk_pcie       ( clk                           ),
        .rdwr_addr      ( pcie_rx_addr                  ),
        .wr_be          ( bram_wr_be                    ),
        .wr_data        ( bram_wr_data                  ),
        .rdreq_tag      ( pcie_rx_tag                   ),
        .rdreq_tp       ( bram_rd_tlp ? 2'b01 : 2'b00   ),
        .rdreq_reqid    ( pcie_rx_reqid                 ),
        .rdreq_tlpwr    ( bram_wr_tlp                   ),
        .rd_data        ( bram_rd_data                  ),
        .rd_addr        ( bram_rd_addr                  ),
        .rd_tag         ( bram_rd_tag                   ),
        .rd_tp          ( bram_rd_tp                    ),
        .rd_reqid       ( bram_rd_reqid                 ),
        .rd_tlpwr       ( bram_rd_tlpwr                 )
    );

    pcileech_cfgspace_pcie_tx i_pcileech_cfgspace_pcie_tx(
        .rst            ( rst                           ),
        .clk_pcie       ( clk                           ),
        .pcie_id        ( pcie_id                       ),
        .tlps_cfg_rsp   ( tlps_cfg_rsp                  ),
        .cfg_wren       ( bram_rd_valid                 ),
        .cfg_tlpwr      ( bram_rd_tlpwr                 ),
        .cfg_tag        ( bram_rd_tag                   ),
        .cfg_data       ( bram_rd_data                  ),
        .cfg_reqid      ( bram_rd_reqid                 )
    );

    // -------------------------------------------------------------------------
    // 3. MSI capability snoop
    // -------------------------------------------------------------------------
    logic [15:0] msi_ctrl_q;
    logic [63:0] msi_addr_q;
    logic [31:0] msi_data_q;

    assign msi_addr = msi_addr_q;
    assign msi_data = msi_data_q;
    assign msi_en   = msi_ctrl_q[0];

    integer b;
    always @ ( posedge clk ) begin
        if ( rst ) begin
            msi_ctrl_q <= 16'h0080;      // 64-bit capable, one vector, disabled
            msi_addr_q <= 64'h0;
            msi_data_q <= 32'h0;
        end
        else if ( pcie_rx_wren ) begin
            case ( pcie_rx_addr )
                10'h010: begin            // 0x40 : MSI cap header + control
                    if ( pcie_rx_be[2] ) msi_ctrl_q[7:0]  <= pcie_rx_data[23:16];
                    if ( pcie_rx_be[3] ) msi_ctrl_q[15:8] <= pcie_rx_data[31:24];
                end
                10'h011: begin            // 0x44 : message address low
                    for ( b = 0; b < 4; b = b + 1 )
                        if ( pcie_rx_be[b] ) msi_addr_q[b*8 +: 8] <= pcie_rx_data[b*8 +: 8];
                end
                10'h012: begin            // 0x48 : message address high
                    for ( b = 0; b < 4; b = b + 1 )
                        if ( pcie_rx_be[b] ) msi_addr_q[32 + b*8 +: 8] <= pcie_rx_data[b*8 +: 8];
                end
                10'h013: begin            // 0x4C : message data
                    if ( pcie_rx_be[0] ) msi_data_q[7:0]   <= pcie_rx_data[7:0];
                    if ( pcie_rx_be[1] ) msi_data_q[15:8]  <= pcie_rx_data[15:8];
                    if ( pcie_rx_be[2] ) msi_data_q[23:16] <= pcie_rx_data[23:16];
                    if ( pcie_rx_be[3] ) msi_data_q[31:24] <= pcie_rx_data[31:24];
                end
                default: ;
            endcase
        end
    end

endmodule


// -----------------------------------------------------------------------------
// BRAM / write-mask wrapper for the 4 kB configuration space.
// -----------------------------------------------------------------------------
module pcileech_mem_wrap(
    input               clk_pcie,
    input   [9:0]       rdwr_addr,
    input   [3:0]       wr_be,
    input   [31:0]      wr_data,
    input   [7:0]       rdreq_tag,
    input   [1:0]       rdreq_tp,
    input   [15:0]      rdreq_reqid,
    input               rdreq_tlpwr,
    output bit  [9:0]   rd_addr,
    output      [31:0]  rd_data,
    output bit  [7:0]   rd_tag,
    output bit  [1:0]   rd_tp,
    output bit  [15:0]  rd_reqid,
    output bit          rd_tlpwr
);

    bit [3:0]  wr_be_d;
    bit [31:0] wr_data_d;

    wire [31:0] wr_mask;
    wire [31:0] wr_dina;

    always @ ( posedge clk_pcie ) begin
        wr_be_d     <= wr_be;
        wr_data_d   <= wr_data;
        rd_addr     <= rdwr_addr;
        rd_tag      <= rdreq_tag;
        rd_tp       <= rdreq_tp;
        rd_reqid    <= rdreq_reqid;
        rd_tlpwr    <= rdreq_tlpwr;
    end

    bram_pcie_cfgspace i_bram_pcie_cfgspace(
        .clka           ( clk_pcie                  ),
        .clkb           ( clk_pcie                  ),
        .wea            ( wr_be_d                   ),
        .addra          ( rd_addr                   ),
        .dina           ( wr_dina                   ),
        .addrb          ( rdwr_addr                 ),
        .doutb          ( rd_data                   )
    );

    drom_pcie_cfgspace_writemask i_drom_pcie_cfgspace_writemask(
        .a              ( rd_addr                   ),
        .spo            ( wr_mask                   )
    );

    genvar i;
    generate
        for (i = 0; i < 32; i++) begin
            assign wr_dina[i] = wr_mask[i] ? wr_data_d[i] : rd_data[i];
        end
    endgenerate

endmodule


// -----------------------------------------------------------------------------
// Configuration read completion generator.
// -----------------------------------------------------------------------------
module pcileech_cfgspace_pcie_tx(
    input                   rst,
    input                   clk_pcie,
    input   [15:0]          pcie_id,
    IfAXIS128.source        tlps_cfg_rsp,
    input                   cfg_wren,
    input                   cfg_tlpwr,
    input [7:0]             cfg_tag,
    input [31:0]            cfg_data,
    input [15:0]            cfg_reqid
);

    wire [31:0] cpl_tlp_data_dw0_rd  = 32'b01001010000000000000000000000001;
    wire [31:0] cpl_tlp_data_dw0_wr  = 32'b00001010000000000000000000000000;
    wire [31:0] cpl_tlp_data_dw1     = { `_bs16(pcie_id), 16'h0004 };
    wire [31:0] cpl_tlp_data_dw2     = { cfg_reqid, cfg_tag, 8'h00 };
    wire [31:0] cpl_tlp_data_dw3     = cfg_data;
    wire [127:0] cpl_tlp_rd          = { cpl_tlp_data_dw3, cpl_tlp_data_dw2, cpl_tlp_data_dw1, cpl_tlp_data_dw0_rd };
    wire [127:0] cpl_tlp_wr          = { 32'h00000000,     cpl_tlp_data_dw2, cpl_tlp_data_dw1, cpl_tlp_data_dw0_wr };
    wire [128:0] cpl_tlps            = cfg_tlpwr ? {1'b0, cpl_tlp_wr} : {1'b1, cpl_tlp_rd};

    wire tx_tp;
    wire tx_empty;

    fifo_129_129_clk1 i_fifo_129_129_clk1 (
        .srst           ( rst                       ),
        .clk            ( clk_pcie                  ),
        .wr_en          ( cfg_wren                  ),
        .din            ( cpl_tlps                  ),
        .full           (                           ),
        .rd_en          ( tlps_cfg_rsp.tready       ),
        .dout           ( {tx_tp, tlps_cfg_rsp.tdata} ),
        .empty          ( tx_empty                  ),
        .valid          ( tlps_cfg_rsp.tvalid       )
    );

    assign tlps_cfg_rsp.tkeepdw = (tx_tp ? 4'b1111 : 4'b0111);
    assign tlps_cfg_rsp.tlast   = 1;
    assign tlps_cfg_rsp.tuser   = 0;
    assign tlps_cfg_rsp.has_data= ~tx_empty;

endmodule
