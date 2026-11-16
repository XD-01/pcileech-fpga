// -----------------------------------------------------------------------------
// NVMe admin command engine.
//
// Consumes the admin submission queue that the host programmed in ASQ:
//   * fetch a 64-byte SQE with a MemRd
//   * execute the admin command (Identify / Set/Get Features / Create-Delete
//     I/O queues / Abort / Keep Alive / Get Log Page / Async Event Request)
//   * write the 16-byte CQE into ACQ with a MemWr and raise MSI-X vector 0
//
// Identify Controller reports NN = 0: no namespace, therefore no disk is
// exposed to the host.  Async Event Requests are consumed silently (kept
// pending), as allowed by the specification.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module nvme_admin(
    input               clk,
    input               rst,
    input [15:0]        pcie_id,
    // controller registers
    input               cc_en,
    input [11:0]        asqs,
    input [11:0]        acqs,
    input [63:0]        asq,
    input [63:0]        acq,
    input [15:0]        sq0_tail,
    input [127:0]       msix0,
    input [127:0]       msix1,
    input [127:0]       msix2,
    input [127:0]       msix3,
    // completions routed from the PCIe receive path
    IfAXIS128.sink_lite nvme_cpl,
    // outgoing NVMe TLPs
    IfAXIS128.source    tlps_out
);

    localparam [2:0] K_RD    = 3'd0;
    localparam [2:0] K_WR16  = 3'd1;
    localparam [2:0] K_IDENT = 3'd2;
    localparam [2:0] K_ZERO  = 3'd3;
    localparam [2:0] K_IRQ   = 3'd4;

    localparam [2:0] A_IDLE = 3'd0;
    localparam [2:0] A_RD   = 3'd1;
    localparam [2:0] A_DATA = 3'd2;
    localparam [2:0] A_CQE  = 3'd3;
    localparam [2:0] A_IRQ  = 3'd4;

    // -------------------------------------------------------------------------
    // TX request engine
    // -------------------------------------------------------------------------
    wire        req_valid;
    wire        req_ready;
    wire        req_done;
    wire [2:0]  req_kind;
    wire [63:0] req_addr;
    wire [127:0] req_wdata;
    wire [11:0] req_len_dw;

    nvme_tx_req i_nvme_tx_req(
        .clk        ( clk           ),
        .rst        ( rst           ),
        .pcie_id    ( pcie_id       ),
        .req_valid  ( req_valid     ),
        .req_ready  ( req_ready     ),
        .req_kind   ( req_kind      ),
        .req_addr   ( req_addr      ),
        .req_wdata  ( req_wdata     ),
        .req_len_dw ( req_len_dw    ),
        .req_done   ( req_done      ),
        .tlps_out   ( tlps_out      )
    );

    // -------------------------------------------------------------------------
    // Completion capture (64-byte read = 5 beats: 1 + 4 + 4 + 4 + 3 DW)
    // -------------------------------------------------------------------------
    reg [31:0]  sqe [0:15];
    reg [2:0]   cpl_beat;
    reg [4:0]   cpl_base;
    reg         cpl_done_r;
    reg         cpl_err;

    wire [31:0] bs0 = { nvme_cpl.tdata[7:0],   nvme_cpl.tdata[15:8],  nvme_cpl.tdata[23:16],  nvme_cpl.tdata[31:24]   };
    wire [31:0] bs1 = { nvme_cpl.tdata[39:32], nvme_cpl.tdata[47:40], nvme_cpl.tdata[55:48],  nvme_cpl.tdata[63:56]   };
    wire [31:0] bs2 = { nvme_cpl.tdata[71:64], nvme_cpl.tdata[79:72], nvme_cpl.tdata[87:80],  nvme_cpl.tdata[95:88]   };
    wire [31:0] bs3 = { nvme_cpl.tdata[103:96], nvme_cpl.tdata[111:104], nvme_cpl.tdata[119:112], nvme_cpl.tdata[127:120] };

    always @ ( posedge clk ) begin
        cpl_done_r <= 1'b0;
        if ( rst ) begin
            cpl_beat <= 3'd0;
            cpl_base <= 5'd0;
            cpl_err  <= 1'b0;
        end
        else if ( nvme_cpl.tvalid ) begin
            if ( nvme_cpl.tuser[0] ) begin
                sqe[0]   <= bs3;
                cpl_err  <= (nvme_cpl.tdata[47:45] != 3'd0);
                cpl_beat <= 3'd1;
                cpl_base <= 5'd1;
                if ( nvme_cpl.tlast )
                    cpl_done_r <= 1'b1;
            end
            else if ( cpl_beat < 3'd5 ) begin
                if ( nvme_cpl.tkeepdw[0] && (cpl_base + 0 <= 5'd15) ) sqe[cpl_base + 0] <= bs0;
                if ( nvme_cpl.tkeepdw[1] && (cpl_base + 1 <= 5'd15) ) sqe[cpl_base + 1] <= bs1;
                if ( nvme_cpl.tkeepdw[2] && (cpl_base + 2 <= 5'd15) ) sqe[cpl_base + 2] <= bs2;
                if ( nvme_cpl.tkeepdw[3] && (cpl_base + 3 <= 5'd15) ) sqe[cpl_base + 3] <= bs3;
                cpl_beat <= cpl_beat + 3'd1;
                cpl_base <= cpl_base + 5'd4;
                if ( nvme_cpl.tlast )
                    cpl_done_r <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Command engine
    // -------------------------------------------------------------------------
    reg [2:0]   state;
    reg [15:0]  sq_head;
    reg [15:0]  cq_head;
    reg         phase;

    reg         req_valid_r;
    reg         req_sent;
    reg [2:0]   req_kind_r;
    reg [63:0]  req_addr_r;
    reg [127:0] req_wdata_r;
    reg [11:0]  req_len_r;

    reg [15:0]  cmd_cid;
    reg [31:0]  cmd_result;

    assign req_valid  = req_valid_r;
    assign req_kind   = req_kind_r;
    assign req_addr   = req_addr_r;
    assign req_wdata  = req_wdata_r;
    assign req_len_dw = req_len_r;

    wire [7:0]  cmd_opcode = sqe[0][7:0];
    wire [31:0] cmd_cdw10  = sqe[10];

    wire [15:0] sq_head_next = (sq_head == {4'd0, asqs}) ? 16'd0 : (sq_head + 16'd1);
    wire        irq_ok       = (msix0[63:0] != 64'd0) && !msix0[96];

    wire [31:0] cqe_dw2_w = { sq_head, 16'd0 };
    wire [31:0] cqe_dw3_w = { cmd_cid, 15'd0, phase };

    // zero-length / log page transfer size
    wire [16:0] numd_plus1 = { 1'b0, cmd_cdw10[31:16] } + 17'd1;
    wire [11:0] log_len    = (numd_plus1 > 17'd1024) ? 12'd1024 : numd_plus1[11:0];

    always @ ( posedge clk ) begin
        if ( rst ) begin
            state       <= A_IDLE;
            sq_head     <= 16'd0;
            cq_head     <= 16'd0;
            phase       <= 1'b1;
            req_valid_r <= 1'b0;
            req_sent    <= 1'b0;
            req_kind_r  <= K_RD;
            req_addr_r  <= 64'd0;
            req_wdata_r <= 128'd0;
            req_len_r   <= 12'd0;
            cmd_cid     <= 16'd0;
            cmd_result  <= 32'd0;
        end
        else if ( !cc_en ) begin
            state       <= A_IDLE;
            sq_head     <= 16'd0;
            cq_head     <= 16'd0;
            phase       <= 1'b1;
            req_valid_r <= 1'b0;
            req_sent    <= 1'b0;
        end
        else begin
            if ( req_valid_r && req_ready )
                req_valid_r <= 1'b0;

            case ( state )
                A_IDLE: begin
                    req_sent <= 1'b0;
                    if ( sq0_tail != sq_head ) begin
                        req_kind_r  <= K_RD;
                        req_addr_r  <= asq + { 42'd0, sq_head, 6'b000000 };
                        req_len_r   <= 12'd16;
                        req_wdata_r <= 128'd0;
                        req_valid_r <= 1'b1;
                        state       <= A_RD;
                    end
                end
                A_RD: begin
                    if ( cpl_done_r ) begin
                        cmd_cid <= sqe[0][31:16];
                        sq_head <= sq_head_next;
                        // Identify
                        if ( cmd_opcode == 8'h06 ) begin
                            if ( cmd_cdw10[7:0] == 8'h01 ) begin
                                req_kind_r <= K_IDENT;
                                req_addr_r <= { sqe[7], sqe[6] };
                                req_len_r  <= 12'd1024;
                                state      <= A_DATA;
                            end
                            else begin
                                req_kind_r <= K_ZERO;
                                req_addr_r <= { sqe[7], sqe[6] };
                                req_len_r  <= (cmd_cdw10[7:0] == 8'h02) ? 12'd1 : 12'd1024;
                                state      <= A_DATA;
                            end
                            cmd_result <= 32'd0;
                        end
                        // Get Log Page
                        else if ( cmd_opcode == 8'h02 ) begin
                            req_kind_r <= K_ZERO;
                            req_addr_r <= { sqe[7], sqe[6] };
                            req_len_r  <= log_len;
                            cmd_result <= 32'd0;
                            state      <= A_DATA;
                        end
                        // Async Event Request: keep pending, no completion
                        else if ( cmd_opcode == 8'h0C ) begin
                            state <= A_IDLE;
                        end
                        else begin
                            cmd_result <= 32'd0;
                            state      <= A_CQE;
                        end
                    end
                end
                A_DATA: begin
                    if ( !req_sent ) begin
                        req_sent    <= 1'b1;
                        req_valid_r <= 1'b1;
                    end
                    else if ( req_done ) begin
                        req_sent <= 1'b0;
                        state    <= A_CQE;
                    end
                end
                A_CQE: begin
                    if ( !req_sent ) begin
                        req_kind_r  <= K_WR16;
                        req_addr_r  <= acq + { 44'd0, cq_head, 4'b0000 };
                        req_wdata_r <= { cqe_dw3_w, cqe_dw2_w, 32'd0, cmd_result };
                        req_len_r   <= 12'd4;
                        req_sent    <= 1'b1;
                        req_valid_r <= 1'b1;
                    end
                    else if ( req_done ) begin
                        req_sent <= 1'b0;
                        if ( cq_head == { 4'd0, acqs } ) begin
                            cq_head <= 16'd0;
                            phase   <= ~phase;
                        end
                        else begin
                            cq_head <= cq_head + 16'd1;
                        end
                        state <= A_IRQ;
                    end
                end
                A_IRQ: begin
                    if ( !req_sent ) begin
                        if ( irq_ok ) begin
                            req_kind_r  <= K_IRQ;
                            req_addr_r  <= msix0[63:0];
                            req_wdata_r <= { 96'd0, msix0[95:64] };
                            req_len_r   <= 12'd1;
                            req_sent    <= 1'b1;
                            req_valid_r <= 1'b1;
                        end
                        else begin
                            state <= A_IDLE;
                        end
                    end
                    else if ( req_done ) begin
                        req_sent <= 1'b0;
                        state    <= A_IDLE;
                    end
                end
                default: state <= A_IDLE;
            endcase
        end
    end

endmodule
