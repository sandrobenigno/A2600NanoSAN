`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name:    db9_to_spi_san
// By Sandro Benigno (EvilPlaymobil)
// Description: 
//   SPI Master controller for DB9-to-SPI gamepad adapter on Tang Nano 20k.
//   Operates at ~1.03 MHz SPI clock from the 28.8 MHz core clock (MSB-first, Mode 3).
//   
//   Optimized Dual-Mode Polling:
//   - Fast Scanline Poll (Command 0x01, 5 Bytes) triggered on HSYNC rising edge.
//     Reads Joysticks Fire buttons, Joystick 1 directions, and all 4 paddles.
//   - Full VBlank Poll (Command 0x02, 6 Bytes) triggered on VSYNC rising edge.
//     Reads full controller state including Joystick 2 directions.
//
//   Physical Pins (Tang Nano 20k Gamepad 1):
//   - Pino 52: ds_clk  (SPI SCLK)
//   - Pino 53: ds_mosi (SPI MOSI)
//   - Pino 71: ds_miso (SPI MISO)
//   - Pino 72: ds_cs   (SPI SS/CS)
//
//   SPI Payload Mapping (Active-Low from Slave):
//   - Byte 0: [7:6] Res, [5] Joy2 Fire, [4] Joy1 Fire, [3] J1 Right, [2] J1 Left, [1] J1 Down, [0] J1 Up
//   - Byte 1 (Command 0x02 only): [7:4] Res, [3] J2 Right, [2] J2 Left, [1] J2 Down, [0] J2 Up
//   - Paddle Bytes: 8-bit analog values
//
//////////////////////////////////////////////////////////////////////////////////

module db9_to_spi_san (
    input clk,             // 28.8 MHz core system clock (divided from PLL 144 MHz)
    input rst,             // active high reset
    input vsync,           // vertical sync (active high)
    input hsync,           // horizontal sync (active high)
    
    // SPI Physical Pins
    output reg ds_clk,     // Pin 52
    output reg ds_mosi,    // Pin 53
    input ds_miso,         // Pin 71
    output reg ds_cs,      // Pin 72
    
    // Decoded Outputs (Active-High for VHDL Core)
    output reg joy1_up,
    output reg joy1_down,
    output reg joy1_left,
    output reg joy1_right,
    output reg joy1_fire,
    
    output reg joy2_up,
    output reg joy2_down,
    output reg joy2_left,
    output reg joy2_right,
    output reg joy2_fire,
    
    output reg [7:0] paddle1,
    output reg [7:0] paddle2,
    output reg [7:0] paddle3,
    output reg [7:0] paddle4
);

    // States
    localparam S_IDLE       = 3'd0;
    localparam S_CS_LOW     = 3'd1;
    localparam S_CLK_LOW    = 3'd2;
    localparam S_CLK_HIGH   = 3'd3;
    localparam S_BYTE_DONE  = 3'd4;
    localparam S_CS_HIGH    = 3'd5;

    // Registers
    reg [2:0] state;
    reg [4:0] clk_cnt;      // Clock divider counter for SPI tick generation
    reg spi_tick;           // SPI tick (2.057 MHz for ~1.03 MHz clock)

    reg [2:0] bit_cnt;      // 0 to 7
    reg [2:0] byte_cnt;     // 0 to 5
    reg [2:0] max_bytes;    // 5 (Comando 0x01) or 6 (Comando 0x02)
    reg [7:0] tx_byte;      // Command byte to send
    reg [7:0] rx_byte;      // Data byte received
    reg [7:0] rx_buffer [0:5];

    // Trigger flags
    reg last_vsync;
    reg last_hsync;
    reg vsync_trig;
    reg hsync_trig;
    reg in_vsync;

    // Clock Divider: Generates spi_tick every 14 cycles of the 28.8 MHz clock.
    // 28.8 MHz / 14 = 2.057 MHz tick rate.
    // Since each SPI clock cycle (ds_clk) requires 2 ticks (Low/High), 
    // the resulting SPI clock frequency is: 2.057 MHz / 2 = ~1.028 MHz.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_cnt  <= 5'd0;
            spi_tick <= 1'b0;
        end else begin
            if (clk_cnt >= 5'd13) begin
                clk_cnt  <= 5'd0;
                spi_tick <= 1'b1;
            end else begin
                clk_cnt  <= clk_cnt + 5'd1;
                spi_tick <= 1'b0;
            end
        end
    end

    // Edge Detectors for VSYNC and HSYNC
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            last_vsync <= 1'b0;
            last_hsync <= 1'b0;
            vsync_trig <= 1'b0;
            hsync_trig <= 1'b0;
            in_vsync   <= 1'b0;
        end else begin
            last_vsync <= vsync;
            last_hsync <= hsync;

            // VSYNC edge detector (active high)
            if (vsync && !last_vsync) begin
                vsync_trig <= 1'b1;
                in_vsync   <= 1'b1;
            end else if (!vsync && last_vsync) begin
                in_vsync   <= 1'b0;
            end

            // HSYNC edge detector (active high)
            if (hsync && !last_hsync) begin
                hsync_trig <= 1'b1;
            end

            // Clear trigger signals when FSM starts processing them
            if (state == S_CS_LOW) begin
                if (max_bytes == 3'd6)
                    vsync_trig <= 1'b0;
                else
                    hsync_trig <= 1'b0;
            end
        end
    end

    // SPI Master State Machine (LSB/MSB: MSB-first, SCLK Idle High: Mode 3)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            ds_clk     <= 1'b1; // Idle High
            ds_mosi    <= 1'b0;
            ds_cs      <= 1'b1; // Idle High
            bit_cnt    <= 3'd0;
            byte_cnt   <= 3'd0;
            max_bytes  <= 3'd5;
            tx_byte    <= 8'h00;
            rx_byte    <= 8'h00;
            
            // Outputs reset (default inactive)
            joy1_up    <= 1'b0;
            joy1_down  <= 1'b0;
            joy1_left  <= 1'b0;
            joy1_right <= 1'b0;
            joy1_fire  <= 1'b0;
            joy2_up    <= 1'b0;
            joy2_down  <= 1'b0;
            joy2_left  <= 1'b0;
            joy2_right <= 1'b0;
            joy2_fire  <= 1'b0;
            paddle1    <= 8'h00;
            paddle2    <= 8'h00;
            paddle3    <= 8'h00;
            paddle4    <= 8'h00;
        end else if (spi_tick) begin
            case (state)
                S_IDLE: begin
                    ds_clk  <= 1'b1;
                    ds_mosi <= 1'b0;
                    ds_cs   <= 1'b1;
                    bit_cnt <= 3'd0;
                    byte_cnt <= 3'd0;
                    
                    if (vsync_trig) begin
                        // Start Full VBlank Poll (Comando 0x02 - 6 Bytes)
                        max_bytes <= 3'd6;
                        tx_byte   <= 8'h02;
                        state     <= S_CS_LOW;
                    end else if (hsync_trig && !in_vsync) begin
                        // Start Fast Scanline Poll (Comando 0x01 - 5 Bytes)
                        max_bytes <= 3'd5;
                        tx_byte   <= 8'h01;
                        state     <= S_CS_LOW;
                    end
                end

                S_CS_LOW: begin
                    ds_cs <= 1'b0; // Activate CS
                    state <= S_CLK_LOW;
                end

                S_CLK_LOW: begin
                    ds_clk  <= 1'b0; // SCLK Falling Edge (Shift out MOSI)
                    // MSB-first transmission
                    ds_mosi <= tx_byte[7 - bit_cnt];
                    state   <= S_CLK_HIGH;
                end

                S_CLK_HIGH: begin
                    ds_clk <= 1'b1; // SCLK Rising Edge (Sample MISO)
                    // MSB-first reception
                    rx_byte[7 - bit_cnt] <= ds_miso;
                    
                    if (bit_cnt == 3'd7) begin
                        state <= S_BYTE_DONE;
                    end else begin
                        bit_cnt <= bit_cnt + 3'd1;
                        state   <= S_CLK_LOW;
                    end
                end

                S_BYTE_DONE: begin
                    rx_buffer[byte_cnt] <= rx_byte;
                    byte_cnt            <= byte_cnt + 3'd1;
                    bit_cnt             <= 3'd0;
                    
                    // Subsequent bytes send dummy 0x00 on MOSI
                    tx_byte <= 8'h00; 

                    if (byte_cnt + 3'd1 == max_bytes) begin
                        state <= S_CS_HIGH;
                    end else begin
                        state <= S_CLK_LOW;
                    end
                end

                S_CS_HIGH: begin
                    ds_cs   <= 1'b1; // Deactivate CS
                    ds_mosi <= 1'b0;
                    
                    // Parse and latch received data to stable outputs (Inputs are Active-Low, invert to Active-High)
                    // Byte 0 contains fires for both joysticks and directions for Joystick 1
                    joy1_up    <= ~rx_buffer[0][0];
                    joy1_down  <= ~rx_buffer[0][1];
                    joy1_left  <= ~rx_buffer[0][2];
                    joy1_right <= ~rx_buffer[0][3];
                    joy1_fire  <= ~rx_buffer[0][4];
                    joy2_fire  <= ~rx_buffer[0][5];

                    if (max_bytes == 3'd6) begin
                        // Comando 0x02 read full frame (Joystick 2 directions in Byte 1)
                        joy2_up    <= ~rx_buffer[1][0];
                        joy2_down  <= ~rx_buffer[1][1];
                        joy2_left  <= ~rx_buffer[1][2];
                        joy2_right <= ~rx_buffer[1][3];

                        // Paddles are in bytes 2..5
                        paddle1 <= rx_buffer[2];
                        paddle2 <= rx_buffer[3];
                        paddle3 <= rx_buffer[4];
                        paddle4 <= rx_buffer[5];
                    end else begin
                        // Comando 0x01 (Fast Scanline): Keep previous Joystick 2 directions stable
                        // Paddles are in bytes 1..4
                        paddle1 <= rx_buffer[1];
                        paddle2 <= rx_buffer[2];
                        paddle3 <= rx_buffer[3];
                        paddle4 <= rx_buffer[4];
                    end

                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
