
/*
 * Copyright (C) 2026
 * Author: Abhinav S <abhinavsasivala02@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 */

`include "mldsa_params.vh"

module tb_ntt_check;
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    reg  start, intt_mode;
    wire busy, done;
    reg  ext_we;
    reg  [7:0] ext_addr;
    reg  [`MLDSA_QBITS-1:0] ext_din;
    wire [`MLDSA_QBITS-1:0] ext_dout;

    ntt_core u_ntt (
        .clk(clk), .rst_n(rst_n), .start(start), .intt_mode(intt_mode),
        .busy(busy), .done(done),
        .ext_we(ext_we), .ext_addr(ext_addr),
        .ext_din(ext_din), .ext_dout(ext_dout)
    );

    integer i;
    reg [22:0] data_in [0:255];
    reg [22:0] data_out [0:255];

    integer watchdog = 0;
    reg dbg = 0;
    always @(posedge clk) begin
        if (dbg) $display("DBG c=%0d state=%0d addra=%0d addrb=%0d bfa=%0d bfb=%0d zeta=%0d dina=%0d dinb=%0d wa3=%0d wb3=%0d wea=%0d web=%0d j=%0d k=%0d", watchdog, u_ntt.state, u_ntt.fsm_addra, u_ntt.fsm_addrb, u_ntt.bf_a_in, u_ntt.bf_b_in, u_ntt.bf_zeta, u_ntt.fsm_dina, u_ntt.fsm_dinb, u_ntt.wa_dly_3, u_ntt.wb_dly_3, u_ntt.fsm_wea, u_ntt.fsm_web, u_ntt.j_cnt, u_ntt.k_idx);
        watchdog = watchdog + 1;
        if (watchdog < 400) $display("t=%0d busy=%0d done=%0d state=%0d start=%0d", watchdog, u_ntt.busy, u_ntt.done, u_ntt.state, start);
        if (watchdog > 300000) begin
            $display("WATCHDOG TIMEOUT");
            $finish;
        end
    end

        initial begin
        for (i = 0; i < 256; i = i + 1)
            data_in[i] = (i == 0) ? 1 : 0;
    end

    // Phase 5: forward NTT of actual s1[0] (caddq form) to isolate core vs keygen
`ifdef USE_S1_DATA
    task set_s1_data();
        begin
`include "s1_data.vh"
        end
    endtask
`endif

        task load_poly(input integer mode);
        begin
            @(posedge clk); ext_we <= 1'b1; intt_mode <= mode[0];
            for (i = 0; i < 256; i = i + 1) begin
                ext_addr <= i;
                ext_din  <= data_in[i];
                @(posedge clk);
            end
            ext_we <= 1'b0;
            @(posedge clk);
        end
    endtask

    task read_poly();
        begin
            @(posedge clk);
            for (i = 0; i < 256; i = i + 1) begin
                ext_addr <= i;
                @(posedge clk);                   @(posedge clk);                   data_out[i] <= ext_dout;
            end
            @(posedge clk);
        end
    endtask

    task dump_poly(input [255:0] name);
        begin
            $write("POLY %s:", name);
            for (i = 0; i < 256; i = i + 1)
                $write("%s%x", i==0 ? " " : ",", data_out[i]);
            $write("\n");
        end
    endtask

    initial begin
        $dumpfile("tb_ntt_check.vcd");
        $dumpvars(0, tb_ntt_check);

        rst_n = 0;
        start = 0; intt_mode = 0; ext_we = 0; ext_addr = 0; ext_din = 0;
        #20; rst_n = 1; #10;

        // ---- 1) Forward NTT of x ----
        $display("PHASE0 START");
        load_poly(0);
        read_poly();
        dump_poly("LOADED");

        $display("PHASE1 START");
        load_poly(0);
        $display("PHASE1 LOADED");
        dbg = 1;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        while (!done) @(posedge clk);
        dbg = 0;
        $display("PHASE1 DONE");
        @(posedge clk);
        read_poly();
        dump_poly("NTT");

        // ---- 2) Inverse NTT of the NTT output ----
        $display("PHASE2 START");
        for (i = 0; i < 256; i = i + 1) data_in[i] = data_out[i];
        load_poly(1);
        $display("PHASE2 LOADED");
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        while (!done) @(posedge clk);
        $display("PHASE2 DONE");
        @(posedge clk);
        read_poly();
        dump_poly("INTT");

        // ---- 3) Inverse NTT of x directly (isolate INTT) ----
        $display("PHASE3 START");
        for (i = 0; i < 256; i = i + 1) data_in[i] = (i * 7 + 1) % `MLDSA_Q;
        load_poly(1);
        $display("PHASE3 LOADED");
        dbg = 1;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        while (!done) @(posedge clk);
        dbg = 0;
        $display("PHASE3 DONE");
        @(posedge clk);
        read_poly();
        dump_poly("INTTX");

        // ---- 4) Forward NTT of general polynomial (isolate forward NTT) ----
        $display("PHASE4 START");
        for (i = 0; i < 256; i = i + 1) data_in[i] = (i * 7 + 1) % `MLDSA_Q;
        load_poly(0);
        $display("PHASE4 LOADED");
        dbg = 1;
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        while (!done) @(posedge clk);
        dbg = 0;
        $display("PHASE4 DONE");
        @(posedge clk);
        read_poly();
        dump_poly("FWDNTT");

`ifdef USE_S1_DATA
        // ---- 5) Forward NTT of actual s1[0] data ----
        $display("PHASE5 START");
        set_s1_data();
        load_poly(0);
        $display("PHASE5 LOADED");
        @(negedge clk); start = 1; @(negedge clk); start = 0;
        while (!done) @(posedge clk);
        $display("PHASE5 DONE");
        @(posedge clk);
        read_poly();
        dump_poly("S1NTT");
`endif

        $display("ALL DONE");
        $finish;
    end
endmodule
