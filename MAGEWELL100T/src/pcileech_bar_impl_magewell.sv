// -----------------------------------------------------------------------------
// Magewell Pro Capture AIO (PCI 1CD7:0002) BAR0 implementation.
//
// The 4 kB BAR0 aperture is backed by the existing bram_bar_zero4k block RAM
// (1024 x 32, one-cycle read latency).  The first eight dwords are a read-only
// identity / status block; every other dword is a benign read/write scratch
// register so that an unknown driver probe can read back what it wrote instead
// of seeing 0xFFFFFFFF.
//
// The card exposes no video input and therefore reports "no signal" (status
// bit 1 = 0).  No interrupts and no DMA are generated: the only active data
// path is the unmodified PCILeech FT601 bridge.
//
// Latency = 2 CLKs, identical to pcileech_bar_impl_zerowrite4k.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module pcileech_bar_impl_magewell(
    input               rst,
    input               clk,
    // incoming BAR writes:
    input [31:0]        wr_addr,
    input [3:0]         wr_be,
    input [31:0]        wr_data,
    input               wr_valid,
    // incoming BAR reads:
    input  [87:0]       rd_req_ctx,
    input  [31:0]       rd_req_addr,
    input               rd_req_valid,
    // outgoing BAR read replies:
    output bit [87:0]   rd_rsp_ctx,
    output bit [31:0]   rd_rsp_data,
    output bit          rd_rsp_valid
);

    // -------------------------------------------------------------------------
    // Read-only identity / status block (offset 0x000 .. 0x01C)
    // -------------------------------------------------------------------------
    localparam [31:0] REG_CHIP_ID    = 32'h0002_1CD7;   // 0x000: DID << 16 | VID
    localparam [31:0] REG_FW_VER     = 32'h0001_0031;   // 0x004: firmware 1.31
    localparam [31:0] REG_HW_VER     = 32'h0001_0031;   // 0x008: board rev 1.31
    localparam [31:0] REG_CAPS       = 32'h0000_0000;   // 0x00C: no video input
    localparam [31:0] REG_STATUS     = 32'h0000_0001;   // 0x010: [0] fw ready
                                                        //        [1] signal lock = 0
    localparam [31:0] REG_IRQ_STATUS = 32'h0000_0000;   // 0x018: no interrupts
    localparam [31:0] REG_FRAME_SEQ  = 32'h0000_0000;   // 0x020: no frames
    localparam [31:0] REG_DMA_STATUS = 32'h0000_0000;   // 0x024: DMA idle

    // -------------------------------------------------------------------------
    // Register file (block RAM, initialised to zero)
    // -------------------------------------------------------------------------
    wire [9:0] wa = wr_addr[11:2];
    wire [9:0] ra = rd_req_addr[11:2];

    // Identity / status words are read-only; drop writes to them.
    function automatic magewell_is_ro(input [9:0] idx);
        case (idx)
            10'h000, 10'h001, 10'h002, 10'h003,
            10'h004, 10'h006: magewell_is_ro = 1'b1;
            default:          magewell_is_ro = 1'b0;
        endcase
    endfunction

    wire [3:0] wr_be_masked = magewell_is_ro(wa) ? 4'b0000 : wr_be;

    wire [31:0] doutb;

    bram_bar_zero4k i_bram_bar_zero4k(
        // Port A - write:
        .addra  ( wa                    ),
        .clka   ( clk                   ),
        .dina   ( wr_data               ),
        .ena    ( wr_valid && (|wr_be_masked) ),
        .wea    ( wr_be_masked          ),
        // Port B - read (one CLK latency):
        .addrb  ( ra                    ),
        .clkb   ( clk                   ),
        .doutb  ( doutb                 ),
        .enb    ( rd_req_valid          )
    );

    // -------------------------------------------------------------------------
    // Two-stage read pipeline (matches pcileech_bar_impl_zerowrite4k)
    // -------------------------------------------------------------------------
    bit [87:0]  drd_req_ctx;
    bit         drd_req_valid;
    bit [9:0]   rd_idx_d1;

    function automatic [31:0] magewell_ro_value(
        input [9:0]  idx,
        input [31:0] rw_data
    );
        case (idx)
            10'h000: magewell_ro_value = REG_CHIP_ID;
            10'h001: magewell_ro_value = REG_FW_VER;
            10'h002: magewell_ro_value = REG_HW_VER;
            10'h003: magewell_ro_value = REG_CAPS;
            10'h004: magewell_ro_value = REG_STATUS;
            10'h006: magewell_ro_value = REG_IRQ_STATUS;
            10'h008: magewell_ro_value = REG_FRAME_SEQ;
            10'h009: magewell_ro_value = REG_DMA_STATUS;
            default: magewell_ro_value = rw_data;
        endcase
    endfunction

    always @ ( posedge clk ) begin
        drd_req_ctx     <= rd_req_ctx;
        drd_req_valid   <= rd_req_valid;
        rd_idx_d1       <= ra;
        rd_rsp_ctx      <= drd_req_ctx;
        rd_rsp_valid    <= drd_req_valid;
        rd_rsp_data     <= magewell_ro_value(rd_idx_d1, doutb);
    end

endmodule
