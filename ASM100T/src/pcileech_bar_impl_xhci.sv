// -----------------------------------------------------------------------------
// BAR0 implementation for the ASM1042 xHCI controller (64 kB aperture).
// Bridges the PCILeech BAR engines to xhci_regs and exports the controller
// state used by the command/event ring engine.  Latency = 2 CLKs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pcileech_bar_impl_xhci(
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
    output              xhci_usbcmd_rs,
    output              xhci_usbcmd_inte,
    output [63:0]       xhci_crcr,
    output              xhci_crcr_wr,
    output [63:0]       xhci_dcbaap,
    output [7:0]        xhci_config_max_slots,
    output [15:0]       xhci_erstsz,
    output [63:0]       xhci_erstba,
    output              xhci_erstba_wr,
    output [63:0]       xhci_erdp,
    output              xhci_iman_ie,
    output              xhci_db0_wr,
    output              xhci_hcrst,
    input               xhci_eint_set,
    input               xhci_ip_set,
    // MSI-X table lookup
    input  [2:0]        xhci_msix_sel,
    output [63:0]       xhci_msix_addr,
    output [31:0]       xhci_msix_data,
    output              xhci_msix_mask
);

    wire [31:0] regs_rd_data;
    wire        regs_rd_valid;

    xhci_regs i_xhci_regs(
        .clk                ( clk                   ),
        .rst                ( rst                   ),
        .wr_valid           ( wr_valid              ),
        .wr_addr            ( wr_addr[15:0]         ),
        .wr_data            ( wr_data               ),
        .wr_be              ( wr_be                 ),
        .rd_valid           ( rd_req_valid          ),
        .rd_addr            ( rd_req_addr[15:0]     ),
        .rd_data            ( regs_rd_data          ),
        .rd_valid_o         ( regs_rd_valid         ),
        .usbcmd_rs          ( xhci_usbcmd_rs        ),
        .usbcmd_inte        ( xhci_usbcmd_inte      ),
        .crcr               ( xhci_crcr             ),
        .crcr_wr            ( xhci_crcr_wr          ),
        .dcbaap             ( xhci_dcbaap           ),
        .config_max_slots   ( xhci_config_max_slots ),
        .erstsz             ( xhci_erstsz           ),
        .erstba             ( xhci_erstba           ),
        .erstba_wr          ( xhci_erstba_wr        ),
        .erdp               ( xhci_erdp             ),
        .iman_ie            ( xhci_iman_ie          ),
        .db0_wr             ( xhci_db0_wr           ),
        .xhci_hcrst         ( xhci_hcrst             ),
        .usbsts_eint_set    ( xhci_eint_set         ),
        .iman_ip_set        ( xhci_ip_set           ),
        .msix_sel           ( xhci_msix_sel         ),
        .msix_addr          ( xhci_msix_addr        ),
        .msix_data          ( xhci_msix_data        ),
        .msix_mask          ( xhci_msix_mask        )
    );

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
