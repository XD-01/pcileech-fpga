// -----------------------------------------------------------------------------
// BAR0 implementation for the NVMe controller: bridges the PCILeech BAR
// read/write engines to nvme_regs (16 kB aperture) and exports the controller
// state consumed by the admin command engine.
// Latency = 2 CLKs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pcileech_bar_impl_nvme(
    input               rst,
    input               clk,
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    output bit [87:0]   rd_rsp_ctx,
    output [31:0]       rd_rsp_data,
    output              rd_rsp_valid,
    // controller state
    output              nvme_cc_en,
    output [11:0]       nvme_asqs,
    output [11:0]       nvme_acqs,
    output [63:0]       nvme_asq,
    output [63:0]       nvme_acq,
    output [15:0]       nvme_sq0_tail,
    output [15:0]       nvme_sq_tail1,
    output [15:0]       nvme_sq_tail2,
    output [15:0]       nvme_sq_tail3,
    output [15:0]       nvme_sq_tail4,
    // MSI-X table lookup
    input  [4:0]        nvme_msix_sel,
    output [63:0]       nvme_msix_addr,
    output [31:0]       nvme_msix_data,
    output              nvme_msix_mask,
    // MSI-X PBA
    input               nvme_pba_set,
    input  [4:0]        nvme_pba_idx,
    input               nvme_pba_clr,
    input  [4:0]        nvme_pba_clr_idx
);

    wire [31:0] regs_rd_data;
    wire        regs_rd_valid;

    nvme_regs i_nvme_regs(
        .clk            ( clk               ),
        .rst            ( rst               ),
        .wr_valid       ( wr_valid          ),
        .wr_addr        ( wr_addr[13:0]     ),
        .wr_data        ( wr_data           ),
        .wr_be          ( wr_be             ),
        .rd_valid       ( rd_req_valid      ),
        .rd_addr        ( rd_req_addr[13:0] ),
        .rd_data        ( regs_rd_data      ),
        .rd_valid_o     ( regs_rd_valid     ),
        .cc_en          ( nvme_cc_en        ),
        .asqs           ( nvme_asqs         ),
        .acqs           ( nvme_acqs         ),
        .asq            ( nvme_asq          ),
        .acq            ( nvme_acq          ),
        .sq0_tail       ( nvme_sq0_tail     ),
        .sq_tail1       ( nvme_sq_tail1     ),
        .sq_tail2       ( nvme_sq_tail2     ),
        .sq_tail3       ( nvme_sq_tail3     ),
        .sq_tail4       ( nvme_sq_tail4     ),
        .msix_sel       ( nvme_msix_sel     ),
        .msix_addr      ( nvme_msix_addr    ),
        .msix_data      ( nvme_msix_data    ),
        .msix_mask      ( nvme_msix_mask    ),
        .pba_set        ( nvme_pba_set      ),
        .pba_idx        ( nvme_pba_idx      ),
        .pba_clr        ( nvme_pba_clr      ),
        .pba_clr_idx    ( nvme_pba_clr_idx  )
    );

    // Context is delayed by the same two clock cycles as the read data.
    bit [87:0] ctx_d1;
    bit [87:0] ctx_d2;

    always @ ( posedge clk ) begin
        ctx_d1     <= rd_req_ctx;
        ctx_d2     <= ctx_d1;
        rd_rsp_ctx <= ctx_d2;
    end

    assign rd_rsp_data  = regs_rd_data;
    assign rd_rsp_valid = regs_rd_valid;

endmodule
