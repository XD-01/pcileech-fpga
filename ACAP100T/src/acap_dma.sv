// -----------------------------------------------------------------------------
// ACAP-100T : frame DMA engine
//
// Each frame is written into one host frame buffer as a sequence of 128-byte
// posted memory-write TLPs:
//
//   offset 0      128-byte block : 32-byte frame header + 96 zero bytes
//   offset 128..  YUYV payload, 128 bytes per TLP
//
// The source is back-pressured, so the FIFO only fills if the PCIe link stalls.
// A 16-entry beat FIFO (256 bytes) decouples pixel packing from TLP framing.
//
// A frame completion raises an MSI (if enabled) and sets the buffer's done bit
// in acap_regs.  The driver acknowledges the buffer through BAR0.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_dma #(
    parameter int WIDTH  = `ACAP_WIDTH,
    parameter int HEIGHT = `ACAP_HEIGHT
)(
    input                   clk,
    input                   rst,
    input [15:0]            pcie_id,

    // Video source
    input                   sof,
    input                   pix_valid,
    input  [15:0]           pix_data,
    output logic            pix_ready,

    // Control / buffer ring
    input                   capture_enable,
    input                   next_buf_valid,
    input  [2:0]            next_buf_index,
    input  [63:0]           next_buf_addr,

    // MSI
    input  [63:0]           msi_addr,
    input  [31:0]           msi_data,
    input                   msi_en,
    input  [2:0]            irq_enable,

    // Completion status
    output logic            frame_done_pulse,
    output logic [2:0]      frame_done_index,
    output logic [31:0]     frame_seq_out,
    output logic [63:0]     frame_ts_out,
    output logic [31:0]     frame_size_out,
    output logic            frame_stall,
    output                  dma_busy,

    // TLP output
    IfAXIS128.source        tlps_out
);

    localparam int TOTAL_PIXELS = WIDTH * HEIGHT;
    localparam int VIDEO_BYTES  = TOTAL_PIXELS * 2;
    localparam int VIDEO_TLPS   = (VIDEO_BYTES + 127) / 128;
    localparam int FRAME_BYTES  = 128 + VIDEO_TLPS * 128;

    localparam [31:0] FRAME_BYTES32 = FRAME_BYTES;
    localparam [15:0] LAST_TLP      = 16'(VIDEO_TLPS - 1);
    localparam int    FIFO_DEPTH    = 16;

    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_HDR  = 3'd1;
    localparam [2:0] S_VID  = 3'd2;
    localparam [2:0] S_MSI  = 3'd3;

    wire dma_rst = rst || !capture_enable;

    // -------------------------------------------------------------------------
    // Frame-sequencing state (declared early because the packer uses it)
    // -------------------------------------------------------------------------
    logic [2:0]  tlp_state;
    logic [3:0]  beat_idx;
    logic [15:0] tlp_idx;
    logic [63:0] buf_addr;
    logic [2:0]  buf_index;
    logic [63:0] frame_ts;
    logic [31:0] seq;
    logic        stall_latched;

    wire start_frame = (tlp_state == S_IDLE) && capture_enable && sof && next_buf_valid;

    // -------------------------------------------------------------------------
    // Timestamp: 62.5 MHz user clock, 16 ns per tick
    // -------------------------------------------------------------------------
    logic [63:0] ts;
    always @ ( posedge clk ) begin
        if ( rst )
            ts <= 64'd0;
        else
            ts <= ts + 64'd16;
    end

    // -------------------------------------------------------------------------
    // Beat FIFO: 128-bit x 16
    // -------------------------------------------------------------------------
    logic [127:0] beat_mem [0:FIFO_DEPTH-1];
    logic [4:0]   wr_ptr;
    logic [4:0]   rd_ptr;
    logic [4:0]   beat_count;
    logic [127:0] beat_push_data;
    logic         beat_push;
    logic         beat_pop;

    wire          beat_empty = (beat_count == 5'd0);
    wire          beat_full  = (beat_count == 5'd16);
    wire [127:0]  beat_dout  = beat_mem[rd_ptr[3:0]];

    always @ ( posedge clk ) begin
        if (dma_rst) begin
            wr_ptr     <= 5'd0;
            rd_ptr     <= 5'd0;
            beat_count <= 5'd0;
        end
        else begin
            if (beat_push && !beat_full)
                beat_mem[wr_ptr[3:0]] <= beat_push_data;
            if (beat_pop && !beat_empty)
                rd_ptr <= rd_ptr + 5'd1;
            beat_count <= beat_count +
                          (beat_push && !beat_full ? 5'd1 : 5'd0) -
                          (beat_pop  && !beat_empty ? 5'd1 : 5'd0);
        end
    end

    // -------------------------------------------------------------------------
    // Pixel packer: 8 YUYV pixels -> one 128-bit beat
    // -------------------------------------------------------------------------
    logic [127:0] pack_beat;
    logic [2:0]   pack_lane;
    logic [31:0]  pix_count;
    logic         pack_done;
    logic [127:0] pack_beat_next;

    wire pack_last_pixel = (pix_count == (TOTAL_PIXELS[31:0] - 32'd1));

    always_comb begin
        pack_beat_next = pack_beat;
        pack_beat_next[{pack_lane, 4'b0000} +: 16] = pix_data;
    end

    wire pix_accept = capture_enable && pix_valid && pix_ready && !pack_done &&
                      ((tlp_state == S_HDR) || (tlp_state == S_VID));

    assign beat_push      = pix_accept && ((pack_lane == 3'd7) || pack_last_pixel);
    assign beat_push_data = pack_beat_next;

    always @ ( posedge clk ) begin
        if (dma_rst || start_frame) begin
            pack_beat <= 128'd0;
            pack_lane <= 3'd0;
            pix_count <= 32'd0;
            pack_done <= 1'b0;
        end
        else if (pix_accept) begin
            pix_count <= pix_count + 32'd1;
            if (pack_lane == 3'd7 || pack_last_pixel) begin
                pack_beat <= 128'd0;
                pack_lane <= 3'd0;
            end
            else begin
                pack_beat <= pack_beat_next;
                pack_lane <= pack_lane + 3'd1;
            end
            if (pack_last_pixel)
                pack_done <= 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // TLP header builders
    // -------------------------------------------------------------------------
    wire [31:0] hdr_dw0 = 32'h6000_0020;                    // 4DW MemWr, 32 DW
    wire [31:0] hdr_dw1 = { pcie_id, 8'h00, 4'hF, 4'hF };

    wire [63:0] vid_addr = buf_addr + 64'd128 + ({48'd0, tlp_idx} << 7);

    wire [127:0] hdr_beat0 = { buf_addr[63:32], {buf_addr[31:2], 2'b00}, hdr_dw1, hdr_dw0 };
    wire [127:0] hdr_beat1 = { vid_addr[63:32], {vid_addr[31:2], 2'b00}, hdr_dw1, hdr_dw0 };

    wire [31:0] msi_dw1 = { pcie_id, 8'h00, 4'h1, 4'h1 };
    wire [127:0] msi_hdr = { msi_addr[63:32], {msi_addr[31:2], 2'b00}, msi_dw1, 32'h6000_0001 };

    // Frame header block (32 bytes) in two beats
    wire [31:0] fh_dw0 = `ACAP_HDR_MAGIC0;
    wire [31:0] fh_dw1 = `ACAP_HDR_MAGIC1;
    wire [31:0] fh_dw2 = seq + 32'd1;
    wire [31:0] fh_dw3 = { HEIGHT[15:0], WIDTH[15:0] };
    wire [31:0] fh_dw4 = { 16'h0000, 8'h01, `ACAP_FORMAT_YUYV };
    wire [31:0] fh_dw5 = WIDTH[31:0] * 32'd2;
    wire [31:0] fh_dw6 = frame_ts[31:0];
    wire [31:0] fh_dw7 = frame_ts[63:32];
    wire [127:0] fh_beat0 = { fh_dw3, fh_dw2, fh_dw1, fh_dw0 };
    wire [127:0] fh_beat1 = { fh_dw7, fh_dw6, fh_dw5, fh_dw4 };

    // -------------------------------------------------------------------------
    // Output beat multiplexing
    // -------------------------------------------------------------------------
    logic [127:0] out_beat;
    logic [3:0]   out_keep;
    logic         out_last;
    logic         out_valid;

    always_comb begin
        out_beat  = 128'd0;
        out_keep  = 4'hF;
        out_last  = 1'b0;
        out_valid = 1'b0;

        case (tlp_state)
            S_HDR: begin
                out_valid = 1'b1;
                case (beat_idx)
                    4'd0: out_beat = hdr_beat0;
                    4'd1: out_beat = fh_beat0;
                    4'd2: out_beat = fh_beat1;
                    default: out_beat = 128'd0;
                endcase
                out_last = (beat_idx == 4'd8);
            end
            S_VID: begin
                if (beat_idx == 4'd0) begin
                    out_valid = 1'b1;
                    out_beat  = hdr_beat1;
                end
                else begin
                    out_valid = !beat_empty || pack_done;
                    out_beat  = beat_empty ? 128'd0 : beat_dout;
                end
                out_last = (beat_idx == 4'd8);
            end
            S_MSI: begin
                out_valid = 1'b1;
                if (beat_idx == 4'd0) begin
                    out_beat = msi_hdr;
                end
                else begin
                    out_beat = { 96'd0, 16'd0, msi_data[15:0] };
                    out_keep = 4'h1;
                    out_last = 1'b1;
                end
            end
            default: ;
        endcase
    end

    assign tlps_out.tdata    = out_beat;
    assign tlps_out.tkeepdw  = out_keep;
    assign tlps_out.tlast    = out_last;
    assign tlps_out.tvalid   = out_valid;
    assign tlps_out.tuser    = 9'd0;
    assign tlps_out.has_data = (tlp_state != S_IDLE);

    wire beat_fire = out_valid && tlps_out.tready;

    assign beat_pop = (tlp_state == S_VID) && (beat_idx != 4'd0) &&
                      beat_fire && !beat_empty;

    assign dma_busy = (tlp_state != S_IDLE);

    // -------------------------------------------------------------------------
    // pix_ready: the source is paused at SOF when no frame buffer is free.
    // -------------------------------------------------------------------------
    always_comb begin
        pix_ready = 1'b0;
        if (capture_enable) begin
            if (tlp_state == S_IDLE) begin
                // Hold the first pixel while the sequencer moves to S_HDR.
                pix_ready = sof ? 1'b0 : 1'b1;
            end
            else if (tlp_state == S_HDR || tlp_state == S_VID) begin
                pix_ready = (beat_count < 5'd15) && !pack_done;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Main sequencer
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if (dma_rst) begin
            tlp_state        <= S_IDLE;
            beat_idx         <= 4'd0;
            tlp_idx          <= 16'd0;
            buf_addr         <= 64'd0;
            buf_index        <= 3'd0;
            frame_ts         <= 64'd0;
            seq              <= 32'd0;
            frame_done_pulse <= 1'b0;
            frame_done_index <= 3'd0;
            frame_seq_out    <= 32'd0;
            frame_ts_out     <= 64'd0;
            frame_size_out   <= FRAME_BYTES32;
            frame_stall      <= 1'b0;
            stall_latched    <= 1'b0;
        end
        else begin
            frame_done_pulse <= 1'b0;
            frame_stall      <= 1'b0;

            case (tlp_state)
                S_IDLE: begin
                    if (next_buf_valid)
                        stall_latched <= 1'b0;
                    if (sof && !next_buf_valid && !stall_latched) begin
                        frame_stall   <= 1'b1;
                        stall_latched <= 1'b1;
                    end
                    if (start_frame) begin
                        buf_addr      <= next_buf_addr;
                        buf_index     <= next_buf_index;
                        frame_ts      <= ts;
                        tlp_state     <= S_HDR;
                        beat_idx      <= 4'd0;
                        tlp_idx       <= 16'd0;
                        stall_latched <= 1'b0;
                    end
                end

                S_HDR: begin
                    if (beat_fire) begin
                        if (beat_idx == 4'd8) begin
                            beat_idx  <= 4'd0;
                            tlp_idx   <= 16'd0;
                            tlp_state <= S_VID;
                        end
                        else begin
                            beat_idx <= beat_idx + 4'd1;
                        end
                    end
                end

                S_VID: begin
                    if (beat_fire) begin
                        if (beat_idx == 4'd8) begin
                            beat_idx <= 4'd0;
                            if (tlp_idx == LAST_TLP) begin
                                frame_done_pulse <= 1'b1;
                                frame_done_index <= buf_index;
                                frame_seq_out    <= seq + 32'd1;
                                frame_ts_out     <= frame_ts;
                                seq              <= seq + 32'd1;
                                if (msi_en && irq_enable[0] && (msi_addr != 64'd0))
                                    tlp_state <= S_MSI;
                                else
                                    tlp_state <= S_IDLE;
                            end
                            else begin
                                tlp_idx <= tlp_idx + 16'd1;
                            end
                        end
                        else begin
                            beat_idx <= beat_idx + 4'd1;
                        end
                    end
                end

                S_MSI: begin
                    if (beat_fire) begin
                        if (beat_idx == 4'd1) begin
                            beat_idx  <= 4'd0;
                            tlp_state <= S_IDLE;
                        end
                        else begin
                            beat_idx <= beat_idx + 4'd1;
                        end
                    end
                end

                default: tlp_state <= S_IDLE;
            endcase
        end
    end

endmodule
