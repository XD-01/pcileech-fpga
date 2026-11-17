// -----------------------------------------------------------------------------
// NVMe host-memory request generator.
//
// Emits 4-DW-header MemRd / MemWr TLPs on the NVMe TX stream:
//   K_RD     : 64-byte MemRd (admin submission queue entry)
//   K_WR16   : 16-byte MemWr (admin completion queue entry)
//   K_IDENT  : 4096-byte MemWr from the Identify Controller ROM
//   K_ZERO   : N dwords of zero (log pages / empty namespace list)
//   K_IRQ    : 4-byte MemWr (MSI-X message)
//
// Memory writes are split into 512-byte (128 DW) TLPs to stay within the
// 512-byte maximum payload size of the PCIe core.  Tag is always 0xFF for
// reads; writes are posted and use the same reserved tag.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module nvme_tx_req(
    input               clk,
    input               rst,
    input [15:0]        pcie_id,
    // request interface
    input               req_valid,
    output              req_ready,
    input [2:0]         req_kind,
    input [63:0]        req_addr,
    input [127:0]       req_wdata,
    input [11:0]        req_len_dw,
    input [7:0]         req_lid,
    output bit          req_done,
    // outgoing TLP stream
    IfAXIS128.source    tlps_out
);

    localparam [2:0] K_RD    = 3'd0;
    localparam [2:0] K_WR16  = 3'd1;
    localparam [2:0] K_IDENT = 3'd2;
    localparam [2:0] K_ZERO  = 3'd3;
    localparam [2:0] K_IRQ   = 3'd4;
    localparam [2:0] K_LOG   = 3'd5;

    localparam [1:0] T_IDLE = 2'd0;
    localparam [1:0] T_HDR  = 2'd1;
    localparam [1:0] T_DATA = 2'd2;

    reg [1:0]   tstate;
    reg [2:0]   kind;
    reg [63:0]  addr;
    reg [127:0] wdata;
    reg [7:0]   lid;
    reg [11:0]  total_dw;
    reg [11:0]  chunk_dw;
    reg [11:0]  beat_rem;
    reg [11:0]  data_idx;

    assign req_ready = (tstate == T_IDLE);

    wire is_rd = (kind == K_RD);

    // -------------------------------------------------------------------------
    // Identify Controller data ROM (256 x 128-bit beats)
    // -------------------------------------------------------------------------
    wire [127:0] ident_data;
    nvme_ident_data i_ident(
        .idx    ( data_idx[9:2] ),
        .data   ( ident_data    )
    );

    wire [127:0] log_data;
    nvme_log_data i_log(
        .lid    ( lid           ),
        .idx    ( data_idx[9:2] ),
        .data   ( log_data      )
    );

    // -------------------------------------------------------------------------
    // Pending request length
    // -------------------------------------------------------------------------
    wire [11:0] req_len = (req_kind == K_RD)    ? 12'd16   :
                          (req_kind == K_WR16)  ? 12'd4    :
                          (req_kind == K_IDENT) ? 12'd1024 :
                          (req_kind == K_IRQ)   ? 12'd1    : req_len_dw;

    // -------------------------------------------------------------------------
    // Data word source (memory order, little endian)
    // -------------------------------------------------------------------------
    wire [31:0] src_dw0 = (kind == K_IDENT) ? ident_data[31:0]   :
                          (kind == K_LOG)   ? log_data[31:0]     :
                          (kind == K_WR16)  ? wdata[31:0]        :
                          (kind == K_IRQ)   ? wdata[31:0]        : 32'd0;
    wire [31:0] src_dw1 = (kind == K_IDENT) ? ident_data[63:32]  :
                          (kind == K_LOG)   ? log_data[63:32]    :
                          (kind == K_WR16)  ? wdata[63:32]       : 32'd0;
    wire [31:0] src_dw2 = (kind == K_IDENT) ? ident_data[95:64]  :
                          (kind == K_LOG)   ? log_data[95:64]    :
                          (kind == K_WR16)  ? wdata[95:64]       : 32'd0;
    wire [31:0] src_dw3 = (kind == K_IDENT) ? ident_data[127:96] :
                          (kind == K_LOG)   ? log_data[127:96]   :
                          (kind == K_WR16)  ? wdata[127:96]      : 32'd0;

    // Wire order (first payload byte is the MSB of the transmitted dword).
    wire [31:0] w_dw0 = { src_dw0[7:0],  src_dw0[15:8],  src_dw0[23:16],  src_dw0[31:24] };
    wire [31:0] w_dw1 = { src_dw1[7:0],  src_dw1[15:8],  src_dw1[23:16],  src_dw1[31:24] };
    wire [31:0] w_dw2 = { src_dw2[7:0],  src_dw2[15:8],  src_dw2[23:16],  src_dw2[31:24] };
    wire [31:0] w_dw3 = { src_dw3[7:0],  src_dw3[15:8],  src_dw3[23:16],  src_dw3[31:24] };

    wire [3:0]  keep_dw = (beat_rem >= 12'd4) ? 4'b1111 :
                          (beat_rem == 12'd3) ? 4'b0111 :
                          (beat_rem == 12'd2) ? 4'b0011 : 4'b0001;

    wire        last_beat = (beat_rem <= 12'd4);

    // -------------------------------------------------------------------------
    // 4-DW header (64-bit addressing)
    // -------------------------------------------------------------------------
    wire [31:0] hdr0 = (is_rd ? 32'h20000000 : 32'h60000000) | {22'd0, chunk_dw[9:0]};
    wire [3:0]  hdr_last_be = (is_rd || (chunk_dw > 12'd1)) ? 4'hF : 4'h0;
    wire [31:0] hdr1 = { pcie_id[7:0], pcie_id[15:8], 8'hFF, hdr_last_be, 4'hF };
    wire [31:0] hdr2 = { addr[31:2], 2'b00 };
    wire [31:0] hdr3 = addr[63:32];

    // -------------------------------------------------------------------------
    // Output
    // -------------------------------------------------------------------------
    assign tlps_out.tdata = (tstate == T_HDR) ? { hdr3, hdr2, hdr1, hdr0 } :
                                               { w_dw3, w_dw2, w_dw1, w_dw0 };
    assign tlps_out.tkeepdw = (tstate == T_HDR) ? 4'b1111 : keep_dw;
    assign tlps_out.tlast   = (tstate == T_HDR) ? is_rd : last_beat;
    assign tlps_out.tvalid  = (tstate == T_HDR) || (tstate == T_DATA);
    assign tlps_out.has_data = (tstate != T_IDLE);
    assign tlps_out.tuser[0] = (tstate == T_HDR);
    assign tlps_out.tuser[1] = tlps_out.tlast;
    assign tlps_out.tuser[8:2] = 7'd0;

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            tstate   <= T_IDLE;
            req_done <= 1'b0;
            kind     <= K_RD;
            addr     <= 64'd0;
            wdata    <= 128'd0;
            lid      <= 8'd0;
            total_dw <= 12'd0;
            chunk_dw <= 12'd0;
            beat_rem <= 12'd0;
            data_idx <= 12'd0;
        end
        else begin
            req_done <= 1'b0;
            case ( tstate )
                T_IDLE: begin
                    if ( req_valid ) begin
                        kind     <= req_kind;
                        addr     <= req_addr;
                        wdata    <= req_wdata;
                        lid      <= req_lid;
                        total_dw <= req_len;
                        chunk_dw <= (req_len > 12'd128) ? 12'd128 : req_len;
                        beat_rem <= (req_len > 12'd128) ? 12'd128 : req_len;
                        data_idx <= 12'd0;
                        tstate   <= T_HDR;
                    end
                end
                T_HDR: begin
                    if ( tlps_out.tready ) begin
                        if ( is_rd ) begin
                            tstate   <= T_IDLE;
                            req_done <= 1'b1;
                        end
                        else begin
                            beat_rem <= chunk_dw;
                            tstate   <= T_DATA;
                        end
                    end
                end
                T_DATA: begin
                    if ( tlps_out.tready ) begin
                        if ( last_beat ) begin
                            if ( total_dw == chunk_dw ) begin
                                tstate   <= T_IDLE;
                                req_done <= 1'b1;
                            end
                            else begin
                                total_dw <= total_dw - chunk_dw;
                                addr     <= addr + { 50'd0, chunk_dw, 2'b00 };
                                chunk_dw <= (total_dw - chunk_dw > 12'd128) ? 12'd128 : (total_dw - chunk_dw);
                                beat_rem <= (total_dw - chunk_dw > 12'd128) ? 12'd128 : (total_dw - chunk_dw);
                                tstate   <= T_HDR;
                            end
                        end
                        else begin
                            beat_rem <= beat_rem - 12'd4;
                            data_idx <= data_idx + 12'd4;
                        end
                    end
                end
            endcase
        end
    end

endmodule
