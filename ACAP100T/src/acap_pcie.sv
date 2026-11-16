// -----------------------------------------------------------------------------
// ACAP-100T : PCIe endpoint wrapper
//
// Reuses the proven CaptainDMA 100T 7-series PCIe core configuration:
//   Artix-7 XC7A100T-FGG484-2, PCIe Gen2 x1, AXI4-Stream (TLP) interface.
//
// The host-visible configuration space is emulated in acap_cfgspace.sv.  BAR0
// accesses are decoded by acap_bar.sv and reach the register file in
// acap_regs.sv.  DMA frames are injected into the third transmit arbiter input.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_pcie (
    input                   rst,
    input                   clk_sys,

    // PCIe fabric
    input                   pcie_clk_p,
    input                   pcie_clk_n,
    input  [0:0]            pcie_rx_p,
    input  [0:0]            pcie_rx_n,
    output [0:0]            pcie_tx_p,
    output [0:0]            pcie_tx_n,

    // User clock / reset
    output                  clk_pcie,
    output                  rst_subsys,
    output                  link_up,
    output [15:0]           pcie_id,
    output [5:0]            ltssm,
    output [1:0]            link_width,
    output                  link_speed,

    // DMA TLP source (from acap_dma)
    IfAXIS128.sink          tlps_dma,

    // BAR register bus
    output [31:0]           bar_wr_addr,
    output [3:0]            bar_wr_be,
    output [31:0]           bar_wr_data,
    output                  bar_wr_valid,
    output [87:0]           bar_rd_ctx,
    output [31:0]           bar_rd_addr,
    output                  bar_rd_valid,
    input  [87:0]           bar_rd_rsp_ctx,
    input  [31:0]           bar_rd_rsp_data,
    input                   bar_rd_rsp_valid,

    // MSI programming from the configuration space
    output [63:0]           msi_addr,
    output [31:0]           msi_data,
    output                  msi_en
);

    // -------------------------------------------------------------------------
    // Core-facing 64-bit AXI4-Stream
    // -------------------------------------------------------------------------
    wire [63:0] rx_tdata;
    wire [7:0]  rx_tkeep;
    wire        rx_tlast;
    wire [21:0] rx_tuser;
    wire        rx_tvalid;
    wire        rx_tready;

    wire [63:0] tx_tdata;
    wire [7:0]  tx_tkeep;
    wire        tx_tlast;
    wire        tx_tvalid;
    wire        tx_tready;

    // -------------------------------------------------------------------------
    // Internal 128-bit TLP interfaces
    // -------------------------------------------------------------------------
    IfAXIS128 tlps_rx();
    IfAXIS128 tlps_tx();
    IfAXIS128 tlps_cfg();
    IfAXIS128 tlps_bar();

    // -------------------------------------------------------------------------
    // Reference clock and core
    // -------------------------------------------------------------------------
    wire pcie_clk_c;
    wire user_lnk_up;
    wire rst_user;
    wire [7:0]  cfg_bus_number;
    wire [4:0]  cfg_device_number;
    wire [2:0]  cfg_function_number;
    wire [5:0]  pl_ltssm_state;
    wire [1:0]  pl_sel_lnk_width;
    wire        pl_sel_lnk_rate;

    IBUFDS_GTE2 refclk_ibuf (
        .O     ( pcie_clk_c ),
        .ODIV2 (            ),
        .I     ( pcie_clk_p ),
        .CEB   ( 1'b0       ),
        .IB    ( pcie_clk_n )
    );

    // -------------------------------------------------------------------------
    // User reset synchronised into the PCIe user clock domain
    // -------------------------------------------------------------------------
    reg [2:0] rst_sync;
    always @ ( posedge clk_pcie or posedge rst ) begin
        if ( rst )
            rst_sync <= 3'b111;
        else
            rst_sync <= { rst_sync[1:0], 1'b0 };
    end
    assign rst_subsys = rst_sync[2] || rst_user;

    assign link_up    = user_lnk_up;
    assign pcie_id    = { cfg_bus_number, cfg_device_number, cfg_function_number };
    assign ltssm      = pl_ltssm_state;
    assign link_width = pl_sel_lnk_width;
    assign link_speed = pl_sel_lnk_rate;

    // -------------------------------------------------------------------------
    // TLP receive conversion
    // -------------------------------------------------------------------------
    acap_tlps128_src64 i_rx_conv (
        .rst        ( rst_subsys    ),
        .clk_pcie   ( clk_pcie      ),
        .rx_tdata   ( rx_tdata      ),
        .rx_tkeep   ( rx_tkeep      ),
        .rx_tlast   ( rx_tlast      ),
        .rx_tuser   ( rx_tuser      ),
        .rx_tvalid  ( rx_tvalid     ),
        .rx_tready  ( rx_tready     ),
        .tlps_out   ( tlps_rx.source_lite )
    );

    // -------------------------------------------------------------------------
    // Configuration space and BAR decoder
    // -------------------------------------------------------------------------
    wire        cfg_wr_valid;
    wire [9:0]  cfg_wr_addr;
    wire [31:0] cfg_wr_data;
    wire [3:0]  cfg_wr_be;

    acap_cfgspace i_cfgspace (
        .rst            ( rst_subsys        ),
        .clk            ( clk_pcie          ),
        .tlps_in        ( tlps_rx.sink_lite ),
        .pcie_id        ( pcie_id           ),
        .tlps_cfg_rsp   ( tlps_cfg.source   ),
        .cfg_wr_valid   ( cfg_wr_valid      ),
        .cfg_wr_addr    ( cfg_wr_addr       ),
        .cfg_wr_data    ( cfg_wr_data       ),
        .cfg_wr_be      ( cfg_wr_be         ),
        .msi_addr       ( msi_addr          ),
        .msi_data       ( msi_data          ),
        .msi_en         ( msi_en            )
    );

    acap_bar_ctrl i_bar (
        .rst            ( rst_subsys        ),
        .clk            ( clk_pcie          ),
        .bar_en         ( 1'b1              ),
        .pcie_id        ( pcie_id           ),
        .tlps_in        ( tlps_rx.sink_lite ),
        .tlps_out       ( tlps_bar.source   ),
        .wr_addr        ( bar_wr_addr       ),
        .wr_be          ( bar_wr_be         ),
        .wr_data        ( bar_wr_data       ),
        .wr_valid       ( bar_wr_valid      ),
        .rd_req_ctx     ( bar_rd_ctx        ),
        .rd_req_addr    ( bar_rd_addr       ),
        .rd_req_valid   ( bar_rd_valid      ),
        .rd_rsp_ctx     ( bar_rd_rsp_ctx    ),
        .rd_rsp_data    ( bar_rd_rsp_data   ),
        .rd_rsp_valid   ( bar_rd_rsp_valid  )
    );

    // -------------------------------------------------------------------------
    // Mirror host BAR0 / command writes into the hard block
    // -------------------------------------------------------------------------
    wire cfg_mgmt_wr_en;
    wire [9:0] cfg_mgmt_dwaddr;
    wire [31:0] cfg_mgmt_di;
    wire [3:0] cfg_mgmt_byte_en;
    wire cfg_mgmt_wr_readonly;
    wire cfg_mgmt_wr_rw1c_as_rw;
    wire cfg_mgmt_rd_wr_done;

    acap_core_cfg i_core_cfg (
        .clk                   ( clk_pcie            ),
        .rst                   ( rst_subsys          ),
        .link_up               ( user_lnk_up         ),
        .cfg_wr_valid          ( cfg_wr_valid        ),
        .cfg_wr_addr           ( cfg_wr_addr         ),
        .cfg_wr_data           ( cfg_wr_data         ),
        .cfg_wr_be             ( cfg_wr_be           ),
        .cfg_mgmt_wr_en        ( cfg_mgmt_wr_en      ),
        .cfg_mgmt_dwaddr       ( cfg_mgmt_dwaddr     ),
        .cfg_mgmt_di           ( cfg_mgmt_di         ),
        .cfg_mgmt_byte_en      ( cfg_mgmt_byte_en    ),
        .cfg_mgmt_wr_readonly  ( cfg_mgmt_wr_readonly ),
        .cfg_mgmt_wr_rw1c_as_rw( cfg_mgmt_wr_rw1c_as_rw ),
        .cfg_mgmt_rd_wr_done   ( cfg_mgmt_rd_wr_done )
    );

    // -------------------------------------------------------------------------
    // Transmit arbitration and conversion
    // -------------------------------------------------------------------------
    acap_tlps128_mux3 i_tx_mux (
        .clk_pcie   ( clk_pcie          ),
        .rst        ( rst_subsys        ),
        .tlps_out   ( tlps_tx.source    ),
        .tlps_in1   ( tlps_cfg.sink     ),
        .tlps_in2   ( tlps_bar.sink     ),
        .tlps_in3   ( tlps_dma          )
    );

    acap_tlps128_dst64 i_tx_conv (
        .rst        ( rst_subsys        ),
        .clk_pcie   ( clk_pcie          ),
        .tlps_in    ( tlps_tx.sink      ),
        .tx_tdata   ( tx_tdata          ),
        .tx_tkeep   ( tx_tkeep          ),
        .tx_tlast   ( tx_tlast          ),
        .tx_tvalid  ( tx_tvalid         ),
        .tx_tready  ( tx_tready         )
    );

    // -------------------------------------------------------------------------
    // 7-series PCIe hard block
    // -------------------------------------------------------------------------
    pcie_7x_0 i_pcie_7x_0 (
        .pci_exp_txp                ( pcie_tx_p                 ),
        .pci_exp_txn                ( pcie_tx_n                 ),
        .pci_exp_rxp                ( pcie_rx_p                 ),
        .pci_exp_rxn                ( pcie_rx_n                 ),
        .sys_clk                    ( pcie_clk_c                ),
        .sys_rst_n                  ( ~rst                      ),

        .s_axis_tx_tdata            ( tx_tdata                  ),
        .s_axis_tx_tkeep            ( tx_tkeep                  ),
        .s_axis_tx_tlast            ( tx_tlast                  ),
        .s_axis_tx_tready           ( tx_tready                 ),
        .s_axis_tx_tuser            ( 4'b0                      ),
        .s_axis_tx_tvalid           ( tx_tvalid                 ),

        .m_axis_rx_tdata            ( rx_tdata                  ),
        .m_axis_rx_tkeep            ( rx_tkeep                  ),
        .m_axis_rx_tlast            ( rx_tlast                  ),
        .m_axis_rx_tready           ( rx_tready                 ),
        .m_axis_rx_tuser            ( rx_tuser                  ),
        .m_axis_rx_tvalid           ( rx_tvalid                 ),

        .cfg_mgmt_dwaddr            ( cfg_mgmt_dwaddr           ),
        .cfg_mgmt_byte_en           ( cfg_mgmt_byte_en          ),
        .cfg_mgmt_do                (                           ),
        .cfg_mgmt_rd_en             ( 1'b0                      ),
        .cfg_mgmt_rd_wr_done        ( cfg_mgmt_rd_wr_done       ),
        .cfg_mgmt_wr_readonly       ( cfg_mgmt_wr_readonly      ),
        .cfg_mgmt_wr_rw1c_as_rw     ( cfg_mgmt_wr_rw1c_as_rw    ),
        .cfg_mgmt_di                ( cfg_mgmt_di               ),
        .cfg_mgmt_wr_en             ( cfg_mgmt_wr_en            ),

        .cfg_interrupt_assert       ( 1'b0                      ),
        .cfg_interrupt              ( 1'b0                      ),
        .cfg_interrupt_mmenable     (                           ),
        .cfg_interrupt_msienable    (                           ),
        .cfg_interrupt_msixenable   (                           ),
        .cfg_interrupt_msixfm       (                           ),
        .cfg_pciecap_interrupt_msgnum ( 5'd0                    ),
        .cfg_interrupt_rdy          (                           ),
        .cfg_interrupt_do           (                           ),
        .cfg_interrupt_stat         ( 1'b0                      ),
        .cfg_interrupt_di           ( 8'd0                      ),

        .cfg_ds_bus_number          ( 8'd0                      ),
        .cfg_ds_device_number       ( 5'd0                      ),
        .cfg_ds_function_number     ( 3'd0                      ),
        .cfg_dsn                    ( 64'h4143415031303054      ),
        .cfg_pm_force_state         ( 2'd0                      ),
        .cfg_pm_force_state_en      ( 1'b0                      ),
        .cfg_pm_halt_aspm_l0s       ( 1'b0                      ),
        .cfg_pm_halt_aspm_l1        ( 1'b0                      ),
        .cfg_pm_send_pme_to         ( 1'b0                      ),
        .cfg_pm_wake                ( 1'b0                      ),
        .rx_np_ok                   ( 1'b1                      ),
        .rx_np_req                  ( 1'b1                      ),
        .cfg_trn_pending            ( 1'b0                      ),
        .cfg_turnoff_ok             ( 1'b0                      ),
        .tx_cfg_gnt                 ( 1'b1                      ),

        .cfg_command                (                           ),
        .cfg_bus_number             ( cfg_bus_number            ),
        .cfg_device_number          ( cfg_device_number         ),
        .cfg_function_number        ( cfg_function_number       ),
        .cfg_root_control_pme_int_en(                           ),
        .cfg_bridge_serr_en         (                           ),
        .cfg_dcommand               (                           ),
        .cfg_dcommand2              (                           ),
        .cfg_dstatus                (                           ),
        .cfg_lcommand               (                           ),
        .cfg_lstatus                (                           ),
        .cfg_pcie_link_state        (                           ),
        .cfg_pmcsr_pme_en           (                           ),
        .cfg_pmcsr_pme_status       (                           ),
        .cfg_pmcsr_powerstate       (                           ),
        .cfg_received_func_lvl_rst  (                           ),
        .cfg_status                 (                           ),
        .cfg_to_turnoff             (                           ),
        .tx_buf_av                  (                           ),
        .tx_cfg_req                 (                           ),
        .tx_err_drop                (                           ),
        .cfg_vc_tcvc_map            (                           ),
        .cfg_aer_rooterr_corr_err_received          (           ),
        .cfg_aer_rooterr_corr_err_reporting_en      (           ),
        .cfg_aer_rooterr_fatal_err_received         (           ),
        .cfg_aer_rooterr_fatal_err_reporting_en     (           ),
        .cfg_aer_rooterr_non_fatal_err_received     (           ),
        .cfg_aer_rooterr_non_fatal_err_reporting_en (           ),
        .cfg_root_control_syserr_corr_err_en        (           ),
        .cfg_root_control_syserr_fatal_err_en       (           ),
        .cfg_root_control_syserr_non_fatal_err_en   (           ),
        .cfg_slot_control_electromech_il_ctl_pulse  (           ),

        .pl_initial_link_width      (                           ),
        .pl_phy_lnk_up              (                           ),
        .pl_lane_reversal_mode      (                           ),
        .pl_link_gen2_cap           (                           ),
        .pl_link_partner_gen2_supported (                       ),
        .pl_link_upcfg_cap          (                           ),
        .pl_sel_lnk_rate            ( pl_sel_lnk_rate            ),
        .pl_sel_lnk_width           ( pl_sel_lnk_width           ),
        .pl_ltssm_state             ( pl_ltssm_state             ),
        .pl_rx_pm_state             (                           ),
        .pl_tx_pm_state             (                           ),
        .pl_directed_change_done    (                           ),
        .pl_received_hot_rst        (                           ),
        .pl_directed_link_auton     ( 1'b0                      ),
        .pl_directed_link_change    ( 2'b00                     ),
        .pl_directed_link_speed     ( 1'b1                      ),
        .pl_directed_link_width     ( 2'b00                     ),
        .pl_upstream_prefer_deemph  ( 1'b1                      ),
        .pl_transmit_hot_rst        ( 1'b0                      ),
        .pl_downstream_deemph_source( 1'b0                      ),

        .pcie_drp_clk               ( clk_sys                   ),
        .pcie_drp_en                ( 1'b0                      ),
        .pcie_drp_we                ( 1'b0                      ),
        .pcie_drp_addr              ( 9'd0                      ),
        .pcie_drp_di                ( 16'd0                     ),
        .pcie_drp_rdy               (                           ),
        .pcie_drp_do                (                           ),

        .user_clk_out               ( clk_pcie                  ),
        .user_reset_out             ( rst_user                  ),
        .user_lnk_up                ( user_lnk_up               ),
        .user_app_rdy               (                           )
    );

endmodule
