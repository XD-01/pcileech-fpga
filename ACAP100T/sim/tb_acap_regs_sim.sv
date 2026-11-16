// -----------------------------------------------------------------------------
// ACAP-100T register-file simulation
// Checks BAR writes, two-cycle BAR reads, buffer programming and status.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`include "acap_pkg.svh"

module tb_acap_regs_sim;

    reg clk = 1'b0;
    always #8 clk = ~clk;

    reg rst = 1'b1;

    reg [31:0] bar_wr_addr = 32'd0;
    reg [3:0]  bar_wr_be = 4'h0;
    reg [31:0] bar_wr_data = 32'd0;
    reg        bar_wr_valid = 1'b0;

    reg  [87:0] bar_rd_ctx = 88'd0;
    reg  [31:0] bar_rd_addr = 32'd0;
    reg         bar_rd_valid = 1'b0;
    wire [87:0] bar_rd_rsp_ctx;
    wire [31:0] bar_rd_rsp_data;
    wire        bar_rd_rsp_valid;

    wire capture_enable, pattern_select;
    wire [2:0] irq_enable;
    wire next_buf_valid;
    wire [2:0] next_buf_index;
    wire [63:0] next_buf_addr;
    wire [31:0] frame_bytes;

    integer errors = 0;
    reg [31:0] rd_data;

    acap_regs u_regs (
        .clk               ( clk             ),
        .rst               ( rst             ),
        .bar_wr_addr       ( bar_wr_addr     ),
        .bar_wr_be         ( bar_wr_be       ),
        .bar_wr_data       ( bar_wr_data     ),
        .bar_wr_valid      ( bar_wr_valid    ),
        .bar_rd_ctx        ( bar_rd_ctx      ),
        .bar_rd_addr       ( bar_rd_addr     ),
        .bar_rd_valid      ( bar_rd_valid    ),
        .bar_rd_rsp_ctx    ( bar_rd_rsp_ctx  ),
        .bar_rd_rsp_data   ( bar_rd_rsp_data ),
        .bar_rd_rsp_valid  ( bar_rd_rsp_valid),
        .link_up           ( 1'b1            ),
        .ltssm             ( 6'd0            ),
        .link_width        ( 2'd1            ),
        .link_speed        ( 1'b1            ),
        .msi_en            ( 1'b0            ),
        .dma_busy          ( 1'b0            ),
        .frame_done_pulse  ( 1'b0            ),
        .frame_done_index  ( 3'd0            ),
        .frame_seq_in      ( 32'd0           ),
        .frame_ts_in       ( 64'd0           ),
        .frame_size_in     ( 32'd0           ),
        .frame_stall       ( 1'b0            ),
        .capture_enable    ( capture_enable  ),
        .pattern_select    ( pattern_select  ),
        .frame_bytes       ( frame_bytes     ),
        .irq_enable        ( irq_enable      ),
        .next_buf_valid    ( next_buf_valid  ),
        .next_buf_index    ( next_buf_index  ),
        .next_buf_addr     ( next_buf_addr   )
    );

    task automatic wr(input [31:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            bar_wr_addr = addr;
            bar_wr_data = data;
            bar_wr_be = 4'hF;
            bar_wr_valid = 1'b1;
            @(negedge clk);
            bar_wr_valid = 1'b0;
        end
    endtask

    task automatic rd(input [31:0] addr, input [31:0] expected);
        begin
            @(negedge clk);
            bar_rd_addr = addr;
            bar_rd_ctx = {8'hA5, 80'h0};
            bar_rd_valid = 1'b1;
            @(negedge clk);
            bar_rd_valid = 1'b0;
            @(posedge clk);
            #1;
            rd_data = bar_rd_rsp_data;
            if (!bar_rd_rsp_valid) begin
                $display("ERROR: read of %03x not valid", addr);
                errors = errors + 1;
            end
            if (bar_rd_rsp_ctx[87:80] !== 8'hA5) begin
                $display("ERROR: read context lost");
                errors = errors + 1;
            end
            if (rd_data !== expected) begin
                $display("ERROR: read %03x = %08x, expected %08x",
                         addr, rd_data, expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        #100 rst = 1'b0;
        repeat (5) @(posedge clk);

        rd(32'h000, 32'h4D434150);
        rd(32'h004, 32'h00010000);
        rd(32'h030, 32'd1920);
        rd(32'h034, 32'd1080);
        rd(32'h038, 32'd3840);
        rd(32'h044, 32'd4147328);

        wr(32'h100, 32'h11223344);
        wr(32'h104, 32'h55667788);
        wr(32'h10C, 32'h1);

        rd(32'h100, 32'h11223344);
        rd(32'h104, 32'h55667788);
        rd(32'h10C, 32'h00000001);

        wr(32'h040, 32'h4);
        rd(32'h040, 32'h00000004);
        rd(32'h04C, 32'h00000000);

        wr(32'h010, 32'h1);
        rd(32'h010, 32'h00000001);
        if (capture_enable !== 1'b1) begin
            $display("ERROR: capture_enable not asserted");
            errors = errors + 1;
        end

        if (frame_bytes !== 32'd4147328) begin
            $display("ERROR: frame_bytes output %0d", frame_bytes);
            errors = errors + 1;
        end
        if (next_buf_valid !== 1'b1 || next_buf_index !== 3'd0 ||
            next_buf_addr !== 64'h5566778811223344) begin
            $display("ERROR: next buffer %0d %0d %016x", next_buf_valid,
                     next_buf_index, next_buf_addr);
            errors = errors + 1;
        end

        $display("regs sim errors=%0d", errors);
        if (errors != 0)
            $fatal(1, "REGS SIM FAILED");
        $display("REGS SIM PASSED");
        $finish;
    end

endmodule
