// -----------------------------------------------------------------------------
// ACAP-100T : BAR0 register file, frame-buffer ring and interrupt status
//
// Register map (32-bit accesses, offsets from BAR0):
//   0x000 R  MAGIC          0x4D434150 ("MCAP")
//   0x004 R  VERSION        0x00010000
//   0x008 R  CAPS           [0] capture [1] TPG [2] MSI [3] 64-bit [4] ring
//                           [15:8] max buffers [31:16] max width
//   0x00C R  STATUS         [0] link up [1] enable [2] DMA busy [3] MSI on
//                           [4] no free buffer [10:8] active buffer
//                           [15:12] link width [21:16] LTSSM
//   0x010 RW CONTROL        [0] capture enable [1] pattern select
//   0x014 RW IRQ_STATUS     [0] frame done [1] frame stall [2] error (RW1C)
//   0x018 RW IRQ_ENABLE     same bits
//   0x01C R  FRAME_SEQ      number of completed frames
//   0x020 R  DROPPED        frames that could not start
//   0x024 R  LAST_SIZE      bytes written for the last frame
//   0x028 R  LAST_TS_LO     timestamp low
//   0x02C R  LAST_TS_HI     timestamp high
//   0x030 R  WIDTH
//   0x034 R  HEIGHT
//   0x038 R  STRIDE         bytes per line
//   0x03C R  FORMAT         0 = YUYV 4:2:2
//   0x040 RW BUFFER_COUNT   1..8
//   0x044 R  FRAME_BYTES    required bytes per frame buffer
//   0x048 R  ACTIVE_BUFFER  index of the last completed frame
//   0x04C R  BUF_DONE       per-buffer done bits
//   0x050 W  BUF_ACK        write 1 to clear done bits
//   0x0E0 R  HTOTAL
//   0x0E4 R  VTOTAL
//   0x0E8 R  PIXEL_CLK_HZ
//   0x0EC R  FRAME_RATE_MHZ milli-Hz
//   0x0F0 R  PCIE_LINK      [5:0] LTSSM [9:8] width [10] Gen2
//   0x0F4 R  BUILD_ID
//   0x100 + i*16: BUF_ADDR_LO, BUF_ADDR_HI, reserved, BUF_CTRL[0]=valid
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module acap_regs #(
    parameter int WIDTH  = `ACAP_WIDTH,
    parameter int HEIGHT = `ACAP_HEIGHT
)(
    input                   clk,
    input                   rst,

    // BAR bus
    input  [31:0]           bar_wr_addr,
    input  [3:0]            bar_wr_be,
    input  [31:0]           bar_wr_data,
    input                   bar_wr_valid,
    input  [87:0]           bar_rd_ctx,
    input  [31:0]           bar_rd_addr,
    input                   bar_rd_valid,
    output [87:0]           bar_rd_rsp_ctx,
    output [31:0]           bar_rd_rsp_data,
    output                  bar_rd_rsp_valid,

    // PCIe / DMA status
    input                   link_up,
    input  [5:0]            ltssm,
    input  [1:0]            link_width,
    input                   link_speed,
    input                   msi_en,
    input                   dma_busy,
    input                   frame_done_pulse,
    input  [2:0]            frame_done_index,
    input  [31:0]           frame_seq_in,
    input  [63:0]           frame_ts_in,
    input  [31:0]           frame_size_in,
    input                   frame_stall,

    // Capture control
    output                  capture_enable,
    output                  pattern_select,
    output [31:0]           frame_bytes,
    output [2:0]            irq_enable,
    output logic            next_buf_valid,
    output logic [2:0]      next_buf_index,
    output logic [63:0]     next_buf_addr
);

    localparam [31:0] FRAME_BYTES = `ACAP_FRAME_BYTES;
    localparam [31:0] PIXEL_CLK_HZ = 32'd62_500_000;
    localparam [31:0] FRAME_RATE_MHZ = 32'd25_252;   // 25.2525 Hz

    logic [1:0]  control;
    logic [2:0]  irq_status;
    logic [2:0]  irq_enable_r;
    logic [31:0] frame_seq;
    logic [31:0] dropped;
    logic [31:0] last_size;
    logic [63:0] last_ts;
    logic [2:0]  active_buf;
    logic [7:0]  buf_done;
    logic [7:0]  buf_valid;
    logic [63:0] buf_addr [0:7];
    logic [3:0]  buffer_count_r;
    logic [2:0]  last_alloc;

    assign capture_enable = control[0];
    assign pattern_select = control[1];
    assign frame_bytes    = FRAME_BYTES;
    assign irq_enable     = irq_enable_r;

    // -------------------------------------------------------------------------
    // Next free buffer: round-robin from last_alloc+1
    // -------------------------------------------------------------------------
    integer k;
    logic [2:0] idx;
    always_comb begin
        next_buf_valid = 1'b0;
        next_buf_index = 3'd0;
        next_buf_addr  = 64'd0;
        for (k = 1; k <= 8; k = k + 1) begin
            idx = (last_alloc + k[2:0]) & 3'h7;
            if (!next_buf_valid && ({1'b0, idx} < buffer_count_r) &&
                buf_valid[idx] && !buf_done[idx]) begin
                next_buf_valid = 1'b1;
                next_buf_index = idx;
                next_buf_addr  = buf_addr[idx];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Write side
    // -------------------------------------------------------------------------
    wire [11:0] wa        = bar_wr_addr[11:0];
    wire        wa_buf    = (wa >= 12'h100) && (wa < 12'h180);
    wire [2:0]  wa_buf_i  = wa[6:4];
    wire [1:0]  wa_buf_s  = wa[3:2];
    wire        en_rise   = bar_wr_valid && (wa == 12'h010) && bar_wr_be[0] &&
                            bar_wr_data[0] && !control[0];

    integer b;
    always @ ( posedge clk ) begin
        if (rst) begin
            control        <= 2'b00;
            irq_status     <= 3'b000;
            irq_enable_r   <= 3'b000;
            frame_seq      <= 32'd0;
            dropped        <= 32'd0;
            last_size      <= 32'd0;
            last_ts        <= 64'd0;
            active_buf     <= 3'd0;
            buf_done       <= 8'd0;
            buf_valid      <= 8'd0;
            buffer_count_r <= 4'd0;
            last_alloc     <= 3'd0;
            for (b = 0; b < 8; b = b + 1) begin
                buf_addr[b] <= 64'd0;
            end
        end
        else begin
            if (bar_wr_valid) begin
                case (wa)
                    12'h010: begin
                        if (bar_wr_be[0]) begin
                            control[0] <= bar_wr_data[0];
                            control[1] <= bar_wr_data[1];
                        end
                    end
                    12'h014: begin
                        if (bar_wr_be[0]) begin
                            irq_status <= irq_status & ~bar_wr_data[2:0];
                        end
                    end
                    12'h018: begin
                        if (bar_wr_be[0]) begin
                            irq_enable_r <= bar_wr_data[2:0];
                        end
                    end
                    12'h040: begin
                        if (bar_wr_be[0]) begin
                            buffer_count_r <= (bar_wr_data[3:0] > 4'd8) ? 4'd8 : bar_wr_data[3:0];
                        end
                    end
                    12'h050: begin
                        if (bar_wr_be[0]) begin
                            buf_done <= buf_done & ~bar_wr_data[7:0];
                        end
                    end
                    default: begin
                        if (wa_buf) begin
                            case (wa_buf_s)
                                2'd0: if (|bar_wr_be) buf_addr[wa_buf_i][31:0]  <= bar_wr_data;
                                2'd1: if (|bar_wr_be) buf_addr[wa_buf_i][63:32] <= bar_wr_data;
                                2'd2: ;
                                2'd3: begin
                                    if (bar_wr_be[0]) begin
                                        buf_valid[wa_buf_i] <= bar_wr_data[0];
                                        buf_done[wa_buf_i]  <= 1'b0;
                                    end
                                end
                            endcase
                        end
                    end
                endcase
            end

            if (en_rise) begin
                frame_seq  <= 32'd0;
                dropped    <= 32'd0;
                last_size  <= 32'd0;
                last_ts    <= 64'd0;
                active_buf <= 3'd0;
                last_alloc <= 3'd0;
                buf_done   <= 8'd0;
                irq_status <= 3'b000;
            end

            if (frame_done_pulse) begin
                buf_done[frame_done_index] <= 1'b1;
                active_buf  <= frame_done_index;
                frame_seq   <= frame_seq_in;
                last_size   <= frame_size_in;
                last_ts     <= frame_ts_in;
                last_alloc  <= frame_done_index;
                irq_status[0] <= 1'b1;
            end

            if (frame_stall) begin
                dropped       <= dropped + 32'd1;
                irq_status[1] <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Status word
    // -------------------------------------------------------------------------
    logic [31:0] status;
    always_comb begin
        status = 32'd0;
        status[0]     = link_up;
        status[1]     = control[0];
        status[2]     = dma_busy;
        status[3]     = msi_en;
        status[4]     = ~next_buf_valid;
        status[10:8]  = active_buf;
        status[13:12] = link_width;
        status[21:16] = ltssm;
    end

    // -------------------------------------------------------------------------
    // Read side, two-cycle latency
    // -------------------------------------------------------------------------
    logic [11:0] rd_addr_d1;
    logic [87:0] rd_ctx_d1;
    logic [87:0] rd_ctx_d2;
    logic        rd_valid_d1;
    logic        rd_valid_d2;
    logic [31:0] rd_data_d2;
    logic [31:0] rd_data_comb;

    always_comb begin
        rd_data_comb = 32'd0;
        if ((rd_addr_d1 >= 12'h100) && (rd_addr_d1 < 12'h180)) begin
            case (rd_addr_d1[3:2])
                2'd0: rd_data_comb = buf_addr[rd_addr_d1[6:4]][31:0];
                2'd1: rd_data_comb = buf_addr[rd_addr_d1[6:4]][63:32];
                2'd2: rd_data_comb = 32'd0;
                2'd3: rd_data_comb = {31'd0, buf_valid[rd_addr_d1[6:4]]};
            endcase
        end
        else begin
            case (rd_addr_d1)
                12'h000: rd_data_comb = `ACAP_MAGIC;
                12'h004: rd_data_comb = `ACAP_VERSION;
                12'h008: rd_data_comb = (WIDTH << 16) | 32'h0000_081F;
                12'h00C: rd_data_comb = status;
                12'h010: rd_data_comb = {30'd0, control};
                12'h014: rd_data_comb = {29'd0, irq_status};
                12'h018: rd_data_comb = {29'd0, irq_enable_r};
                12'h01C: rd_data_comb = frame_seq;
                12'h020: rd_data_comb = dropped;
                12'h024: rd_data_comb = last_size;
                12'h028: rd_data_comb = last_ts[31:0];
                12'h02C: rd_data_comb = last_ts[63:32];
                12'h030: rd_data_comb = WIDTH[31:0];
                12'h034: rd_data_comb = HEIGHT[31:0];
                12'h038: rd_data_comb = `ACAP_STRIDE;
                12'h03C: rd_data_comb = {24'd0, `ACAP_FORMAT_YUYV};
                12'h040: rd_data_comb = {28'd0, buffer_count_r};
                12'h044: rd_data_comb = FRAME_BYTES;
                12'h048: rd_data_comb = {29'd0, active_buf};
                12'h04C: rd_data_comb = {24'd0, buf_done};
                12'h050: rd_data_comb = 32'd0;
                12'h0E0: rd_data_comb = `ACAP_HTOTAL;
                12'h0E4: rd_data_comb = `ACAP_VTOTAL;
                12'h0E8: rd_data_comb = PIXEL_CLK_HZ;
                12'h0EC: rd_data_comb = FRAME_RATE_MHZ;
                12'h0F0: rd_data_comb = {22'd0, link_speed, 1'b0, link_width, ltssm};
                12'h0F4: rd_data_comb = 32'h2026_1116;
                default: rd_data_comb = 32'd0;
            endcase
        end
    end

    assign bar_rd_rsp_ctx   = rd_ctx_d2;
    assign bar_rd_rsp_data  = rd_data_d2;
    assign bar_rd_rsp_valid = rd_valid_d2;

    always @ ( posedge clk ) begin
        if (rst) begin
            rd_addr_d1    <= 12'd0;
            rd_ctx_d1     <= 88'd0;
            rd_ctx_d2     <= 88'd0;
            rd_valid_d1   <= 1'b0;
            rd_valid_d2   <= 1'b0;
            rd_data_d2    <= 32'd0;
        end
        else begin
            rd_addr_d1    <= bar_rd_addr[11:0];
            rd_ctx_d1     <= bar_rd_ctx;
            rd_valid_d1   <= bar_rd_valid;
            rd_ctx_d2     <= rd_ctx_d1;
            rd_valid_d2   <= rd_valid_d1;
            rd_data_d2    <= rd_data_comb;
        end
    end

endmodule
