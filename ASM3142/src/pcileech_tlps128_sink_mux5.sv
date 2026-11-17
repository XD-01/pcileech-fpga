// ------------------------------------------------------------------------
// TLP transmit mux with five inputs.
// Selects the lowest-numbered input with pending data and transmits the
// full packet.  Input 3 is the FT601 stream and input 5 the NVMe engine,
// so the FT601 path always wins arbitration (maximum throughput).
// ------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_tlps128_sink_mux5 (
    input                       clk_pcie,
    input                       rst,
    IfAXIS128.source            tlps_out,
    IfAXIS128.sink              tlps_in1,
    IfAXIS128.sink              tlps_in2,
    IfAXIS128.sink              tlps_in3,
    IfAXIS128.sink              tlps_in4,
    IfAXIS128.sink              tlps_in5
);

    bit [2:0] id = 0;

    assign tlps_out.has_data = tlps_in1.has_data || tlps_in2.has_data || tlps_in3.has_data ||
                               tlps_in4.has_data || tlps_in5.has_data;

    assign tlps_out.tdata    = (id==1) ? tlps_in1.tdata :
                               (id==2) ? tlps_in2.tdata :
                               (id==3) ? tlps_in3.tdata :
                               (id==4) ? tlps_in4.tdata :
                               (id==5) ? tlps_in5.tdata : 0;

    assign tlps_out.tkeepdw  = (id==1) ? tlps_in1.tkeepdw :
                               (id==2) ? tlps_in2.tkeepdw :
                               (id==3) ? tlps_in3.tkeepdw :
                               (id==4) ? tlps_in4.tkeepdw :
                               (id==5) ? tlps_in5.tkeepdw : 0;

    assign tlps_out.tlast    = (id==1) ? tlps_in1.tlast :
                               (id==2) ? tlps_in2.tlast :
                               (id==3) ? tlps_in3.tlast :
                               (id==4) ? tlps_in4.tlast :
                               (id==5) ? tlps_in5.tlast : 0;

    assign tlps_out.tuser    = (id==1) ? tlps_in1.tuser :
                               (id==2) ? tlps_in2.tuser :
                               (id==3) ? tlps_in3.tuser :
                               (id==4) ? tlps_in4.tuser :
                               (id==5) ? tlps_in5.tuser : 0;

    assign tlps_out.tvalid   = (id==1) ? tlps_in1.tvalid :
                               (id==2) ? tlps_in2.tvalid :
                               (id==3) ? tlps_in3.tvalid :
                               (id==4) ? tlps_in4.tvalid :
                               (id==5) ? tlps_in5.tvalid : 0;

    wire [2:0] id_next_newsel = tlps_in1.has_data ? 1 :
                                tlps_in2.has_data ? 2 :
                                tlps_in3.has_data ? 3 :
                                tlps_in4.has_data ? 4 :
                                tlps_in5.has_data ? 5 : 0;

    wire [2:0] id_next = ((id==0) || (tlps_out.tvalid && tlps_out.tlast)) ? id_next_newsel : id;

    assign tlps_in1.tready = tlps_out.tready && (id_next==1);
    assign tlps_in2.tready = tlps_out.tready && (id_next==2);
    assign tlps_in3.tready = tlps_out.tready && (id_next==3);
    assign tlps_in4.tready = tlps_out.tready && (id_next==4);
    assign tlps_in5.tready = tlps_out.tready && (id_next==5);

    always @ ( posedge clk_pcie ) begin
        id <= rst ? 0 : id_next;
    end

endmodule
