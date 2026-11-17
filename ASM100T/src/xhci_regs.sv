// -----------------------------------------------------------------------------
// xHCI (ASM1042) MMIO register file, BAR0 = 64 kB.
//
//  Capability  0x0000..0x001F
//  Operational 0x0020.. (USBCMD, USBSTS, PAGESIZE, DNCTRL, CRCR, DCBAAP,
//                        CONFIG, MFINDEX, PORTSC[1..2] at 0x0420/0x0430)
//  Runtime     0x2000 (MFINDEX) + IR0 at 0x2020..0x203F
//  Doorbells   0x3000 (DB0..)
//  MSI-X table 0x5000, PBA 0x6000
//
// Read latency: 2 CLKs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module xhci_regs(
    input               clk,
    input               rst,
    // BAR0
    input               wr_valid,
    input [15:0]        wr_addr,
    input [31:0]        wr_data,
    input [3:0]         wr_be,
    input               rd_valid,
    input [15:0]        rd_addr,
    output bit [31:0]   rd_data,
    output bit          rd_valid_o,
    // state to the command engine
    output              usbcmd_rs,
    output              usbcmd_inte,
    output [63:0]       crcr,
    output reg          crcr_wr,
    output [63:0]       dcbaap,
    output [7:0]        config_max_slots,
    output [15:0]       erstsz,
    output [63:0]       erstba,
    output reg          erstba_wr,
    output [63:0]       erdp,
    output              iman_ie,
    output reg          db0_wr,
    input               usbsts_eint_set,
    input               iman_ip_set,
    // MSI-X table lookup
    input  [2:0]        msix_sel,
    output [63:0]       msix_addr,
    output [31:0]       msix_data,
    output              msix_mask
);

    // Capability constants
    localparam [7:0]  CAPLENGTH  = 8'h20;
    localparam [15:0] HCIVERSION = 16'h0100;
    localparam [31:0] HCSPARAMS1  = 32'h02000120;   // 2 ports, 1 intr, 32 slots
    localparam [31:0] HCCPARAMS1  = 32'h0000000D;   // AC64, CSZ, PPC

    reg [31:0] usbcmd;
    reg        eint;
    reg        ip;
    reg        ie;
    reg [31:0] imod_r;
    reg [63:0] crcr_r;
    reg        crcr_rcs;
    reg [63:0] dcbaap_r;
    reg [7:0]  config_r;
    reg [15:0] erstsz_r;
    reg [63:0] erstba_r;
    reg [63:0] erdp_r;
    reg [31:0] msix [0:31];

    wire [15:0] wr_idx = wr_addr[15:2];
    wire [15:0] rd_idx = rd_addr[15:2];

    assign usbcmd_rs        = usbcmd[0];
    assign usbcmd_inte      = usbcmd[2];
    assign crcr             = { crcr_r[63:4], 3'b000, crcr_rcs };
    assign dcbaap           = dcbaap_r;
    assign config_max_slots = config_r;
    assign erstsz           = erstsz_r;
    assign erstba           = erstba_r;
    assign erdp             = erdp_r;
    assign iman_ie          = ie;

    wire crr = usbcmd[0] && (crcr_r[63:4] != 60'd0);
    wire [31:0] usbsts = (eint ? 32'h00000008 : 32'd0) |
                         (usbcmd[0] ? 32'd0 : 32'd1);

    // -------------------------------------------------------------------------
    // MSI-X lookup
    // -------------------------------------------------------------------------
    wire [4:0] msix_base = { msix_sel, 2'b00 };
    assign msix_addr = { msix[msix_base + 5'd1], msix[msix_base] };
    assign msix_data = msix[msix_base + 5'd2];
    assign msix_mask = msix[msix_base + 5'd3][0];

    // -------------------------------------------------------------------------
    // Read decode (2 CLK latency)
    // -------------------------------------------------------------------------
    function [31:0] xhci_read(input [15:0] idx);
        case ( idx )
            16'h0000: xhci_read = { HCIVERSION, CAPLENGTH };
            16'h0001: xhci_read = HCSPARAMS1;
            16'h0002: xhci_read = 32'h00000000;
            16'h0003: xhci_read = 32'h00000000;
            16'h0004: xhci_read = HCCPARAMS1;
            16'h0005: xhci_read = 32'h00003000;         // DBOFF
            16'h0006: xhci_read = 32'h00002000;         // RTSOFF
            16'h0007: xhci_read = 32'h00000000;
            16'h0008: xhci_read = { 27'd0, usbcmd[4:0] };
            16'h0009: xhci_read = usbsts;
            16'h000A: xhci_read = 32'h00000001;         // PAGESIZE 4 kB
            16'h000B: xhci_read = 32'h00000000;         // DNCTRL
            16'h000C: xhci_read = crcr_r[31:0] | { 31'd0, crcr_rcs } | (crr ? 32'h8 : 32'd0);
            16'h000D: xhci_read = crcr_r[63:32];
            16'h000E: xhci_read = dcbaap_r[31:0];
            16'h000F: xhci_read = dcbaap_r[63:32];
            16'h0010: xhci_read = { 24'd0, config_r };
            16'h0011: xhci_read = 32'h00000000;         // MFINDEX
            16'h0108: xhci_read = 32'h000002A0;         // PORTSC1: PP=1, PLS=RxDetect
            16'h010C: xhci_read = 32'h000002A0;         // PORTSC2
            16'h0800: xhci_read = 32'h00000000;         // runtime MFINDEX
            16'h0808: xhci_read = { 30'd0, ie, ip };    // IMAN
            16'h0809: xhci_read = imod_r;
            16'h080A: xhci_read = { 16'd0, erstsz_r };
            16'h080C: xhci_read = erstba_r[31:0];
            16'h080D: xhci_read = erstba_r[63:32];
            16'h080E: xhci_read = erdp_r[31:0];
            16'h080F: xhci_read = erdp_r[63:32];
            16'h1800: xhci_read = 32'h00000000;         // PBA
            default: xhci_read = ((idx >= 16'h1400) && (idx <= 16'h141F)) ?
                                  msix[idx[4:0]] : 32'h00000000;
        endcase
    endfunction

    bit [15:0] idx_d1;
    bit        vld_d1;

    always @ ( posedge clk ) begin
        idx_d1     <= rd_idx;
        vld_d1     <= rd_valid;
        rd_data    <= xhci_read(idx_d1);
        rd_valid_o <= vld_d1;
    end

    // -------------------------------------------------------------------------
    // Writes
    // -------------------------------------------------------------------------
    integer i;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            usbcmd      <= 32'd0;
            eint        <= 1'b0;
            ip          <= 1'b0;
            ie          <= 1'b0;
            imod_r      <= 32'd0;
            crcr_r      <= 64'd0;
            crcr_rcs    <= 1'b0;
            dcbaap_r    <= 64'd0;
            config_r    <= 8'd0;
            erstsz_r    <= 16'd0;
            erstba_r    <= 64'd0;
            erdp_r      <= 64'd0;
            crcr_wr     <= 1'b0;
            erstba_wr   <= 1'b0;
            db0_wr      <= 1'b0;
            for ( i = 0; i < 32; i = i + 1 )
                msix[i] <= 32'd0;
        end
        else begin
            crcr_wr   <= 1'b0;
            erstba_wr <= 1'b0;
            db0_wr    <= 1'b0;

            if ( usbsts_eint_set ) eint <= 1'b1;
            if ( iman_ip_set )     ip   <= 1'b1;

            if ( wr_valid ) begin
                if ( (wr_idx >= 16'h1400) && (wr_idx <= 16'h141F) )
                    msix[wr_idx[4:0]] <= wr_data;
                else case ( wr_idx )
                    16'h0008: begin
                        usbcmd <= { 27'd0, wr_data[4:0] } & ~32'h00000002;
                        if ( wr_data[1] ) begin          // HCRST
                            crcr_r   <= 64'd0;
                            crcr_rcs <= 1'b0;
                            dcbaap_r <= 64'd0;
                            config_r <= 8'd0;
                            erstsz_r <= 16'd0;
                            erstba_r <= 64'd0;
                            erdp_r   <= 64'd0;
                            ie       <= 1'b0;
                            ip       <= 1'b0;
                            eint     <= 1'b0;
                        end
                    end
                    16'h0009: if ( wr_data[3] ) eint <= 1'b0;   // clear EINT
                    16'h000C: begin
                        crcr_r[31:0] <= { wr_data[31:4], 4'd0 };
                        crcr_rcs     <= wr_data[0];
                        crcr_wr      <= 1'b1;
                    end
                    16'h000D: begin
                        crcr_r[63:32] <= wr_data;
                        crcr_wr       <= 1'b1;
                    end
                    16'h000E: dcbaap_r[31:0]  <= wr_data;
                    16'h000F: dcbaap_r[63:32] <= wr_data;
                    16'h0010: config_r <= wr_data[7:0];
                    16'h0808: begin                         // IMAN
                        if ( wr_data[0] ) ip <= 1'b0;
                        ie <= wr_data[1];
                    end
                    16'h0809: imod_r <= wr_data;
                    16'h080A: erstsz_r <= wr_data[15:0];
                    16'h080C: begin
                        erstba_r  <= { erstba_r[63:32], wr_data };
                        erstba_wr <= 1'b1;
                    end
                    16'h080D: begin
                        erstba_r  <= { wr_data, erstba_r[31:0] };
                        erstba_wr <= 1'b1;
                    end
                    16'h080E: erdp_r[31:0]  <= wr_data;
                    16'h080F: erdp_r[63:32] <= wr_data;
                    16'h0C00: db0_wr <= 1'b1;               // doorbell 0
                    default: ;
                endcase
            end
        end
    end

endmodule
