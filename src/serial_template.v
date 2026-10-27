module serial_template (
    input sys_clk,          // 27 MHz System clock input
    input sys_rst_n,        // Active-low asynchronous reset input
    output [5:0] bled,      // 6 onboard LEDs 
    input [3:0] sw,         // 4 onboard switches defaulty
    input [3:0] btn,        // 4 onboard push buttons (btn[0] starts countdown)
    output [7:0] led,       // 8 LEDs acting as data monitors for UART RX bytes
    output reg [7:0] seven, // 7-segment display segment data outputs (a-b-c-d-e-f-g)
    output reg [3:0] segment, // 7-segment display digit select lines 
    input uart_rx           // UART serial data receive pin
);

//Configuration Parameters 
parameter CLK_FRE  = 27;     // System clock frequency in MHz (27 MHz)
parameter UART_FRE = 115200; // UART communication baud rate given in the intructions

// --- Internal Registers and Counters ---
reg [6:0]  hex2seven[15:0];  // to decode 4-bit Hex numbers to 7-segment patterns
reg [15:0] dispCounter;      // clock divider to make understand human eye 
reg [1:0]  segCounter;       // 2-bit counter pointing to the active 7-segment digit (0 to 3)
reg [24:0] divCounter;       // Clock divider counter used to generate a 1-second pulse

//Interface Connections
wire [3:0] DISP3;            // BCD value for Minutes Tens digit
wire [3:0] DISP2;            // BCD value for Minutes Ones digit
wire [3:0] DISP1;            // BCD value for Seconds Tens digit
wire [3:0] DISP0;            // BCD value for Seconds Ones digit
wire rx_data_valid;          // Flag from UART receiver indicating the data valid
wire rx_data_ready;          // Downstream ready signal telling UART rx it's OK to receive data 

assign rx_data_ready = 1'b1; // Permanently ready to process incoming UART data

//Countdown Timer BCD Registers
reg [3:0] timer_mm_tens;     // Minutes Tens register (0-9)
reg [3:0] timer_mm_ones;     // Minutes Ones register (0-9)
reg [3:0] timer_ss_tens;     // Seconds Tens register (0-5, validated to 5 max ın the below codes)
reg [3:0] timer_ss_ones;     // Seconds Ones register (0-9)

reg timer_running;           // flag for counting workıng

wire [7:0] rx_data_internal; // Wire from UART

//Driving Outputs
assign DISP3 = timer_mm_tens; 
assign DISP2 = timer_mm_ones; 
assign DISP1 = timer_ss_tens; 
assign DISP0 = timer_ss_ones; 

assign bled = 6'b111111;       // Turns off board LEDs 
assign led = rx_data_internal; // Mirrors the raw incoming UART data onto the 8 external LEDs

//UART Receiver Module Instantiation
uart_rx#
(
	.CLK_FRE(CLK_FRE),
	.BAUD_RATE(UART_FRE)
) uart_rx_inst
(
	.clk                        (sys_clk                  ),
	.rst_n                      (sys_rst_n                ),
	.rx_data                    (rx_data_internal         ), 
	.rx_data_valid              (rx_data_valid            ),
	.rx_data_ready              (rx_data_ready            ),
	.rx_pin                     (uart_rx                  )
);

initial begin
	// Populating hex-to-seven-segment display decoder values (active-high segments: abcdefg)
	hex2seven[0]  = 7'b00111111;
	hex2seven[1]  = 7'b00000110;
	hex2seven[2]  = 7'b01011011;
	hex2seven[3]  = 7'b01001111;
	hex2seven[4]  = 7'b01100110;
	hex2seven[5]  = 7'b01101101;
	hex2seven[6]  = 7'b01111101;
	hex2seven[7]  = 7'b00000111;
	hex2seven[8]  = 7'b01111111;
	hex2seven[9]  = 7'b01101111;
	hex2seven[10] = 7'b01110111;
	hex2seven[11] = 7'b01111100;
	hex2seven[12] = 7'b00111001;
	hex2seven[13] = 7'b01011110;
	hex2seven[14] = 7'b01111001;
	hex2seven[15] = 7'b01110001;
	segment = 4'b0001;          // Start display refresh on the rightmost digit (inital diplay configurain in fpga)
end

// for activation the next display evert 2.4 ms
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        dispCounter <= 16'd0;
        segCounter <= 2'd0;
    end
    else begin
        dispCounter <= dispCounter + 16'd1;
        if (dispCounter == 16'd0) begin
            segCounter <= segCounter + 2'd1;  //  the range 2.4 milisecond for human eye
        end
    end
end

// 7-Segment FOrmat
// display counter to specific digits, decoding BCD values and formatting the decimal point separator
always @(*) begin
	case (segCounter)
	2'b00 : begin seven <= {1'b0, hex2seven[DISP0]}; segment <= 4'b0001; end // Display Seconds Ones (No decimal point)
	2'b01 : begin seven <= {1'b0, hex2seven[DISP1]}; segment <= 4'b0010; end // Display Seconds Tens (No decimal point)
	2'b10 : begin seven <= {1'b1, hex2seven[DISP2]}; segment <= 4'b0100; end // Display Minutes Ones (Injects decimal point for MM.SS)
	2'b11 : begin seven <= {1'b0, hex2seven[DISP3]}; segment <= 4'b1000; end // Display Minutes Tens (No decimal point)
	endcase
end

reg one_second_tick;

//Timebase Generation 
// for considering the 27mghth clock tick as if just active clock tick
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        divCounter <= 25'd0;
        one_second_tick <= 1'b0;
    end
    else begin
        if (divCounter == 25'd26_999_999) begin
            divCounter <= 25'd0;         
            one_second_tick <= 1'b1;     //  Triggers active high pulse in the exactly 27mghz
        end
        else begin
            divCounter <= divCounter + 1'b1; 
            one_second_tick <= 1'b0;      // Clears the pulse immediately for  next cycle
        end
    end
end

// Time Configuration & Countdown Controller 
always @(posedge sys_clk or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        timer_mm_tens <= 4'd0;
        timer_mm_ones <= 4'd0;
        timer_ss_tens <= 4'd0;
        timer_ss_ones <= 4'd0;
        timer_running <= 1'b0;
    end
    else begin
        // START COUNTDOWN CONTROL
        // When the button is pressed, it starts the countdown only if the timer is not 00:00.
        if (btn[0] == 1'b0) begin
            if (!(timer_mm_tens == 4'd0 && timer_mm_ones == 4'd0 && 
                  timer_ss_tens == 4'd0 && timer_ss_ones == 4'd0)) begin
                
                timer_running <= 1'b1;
                
                //  The adjustment block for fit  the given range in the instruction and clock ranges (e.g., if user input numbers like xx:67, force it to xx:59)
                if (timer_ss_tens > 4'd5) begin
                    timer_ss_tens <= 4'd5;
                    timer_ss_ones <= 4'd9;
                end
            end
        end
        
        //  to stop the count down and  stop the execution when counter reaches exactly  (00:00)
        if (timer_mm_tens == 4'd0 && timer_mm_ones == 4'd0 && 
            timer_ss_tens == 4'd0 && timer_ss_ones == 4'd0) begin
            timer_running <= 1'b0;
        end

        // Active Countdown Mode
        //  executable when one_second_tick 
// STEP 1: Seconds Ones Digit Control // If seconds ones is greater than 0 (e.g., 12:45), simply decrement it by 1 (becomes 12:44).
        if (timer_running) begin
            if (one_second_tick) begin
                if (timer_ss_ones > 4'd0) begin
                    timer_ss_ones <= timer_ss_ones - 4'd1;
                end 
                else begin
// STEP 2: Borrow from Seconds Tens Digit 
// If seconds ones is 0 but seconds tens is greater than 0 (e.g., 12:40), 
// decrement seconds tens by 1 and reset seconds ones to 9 (becomes 12:39).
                    if (timer_ss_tens > 4'd0) begin
                        timer_ss_ones <= 4'd9;
                        timer_ss_tens <= timer_ss_tens - 4'd1;
                    end 
// STEP 3: Borrow from Minutes Ones Digit 
// If total seconds reach 00 but minutes ones is greater than 0 (e.g., 12:00), 
// decrement minutes ones by 1 and reset seconds to 59 (becomes 11:59).
                    else begin
                        if (timer_mm_ones > 4'd0) begin
                            timer_ss_ones <= 4'd9;
                            timer_ss_tens <= 4'd5; 
                            timer_mm_ones <= timer_mm_ones - 4'd1;
                        end 
// STEP 4: Borrow from Minutes Tens Digit
 // If both seconds and minutes ones are 0 but minutes tens is greater than 0 (e.g., 10:00), 
// decrement minutes tens by 1 and reset the rest to 9:59 (becomes 09:59).
                        else begin
                            if (timer_mm_tens > 4'd0) begin
                                timer_ss_ones <= 4'd9;
                                timer_ss_tens <= 4'd5;
                                timer_mm_ones <= 4'd9;
                                timer_mm_tens <= timer_mm_tens - 4'd1;
                            end
                        end
                    end
                end
            end
        end 
        // Shift-In Configuration
        // When timer is idle, valid incoming UART ASCII digits (0-9) shift right-to-left across digits 
        else begin
            if (rx_data_valid && (rx_data_internal >= 8'h30 && rx_data_internal <= 8'h39)) begin
                timer_mm_tens <= timer_mm_ones; 
                timer_mm_ones <= timer_ss_tens; 
                timer_ss_tens <= timer_ss_ones;
                timer_ss_ones <= rx_data_internal - 8'h30; // Convert ASCII character (e.g., 8'h35) to 4-bit integer (5)
            end
        end
    end
end

endmodule