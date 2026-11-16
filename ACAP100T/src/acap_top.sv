// -----------------------------------------------------------------------------
// ACAP-100T : top level
//
// CaptainDMA 100T (Artix-7 XC7A100T-FGG484-2, PCIe Gen2 x1).
// The board's FT601 USB bridge is held in reset and is not used.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_top (
    input           clk,              // 100 MHz board oscillator
    output          user_ld1_n,
    output          user_ld2_n,
    input           user_sw1_n,
    input           user_sw2_n,
    output          ft601_rst_n,

    // PCIe edge connector
    output [0:0]    pcie_tx_p,
    output [0:0]    pcie_tx_n,
    input  [0:0]    pcie_rx_p,
    input  [0:0]    pcie_rx_n,
    input           pcie_clk_p,
    input           pcie_clk_n,
    input           pcie_perst_n,
    output          pcie_wake_n
);

    // -------------------------------------------------------------------------
    // Power-on reset (~10.5 ms) plus PERST# and the front-panel switch
    // -------------------------------------------------------------------------
    reg [19:0] por_cnt = 20'd0;
    wire       por_done = &por_cnt;

    always @ ( posedge clk ) begin
        if ( !por_done )
            por_cnt <= por_cnt + 20'd1;
    end

    wire sys_rst = ~por_done | ~pcie_perst_n | ~user_sw2_n;

    // -------------------------------------------------------------------------
    // PCIe / capture interfaces
    // -------------------------------------------------------------------------
    IfAXIS128 axis_dma();

    wire        clk_pcie;
    wire        rst_subsys;
    wire        link_up;
    wire [15:0] pcie_id;
    wire [5:0]  ltssm;
    wire [1:0]  link_width;
    wire        link_speed;

    wire [31:0] bar_wr_addr;
    wire [3:0]  bar_wr_be;
    wire [31:0] bar_wr_data;
    wire        bar_wr_valid;
    wire [87:0] bar_rd_ctx;
    wire [31:0] bar_rd_addr;
    wire        bar_rd_valid;
    wire [87:0] bar_rd_rsp_ctx;
    wire [31:0] bar_rd_rsp_data;
    wire        bar_rd_rsp_valid;

    wire [63:0] msi_addr;
    wire [31:0] msi_data;
    wire        msi_en;

    wire        capture_enable;
    wire        pattern_select;
    wire [2:0]  irq_enable;
    wire        next_buf_valid;
    wire [2:0]  next_buf_index;
    wire [63:0] next_buf_addr;

    wire        frame_done_pulse;
    wire [2:0]  frame_done_index;
    wire [31:0] frame_seq;
    wire [63:0] frame_ts;
    wire [31:0] frame_size;
    wire        frame_stall;
    wire        dma_busy;

    wire        sof;
    wire        pix_valid;
    wire [15:0] pix_data;
    wire        pix_ready;
    wire        frame_active;

    acap_pcie i_pcie (
        .rst                ( sys_rst           ),
        .clk_sys            ( clk               ),
        .pcie_clk_p         ( pcie_clk_p        ),
        .pcie_clk_n         ( pcie_clk_n        ),
        .pcie_rx_p          ( pcie_rx_p         ),
        .pcie_rx_n          ( pcie_rx_n         ),
        .pcie_tx_p          ( pcie_tx_p         ),
        .pcie_tx_n          ( pcie_tx_n         ),
        .clk_pcie           ( clk_pcie          ),
        .rst_subsys         ( rst_subsys        ),
        .link_up            ( link_up           ),
        .pcie_id            ( pcie_id           ),
        .ltssm              ( ltssm             ),
        .link_width         ( link_width        ),
        .link_speed         ( link_speed        ),
        .tlps_dma           ( axis_dma.sink     ),
        .bar_wr_addr        ( bar_wr_addr       ),
        .bar_wr_be          ( bar_wr_be         ),
        .bar_wr_data        ( bar_wr_data       ),
        .bar_wr_valid       ( bar_wr_valid      ),
        .bar_rd_ctx         ( bar_rd_ctx        ),
        .bar_rd_addr        ( bar_rd_addr       ),
        .bar_rd_valid       ( bar_rd_valid      ),
        .bar_rd_rsp_ctx     ( bar_rd_rsp_ctx    ),
        .bar_rd_rsp_data    ( bar_rd_rsp_data   ),
        .bar_rd_rsp_valid   ( bar_rd_rsp_valid  ),
        .msi_addr           ( msi_addr          ),
        .msi_data           ( msi_data          ),
        .msi_en             ( msi_en            )
    );

    acap_regs i_regs (
        .clk                ( clk_pcie          ),
        .rst                ( rst_subsys        ),
        .bar_wr_addr        ( bar_wr_addr       ),
        .bar_wr_be          ( bar_wr_be         ),
        .bar_wr_data        ( bar_wr_data       ),
        .bar_wr_valid       ( bar_wr_valid      ),
        .bar_rd_ctx         ( bar_rd_ctx        ),
        .bar_rd_addr        ( bar_rd_addr       ),
        .bar_rd_valid       ( bar_rd_valid      ),
        .bar_rd_rsp_ctx     ( bar_rd_rsp_ctx    ),
        .bar_rd_rsp_data    ( bar_rd_rsp_data   ),
        .bar_rd_rsp_valid   ( bar_rd_rsp_valid  ),
        .link_up            ( link_up           ),
        .ltssm              ( ltssm             ),
        .link_width         ( link_width        ),
        .link_speed         ( link_speed        ),
        .msi_en             ( msi_en            ),
        .dma_busy           ( dma_busy          ),
        .frame_done_pulse   ( frame_done_pulse  ),
        .frame_done_index   ( frame_done_index  ),
        .frame_seq_in       ( frame_seq         ),
        .frame_ts_in        ( frame_ts          ),
        .frame_size_in      ( frame_size        ),
        .frame_stall        ( frame_stall       ),
        .capture_enable     ( capture_enable    ),
        .pattern_select     ( pattern_select    ),
        .frame_bytes        (                   ),
        .irq_enable         ( irq_enable        ),
        .next_buf_valid     ( next_buf_valid    ),
        .next_buf_index     ( next_buf_index    ),
        .next_buf_addr      ( next_buf_addr     )
    );

    // Front-panel switch SW1 inverts the selected pattern.
    reg [1:0] sw1_sync;
    always @ ( posedge clk_pcie or posedge rst_subsys ) begin
        if ( rst_subsys )
            sw1_sync <= 2'b00;
        else
            sw1_sync <= { sw1_sync[0], user_sw1_n };
    end
    wire sw1_pattern = ~sw1_sync[1];

    acap_video i_video (
        .clk            ( clk_pcie          ),
        .rst            ( rst_subsys        ),
        .enable         ( capture_enable    ),
        .pattern_sel    ( pattern_select ^ sw1_pattern ),
        .pix_ready      ( pix_ready         ),
        .sof            ( sof               ),
        .pix_valid      ( pix_valid         ),
        .pix_data       ( pix_data          ),
        .frame_active   ( frame_active      )
    );

    acap_dma i_dma (
        .clk                ( clk_pcie          ),
        .rst                ( rst_subsys        ),
        .pcie_id            ( pcie_id           ),
        .sof                ( sof               ),
        .pix_valid          ( pix_valid         ),
        .pix_data           ( pix_data          ),
        .pix_ready          ( pix_ready         ),
        .capture_enable     ( capture_enable    ),
        .next_buf_valid     ( next_buf_valid    ),
        .next_buf_index     ( next_buf_index    ),
        .next_buf_addr      ( next_buf_addr     ),
        .msi_addr           ( msi_addr          ),
        .msi_data           ( msi_data          ),
        .msi_en             ( msi_en            ),
        .irq_enable         ( irq_enable        ),
        .frame_done_pulse   ( frame_done_pulse  ),
        .frame_done_index   ( frame_done_index  ),
        .frame_seq_out      ( frame_seq         ),
        .frame_ts_out       ( frame_ts          ),
        .frame_size_out     ( frame_size        ),
        .frame_stall        ( frame_stall       ),
        .dma_busy           ( dma_busy          ),
        .tlps_out           ( axis_dma.source   )
    );

    // -------------------------------------------------------------------------
    // Board housekeeping
    // -------------------------------------------------------------------------
    reg [23:0] heartbeat = 24'd0;
    always @ ( posedge clk_pcie )
        heartbeat <= heartbeat + 24'd1;

    assign user_ld1_n = ~link_up;
    assign user_ld2_n = ~(dma_busy ? 1'b1 : heartbeat[23]);

    assign ft601_rst_n = 1'b0;       // USB bridge unused, held in reset
    assign pcie_wake_n = 1'b1;

endmodule
