// -----------------------------------------------------------------------------
// FT601 receive completion router + transparent MemRd tag remapping.
//
// The NVMe engine uses tag 0xFF for its host-memory reads.  The FT601 host
// software may also use tag 0xFF (or 0xFE) for its own MemRd requests.  To
// keep the FT601 protocol untouched:
//
//   * every FT601 MemRd with tag 0xFE/0xFF is transparently rewritten to one
//     of four reserved remap tags (0xFD..0xFA) on the transmit path;
//   * the returning CplD is matched and rewritten back to the original tag
//     before it reaches the FT601 FIFO;
//   * a small 4-bit bitmap prevents allocating a remap tag that is already
//     in flight from another FT601 request.
//
// A four-entry pool keeps the allocation logic to a 4-way priority mux
// instead of a 256-way search, which is required to close timing at 62.5 MHz.
//
// Completions belonging to the NVMe engine (requester ID == our PCIe ID and
// tag 0xFF) are diverted away from the FT601 stream.
//
// The remap is purely combinational on the transmit stream: no extra cycles
// are added, so the FT601 throughput is not reduced.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_ft601_cpl_router(
    input               clk,
    input               rst,
    input [15:0]        pcie_id,
    // PCIe receive stream
    IfAXIS128.sink_lite tlps_in,
    // To the PCILeech filter / FT601 destination FIFO
    IfAXIS128.source_lite tlps_ft601,
    // To the NVMe admin engine
    IfAXIS128.source_lite tlps_nvme,
    // FT601 transmit stream (from src_fifo), tag remap snoop
    input               tx_valid,
    input               tx_first,
    input               tx_last,
    input [127:0]       tx_tdata,
    output [127:0]      tx_tdata_out
);

    // -------------------------------------------------------------------------
    // Remap tag pool
    // -------------------------------------------------------------------------
    localparam [7:0] POOL0 = 8'hFD;
    localparam [7:0] POOL1 = 8'hFC;
    localparam [7:0] POOL2 = 8'hFB;
    localparam [7:0] POOL3 = 8'hFA;

    reg [7:0] map_orig0, map_orig1, map_orig2, map_orig3;
    reg       map_v0,    map_v1,    map_v2,    map_v3;
    reg [3:0] pool_busy;        // pool tag currently in flight

    wire free0 = ~map_v0 & ~pool_busy[0];
    wire free1 = ~map_v1 & ~pool_busy[1];
    wire free2 = ~map_v2 & ~pool_busy[2];
    wire free3 = ~map_v3 & ~pool_busy[3];

    wire       alloc_ok  = free0 | free1 | free2 | free3;
    wire [1:0] alloc_idx = free0 ? 2'd0 :
                           free1 ? 2'd1 :
                           free2 ? 2'd2 : 2'd3;
    wire [7:0] alloc_tag = (alloc_idx == 2'd0) ? POOL0 :
                           (alloc_idx == 2'd1) ? POOL1 :
                           (alloc_idx == 2'd2) ? POOL2 : POOL3;

    // -------------------------------------------------------------------------
    // Transmit stream: replace the tag of reserved-tag MemRd requests
    // -------------------------------------------------------------------------
    wire [7:0] tx_tag = tx_tdata[47:40];
    wire       tx_memrd = tx_first &&
                          (tx_tdata[31:29] == 3'b000 || tx_tdata[31:29] == 3'b001) &&
                          (tx_tdata[28:24] == 5'b00000);
    wire       tx_reserved = (tx_tag == 8'hFE) || (tx_tag == 8'hFF);
    wire [7:0] tx_tag_new = (tx_reserved && alloc_ok) ? alloc_tag : tx_tag;

    assign tx_tdata_out = (tx_memrd && tx_reserved && alloc_ok) ?
                          { tx_tdata[127:48], tx_tag_new, tx_tdata[39:0] } : tx_tdata;

    // -------------------------------------------------------------------------
    // Receive completion: restore the original tag
    // -------------------------------------------------------------------------
    wire        first     = tlps_in.tuser[0];
    wire [7:0]  rx_tag    = tlps_in.tdata[79:72];   // Cpl/CplD DW2 bits [15:8]
    wire [15:0] rx_reqid  = tlps_in.tdata[95:80];
    wire        is_cpl    = first && ((tlps_in.tdata[31:25] == 7'b0000101) ||
                                      (tlps_in.tdata[31:25] == 7'b0100101));

    reg  [7:0]  rest_tag;
    reg         rest_v;
    always @ * begin
        rest_tag = rx_tag;
        rest_v   = 1'b0;
        case ( rx_tag )
            POOL0: if ( map_v0 ) begin rest_v = 1'b1; rest_tag = map_orig0; end
            POOL1: if ( map_v1 ) begin rest_v = 1'b1; rest_tag = map_orig1; end
            POOL2: if ( map_v2 ) begin rest_v = 1'b1; rest_tag = map_orig2; end
            POOL3: if ( map_v3 ) begin rest_v = 1'b1; rest_tag = map_orig3; end
            default: ;
        endcase
    end

    wire [127:0] ft601_tdata = (first && is_cpl && rest_v) ?
                               { tlps_in.tdata[127:80], rest_tag, tlps_in.tdata[71:0] } :
                               tlps_in.tdata;

    // -------------------------------------------------------------------------
    // State update
    // -------------------------------------------------------------------------
    always @ ( posedge clk ) begin
        if ( rst ) begin
            map_v0 <= 1'b0; map_v1 <= 1'b0; map_v2 <= 1'b0; map_v3 <= 1'b0;
            map_orig0 <= 8'd0; map_orig1 <= 8'd0; map_orig2 <= 8'd0; map_orig3 <= 8'd0;
            pool_busy <= 4'd0;
        end
        else begin
            // FT601 MemRd: allocate a remap tag for 0xFE/0xFF, otherwise
            // just mark a pool tag as busy if the host uses one directly.
            if ( tx_valid && tx_first && tx_memrd ) begin
                if ( tx_reserved ) begin
                    if ( alloc_ok ) begin
                        pool_busy[alloc_idx] <= 1'b1;
                        case ( alloc_idx )
                            2'd0: begin map_v0 <= 1'b1; map_orig0 <= tx_tag; end
                            2'd1: begin map_v1 <= 1'b1; map_orig1 <= tx_tag; end
                            2'd2: begin map_v2 <= 1'b1; map_orig2 <= tx_tag; end
                            default: begin map_v3 <= 1'b1; map_orig3 <= tx_tag; end
                        endcase
                    end
                end
                else begin
                    case ( tx_tag )
                        POOL0: pool_busy[0] <= 1'b1;
                        POOL1: pool_busy[1] <= 1'b1;
                        POOL2: pool_busy[2] <= 1'b1;
                        POOL3: pool_busy[3] <= 1'b1;
                        default: ;
                    endcase
                end
            end
            // Completion: free the pool entry and drop the reverse mapping.
            if ( tlps_in.tvalid && tlps_in.tuser[0] && is_cpl ) begin
                case ( rx_tag )
                    POOL0: begin pool_busy[0] <= 1'b0; map_v0 <= 1'b0; end
                    POOL1: begin pool_busy[1] <= 1'b0; map_v1 <= 1'b0; end
                    POOL2: begin pool_busy[2] <= 1'b0; map_v2 <= 1'b0; end
                    POOL3: begin pool_busy[3] <= 1'b0; map_v3 <= 1'b0; end
                    default: ;
                endcase
            end
        end
    end

    // -------------------------------------------------------------------------
    // NVMe completion routing
    // -------------------------------------------------------------------------
    wire to_nvme_f = is_cpl && (rx_reqid == { pcie_id[7:0], pcie_id[15:8] }) &&
                     (rx_tag == 8'hFF);

    reg pkt_nvme;
    always @ ( posedge clk ) begin
        if ( rst )
            pkt_nvme <= 1'b0;
        else if ( tlps_in.tvalid && first )
            pkt_nvme <= to_nvme_f;
    end

    wire sel_nvme = first ? to_nvme_f : pkt_nvme;

    assign tlps_ft601.tdata   = ft601_tdata;
    assign tlps_ft601.tkeepdw = tlps_in.tkeepdw;
    assign tlps_ft601.tvalid  = tlps_in.tvalid && !sel_nvme;
    assign tlps_ft601.tlast   = tlps_in.tlast;
    assign tlps_ft601.tuser   = tlps_in.tuser;

    assign tlps_nvme.tdata    = tlps_in.tdata;
    assign tlps_nvme.tkeepdw  = tlps_in.tkeepdw;
    assign tlps_nvme.tvalid   = tlps_in.tvalid && sel_nvme;
    assign tlps_nvme.tlast    = tlps_in.tlast;
    assign tlps_nvme.tuser    = tlps_in.tuser;

endmodule
