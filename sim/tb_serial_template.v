// Testbench for the serial countdown timer (serial_template.v + uart_rx.v)
//
// What it checks:
//   1. UART input: digits sent at 115200 baud are shifted into the display (MM:SS)
//   2. Countdown:  each 1-second tick decrements the time with correct borrows
//                  (e.g. 12:00 -> 11:59, 10:00 -> 09:59)
//   3. Stop:       the countdown stops at 00:00 and does not underflow
//   4. Clamping:   invalid seconds (e.g. xx:75) are clamped to xx:59 on start
//   5. Reset:      the active-low reset clears the display to 00:00
//
// Note on simulation time: the real design generates its 1-second tick from a
// 27 MHz clock (27,000,000 cycles). Simulating that cycle-by-cycle is slow, so the
// testbench injects the one_second_tick pulse directly. The clock divider itself
// is checked separately by letting it run for one full second once.
//
// Run:  iverilog -g2012 -o sim/tb.vvp sim/tb_serial_template.v src/serial_template.v src/uart_rx.v
//       vvp sim/tb.vvp

`timescale 1ns / 1ps

module tb_serial_template;

    // 27 MHz clock -> 37.037 ns period
    localparam real CLK_PERIOD = 1000.0 / 27.0;
    // One UART bit = CLK_FRE * 1e6 / BAUD clock cycles (same formula as uart_rx.v)
    localparam integer BIT_CYCLES = 27 * 1000000 / 115200;

    reg        sys_clk   = 1'b0;
    reg        sys_rst_n = 1'b0;
    reg  [3:0] sw        = 4'b1111;
    reg  [3:0] btn       = 4'b1111;   // buttons are active-low, 1 = released
    reg        uart_rx   = 1'b1;      // UART line idles high

    wire [5:0] bled;
    wire [7:0] led;
    wire [7:0] seven;
    wire [3:0] segment;

    integer errors = 0;

    serial_template dut (
        .sys_clk   (sys_clk),
        .sys_rst_n (sys_rst_n),
        .bled      (bled),
        .sw        (sw),
        .btn       (btn),
        .led       (led),
        .seven     (seven),
        .segment   (segment),
        .uart_rx   (uart_rx)
    );

    always #(CLK_PERIOD / 2.0) sys_clk = ~sys_clk;

    // ---------------------------------------------------------------- helpers

    // Send one byte over UART: start bit, 8 data bits (LSB first), stop bit
    task uart_send(input [7:0] data);
        integer i;
        begin
            uart_rx = 1'b0;                                  // start bit
            repeat (BIT_CYCLES) @(posedge sys_clk);
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];
                repeat (BIT_CYCLES) @(posedge sys_clk);
            end
            uart_rx = 1'b1;                                  // stop bit
            repeat (2 * BIT_CYCLES) @(posedge sys_clk);
        end
    endtask

    task uart_send_string(input [8*4-1:0] str);  // exactly 4 characters, e.g. "1205"
        begin
            uart_send(str[31:24]);
            uart_send(str[23:16]);
            uart_send(str[15:8]);
            uart_send(str[7:0]);
        end
    endtask

    // Inject one 1-second tick (one clock cycle wide)
    task tick;
        begin
            @(negedge sys_clk);
            force dut.one_second_tick = 1'b1;
            @(negedge sys_clk);
            release dut.one_second_tick;
            dut.one_second_tick = 1'b0;
            repeat (540) @(posedge sys_clk);   // ~20 us gap so ticks are visible in the waveform
        end
    endtask

    // Pulse the active-low reset, then leave the UART line idle for a while
    // (a real serial line idles high long before the first character arrives)
    task do_reset;
        begin
            sys_rst_n = 1'b0;
            repeat (5) @(posedge sys_clk);
            sys_rst_n = 1'b1;
            repeat (2 * BIT_CYCLES) @(posedge sys_clk);
        end
    endtask

    task press_start;   // press and release btn[0]
        begin
            btn[0] = 1'b0;
            repeat (5) @(posedge sys_clk);
            btn[0] = 1'b1;
            repeat (5) @(posedge sys_clk);
        end
    endtask

    // Compare the displayed time with the expected MM:SS value
    task check(input [3:0] mt, input [3:0] mo, input [3:0] st, input [3:0] so,
               input [8*40-1:0] label);
        begin
            if ({dut.timer_mm_tens, dut.timer_mm_ones, dut.timer_ss_tens, dut.timer_ss_ones}
                    === {mt, mo, st, so})
                $display("  PASS  %0s -> %0d%0d:%0d%0d", label, mt, mo, st, so);
            else begin
                $display("  FAIL  %0s -> expected %0d%0d:%0d%0d, got %0d%0d:%0d%0d", label,
                         mt, mo, st, so,
                         dut.timer_mm_tens, dut.timer_mm_ones,
                         dut.timer_ss_tens, dut.timer_ss_ones);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------- stimulus
    integer k;
    integer cycles, first_tick;
    integer clk_count = 0;
    always @(posedge sys_clk) clk_count <= clk_count + 1;   // free-running cycle counter

    initial begin
        $dumpfile("sim/tb_serial_template.vcd");
        $dumpvars(0, tb_serial_template);

        // Reset
        repeat (10) @(posedge sys_clk);
        sys_rst_n = 1'b1;
        repeat (10) @(posedge sys_clk);
        $display("\n[1] Reset");
        check(0, 0, 0, 0, "after reset");

        // UART input
        $display("\n[2] UART input");
        uart_send_string("1205");
        check(1, 2, 0, 5, "received \"1205\"");
        if (led === 8'h35) $display("  PASS  LEDs mirror last byte ('5' = 0x35)");
        else begin $display("  FAIL  LEDs show 0x%h, expected 0x35", led); errors = errors + 1; end
        uart_send("x");   // non-digit characters must be ignored
        check(1, 2, 0, 5, "non-digit 'x' ignored");

        // Countdown with borrows
        $display("\n[3] Countdown");
        press_start;
        for (k = 0; k < 5; k = k + 1) tick;
        check(1, 2, 0, 0, "5 ticks");
        tick;
        check(1, 1, 5, 9, "borrow 12:00 -> 11:59");
        do_reset;
        uart_send_string("1000");
        press_start;
        tick;
        check(0, 9, 5, 9, "borrow 10:00 -> 09:59");

        // Stop at zero
        $display("\n[4] Stop at 00:00");
        do_reset;
        uart_send_string("0002");
        press_start;
        tick; tick;
        check(0, 0, 0, 0, "reached zero");
        tick; tick;
        check(0, 0, 0, 0, "no underflow after extra ticks");
        if (dut.timer_running == 1'b0) $display("  PASS  timer stopped");
        else begin $display("  FAIL  timer still running at 00:00"); errors = errors + 1; end

        // Clamping of invalid seconds
        $display("\n[5] Invalid seconds");
        uart_send_string("0175");
        check(0, 1, 7, 5, "received \"0175\"");
        press_start;
        check(0, 1, 5, 9, "clamped to 01:59 on start");

        // Reset during countdown
        $display("\n[6] Reset while running");
        tick;
        do_reset;
        check(0, 0, 0, 0, "reset clears display");

        // Real clock divider: one tick every 27,000,000 cycles
        $display("\n[7] Clock divider (1 s at 27 MHz)");
        $dumpoff;   // do not dump 27M cycles into the waveform file
        @(posedge dut.one_second_tick); first_tick = clk_count;
        @(posedge dut.one_second_tick); cycles = clk_count - first_tick;
        if (cycles == 27_000_000)
            $display("  PASS  one tick every %0d cycles = 1.000 s at 27 MHz", cycles);
        else begin
            $display("  FAIL  one tick every %0d cycles, expected 27000000", cycles);
            errors = errors + 1;
        end

        $display("\n%0s: %0d error(s)\n", errors == 0 ? "ALL TESTS PASSED" : "TESTS FAILED", errors);
        $finish;
    end

endmodule
