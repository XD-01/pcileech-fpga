// -----------------------------------------------------------------------------
// ACAP-100T simulation-only testbench
//
// Drives the video source and frame DMA with a small 64x32 frame so a complete
// frame can be verified quickly.  Not included in the Vivado build.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module tb_acap_sim;

    localparam int W = 64;
    localparam int H = 32;
    localparam int HT = 80;
    localparam int VT = 40;
    localparam [63:0] BUF = 64'h0000_0000_1000_0000;

    reg clk = 1'b0;
    always #8 clk = ~clk;               // 62.5 MHz

    reg rst = 1'b1;
    reg capture_enable = 1'b0;
    reg next_buf_valid = 1'b0;
    reg [2:0] next_buf_index = 3'd0;
    reg [63:0] next_buf_addr = BUF;
    reg [63:0] msi_addr = 64'd0;
    reg [31:0] msi_data = 32'd0;
    reg msi_en = 1'b0;
    reg [2:0] irq_enable = 3'd0;

    wire sof, pix_valid, pix_ready, frame_active;
    wire [15:0] pix_data;
    wire frame_done_pulse, frame_stall, dma_busy;
    wire [2:0] frame_done_index;
    wire [31:0] frame_seq_out, frame_size_out;
    wire [63:0] frame_ts_out;

    IfAXIS128 axis();
    assign axis.tready = 1'b1;

    acap_video #(
        .WIDTH(W), .HEIGHT(H), .HTOTAL(HT), .VTOTAL(VT)
    ) u_video (
        .clk          ( clk           ),
        .rst          ( rst           ),
        .enable       ( capture_enable),
        .pattern_sel  ( 1'b0          ),
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
        .msi_addr          ( msi_addr        ),
        .msi_data          ( msi_data        ),
        .msi_en            ( msi_en          ),
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
    integer beat_count = 0;
    integer errors = 0;
    integer i;
    reg [31:0] dw0, dw1, dw2, dw3;
    reg [63:0] cur_addr;
    reg [31:0] first_pixel_dw;

    always @ ( posedge clk ) begin
        if (axis.tvalid && axis.tready) begin
            if ((beat_count % 9) == 0) begin
                dw0 = axis.tdata[31:0];
                dw1 = axis.tdata[63:32];
                dw2 = axis.tdata[95:64];
                dw3 = axis.tdata[127:96];
                cur_addr = {dw3, dw2[31:2], 2'b00};
                if (dw0 !== 32'h6000_0020) begin
                    $display("ERROR: TLP %0d bad header DW0 %08x", tlp_count, dw0);
                    errors = errors + 1;
                end
                if (cur_addr !== (BUF + tlp_count * 128)) begin
                    $display("ERROR: TLP %0d bad address %016x", tlp_count, cur_addr);
                    errors = errors + 1;
                end
                if (tlp_count == 0 && beat_count == 0) begin
                    if (dw1[31:16] !== 16'h0100) begin
                        $display("ERROR: requester id %04x", dw1[31:16]);
                        errors = errors + 1;
                    end
                end
            end

            if (tlp_count == 0 && (beat_count % 9) == 1) begin
                if (axis.tdata[31:0] !== 32'h46524D31) begin
                    $display("ERROR: frame magic0 %08x", axis.tdata[31:0]);
                    errors = errors + 1;
                end
            end
            if (tlp_count == 0 && (beat_count % 9) == 2) begin
                if (axis.tdata[31:0] !== 32'h0000_0100) begin // flags=1, format=0
                    $display("ERROR: frame format/flags %08x", axis.tdata[31:0]);
                    errors = errors + 1;
                end
                if (axis.tdata[63:32] !== 32'd128) begin // stride = 64*2
                    $display("ERROR: frame stride %0d", axis.tdata[63:32]);
                    errors = errors + 1;
                end
            end

            if (tlp_count == 1 && (beat_count % 9) == 1) begin
                first_pixel_dw = axis.tdata[31:0];
                if (first_pixel_dw !== 32'h80EB_80EB) begin
                    $display("ERROR: first pixels %08x", first_pixel_dw);
                    errors = errors + 1;
                end
            end

            if (axis.tlast)
                tlp_count = tlp_count + 1;
            beat_count = beat_count + 1;
        end
    end

    always @ ( posedge clk ) begin
        if (frame_done_pulse) begin
            $display("FRAME DONE seq=%0d size=%0d index=%0d tlps=%0d beats=%0d errors=%0d",
                     frame_seq_out, frame_size_out, frame_done_index,
                     tlp_count, beat_count, errors);
            if (frame_seq_out !== 32'd1) errors = errors + 1;
            if (frame_size_out !== 32'd4224) errors = errors + 1;
            if (tlp_count !== 33) errors = errors + 1;
            if (errors != 0)
                $fatal(1, "SIM FAILED with %0d errors", errors);
            $display("SIM PASSED");
            $finish;
        end
    end

    initial begin
        #100 rst = 1'b0;
        repeat (10) @(posedge clk);
        next_buf_valid = 1'b1;
        capture_enable = 1'b1;
        #5000000;
        $display("TIMEOUT tlps=%0d beats=%0d errors=%0d", tlp_count, beat_count, errors);
        $fatal(1, "SIM TIMEOUT");
    end

endmodule
