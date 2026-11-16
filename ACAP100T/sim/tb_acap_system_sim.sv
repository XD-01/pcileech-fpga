// -----------------------------------------------------------------------------
// ACAP-100T system-level simulation: regs + video + DMA + MSI
//
// Programs one frame buffer through the BAR0 write bus, captures two frames,
// acknowledges the first buffer and checks the MSI TLP and the second frame's
// sequence number.  Simulation only; not part of the Vivado build.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module tb_acap_system_sim;

    localparam int W = 64;
    localparam int H = 32;
    localparam int HT = 80;
    localparam int VT = 40;
    localparam [63:0] BUF = 64'h0000_0000_1000_0000;

    reg clk = 1'b0;
    always #8 clk = ~clk;

    reg rst = 1'b1;

    // BAR write bus
    reg [31:0] bar_wr_addr = 32'd0;
    reg [3:0]  bar_wr_be = 4'h0;
    reg [31:0] bar_wr_data = 32'd0;
    reg        bar_wr_valid = 1'b0;

    // BAR read bus (unused, tied off)
    wire [87:0] bar_rd_rsp_ctx;
    wire [31:0] bar_rd_rsp_data;
    wire        bar_rd_rsp_valid;

    wire capture_enable, pattern_select;
    wire [2:0] irq_enable;
    wire next_buf_valid;
    wire [2:0] next_buf_index;
    wire [63:0] next_buf_addr;
    wire [31:0] frame_bytes_unused;

    wire sof, pix_valid, pix_ready, frame_active;
    wire [15:0] pix_data;

    wire frame_done_pulse, frame_stall, dma_busy;
    wire [2:0] frame_done_index;
    wire [31:0] frame_seq_out, frame_size_out;
    wire [63:0] frame_ts_out;

    IfAXIS128 axis();
    assign axis.tready = 1'b1;

    acap_regs #(.WIDTH(W), .HEIGHT(H)) u_regs (
        .clk               ( clk             ),
        .rst               ( rst             ),
        .bar_wr_addr       ( bar_wr_addr     ),
        .bar_wr_be         ( bar_wr_be       ),
        .bar_wr_data       ( bar_wr_data     ),
        .bar_wr_valid      ( bar_wr_valid    ),
        .bar_rd_ctx        ( 88'd0           ),
        .bar_rd_addr       ( 32'd0           ),
        .bar_rd_valid      ( 1'b0            ),
        .bar_rd_rsp_ctx    ( bar_rd_rsp_ctx  ),
        .bar_rd_rsp_data   ( bar_rd_rsp_data ),
        .bar_rd_rsp_valid  ( bar_rd_rsp_valid),
        .link_up           ( 1'b1            ),
        .ltssm             ( 6'd0            ),
        .link_width        ( 2'd1            ),
        .link_speed        ( 1'b1            ),
        .msi_en            ( 1'b1            ),
        .dma_busy          ( dma_busy        ),
        .frame_done_pulse  ( frame_done_pulse),
        .frame_done_index  ( frame_done_index),
        .frame_seq_in      ( frame_seq_out   ),
        .frame_ts_in       ( frame_ts_out    ),
        .frame_size_in     ( frame_size_out  ),
        .frame_stall       ( frame_stall     ),
        .capture_enable    ( capture_enable  ),
        .pattern_select    ( pattern_select  ),
        .frame_bytes       ( frame_bytes_unused),
        .irq_enable        ( irq_enable      ),
        .next_buf_valid    ( next_buf_valid  ),
        .next_buf_index    ( next_buf_index  ),
        .next_buf_addr     ( next_buf_addr   )
    );

    acap_video #(
        .WIDTH(W), .HEIGHT(H), .HTOTAL(HT), .VTOTAL(VT)
    ) u_video (
        .clk          ( clk           ),
        .rst          ( rst           ),
        .enable       ( capture_enable),
        .pattern_sel  ( pattern_select),
        .pix_ready    ( pix_ready     ),
        .sof          ( sof           ),
        .pix_valid    ( pix_valid     ),
        .pix_data     ( pix_data      ),
        .frame_active ( frame_active  )
    );

    acap_dma #(
        .WIDTH(W), .HEIGHT(H)
    ) u_dma (
        .clk               ( clk             ),
        .rst               ( rst             ),
        .pcie_id           ( 16'h0100        ),
        .sof               ( sof             ),
        .pix_valid         ( pix_valid       ),
        .pix_data          ( pix_data        ),
        .pix_ready         ( pix_ready       ),
        .capture_enable    ( capture_enable  ),
        .next_buf_valid    ( next_buf_valid  ),
        .next_buf_index    ( next_buf_index  ),
        .next_buf_addr     ( next_buf_addr   ),
        .msi_addr          ( 64'h0000_0000_FEE0_0000 ),
        .msi_data          ( 32'h0000_1234   ),
        .msi_en            ( 1'b1            ),
        .irq_enable        ( irq_enable      ),
        .frame_done_pulse  ( frame_done_pulse),
        .frame_done_index  ( frame_done_index),
        .frame_seq_out     ( frame_seq_out   ),
        .frame_ts_out      ( frame_ts_out    ),
        .frame_size_out    ( frame_size_out  ),
        .frame_stall       ( frame_stall     ),
        .dma_busy          ( dma_busy        ),
        .tlps_out          ( axis.source     )
    );

    integer tlp_count = 0;
    integer beats_left = 0;
    integer errors = 0;
    integer frames_done = 0;
    integer i;
    reg [31:0] hdr0_saved;
    reg [31:0] len_dw;
    reg [63:0] msi_seen_addr;
    reg [31:0] msi_seen_data;
    reg msi_seen;

    // -------------------------------------------------------------------------
    // TLP monitor
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if (axis.tvalid && axis.tready) begin
            if (beats_left == 0) begin
                hdr0_saved = axis.tdata[31:0];
                len_dw = axis.tdata[9:0];
                beats_left = 1 + ((len_dw + 3) / 4);
                tlp_count = tlp_count + 1;

                if (hdr0_saved == 32'h6000_0001) begin
                    msi_seen_addr = {axis.tdata[127:96], axis.tdata[95:64]};
                    msi_seen = 1'b1;
                    if (msi_seen_addr !== 64'h0000_0000_FEE0_0000) begin
                        $display("ERROR: MSI address %016x", msi_seen_addr);
                        errors = errors + 1;
                    end
                end
            end
            else begin
                if (hdr0_saved == 32'h6000_0020 && axis.tdata[31:0] == 32'h46524D31) begin
                    if (axis.tdata[95:64] !== (frames_done + 1)) begin
                        $display("ERROR: frame header seq %0d, expected %0d",
                                 axis.tdata[95:64], frames_done + 1);
                        errors = errors + 1;
                    end
                end
                if (hdr0_saved == 32'h6000_0001) begin
                    msi_seen_data = axis.tdata[31:0];
                    if (msi_seen_data !== 32'h0000_1234) begin
                        $display("ERROR: MSI data %08x", msi_seen_data);
                        errors = errors + 1;
                    end
                end
            end

            if (axis.tlast && beats_left != 1) begin
                $display("ERROR: TLP %0d tlast with %0d beats left", tlp_count, beats_left);
                errors = errors + 1;
            end
            beats_left = beats_left - 1;
        end
    end

    // -------------------------------------------------------------------------
    // Frame completion monitor
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if (frame_done_pulse) begin
            frames_done = frames_done + 1;
            $display("frame %0d done: seq=%0d size=%0d index=%0d tlps=%0d",
                     frames_done, frame_seq_out, frame_size_out,
                     frame_done_index, tlp_count);
            if (frames_done == 1) begin
                if (frame_seq_out !== 32'd1) errors = errors + 1;
                if (frame_done_index !== 3'd0) errors = errors + 1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // BAR write helper
    // -------------------------------------------------------------------------
    task automatic wr(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            bar_wr_addr = addr;
            bar_wr_data = data;
            bar_wr_be = 4'hF;
            bar_wr_valid = 1'b1;
            @(negedge clk);
            bar_wr_valid = 1'b0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------
    initial begin
        #100 rst = 1'b0;
        repeat (10) @(posedge clk);

        // Program buffer 0 at BUF and enable it.
        wr(32'h100, BUF[31:0]);
        wr(32'h104, BUF[63:32]);
        wr(32'h10C, 32'h1);       // valid
        wr(32'h040, 32'h1);       // buffer count = 1
        wr(32'h018, 32'h1);       // frame-done interrupt enable
        wr(32'h010, 32'h1);       // enable capture

        // First frame.
        wait (frames_done == 1);
        repeat (5) @(posedge clk);

        if (next_buf_valid !== 1'b0) begin
            $display("ERROR: buffer should not be free before ACK");
            errors = errors + 1;
        end
        if (!msi_seen) begin
            $display("ERROR: MSI TLP not observed");
            errors = errors + 1;
        end

        // Acknowledge buffer 0.
        wr(32'h050, 32'h1);
        repeat (5) @(posedge clk);
        if (next_buf_valid !== 1'b1) begin
            $display("ERROR: buffer not free after ACK");
            errors = errors + 1;
        end

        // Second frame.
        wait (frames_done == 2);
        repeat (5) @(posedge clk);

        $display("tlps=%0d frames=%0d errors=%0d", tlp_count, frames_done, errors);
        if (errors != 0)
            $fatal(1, "SYSTEM SIM FAILED with %0d errors", errors);
        $display("SYSTEM SIM PASSED");
        $finish;
    end

    initial begin
        #20000000;
        $display("TIMEOUT tlps=%0d frames=%0d", tlp_count, frames_done);
        $fatal(1, "SYSTEM SIM TIMEOUT");
    end

endmodule
