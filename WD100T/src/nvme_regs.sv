// -----------------------------------------------------------------------------
// NVMe controller register file (BAR0, 16 kB aperture) for the WD SN850
// emulation: 32 MSI-X vectors, 5 doorbell sets (admin + 4 I/O queues).
//
//  0x0000 CAP         0x0008 VS          0x000C INTMS / 0x0010 INTMC
//  0x0014 CC          0x001C CSTS        0x0024 AQA
//  0x0028 ASQ         0x0030 ACQ
//  0x1000 + q*8 SQ tail doorbell / +4 CQ head doorbell (q = 0..4)
//  0x2000 MSI-X table (32 vectors)      0x3000 MSI-X PBA
//
// Read latency: 2 CLKs.
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
    // Controller state
    output              cc_en,
    output [11:0]       asqs,
    output [11:0]       acqs,
    output [63:0]       asq,
    output [63:0]       acq,
    output [15:0]       sq0_tail,
    output [15:0]       sq_tail1,
    output [15:0]       sq_tail2,
    output [15:0]       sq_tail3,
    output [15:0]       sq_tail4,
    // MSI-X table lookup port
    input  [4:0]        msix_sel,
    output [63:0]       msix_addr,
    output [31:0]       msix_data,
    output              msix_mask,
    // MSI-X PBA update
    input               pba_set,
    input  [4:0]        pba_idx,
    input               pba_clr,
    input  [4:0]        pba_clr_idx
);

    localparam [31:0] CAP_LO = 32'h0F01003F;   // MQES=63, CQR=1, TO=0xF
    localparam [31:0] CAP_HI = 32'h00000020;   // CSS = NVM command set
    localparam [31:0] VS_REG = 32'h00010400;   // NVMe 1.4

    reg [31:0]  intms;
    reg [31:0]  cc;
    reg [31:0]  aqa;
    reg [63:0]  asq_r;
    reg [63:0]  acq_r;
    reg [15:0]  sq_tail [0:4];
    reg [15:0]  cq_head [0:4];
    reg [31:0]  msix [0:127];       // 32 vectors x 4 dwords
    reg [31:0]  pba;

    wire [31:0] be_mask = { {8{wr_be[3]}}, {8{wr_be[2]}}, {8{wr_be[1]}}, {8{wr_be[0]}} };
    wire [11:0] wr_idx  = wr_addr[13:2];
    wire [11:0] rd_idx  = rd_addr[13:2];

    assign cc_en    = cc[0];
    assign asqs     = aqa[11:0];
    assign acqs     = aqa[27:16];
    assign asq      = asq_r;
    assign acq      = acq_r;
    assign sq0_tail = sq_tail[0];
    assign sq_tail1 = sq_tail[1];
    assign sq_tail2 = sq_tail[2];
    assign sq_tail3 = sq_tail[3];
    assign sq_tail4 = sq_tail[4];

    // -------------------------------------------------------------------------
    // MSI-X table lookup
    // -------------------------------------------------------------------------
    wire [6:0] msix_base = { msix_sel, 2'b00 };
    assign msix_addr = { msix[msix_base + 7'd1], msix[msix_base] };
    assign msix_data = msix[msix_base + 7'd2];
    assign msix_mask = msix[msix_base + 7'd3][0];

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
            12'h400: nvme_reg_read = { 16'd0, sq_tail[0] };
            12'h401: nvme_reg_read = { 16'd0, cq_head[0] };
            12'h402: nvme_reg_read = { 16'd0, sq_tail[1] };
            12'h403: nvme_reg_read = { 16'd0, cq_head[1] };
            12'h404: nvme_reg_read = { 16'd0, sq_tail[2] };
            12'h405: nvme_reg_read = { 16'd0, cq_head[2] };
            12'h406: nvme_reg_read = { 16'd0, sq_tail[3] };
            12'h407: nvme_reg_read = { 16'd0, cq_head[3] };
            12'h408: nvme_reg_read = { 16'd0, sq_tail[4] };
            12'h409: nvme_reg_read = { 16'd0, cq_head[4] };
            12'hC00: nvme_reg_read = pba;
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
            for ( i = 0; i < 5; i = i + 1 ) begin
                sq_tail[i] <= 16'd0;
                cq_head[i] <= 16'd0;
            end
            for ( i = 0; i < 128; i = i + 1 )
                msix[i] <= 32'd0;
            pba <= 32'd0;
        end
        else begin
            if ( wr_valid ) begin
                if ( (wr_idx >= 12'h800) && (wr_idx <= 12'h87F) )
                    msix[wr_idx[6:0]] <= (msix[wr_idx[6:0]] & ~be_mask) | (wr_data & be_mask);
                else if ( (wr_idx >= 12'h400) && (wr_idx <= 12'h409) && !wr_idx[0] )
                    sq_tail[(wr_idx - 12'h400) >> 1] <= wr_data[15:0];
                else case ( wr_idx )
                    12'h003: intms <= (intms & ~be_mask) | (wr_data & be_mask);
                    12'h004: intms <= intms & ~wr_data;            // INTMC
                    12'h005: begin
                                 cc <= (cc & ~be_mask) | (wr_data & be_mask);
                                 if ( wr_be[0] && !wr_data[0] ) begin
                                     sq_tail[0] <= 16'd0;
                                     cq_head[0] <= 16'd0;
                                     sq_tail[1] <= 16'd0;
                                     sq_tail[2] <= 16'd0;
                                     sq_tail[3] <= 16'd0;
                                     sq_tail[4] <= 16'd0;
                                     cq_head[1] <= 16'd0;
                                     cq_head[2] <= 16'd0;
                                     cq_head[3] <= 16'd0;
                                     cq_head[4] <= 16'd0;
                                 end
                             end
                    12'h009: aqa           <= (aqa           & ~be_mask) | (wr_data & be_mask);
                    12'h00A: asq_r[31:0]   <= (asq_r[31:0]   & ~be_mask) | (wr_data & be_mask);
                    12'h00B: asq_r[63:32]  <= (asq_r[63:32]  & ~be_mask) | (wr_data & be_mask);
                    12'h00C: acq_r[31:0]   <= (acq_r[31:0]   & ~be_mask) | (wr_data & be_mask);
                    12'h00D: acq_r[63:32]  <= (acq_r[63:32]  & ~be_mask) | (wr_data & be_mask);
                    default: ;
                endcase
            end
            // PBA updates
            if ( pba_set && (pba_idx < 5'd32) )
                pba[pba_idx] <= 1'b1;
            if ( pba_clr && (pba_clr_idx < 5'd32) )
                pba[pba_clr_idx] <= 1'b0;
        end
    end

endmodule
