// -----------------------------------------------------------------------------
// ACAP-100T : 1080p25 YUYV test-pattern source
//
// The source is demand-driven: hcnt/vcnt only advance when the DMA engine
// accepts a pixel.  A real HDMI receiver cannot be back-pressured, but this
// board has no video input connector; a deterministic on-chip pattern is the
// most honest way to exercise the complete capture/DMA/driver path.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_video #(
    parameter int WIDTH  = `ACAP_WIDTH,
    parameter int HEIGHT = `ACAP_HEIGHT,
    parameter int HTOTAL = `ACAP_HTOTAL,
    parameter int VTOTAL = `ACAP_VTOTAL
)(
    input           clk,
    input           rst,
    input           enable,
    input           pattern_sel,
    input           pix_ready,

    output          sof,
    output          pix_valid,
    output [15:0]   pix_data,
    output          frame_active
);

    localparam [11:0] W         = WIDTH[11:0];
    localparam [11:0] H         = HEIGHT[11:0];
    localparam [11:0] HT        = HTOTAL[11:0];
    localparam [11:0] VT        = VTOTAL[11:0];
    localparam [11:0] GRAD_START= (HEIGHT * 3 / 4);
    localparam [11:0] BOX_W     = (WIDTH / 10);
    localparam [11:0] BOX_H     = (HEIGHT / 9);
    localparam [11:0] BOX_Y     = (HEIGHT / 2);

    logic [11:0] hcnt;
    logic [11:0] vcnt;
    logic [11:0] box_x;

    wire advance = enable && pix_ready;

    always @ ( posedge clk ) begin
        if ( rst || !enable ) begin
            hcnt  <= 12'd0;
            vcnt  <= 12'd0;
            box_x <= 12'd0;
        end
        else if ( advance ) begin
            if ( hcnt == (HT - 12'd1) ) begin
                hcnt <= 12'd0;
                if ( vcnt == (VT - 12'd1) ) begin
                    vcnt  <= 12'd0;
                    box_x <= (box_x >= (W - BOX_W - 12'd8)) ? 12'd0 : (box_x + 12'd8);
                end
                else begin
                    vcnt <= vcnt + 12'd1;
                end
            end
            else begin
                hcnt <= hcnt + 12'd1;
            end
        end
    end

    assign sof          = enable && (hcnt == 12'd0) && (vcnt == 12'd0);
    assign pix_valid    = enable && (hcnt < W) && (vcnt < H);
    assign frame_active = enable && (vcnt < H);

    // -------------------------------------------------------------------------
    // Pattern generation
    // -------------------------------------------------------------------------
    logic [19:0] grad;
    logic [7:0]  y;
    logic [7:0]  cb;
    logic [7:0]  cr;
    logic        is_grad;
    logic        is_box;

    assign grad    = (hcnt * 12'd219) >> 11;
    assign is_grad = (vcnt >= GRAD_START);
    assign is_box  = (hcnt >= box_x) && (hcnt < (box_x + BOX_W)) &&
                     (vcnt >= BOX_Y) && (vcnt < (BOX_Y + BOX_H));

    always_comb begin
        // EBU-style 75% colour bars in BT.601 YCbCr
        case (hcnt[10:8])
            3'd0: begin y = 8'd235; cb = 8'd128; cr = 8'd128; end // white
            3'd1: begin y = 8'd210; cb = 8'd 16; cr = 8'd146; end // yellow
            3'd2: begin y = 8'd170; cb = 8'd166; cr = 8'd 16; end // cyan
            3'd3: begin y = 8'd145; cb = 8'd 54; cr = 8'd 34; end // green
            3'd4: begin y = 8'd106; cb = 8'd202; cr = 8'd222; end // magenta
            3'd5: begin y = 8'd 81; cb = 8'd 90; cr = 8'd240; end // red
            3'd6: begin y = 8'd 41; cb = 8'd240; cr = 8'd110; end // blue
            default: begin y = 8'd16; cb = 8'd128; cr = 8'd128; end // black
        endcase

        if ( pattern_sel ) begin
            y  = 8'd16 + grad[7:0];
            cb = 8'd128;
            cr = 8'd128;
        end
        if ( is_grad ) begin
            y  = 8'd16 + grad[7:0];
            cb = 8'd128;
            cr = 8'd128;
        end
        if ( is_box ) begin
            y  = 8'd235;
            cb = 8'd128;
            cr = 8'd128;
        end
    end

    // YUYV byte order in memory: Y0 Cb Y1 Cr.  The pixel word is {chroma, luma}.
    assign pix_data = { hcnt[0] ? cr : cb, y };

endmodule
