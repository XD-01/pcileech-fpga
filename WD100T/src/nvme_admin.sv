// -----------------------------------------------------------------------------
// NVMe controller command engine (WD SN850 emulation, no namespace).
//
// Full command processing:
//   * admin queue (QID 0) + 4 I/O queue pairs (QID 1..4)
//   * spec status codes for every admin command
//   * Identify (CNS 1/2), Get/Set Features, Get Log Page, Create/Delete queues,
//     Abort (including pending Async Event Requests), Firmware Download/Commit,
//     Device Self-test, Keep Alive, Format, Sanitize, Security, Directive, ...
//   * I/O commands complete with "Invalid Namespace or Format" because the
//     controller reports NN = 0 (no virtual disk), Flush with NSID 0xFFFFFFFF
//     succeeds as specified
//   * per-queue MSI-X vector, vector masking and PBA updates
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
    input [15:0]        sq_tail1,
    input [15:0]        sq_tail2,
    input [15:0]        sq_tail3,
    input [15:0]        sq_tail4,
    // MSI-X table lookup
    output reg [4:0]    msix_sel,
    input [63:0]        msix_addr,
    input [31:0]        msix_data,
    input               msix_mask,
    // MSI-X PBA
    output reg          pba_set,
    output reg [4:0]    pba_idx,
    output reg          pba_clr,
    output reg [4:0]    pba_clr_idx,
    // completions routed from the PCIe receive path
    IfAXIS128.sink_lite nvme_cpl,
    // outgoing NVMe TLPs
    IfAXIS128.source    tlps_out
);

    // -------------------------------------------------------------------------
    // Status codes
    // -------------------------------------------------------------------------
    localparam [7:0] SC_OK        = 8'h00;
    localparam [7:0] SC_OPCODE    = 8'h01;
    localparam [7:0] SC_FIELD     = 8'h02;
    localparam [7:0] SC_DATA      = 8'h04;
    localparam [7:0] SC_INTERNAL  = 8'h06;
    localparam [7:0] SC_ABORT     = 8'h07;
    localparam [7:0] SC_INV_NS    = 8'h0B;

    // -------------------------------------------------------------------------
    // Transfer kinds
    // -------------------------------------------------------------------------
    localparam [2:0] K_RD    = 3'd0;
    localparam [2:0] K_WR16  = 3'd1;
    localparam [2:0] K_IDENT = 3'd2;
    localparam [2:0] K_ZERO  = 3'd3;
    localparam [2:0] K_IRQ   = 3'd4;
    localparam [2:0] K_LOG   = 3'd5;

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
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
    wire [7:0]  req_lid;

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
        .req_lid    ( req_lid       ),
        .req_done   ( req_done      ),
        .tlps_out   ( tlps_out      )
    );

    // -------------------------------------------------------------------------
    // Completion capture (64-byte SQE = 5 beats)
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
                if ( nvme_cpl.tlast ) cpl_done_r <= 1'b1;
            end
            else if ( cpl_beat < 3'd5 ) begin
                if ( nvme_cpl.tkeepdw[0] && (cpl_base + 5'd0 <= 5'd15) ) sqe[cpl_base + 5'd0] <= bs0;
                if ( nvme_cpl.tkeepdw[1] && (cpl_base + 5'd1 <= 5'd15) ) sqe[cpl_base + 5'd1] <= bs1;
                if ( nvme_cpl.tkeepdw[2] && (cpl_base + 5'd2 <= 5'd15) ) sqe[cpl_base + 5'd2] <= bs2;
                if ( nvme_cpl.tkeepdw[3] && (cpl_base + 5'd3 <= 5'd15) ) sqe[cpl_base + 5'd3] <= bs3;
                cpl_beat <= cpl_beat + 3'd1;
                cpl_base <= cpl_base + 5'd4;
                if ( nvme_cpl.tlast ) cpl_done_r <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Queue state
    // -------------------------------------------------------------------------
    reg [63:0] isq_base [0:4];
    reg [15:0] isq_size [0:4];
    reg [15:0] isq_head [0:4];
    reg [2:0]  isq_cqid [0:4];
    reg [63:0] icq_base [0:4];
    reg [15:0] icq_size [0:4];
    reg [15:0] icq_head [0:4];
    reg [4:0]  icq_iv   [0:4];
    reg [4:0]  icq_ien;
    reg [4:0]  icq_valid;
    reg [4:0]  isq_valid;
    reg [4:0]  icq_phase;

    reg [15:0] a_sq_head;
    reg [15:0] a_cq_head;
    reg        a_phase;

    function [63:0] sq_base_f(input [2:0] q);
        sq_base_f = (q == 3'd0) ? asq : isq_base[q];
    endfunction
    function [15:0] sq_size_f(input [2:0] q);
        sq_size_f = (q == 3'd0) ? { 4'd0, asqs } : isq_size[q];
    endfunction
    function [15:0] sq_head_f(input [2:0] q);
        sq_head_f = (q == 3'd0) ? a_sq_head : isq_head[q];
    endfunction
    function [15:0] sq_tail_f(input [2:0] q);
        case ( q )
            3'd1: sq_tail_f = sq_tail1;
            3'd2: sq_tail_f = sq_tail2;
            3'd3: sq_tail_f = sq_tail3;
            3'd4: sq_tail_f = sq_tail4;
            default: sq_tail_f = sq0_tail;
        endcase
    endfunction
    function [63:0] cq_base_f(input [2:0] q);
        cq_base_f = (q == 3'd0) ? acq : icq_base[q];
    endfunction
    function [15:0] cq_size_f(input [2:0] q);
        cq_size_f = (q == 3'd0) ? { 4'd0, acqs } : icq_size[q];
    endfunction
    function [15:0] cq_head_f(input [2:0] q);
        cq_head_f = (q == 3'd0) ? a_cq_head : icq_head[q];
    endfunction
    function [4:0] cq_iv_f(input [2:0] q);
        cq_iv_f = (q == 3'd0) ? 5'd0 : icq_iv[q];
    endfunction
    function cq_ien_f(input [2:0] q);
        cq_ien_f = (q == 3'd0) ? 1'b1 : icq_ien[q];
    endfunction
    function cq_phase_f(input [2:0] q);
        cq_phase_f = (q == 3'd0) ? a_phase : icq_phase[q];
    endfunction
    function log_lid_ok(input [7:0] lid);
        case ( lid )
            8'h01, 8'h02, 8'h03, 8'h04, 8'h05, 8'h06, 8'h07,
            8'h08, 8'h09, 8'h0A, 8'h15, 8'h16, 8'h80, 8'h81: log_lid_ok = 1'b1;
            default: log_lid_ok = 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // AER tracking
    // -------------------------------------------------------------------------
    reg [3:0]  aer_v;
    reg [15:0] aer_cid [0:3];

    // -------------------------------------------------------------------------
    // Command state
    // -------------------------------------------------------------------------
    reg [2:0]   state;
    reg [2:0]   cur_qid;
    reg [2:0]   cq_qid;
    reg [15:0]  cmd_cid;
    reg [15:0]  cmd_sqhd;
    reg [7:0]   cmd_status;
    reg [31:0]  cmd_result;
    reg [31:0]  cmd_result_hi;
    reg [2:0]   res_kind;
    reg [63:0]  res_addr;
    reg [11:0]  res_len;
    reg [7:0]   res_lid;
    reg [127:0] res_wdata;
    reg         extra_pending;
    reg [15:0]  extra_cid;
    reg [4:0]   cur_vec;

    reg         req_valid_r;
    reg         req_sent;
    reg [2:0]   req_kind_r;
    reg [63:0]  req_addr_r;
    reg [127:0] req_wdata_r;
    reg [11:0]  req_len_r;
    reg [7:0]   req_lid_r;

    assign req_valid  = req_valid_r;
    assign req_kind   = req_kind_r;
    assign req_addr   = req_addr_r;
    assign req_wdata  = req_wdata_r;
    assign req_len_dw = req_len_r;
    assign req_lid    = req_lid_r;

    // SQE decode
    wire [7:0]   opcode = sqe[0][7:0];
    wire [15:0]  d_cid  = sqe[0][31:16];
    wire [31:0]  d_nsid = sqe[1];
    wire [63:0]  d_prp1 = { sqe[7], sqe[6] };
    wire [31:0]  d_cdw10 = sqe[10];
    wire [31:0]  d_cdw11 = sqe[11];
    wire [31:0]  d_cdw12 = sqe[12];

    wire [15:0] cur_sq_head = sq_head_f(cur_qid);
    wire [15:0] cur_sq_size = sq_size_f(cur_qid);
    wire [15:0] next_sq_head = (cur_sq_head == cur_sq_size) ? 16'd0 : (cur_sq_head + 16'd1);

    // Feature registers
    reg [31:0] f_arb, f_pm, f_temp, f_errrec, f_vwc, f_nq;
    reg [31:0] f_irqcoal, f_irqcfg, f_watomic, f_aec, f_apst, f_kat;
    reg [63:0] f_ts;

    // Log transfer size
    wire [16:0] numd_plus1 = { 1'b0, d_cdw10[31:16] } + 17'd1;
    wire [11:0] log_len = (numd_plus1 > 17'd1024) ? 12'd1024 : numd_plus1[11:0];

    integer j;

    // -------------------------------------------------------------------------
    // Main state machine
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            state           <= A_IDLE;
            cur_qid         <= 3'd0;
            cq_qid          <= 3'd0;
            cmd_cid         <= 16'd0;
            cmd_sqhd        <= 16'd0;
            cmd_status      <= SC_OK;
            cmd_result      <= 32'd0;
            cmd_result_hi   <= 32'd0;
            res_kind        <= K_RD;
            res_addr        <= 64'd0;
            res_len         <= 12'd0;
            res_lid         <= 8'd0;
            res_wdata       <= 128'd0;
            extra_pending   <= 1'b0;
            extra_cid       <= 16'd0;
            cur_vec         <= 5'd0;
            req_valid_r     <= 1'b0;
            req_sent        <= 1'b0;
            req_kind_r      <= K_RD;
            req_addr_r      <= 64'd0;
            req_wdata_r     <= 128'd0;
            req_len_r       <= 12'd0;
            req_lid_r       <= 8'd0;
            a_sq_head       <= 16'd0;
            a_cq_head       <= 16'd0;
            a_phase         <= 1'b1;
            aer_v           <= 4'd0;
            icq_ien         <= 5'd0;
            icq_valid       <= 5'd0;
            isq_valid       <= 5'd0;
            icq_phase       <= 5'd0;
            msix_sel        <= 5'd0;
            pba_set         <= 1'b0;
            pba_idx         <= 5'd0;
            pba_clr         <= 1'b0;
            pba_clr_idx     <= 5'd0;
            f_arb           <= 32'd0;
            f_pm            <= 32'd0;
            f_temp          <= 32'd0;
            f_errrec        <= 32'd0;
            f_vwc           <= 32'd0;
            f_nq            <= 32'd0;
            f_irqcoal       <= 32'd0;
            f_irqcfg        <= 32'd0;
            f_watomic       <= 32'd0;
            f_aec           <= 32'd0;
            f_apst          <= 32'd0;
            f_kat           <= 32'd0;
            f_ts            <= 64'd0;
            for ( j = 0; j < 5; j = j + 1 ) begin
                isq_base[j]  <= 64'd0;
                isq_size[j]  <= 16'd0;
                isq_head[j]  <= 16'd0;
                isq_cqid[j]  <= 3'd0;
                icq_base[j]  <= 64'd0;
                icq_size[j]  <= 16'd0;
                icq_head[j]  <= 16'd0;
                icq_iv[j]    <= 5'd0;
            end
        end
        else if ( !cc_en ) begin
            state       <= A_IDLE;
            a_sq_head   <= 16'd0;
            a_cq_head   <= 16'd0;
            a_phase     <= 1'b1;
            req_valid_r <= 1'b0;
            req_sent    <= 1'b0;
            extra_pending <= 1'b0;
            aer_v       <= 4'd0;
            icq_valid   <= 5'd0;
            isq_valid   <= 5'd0;
            icq_phase   <= 5'd0;
            icq_ien     <= 5'd0;
            pba_set     <= 1'b0;
            pba_clr     <= 1'b0;
        end
        else begin
            pba_set <= 1'b0;
            pba_clr <= 1'b0;
            if ( req_valid_r && req_ready )
                req_valid_r <= 1'b0;

            case ( state )
                // -----------------------------------------------------------------
                A_IDLE: begin
                    req_sent <= 1'b0;
                    if ( sq0_tail != a_sq_head ) begin
                        cur_qid    <= 3'd0;
                        req_kind_r <= K_RD;
                        req_addr_r <= asq + { 42'd0, a_sq_head, 6'b000000 };
                        req_len_r  <= 12'd16;
                        req_lid_r  <= 8'd0;
                        req_valid_r <= 1'b1;
                        state      <= A_RD;
                    end
                    else if ( isq_valid[1] && (sq_tail1 != isq_head[1]) ) begin
                        cur_qid    <= 3'd1;
                        req_kind_r <= K_RD;
                        req_addr_r <= isq_base[1] + { 42'd0, isq_head[1], 6'b000000 };
                        req_len_r  <= 12'd16;
                        req_lid_r  <= 8'd0;
                        req_valid_r <= 1'b1;
                        state      <= A_RD;
                    end
                    else if ( isq_valid[2] && (sq_tail2 != isq_head[2]) ) begin
                        cur_qid    <= 3'd2;
                        req_kind_r <= K_RD;
                        req_addr_r <= isq_base[2] + { 42'd0, isq_head[2], 6'b000000 };
                        req_len_r  <= 12'd16;
                        req_lid_r  <= 8'd0;
                        req_valid_r <= 1'b1;
                        state      <= A_RD;
                    end
                    else if ( isq_valid[3] && (sq_tail3 != isq_head[3]) ) begin
                        cur_qid    <= 3'd3;
                        req_kind_r <= K_RD;
                        req_addr_r <= isq_base[3] + { 42'd0, isq_head[3], 6'b000000 };
                        req_len_r  <= 12'd16;
                        req_lid_r  <= 8'd0;
                        req_valid_r <= 1'b1;
                        state      <= A_RD;
                    end
                    else if ( isq_valid[4] && (sq_tail4 != isq_head[4]) ) begin
                        cur_qid    <= 3'd4;
                        req_kind_r <= K_RD;
                        req_addr_r <= isq_base[4] + { 42'd0, isq_head[4], 6'b000000 };
                        req_len_r  <= 12'd16;
                        req_lid_r  <= 8'd0;
                        req_valid_r <= 1'b1;
                        state      <= A_RD;
                    end
                end
                // -----------------------------------------------------------------
                A_RD: begin
                    if ( cpl_done_r ) begin
                        // consume the SQE
                        if ( cur_qid == 3'd0 ) a_sq_head <= next_sq_head;
                        else isq_head[cur_qid] <= next_sq_head;
                        cmd_cid   <= d_cid;
                        cmd_sqhd  <= next_sq_head;
                        cmd_result <= 32'd0;
                        cmd_result_hi <= 32'd0;
                        cq_qid    <= (cur_qid == 3'd0) ? 3'd0 : isq_cqid[cur_qid];
                        extra_pending <= 1'b0;

                        if ( cpl_err ) begin
                            cmd_status <= SC_DATA;
                            state      <= A_CQE;
                        end
                        else if ( cur_qid != 3'd0 ) begin
                            // I/O queue: no namespace is configured
                            cmd_status <= (opcode == 8'h00 && d_nsid == 32'hFFFFFFFF) ? SC_OK : SC_INV_NS;
                            state      <= A_CQE;
                        end
                        else begin
                            case ( opcode )
                                // ---- Delete I/O SQ --------------------------------
                                8'h00: begin
                                    if ( (d_cdw10[15:0] >= 16'd1) && (d_cdw10[15:0] <= 16'd4) ) begin
                                        isq_valid[d_cdw10[2:0]] <= 1'b0;
                                        cmd_status <= SC_OK;
                                    end
                                    else cmd_status <= SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Create I/O SQ --------------------------------
                                8'h01: begin
                                    if ( (d_cdw10[15:0] >= 16'd1) && (d_cdw10[15:0] <= 16'd4) &&
                                         (d_cdw10[31:16] <= 16'd63) &&
                                         (d_cdw11[31:16] >= 16'd1) && (d_cdw11[31:16] <= 16'd4) &&
                                         icq_valid[d_cdw11[18:16]] ) begin
                                        isq_base[d_cdw10[2:0]] <= d_prp1;
                                        isq_size[d_cdw10[2:0]] <= d_cdw10[31:16];
                                        isq_cqid[d_cdw10[2:0]] <= d_cdw11[18:16];
                                        isq_head[d_cdw10[2:0]] <= 16'd0;
                                        isq_valid[d_cdw10[2:0]] <= 1'b1;
                                        cmd_status <= SC_OK;
                                    end
                                    else cmd_status <= SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Get Log Page ---------------------------------
                                8'h02: begin
                                    if ( log_lid_ok(d_cdw10[7:0]) && (d_prp1 != 0) ) begin
                                        res_kind  <= K_LOG;
                                        res_addr  <= d_prp1;
                                        res_len   <= log_len;
                                        res_lid   <= d_cdw10[7:0];
                                        cmd_status <= SC_OK;
                                        state     <= A_DATA;
                                    end
                                    else if ( !log_lid_ok(d_cdw10[7:0]) ) begin
                                        cmd_status <= SC_FIELD;
                                        state      <= A_CQE;
                                    end
                                    else begin
                                        cmd_status <= SC_FIELD;
                                        state      <= A_CQE;
                                    end
                                end
                                // ---- Delete I/O CQ --------------------------------
                                8'h04: begin
                                    if ( (d_cdw10[15:0] >= 16'd1) && (d_cdw10[15:0] <= 16'd4) ) begin
                                        icq_valid[d_cdw10[2:0]] <= 1'b0;
                                        isq_valid[d_cdw10[2:0]] <= 1'b0;
                                        cmd_status <= SC_OK;
                                    end
                                    else cmd_status <= SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Create I/O CQ --------------------------------
                                8'h05: begin
                                    if ( (d_cdw10[15:0] >= 16'd1) && (d_cdw10[15:0] <= 16'd4) &&
                                         (d_cdw10[31:16] <= 16'd63) && (d_cdw11[20:16] <= 5'd31) ) begin
                                        icq_base[d_cdw10[2:0]]  <= d_prp1;
                                        icq_size[d_cdw10[2:0]]  <= d_cdw10[31:16];
                                        icq_iv[d_cdw10[2:0]]    <= d_cdw11[20:16];
                                        icq_ien[d_cdw10[2:0]]   <= d_cdw11[1];
                                        icq_head[d_cdw10[2:0]]  <= 16'd0;
                                        icq_phase[d_cdw10[2:0]] <= 1'b1;
                                        icq_valid[d_cdw10[2:0]] <= 1'b1;
                                        cmd_status <= SC_OK;
                                    end
                                    else cmd_status <= SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Identify -------------------------------------
                                8'h06: begin
                                    if ( (d_cdw10[7:0] == 8'h01) && (d_prp1 != 0) ) begin
                                        res_kind  <= K_IDENT;
                                        res_addr  <= d_prp1;
                                        res_len   <= 12'd1024;
                                        cmd_status <= SC_OK;
                                        state     <= A_DATA;
                                    end
                                    else if ( d_cdw10[7:0] == 8'h02 ) begin
                                        res_kind  <= K_ZERO;
                                        res_addr  <= d_prp1;
                                        res_len   <= 12'd1;
                                        cmd_status <= SC_OK;
                                        state     <= A_DATA;
                                    end
                                    else if ( (d_cdw10[7:0] == 8'h00) || (d_cdw10[7:0] == 8'h03) ) begin
                                        // no namespace exists
                                        cmd_status <= SC_INV_NS;
                                        state      <= A_CQE;
                                    end
                                    else begin
                                        cmd_status <= SC_FIELD;
                                        state      <= A_CQE;
                                    end
                                end
                                // ---- Abort ----------------------------------------
                                8'h08: begin
                                    if ( aer_v[0] && (aer_cid[0] == d_cdw10[31:16]) ) begin
                                        aer_v[0] <= 1'b0;
                                        extra_pending <= 1'b1;
                                        extra_cid <= aer_cid[0];
                                    end
                                    else if ( aer_v[1] && (aer_cid[1] == d_cdw10[31:16]) ) begin
                                        aer_v[1] <= 1'b0;
                                        extra_pending <= 1'b1;
                                        extra_cid <= aer_cid[1];
                                    end
                                    else if ( aer_v[2] && (aer_cid[2] == d_cdw10[31:16]) ) begin
                                        aer_v[2] <= 1'b0;
                                        extra_pending <= 1'b1;
                                        extra_cid <= aer_cid[2];
                                    end
                                    else if ( aer_v[3] && (aer_cid[3] == d_cdw10[31:16]) ) begin
                                        aer_v[3] <= 1'b0;
                                        extra_pending <= 1'b1;
                                        extra_cid <= aer_cid[3];
                                    end
                                    cmd_status <= SC_OK;
                                    state      <= A_CQE;
                                end
                                // ---- Set Features ---------------------------------
                                8'h09: begin
                                    case ( d_cdw10[7:0] )
                                        8'h01: begin f_arb    <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h02: begin f_pm     <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h04: begin f_temp   <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h05: begin f_errrec <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h06: begin f_vwc    <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h07: begin
                                            f_nq <= { 14'd0, ((d_cdw11[31:16] > 16'd3) ? 2'd3 : d_cdw11[17:16]),
                                                      14'd0, ((d_cdw11[15:0]  > 16'd3) ? 2'd3 : d_cdw11[1:0]) };
                                            cmd_result <= { 14'd0, ((d_cdw11[31:16] > 16'd3) ? 2'd3 : d_cdw11[17:16]),
                                                            14'd0, ((d_cdw11[15:0]  > 16'd3) ? 2'd3 : d_cdw11[1:0]) };
                                            cmd_status <= SC_OK;
                                        end
                                        8'h08: begin f_irqcoal <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h09: begin f_irqcfg  <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h0A: begin f_watomic <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h0B: begin f_aec     <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h0C: begin f_apst    <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        8'h0E: begin
                                            f_ts         <= { d_cdw12, d_cdw11 };
                                            cmd_result   <= d_cdw11;
                                            cmd_result_hi<= d_cdw12;
                                            cmd_status   <= SC_OK;
                                        end
                                        8'h0F: begin f_kat     <= d_cdw11; cmd_result <= d_cdw11; cmd_status <= SC_OK; end
                                        default: cmd_status <= SC_FIELD;
                                    endcase
                                    state <= A_CQE;
                                end
                                // ---- Get Features ---------------------------------
                                8'h0A: begin
                                    case ( d_cdw10[7:0] )
                                        8'h01: begin cmd_result <= f_arb;    cmd_status <= SC_OK; end
                                        8'h02: begin cmd_result <= f_pm;     cmd_status <= SC_OK; end
                                        8'h04: begin cmd_result <= f_temp;   cmd_status <= SC_OK; end
                                        8'h05: begin cmd_result <= f_errrec; cmd_status <= SC_OK; end
                                        8'h06: begin cmd_result <= f_vwc;    cmd_status <= SC_OK; end
                                        8'h07: begin cmd_result <= f_nq;     cmd_status <= SC_OK; end
                                        8'h08: begin cmd_result <= f_irqcoal;cmd_status <= SC_OK; end
                                        8'h09: begin cmd_result <= f_irqcfg; cmd_status <= SC_OK; end
                                        8'h0A: begin cmd_result <= f_watomic;cmd_status <= SC_OK; end
                                        8'h0B: begin cmd_result <= f_aec;    cmd_status <= SC_OK; end
                                        8'h0C: begin cmd_result <= f_apst;   cmd_status <= SC_OK; end
                                        8'h0E: begin
                                            cmd_result    <= f_ts[31:0];
                                            cmd_result_hi <= f_ts[63:32];
                                            cmd_status    <= SC_OK;
                                        end
                                        8'h0F: begin cmd_result <= f_kat;    cmd_status <= SC_OK; end
                                        default: cmd_status <= SC_FIELD;
                                    endcase
                                    state <= A_CQE;
                                end
                                // ---- Async Event Request --------------------------
                                8'h0C: begin
                                    if ( !aer_v[0] ) begin
                                        aer_v[0] <= 1'b1; aer_cid[0] <= d_cid;
                                        state <= A_IDLE;
                                    end
                                    else if ( !aer_v[1] ) begin
                                        aer_v[1] <= 1'b1; aer_cid[1] <= d_cid;
                                        state <= A_IDLE;
                                    end
                                    else if ( !aer_v[2] ) begin
                                        aer_v[2] <= 1'b1; aer_cid[2] <= d_cid;
                                        state <= A_IDLE;
                                    end
                                    else if ( !aer_v[3] ) begin
                                        aer_v[3] <= 1'b1; aer_cid[3] <= d_cid;
                                        state <= A_IDLE;
                                    end
                                    else begin
                                        cmd_status <= SC_FIELD;
                                        state <= A_CQE;
                                    end
                                end
                                // ---- Firmware Commit ------------------------------
                                8'h10: begin
                                    cmd_status <= (d_cdw10[2:0] == 3'd0) ? SC_FIELD : SC_OK;
                                    state <= A_CQE;
                                end
                                // ---- Firmware Image Download ----------------------
                                8'h11: begin
                                    cmd_status <= SC_OK;
                                    state <= A_CQE;
                                end
                                // ---- Device Self-test -----------------------------
                                8'h14: begin
                                    cmd_status <= (d_cdw10[3:0] <= 4'd2) ? SC_OK : SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Keep Alive -----------------------------------
                                8'h18: begin
                                    cmd_status <= SC_OK;
                                    state <= A_CQE;
                                end
                                // ---- Format NVM -----------------------------------
                                8'h80: begin
                                    cmd_status <= SC_INV_NS;
                                    state <= A_CQE;
                                end
                                // ---- Security Send / Receive ----------------------
                                8'h81, 8'h82: begin
                                    cmd_status <= SC_FIELD;
                                    state <= A_CQE;
                                end
                                // ---- Sanitize -------------------------------------
                                8'h84: begin
                                    cmd_status <= SC_OK;
                                    state <= A_CQE;
                                end
                                // ---- Get LBA Status -------------------------------
                                8'h86: begin
                                    cmd_status <= SC_INV_NS;
                                    state <= A_CQE;
                                end
                                // ---- everything else -------------------------------
                                default: begin
                                    cmd_status <= SC_OPCODE;
                                    state <= A_CQE;
                                end
                            endcase
                        end
                    end
                end
                // -----------------------------------------------------------------
                A_DATA: begin
                    if ( !req_sent ) begin
                        req_kind_r  <= res_kind;
                        req_addr_r  <= res_addr;
                        req_len_r   <= res_len;
                        req_wdata_r <= 128'd0;
                        req_lid_r   <= res_lid;
                        req_sent    <= 1'b1;
                        req_valid_r <= 1'b1;
                    end
                    else if ( req_done ) begin
                        req_sent <= 1'b0;
                        state    <= A_CQE;
                    end
                end
                // -----------------------------------------------------------------
                A_CQE: begin
                    if ( extra_pending ) begin
                        // complete the aborted Async Event Request first
                        if ( !req_sent ) begin
                            req_kind_r  <= K_WR16;
                            req_addr_r  <= acq + { 44'd0, a_cq_head, 4'b0000 };
                            req_wdata_r <= { extra_cid, 4'd0, 3'd0, SC_ABORT, a_phase,
                                             a_sq_head, 16'd0,
                                             32'd0, 32'd0 };
                            req_len_r   <= 12'd4;
                            req_sent    <= 1'b1;
                            req_valid_r <= 1'b1;
                        end
                        else if ( req_done ) begin
                            req_sent <= 1'b0;
                            extra_pending <= 1'b0;
                            if ( a_cq_head == { 4'd0, acqs } ) begin
                                a_cq_head <= 16'd0;
                                a_phase   <= ~a_phase;
                            end
                            else begin
                                a_cq_head <= a_cq_head + 16'd1;
                            end
                        end
                    end
                    else begin
                        if ( !req_sent ) begin
                            req_kind_r  <= K_WR16;
                            req_addr_r  <= cq_base_f(cq_qid) + { 44'd0, cq_head_f(cq_qid), 4'b0000 };
                            req_wdata_r <= { cmd_cid, 4'd0, 3'd0, cmd_status, cq_phase_f(cq_qid),
                                             cmd_sqhd, 13'd0, cur_qid,
                                             cmd_result_hi, cmd_result };
                            req_len_r   <= 12'd4;
                            req_sent    <= 1'b1;
                            req_valid_r <= 1'b1;
                        end
                        else if ( req_done ) begin
                            req_sent <= 1'b0;
                            if ( cq_qid == 3'd0 ) begin
                                if ( a_cq_head == { 4'd0, acqs } ) begin
                                    a_cq_head <= 16'd0;
                                    a_phase   <= ~a_phase;
                                end
                                else begin
                                    a_cq_head <= a_cq_head + 16'd1;
                                end
                            end
                            else begin
                                if ( icq_head[cq_qid] == icq_size[cq_qid] ) begin
                                    icq_head[cq_qid]  <= 16'd0;
                                    icq_phase[cq_qid] <= ~icq_phase[cq_qid];
                                end
                                else begin
                                    icq_head[cq_qid] <= icq_head[cq_qid] + 16'd1;
                                end
                            end
                            cur_vec   <= cq_iv_f(cq_qid);
                            msix_sel  <= cq_iv_f(cq_qid);
                            state     <= A_IRQ;
                        end
                    end
                end
                // -----------------------------------------------------------------
                A_IRQ: begin
                    if ( !req_sent ) begin
                        if ( cq_ien_f(cq_qid) && !msix_mask && (msix_addr != 64'd0) ) begin
                            req_kind_r  <= K_IRQ;
                            req_addr_r  <= msix_addr;
                            req_wdata_r <= { 96'd0, msix_data };
                            req_len_r   <= 12'd1;
                            req_lid_r   <= 8'd0;
                            req_sent    <= 1'b1;
                            req_valid_r <= 1'b1;
                            pba_clr     <= 1'b1;
                            pba_clr_idx <= cur_vec;
                        end
                        else begin
                            if ( cq_ien_f(cq_qid) && msix_mask ) begin
                                pba_set <= 1'b1;
                                pba_idx <= cur_vec;
                            end
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
