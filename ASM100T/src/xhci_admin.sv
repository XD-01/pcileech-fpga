// -----------------------------------------------------------------------------
// xHCI command/event ring engine (ASM1042 emulation).
//
//   * command ring fetch from CRCR (Link TRB + cycle handling)
//   * No Op / Enable Slot / Disable Slot / Address Device / Configure Endpoint
//     / Evaluate Context / Reset / Stop / Set TR Dequeue / Force Event etc.
//     -> Command Completion Event (0x21)
//   * event ring segment table fetch, event TRB writes
//   * MSI-X vector 0, IMAN.IP / USBSTS.EINT
//
// 2 ports, 32 slots, 1 interrupter.  Ports report "disconnected" so Windows
// usbxhci.sys starts the controller without any USB device.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module xhci_admin(
    input               clk,
    input               rst,
    input [15:0]        pcie_id,
    input               usbcmd_rs,
    input               usbcmd_inte,
    input [63:0]        crcr,
    input               crcr_wr,
    input [63:0]        dcbaap,
    input [7:0]         config_max_slots,
    input [15:0]        erstsz,
    input [63:0]        erstba,
    input               erstba_wr,
    input [63:0]        erdp,
    input               iman_ie,
    input               db0_wr,
    output reg          usbsts_eint_set,
    output reg          iman_ip_set,
    output reg [2:0]    msix_sel,
    input [63:0]        msix_addr,
    input [31:0]        msix_data,
    input               msix_mask,
    IfAXIS128.sink_lite cpl,
    IfAXIS128.source    tlps_out
);

    localparam [2:0] K_RD   = 3'd0;
    localparam [2:0] K_WR16 = 3'd1;
    localparam [2:0] K_IRQ  = 3'd4;

    localparam [3:0] X_IDLE     = 4'd0;
    localparam [3:0] X_CMD_RD   = 4'd1;
    localparam [3:0] X_EXEC     = 4'd2;
    localparam [3:0] X_ERST_RD  = 4'd3;
    localparam [3:0] X_EVT_PREP = 4'd4;
    localparam [3:0] X_EVT_WR   = 4'd5;
    localparam [3:0] X_IRQ      = 4'd6;

    wire        req_valid;
    wire        req_ready;
    wire        req_done;
    wire [2:0]  req_kind;
    wire [63:0] req_addr;
    wire [127:0] req_wdata;
    wire [11:0] req_len_dw;

    nvme_tx_req i_tx(
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
    // Completion capture (16-byte read = 2 beats)
    // -------------------------------------------------------------------------
    reg [31:0]  cap_dw [0:3];
    reg         cap_done;
    reg         cap_err;

    wire [31:0] cb0 = { cpl.tdata[7:0],   cpl.tdata[15:8],  cpl.tdata[23:16],  cpl.tdata[31:24]   };
    wire [31:0] cb1 = { cpl.tdata[39:32], cpl.tdata[47:40], cpl.tdata[55:48],  cpl.tdata[63:56]   };
    wire [31:0] cb2 = { cpl.tdata[71:64], cpl.tdata[79:72], cpl.tdata[87:80],  cpl.tdata[95:88]   };
    wire [31:0] cb3 = { cpl.tdata[103:96], cpl.tdata[111:104], cpl.tdata[119:112], cpl.tdata[127:120] };

    always @ ( posedge clk ) begin
        cap_done <= 1'b0;
        if ( rst ) begin
            cap_err <= 1'b0;
        end
        else if ( cpl.tvalid ) begin
            if ( cpl.tuser[0] ) begin
                cap_dw[0] <= cb3;
                cap_err   <= (cpl.tdata[47:45] != 3'd0) || cpl.tlast;
                if ( cpl.tlast ) cap_done <= 1'b1;
            end
            else begin
                if ( cpl.tkeepdw[0] ) cap_dw[1] <= cb0;
                if ( cpl.tkeepdw[1] ) cap_dw[2] <= cb1;
                if ( cpl.tkeepdw[2] ) cap_dw[3] <= cb2;
                cap_done <= cpl.tlast;
            end
        end
    end

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------
    reg [3:0]   state;
    reg [63:0]  cmd_ptr;
    reg         cmd_cycle;
    reg         fetch_req;
    reg [63:0]  cur_trb;
    reg [31:0]  trb_dw0, trb_dw1, trb_dw2, trb_dw3;

    reg [63:0]  seg_base;
    reg [15:0]  seg_size;
    reg         erst_loaded;
    reg [63:0]  evt_off;
    reg         evt_cycle;

    reg [31:0]  slot_map;
    reg [5:0]   new_slot;
    reg         slot_found;

    reg [31:0]  evt_dw0, evt_dw1, evt_dw2, evt_dw3;
    reg         irq_sent;

    reg         req_valid_r;
    reg [2:0]   req_kind_r;
    reg [63:0]  req_addr_r;
    reg [127:0] req_wdata_r;
    reg [11:0]  req_len_r;

    assign req_valid  = req_valid_r;
    assign req_kind   = req_kind_r;
    assign req_addr   = req_addr_r;
    assign req_wdata  = req_wdata_r;
    assign req_len_dw = req_len_r;

    wire [5:0]  trb_type = trb_dw3[15:10];
    wire [7:0]  trb_slot = trb_dw3[31:24];

    integer s;
    always @ * begin
        new_slot   = 6'd0;
        slot_found = 1'b0;
        for ( s = 32; s >= 1; s = s - 1 ) begin
            if ( (s <= config_max_slots) && !slot_map[s-1] ) begin
                new_slot   = s[5:0];
                slot_found = 1'b1;
            end
        end
    end

    // Event fields for the TRB currently in trb_dw*
    reg [7:0] evt_code_c;
    reg [7:0] evt_slot_c;
    always @ * begin
        evt_code_c = 8'h05;
        evt_slot_c = 8'd0;
        if ( trb_type == 6'd9 ) begin
            evt_code_c = slot_found ? 8'h01 : 8'h1F;
            evt_slot_c = { 2'd0, new_slot };
        end
        else if ( (trb_type == 6'd10) || ((trb_type >= 6'd11) && (trb_type <= 6'd27)) ) begin
            evt_code_c = 8'h01;
            evt_slot_c = trb_slot;
        end
    end

    wire [31:0] evt_dw0_c = cur_trb[31:0];
    wire [31:0] evt_dw1_c = cur_trb[63:32];
    wire [31:0] evt_dw2_c = { evt_code_c, 24'd0 };
    wire [31:0] evt_dw3_c = { evt_slot_c, 8'd0, 6'h21, 8'd0, 1'b0, evt_cycle };

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            state        <= X_IDLE;
            cmd_ptr      <= 64'd0;
            cmd_cycle    <= 1'b0;
            fetch_req    <= 1'b0;
            cur_trb      <= 64'd0;
            trb_dw0      <= 32'd0;
            trb_dw1      <= 32'd0;
            trb_dw2      <= 32'd0;
            trb_dw3      <= 32'd0;
            seg_base     <= 64'd0;
            seg_size     <= 16'd0;
            erst_loaded  <= 1'b0;
            evt_off      <= 64'd0;
            evt_cycle    <= 1'b1;
            slot_map     <= 32'd0;
            evt_dw0      <= 32'd0;
            evt_dw1      <= 32'd0;
            evt_dw2      <= 32'd0;
            evt_dw3      <= 32'd0;
            irq_sent     <= 1'b0;
            req_valid_r  <= 1'b0;
            req_kind_r   <= K_RD;
            req_addr_r   <= 64'd0;
            req_wdata_r  <= 128'd0;
            req_len_r    <= 12'd4;
            msix_sel     <= 3'd0;
            usbsts_eint_set <= 1'b0;
            iman_ip_set  <= 1'b0;
        end
        else begin
            usbsts_eint_set <= 1'b0;
            iman_ip_set     <= 1'b0;

            if ( crcr_wr ) begin
                cmd_ptr   <= { crcr[63:4], 4'b0 };
                cmd_cycle <= crcr[0];
            end
            if ( erstba_wr ) begin
                erst_loaded <= 1'b0;
                evt_off     <= 64'd0;
                evt_cycle   <= 1'b1;
            end
            if ( db0_wr )
                fetch_req <= 1'b1;

            if ( req_valid_r && req_ready )
                req_valid_r <= 1'b0;

            case ( state )
                // -----------------------------------------------------------------
                X_IDLE: begin
                    if ( fetch_req && usbcmd_rs && (crcr[63:4] != 60'd0) ) begin
                        cur_trb     <= cmd_ptr;
                        req_kind_r  <= K_RD;
                        req_addr_r  <= cmd_ptr;
                        req_len_r   <= 12'd4;
                        req_wdata_r <= 128'd0;
                        req_valid_r <= 1'b1;
                        state       <= X_CMD_RD;
                    end
                end
                // -----------------------------------------------------------------
                X_CMD_RD: begin
                    if ( cap_done ) begin
                        trb_dw0 <= cap_dw[0];
                        trb_dw1 <= cap_dw[1];
                        trb_dw2 <= cap_dw[2];
                        trb_dw3 <= cap_dw[3];
                        state   <= X_EXEC;
                    end
                end
                // -----------------------------------------------------------------
                X_EXEC: begin
                    if ( trb_dw3[0] != cmd_cycle ) begin
                        fetch_req <= 1'b0;
                        state     <= X_IDLE;
                    end
                    else if ( trb_type == 6'd6 ) begin
                        cmd_ptr   <= { trb_dw1, trb_dw0 };
                        cmd_cycle <= trb_dw3[1] ? ~cmd_cycle : cmd_cycle;
                        fetch_req <= 1'b1;
                        state     <= X_IDLE;
                    end
                    else begin
                        evt_dw0 <= evt_dw0_c;
                        evt_dw1 <= evt_dw1_c;
                        evt_dw2 <= evt_dw2_c;
                        evt_dw3 <= evt_dw3_c;
                        irq_sent <= 1'b0;
                        if ( trb_type == 6'd9 ) begin
                            if ( slot_found )
                                slot_map[new_slot-1] <= 1'b1;
                        end
                        else if ( trb_type == 6'd10 ) begin
                            if ( (trb_slot >= 8'd1) && (trb_slot <= 8'd32) )
                                slot_map[trb_slot-1] <= 1'b0;
                        end

                        if ( !erst_loaded ) begin
                            req_kind_r  <= K_RD;
                            req_addr_r  <= erstba;
                            req_len_r   <= 12'd4;
                            req_wdata_r <= 128'd0;
                            req_valid_r <= 1'b1;
                            state       <= X_ERST_RD;
                        end
                        else begin
                            state <= X_EVT_PREP;
                        end
                    end
                end
                // -----------------------------------------------------------------
                X_ERST_RD: begin
                    if ( cap_done ) begin
                        seg_base    <= { cap_dw[1], cap_dw[0] };
                        seg_size    <= (cap_dw[2][31:16] == 16'd0) ? 16'd256 : cap_dw[2][31:16];
                        erst_loaded <= 1'b1;
                        state       <= X_EVT_PREP;
                    end
                end
                // -----------------------------------------------------------------
                X_EVT_PREP: begin
                    req_kind_r  <= K_WR16;
                    req_addr_r  <= seg_base + evt_off;
                    req_wdata_r <= { evt_dw3, evt_dw2, evt_dw1, evt_dw0 };
                    req_len_r   <= 12'd4;
                    req_valid_r <= 1'b1;
                    state       <= X_EVT_WR;
                end
                // -----------------------------------------------------------------
                X_EVT_WR: begin
                    if ( req_done ) begin
                        usbsts_eint_set <= 1'b1;
                        iman_ip_set     <= 1'b1;
                        if ( evt_off + 64'd16 >= { 48'd0, seg_size, 4'b0000 } ) begin
                            evt_off   <= 64'd0;
                            evt_cycle <= ~evt_cycle;
                        end
                        else begin
                            evt_off <= evt_off + 64'd16;
                        end
                        state <= X_IRQ;
                    end
                end
                // -----------------------------------------------------------------
                X_IRQ: begin
                    if ( !irq_sent ) begin
                        if ( usbcmd_inte && iman_ie && !msix_mask && (msix_addr != 64'd0) ) begin
                            req_kind_r  <= K_IRQ;
                            req_addr_r  <= msix_addr;
                            req_wdata_r <= { 96'd0, msix_data };
                            req_len_r   <= 12'd1;
                            req_valid_r <= 1'b1;
                            irq_sent    <= 1'b1;
                            msix_sel    <= 3'd0;
                        end
                        else begin
                            cmd_ptr   <= cmd_ptr + 64'd16;
                            fetch_req <= 1'b1;
                            state     <= X_IDLE;
                        end
                    end
                    else if ( req_done ) begin
                        cmd_ptr   <= cmd_ptr + 64'd16;
                        fetch_req <= 1'b1;
                        state     <= X_IDLE;
                    end
                end
                default: state <= X_IDLE;
            endcase
        end
    end

endmodule
