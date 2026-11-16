// -----------------------------------------------------------------------------
// FT601 receive completion router + transparent MemRd tag remapping.
//
// The NVMe engine uses tag 0xFF for its host-memory reads.  The FT601 host
// software may also use tag 0xFF (or 0xFE) for its own MemRd requests.  To
// keep the FT601 protocol untouched:
//
//   * every FT601 MemRd with tag 0xFE/0xFF is transparently rewritten to a
//     free tag (0x00..0xFD) on the transmit path;
//   * the returning CplD is matched by tag and rewritten back to the original
//     tag before it reaches the FT601 FIFO;
//   * a 256-bit busy bitmap avoids allocating a tag that is still in flight.
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
    // Tag remap state
    // -------------------------------------------------------------------------
    reg [255:0] busy;
    reg [7:0]   map_orig [0:255];
    reg         map_valid [0:255];

    // -------------------------------------------------------------------------
    // Free tag allocation (highest free tag in 0x00..0xFD; the FT601 software
    // normally allocates tags from the bottom upwards)
    // -------------------------------------------------------------------------
    reg [7:0] alloc_tag;
    reg       alloc_found;
    integer k;
    always @ * begin
        alloc_tag   = 8'h00;
        alloc_found = 1'b0;
        for ( k = 0; k <= 253; k = k + 1 ) begin
            if ( !busy[k] ) begin
                alloc_tag   = k[7:0];
                alloc_found = 1'b1;
            end
        end
    end

    integer i;
    always @ ( posedge clk ) begin
        if ( rst ) begin
            busy <= 256'd0;
            for ( i = 0; i < 256; i = i + 1 ) begin
                map_valid[i] <= 1'b0;
                map_orig[i]  <= 8'd0;
            end
        end
        else begin
            // FT601 MemRd: allocate a tag for the reserved tags.
            if ( tx_valid && tx_first &&
                 (tx_tdata[31:29] == 3'b000 || tx_tdata[31:29] == 3'b001) &&
                 (tx_tdata[28:24] == 5'b00000) ) begin
                if ( (tx_tdata[47:40] == 8'hFE) || (tx_tdata[47:40] == 8'hFF) ) begin
                    if ( alloc_found ) begin
                        busy[alloc_tag]      <= 1'b1;
                        map_valid[alloc_tag] <= 1'b1;
                        map_orig[alloc_tag]  <= tx_tdata[47:40];
                    end
                end
                else begin
                    busy[tx_tdata[47:40]] <= 1'b1;
                end
            end
            // Completion: free the tag and drop the reverse mapping.
            // Cpl/CplD header: tag is in DW2 bits [15:8] = tdata[79:72].
            if ( tlps_in.tvalid && tlps_in.tuser[0] &&
                 ((tlps_in.tdata[31:25] == 7'b0000101) || (tlps_in.tdata[31:25] == 7'b0100101)) ) begin
                busy[tlps_in.tdata[79:72]]      <= 1'b0;
                map_valid[tlps_in.tdata[79:72]] <= 1'b0;
            end
        end
    end

    wire [7:0] tx_tag = tx_tdata[47:40];
    wire       tx_memrd = tx_first &&
                          (tx_tdata[31:29] == 3'b000 || tx_tdata[31:29] == 3'b001) &&
                          (tx_tdata[28:24] == 5'b00000);
    wire       tx_reserved = (tx_tag == 8'hFE) || (tx_tag == 8'hFF);
    wire [7:0] tx_tag_new = (tx_reserved && alloc_found) ? alloc_tag : tx_tag;

    assign tx_tdata_out = (tx_memrd && tx_reserved && alloc_found) ?
                          { tx_tdata[127:48], tx_tag_new, tx_tdata[39:0] } : tx_tdata;

    // -------------------------------------------------------------------------
    // Receive routing
    // -------------------------------------------------------------------------
    wire        first     = tlps_in.tuser[0];
    wire [7:0]  rx_tag    = tlps_in.tdata[79:72];   // Cpl/CplD DW2 bits [15:8]
    wire [15:0] rx_reqid  = tlps_in.tdata[95:80];
    wire        is_cpl    = first && ((tlps_in.tdata[31:25] == 7'b0000101) ||
                                      (tlps_in.tdata[31:25] == 7'b0100101));
    wire        to_nvme_f = is_cpl && (rx_reqid == { pcie_id[7:0], pcie_id[15:8] }) &&
                            (rx_tag == 8'hFF);

    reg         pkt_nvme;
    always @ ( posedge clk ) begin
        if ( rst )
            pkt_nvme <= 1'b0;
        else if ( tlps_in.tvalid && first )
            pkt_nvme <= to_nvme_f;
    end

    wire sel_nvme = first ? to_nvme_f : pkt_nvme;

    wire [7:0] rest_tag = map_valid[rx_tag] ? map_orig[rx_tag] : rx_tag;
    wire [127:0] ft601_tdata = (first && is_cpl && map_valid[rx_tag]) ?
                               { tlps_in.tdata[127:80], rest_tag, tlps_in.tdata[71:0] } :
                               tlps_in.tdata;

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
