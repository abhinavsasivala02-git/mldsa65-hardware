`timescale 1ns/1ps

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

module tb_mldsa_top;

                parameter CLK_PERIOD = 10;       parameter TIMEOUT_NS = 50_000_000;
                reg          ACLK;
    reg          ARESETn;

        reg          AWVALID;
    wire         AWREADY;
    reg  [15:0]  AWADDR;
    reg  [2:0]   AWPROT;

        reg          WVALID;
    wire         WREADY;
    reg  [31:0]  WDATA;
    reg  [3:0]   WSTRB;

        wire         BVALID;
    reg          BREADY;
    wire [1:0]   BRESP;

        reg          ARVALID;
    wire         ARREADY;
    reg  [15:0]  ARADDR;
    reg  [2:0]   ARPROT;

        wire         RVALID;
    reg          RREADY;
    wire [31:0]  RDATA;
    wire [1:0]   RRESP;

                initial ACLK = 1'b0;
    always #(CLK_PERIOD/2) ACLK = ~ACLK;

                mldsa_top dut (
        .ACLK    (ACLK),
        .ARESETn (ARESETn),
        .AWVALID (AWVALID),
        .AWREADY (AWREADY),
        .AWADDR  (AWADDR),
        .AWPROT  (AWPROT),
        .WVALID  (WVALID),
        .WREADY  (WREADY),
        .WDATA   (WDATA),
        .WSTRB   (WSTRB),
        .BVALID  (BVALID),
        .BREADY  (BREADY),
        .BRESP   (BRESP),
        .ARVALID (ARVALID),
        .ARREADY (ARREADY),
        .ARADDR  (ARADDR),
        .ARPROT  (ARPROT),
        .RVALID  (RVALID),
        .RREADY  (RREADY),
        .RDATA   (RDATA),
        .RRESP   (RRESP)
    );

                integer tests_passed;
    integer tests_failed;
    integer tests_total;

                task axi_write;
        input [15:0] addr;
        input [31:0] data;
        begin
            @(posedge ACLK);
            AWVALID <= 1'b1;  AWADDR <= addr;  AWPROT <= 3'b000;
            WVALID  <= 1'b1;  WDATA  <= data;  WSTRB  <= 4'hF;
            BREADY  <= 1'b1;

            @(posedge ACLK);
            while (!(AWREADY && WREADY)) @(posedge ACLK);
            AWVALID <= 1'b0;
            WVALID  <= 1'b0;

            while (!BVALID) @(posedge ACLK);
            @(posedge ACLK);
            BREADY <= 1'b0;
        end
    endtask

                reg [31:0] rd_data;

    task axi_read;
        input  [15:0] addr;
        output [31:0] data;
        begin
            @(posedge ACLK);
            ARVALID <= 1'b1;  ARADDR <= addr;  ARPROT <= 3'b000;
            RREADY  <= 1'b1;

            @(posedge ACLK);
            while (!ARREADY) @(posedge ACLK);
            ARVALID <= 1'b0;

            while (!RVALID) @(posedge ACLK);
            data = RDATA;
            @(posedge ACLK);
            RREADY <= 1'b0;
        end
    endtask

            // Returns: status[0]=busy, status[1]=done_sticky, status[2]=sig_valid
        task wait_done;
        output [31:0] final_status;
        reg [31:0] status;
        integer timeout;
        begin
            timeout = 0;
            status  = 32'd0;
            while (!(status[1]) && timeout < 500000) begin
                axi_read(16'h0004, status);
                timeout = timeout + 1;
            end
            final_status = status;
            if (timeout >= 500000)
                $display("[TB] ERROR: Timeout waiting for done after %0d polls!", timeout);
            else
                $display("[TB] Done after %0d polls, status=0x%08h (busy=%b, done=%b, valid=%b)",
                         timeout, status, status[0], status[1], status[2]);
        end
    endtask

                task check_result;
        input [255:0] test_name;
        input         condition;
        begin
            tests_total = tests_total + 1;
            if (condition) begin
                tests_passed = tests_passed + 1;
                $display("[PASS] %0s", test_name);
            end else begin
                tests_failed = tests_failed + 1;
                $display("[FAIL] %0s", test_name);
            end
        end
    endtask

                task load_test_vectors;
        integer i;
        begin
            // seed_xi (32 bytes = 8 words at 0x10)
            $display("[TB] Loading seed_xi ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h0010 + i*4, 32'hDEAD_0000 + i);

            // sk_rho (8 words at 0x30)
            $display("[TB] Loading sk_rho ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h0030 + i*4, 32'hAABB_0000 + i);

            // sk_K (8 words at 0x50)
            $display("[TB] Loading sk_K ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h0050 + i*4, 32'hCCDD_0000 + i);

            // sk_tr (8 words at 0x70)
            $display("[TB] Loading sk_tr ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h0070 + i*4, 32'hEEFF_0000 + i);

            // rnd (8 words at 0x90)
            $display("[TB] Loading rnd ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h0090 + i*4, 32'h1234_0000 + i);

            // c_tilde_orig (8 words at 0xB0)
            $display("[TB] Loading c_tilde ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h00B0 + i*4, 32'h5678_0000 + i);

            // mu (16 words at 0xD0-0xFC)
            $display("[TB] Loading mu ...");
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h00D0 + i*4, 32'hFACE_0000 + i);
            for (i = 0; i < 8; i = i + 1)
                axi_write(16'h00F0 + i*4, 32'hBEEF_0000 + i);

                        $display("[TB] Loading poly_z_ram ...");
            for (i = 0; i < 16; i = i + 1)
                axi_write(16'h2000 + i*4, i * 100);

                        $display("[TB] Loading poly_r0_ram ...");
            for (i = 0; i < 16; i = i + 1)
                axi_write(16'h2400 + i*4, i * 50);
        end
    endtask

                reg [31:0] status;

    initial begin
                tests_passed = 0;
        tests_failed = 0;
        tests_total  = 0;

        AWVALID = 1'b0; AWADDR = 16'd0; AWPROT = 3'd0;
        WVALID  = 1'b0; WDATA  = 32'd0; WSTRB  = 4'h0;
        BREADY  = 1'b0;
        ARVALID = 1'b0; ARADDR = 16'd0; ARPROT = 3'd0;
        RREADY  = 1'b0;

                ARESETn = 1'b0;
        repeat (10) @(posedge ACLK);
        ARESETn = 1'b1;
        repeat (5) @(posedge ACLK);
        $display("");
        $display("================================================================");
        $display("  ML-DSA-65 Testbench - Reset Released at %0t", $time);
        $display("================================================================");

                load_test_vectors;

                axi_read(16'h0004, status);
        $display("[TB] Initial STATUS = 0x%08h", status);

                                $display("");
        $display("=== TEST 1: KeyGen ===");
        axi_write(16'h0000, 32'h0000_0001);          repeat(5) @(posedge ACLK);

        axi_read(16'h0004, status);
        $display("[TB] STATUS after keygen start = 0x%08h", status);
        check_result("KeyGen busy after start", status[0] == 1'b1);

        wait_done(status);
        check_result("KeyGen completed (done=1)", status[1] == 1'b1);

                                $display("");
        $display("=== TEST 2: Verify ===");
        axi_write(16'h0000, 32'h0000_0004);          repeat(5) @(posedge ACLK);

        axi_read(16'h0004, status);
        $display("[TB] STATUS after verify start = 0x%08h", status);
        check_result("Verify busy after start", status[0] == 1'b1);

        wait_done(status);
        check_result("Verify completed (done=1)", status[1] == 1'b1);
        check_result("Verify valid (sig_valid=1)", status[2] == 1'b1);

        axi_read(16'h0004, status);
        $display("[TB] Final Verify STATUS = 0x%08h (sig_valid=%b)", status, status[2]);

                                $display("");
        $display("=== TEST 3: Sign ===");
        axi_write(16'h0000, 32'h0000_0002);          repeat(5) @(posedge ACLK);

        axi_read(16'h0004, status);
        $display("[TB] STATUS after sign start = 0x%08h", status);
        check_result("Sign busy after start", status[0] == 1'b1);

        wait_done(status);
        check_result("Sign completed (done=1)", status[1] == 1'b1);
        check_result("Sign valid (valid=1)", status[2] == 1'b1);

                                $display("");
        $display("================================================================");
        $display("  ML-DSA-65 Testbench Results");
        $display("  Tests Passed: %0d / %0d", tests_passed, tests_total);
        $display("  Tests Failed: %0d", tests_failed);
        if (tests_failed == 0)
            $display("  *** ALL TESTS PASSED ***");
        else
            $display("  *** SOME TESTS FAILED ***");
        $display("  Simulation time: %0t", $time);
        $display("================================================================");
        $finish;
    end

                initial begin
        #(TIMEOUT_NS);
        $display("");
        $display("================================================================");
        $display("  TIMEOUT: Simulation exceeded %0d ns limit", TIMEOUT_NS);
        $display("================================================================");
        $finish;
    end

                `ifdef DUMP_VCD
    initial begin
        $dumpfile("mldsa_top.vcd");
        $dumpvars(0, tb_mldsa_top);
    end
    `endif

                reg [31:0] dbg_cycle;
    initial dbg_cycle = 0;
    always @(posedge ACLK) begin
        if (ARESETn) begin
            dbg_cycle <= dbg_cycle + 1;
            if (dut.u_keygen.busy &&
                (dbg_cycle < 1000 || dbg_cycle % 5000 == 0))
                $display("[DBG] cyc=%0d st=%0d sub=%0d ccnt=%0d lane=%0d byt=%0d pi=%0d shk_rdy=%b ntt_busy=%b",
                         dbg_cycle,
                         dut.u_keygen.state,
                         dut.u_keygen.sub,
                         dut.u_keygen.coeff_cnt,
                         dut.u_keygen.lane_cnt,
                         dut.u_keygen.byte_in_lane,
                         dut.u_keygen.poly_idx,
                         dut.u_shake.a_rdy,
                         dut.u_ntt.busy);
        end
    end

endmodule
