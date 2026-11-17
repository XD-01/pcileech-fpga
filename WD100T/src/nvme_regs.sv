// -----------------------------------------------------------------------------
// NVMe controller register file (BAR0, 16 kB aperture).
//
//  0x0000 CAP         0x0008 VS          0x000C INTMS / 0x0010 INTMC
//  0x0014 CC          0x001C CSTS        0x0024 AQA
//  0x0028 ASQ         0x0030 ACQ
//  0x1000 SQ0 tail doorbell / 0x1004 CQ0 head doorbell
//  0x2000 MSI-X table (4 vectors)      0x3000 MSI-X PBA
//
// Read latency: 2 CLKs (matches the PCILeech BAR engine contract).
// No namespace is implemented; NN in the Identify data is 0.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module nvme_regs(
    input               clk,
    input               rst,
    // BAR0 write side (from pcileech_bar_impl_nvme)
    input               wr_valid,
    input [13:0]        wr_addr,
    input [31:0]        wr_data,
    input [3:0]         wr_be,
    // BAR0 read side
    input               rd_valid,
    input [13:0]        rd_addr,
    output bit [31:0]   rd_data,
    output bit          rd_valid_o,
    // State exported to the admin command engine
    output              cc_en,
    output [11:0]       asqs,
    output [11:0]       acqs,
    output [63:0]       asq,
    output [63:0]       acq,
    output [15:0]       sq0_tail,
    output [127:0]      msix0,
    output [127:0]      msix1,
    output [127:0]      msix2,
    output [127:0]      msix3
);

    // CAP: MQES=63, CQR=1, TO=0xF, DSTRD=0, CSS=NVM(1)
    localparam [31:0] CAP_LO = 32'h0F01003F;
    localparam [31:0] CAP_HI = 32'h00000020;
    localparam [31:0] VS_REG = 32'h00010400;

    reg [31:0]  intms;
    reg [31:0]  cc;
    reg [31:0]  aqa;
    reg [63:0]  asq_r;
    reg [63:0]  acq_r;
    reg [15:0]  sq0_tail_r;
    reg [15:0]  cq0_head_r;
    reg [31:0]  msix [0:127];

    wire [31:0] be_mask = { {8{wr_be[3]}}, {8{wr_be[2]}}, {8{wr_be[1]}}, {8{wr_be[0]}} };
    wire [11:0] wr_idx  = wr_addr[13:2];
    wire [11:0] rd_idx  = rd_addr[13:2];

    assign cc_en   = cc[0];
    assign asqs    = aqa[11:0];
    assign acqs    = aqa[27:16];
    assign asq     = asq_r;
    assign acq     = acq_r;
    assign sq0_tail = sq0_tail_r;
    assign msix0   = { msix[3],  msix[2],  msix[1],  msix[0]  };
    assign msix1   = { msix[7],  msix[6],  msix[5],  msix[4]  };
    assign msix2   = { msix[11], msix[10], msix[9],  msix[8]  };
    assign msix3   = { msix[15], msix[14], msix[13], msix[12] };

    // -------------------------------------------------------------------------
    // Read data (2 CLK latency)
    // -------------------------------------------------------------------------
    function [31:0] nvme_reg_read(input [11:0] idx);
        case ( idx )
            12'h000: nvme_reg_read = CAP_LO;
            12'h001: nvme_reg_read = CAP_HI;
            12'h002: nvme_reg_read = VS_REG;
            12'h003: nvme_reg_read = intms;
            12'h004: nvme_reg_read = 32'h00000000;                 // INTMC reads 0
            12'h005: nvme_reg_read = cc;
            12'h006: nvme_reg_read = 32'h00000000;
            12'h007: nvme_reg_read = { 31'd0, (cc[0] && (asq_r != 0) && (acq_r != 0)) };
            12'h009: nvme_reg_read = aqa;
            12'h00A: nvme_reg_read = asq_r[31:0];
            12'h00B: nvme_reg_read = asq_r[63:32];
            12'h00C: nvme_reg_read = acq_r[31:0];
            12'h00D: nvme_reg_read = acq_r[63:32];
            12'h400: nvme_reg_read = { 16'd0, sq0_tail_r };
            12'h401: nvme_reg_read = { 16'd0, cq0_head_r };
            default: nvme_reg_read = ((idx >= 12'h800) && (idx <= 12'h87F)) ?
                                      msix[idx[6:0]] : 32'h00000000;
        endcase
    endfunction

    bit [11:0] idx_d1;
    bit        vld_d1;

    always @ ( posedge clk ) begin
        idx_d1      <= rd_idx;
        vld_d1      <= rd_valid;
        rd_data     <= nvme_reg_read(idx_d1);
        rd_valid_o  <= vld_d1;
    end

    // -------------------------------------------------------------------------
    // Writes
    // -------------------------------------------------------------------------
    integer i;

    always @ ( posedge clk ) begin
        if ( rst ) begin
            intms       <= 32'd0;
            cc          <= 32'd0;
            aqa         <= 32'd0;
            asq_r       <= 64'd0;
            acq_r       <= 64'd0;
            sq0_tail_r  <= 16'd0;
            cq0_head_r  <= 16'd0;
            for ( i = 0; i < 128; i = i + 1 )
                msix[i] <= 32'd0;
        end
        else if ( wr_valid ) begin
            if ( (wr_idx >= 12'h800) && (wr_idx <= 12'h87F) )
                msix[wr_idx - 12'h800] <= (msix[wr_idx - 12'h800] & ~be_mask) | (wr_data & be_mask);
            else
            case ( wr_idx )
                12'h003: intms      <= (intms      & ~be_mask) | (wr_data & be_mask);
                12'h004: intms      <= intms & ~wr_data;           // INTMC
                12'h005: begin
                             cc <= (cc & ~be_mask) | (wr_data & be_mask);
                             // Controller disable resets the doorbells.
                             if ( wr_be[0] && !wr_data[0] ) begin
                                 sq0_tail_r <= 16'd0;
                                 cq0_head_r <= 16'd0;
                             end
                         end
                12'h009: aqa        <= (aqa        & ~be_mask) | (wr_data & be_mask);
                12'h00A: asq_r[31:0]  <= (asq_r[31:0]  & ~be_mask) | (wr_data & be_mask);
                12'h00B: asq_r[63:32] <= (asq_r[63:32] & ~be_mask) | (wr_data & be_mask);
                12'h00C: acq_r[31:0]  <= (acq_r[31:0]  & ~be_mask) | (wr_data & be_mask);
                12'h00D: acq_r[63:32] <= (acq_r[63:32] & ~be_mask) | (wr_data & be_mask);
                12'h400: sq0_tail_r <= wr_data[15:0];
                12'h401: cq0_head_r <= wr_data[15:0];
                default: ;
            endcase
        end
    end

endmodule
