`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name:    db9_to_spi_san
// By Sandro Benigno (EvilPlaymobil)
// Description: 
//   SPI Master controller for DB9-to-SPI gamepad adapter on Tang Nano 20k.
//   Operates at ~720 kHz SPI clock from the 28.8 MHz core clock (MSB-first, Mode 3).
//   
//   Aggressive Smart Polling:
//   - VBlank Poll (Command 0x02, 2 Bytes): Triggered on VSYNC rising edge.
//     Reads all joystick/fire button states (Byte 0: Joy1+Fires, Byte 1: Joy2 directions).
//   - Fast Scanline Poll (Command 0x01, 4 Bytes): Triggered on HSYNC rising edge (only if paddle_mode active).
//     Reads the 4 analog paddle positions. Excludes digital buttons to minimize transmission time (44.4 µs).
//
//   Physical Pins (Tang Nano 20k Gamepad 1):
//   - Pino 52: db9_spi_clk  (SPI SCLK)
//   - Pino 53: db9_spi_mosi (SPI MOSI)
//   - Pino 71: db9_spi_miso (SPI MISO)
//   - Pino 72: db9_spi_cs   (SPI SS/CS)
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
    input paddle_mode,     // 1 = Paddle Mode active, 0 = Joystick Mode active
    
    // SPI Physical Pins
    output reg db9_spi_clk,     // Pin 52
    output reg db9_spi_mosi,    // Pin 53
    input db9_spi_miso,         // Pin 71
    output reg db9_spi_cs,      // Pin 72
    
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
    reg [2:0] max_bytes;    // 2 (Command 0x02) or 4 (Command 0x01)
    reg [7:0] tx_byte;      // Command byte to send
    reg [7:0] rx_byte;      // Data byte received
    reg [7:0] rx_buffer [0:5];

    // Trigger flags
    reg last_vsync;
    reg last_hsync;
    reg vsync_trig;
    reg hsync_trig;
    reg in_vsync;

    // Clock Divider: Generates spi_tick every 20 cycles of the 28.8 MHz clock.
    // 28.8 MHz / 20 = 1.44 MHz tick rate.
    // Since each SPI clock cycle (db9_spi_clk) requires 2 ticks (Low/High), 
    // the resulting SPI clock frequency is: 1.44 MHz / 2 = ~720 kHz.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            clk_cnt  <= 5'd0;
            spi_tick <= 1'b0;
        end else begin
            if (clk_cnt >= 5'd19) begin
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
                if (tx_byte == 8'h02)
                    vsync_trig <= 1'b0;
                else if (tx_byte == 8'h01)
                    hsync_trig <= 1'b0;
            end
        end
    end

    // SPI Master State Machine (LSB/MSB: MSB-first, SCLK Idle High: Mode 3)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_IDLE;
            db9_spi_clk     <= 1'b1; // Idle High
            db9_spi_mosi    <= 1'b0;
            db9_spi_cs      <= 1'b1; // Idle High
            bit_cnt    <= 3'd0;
            byte_cnt   <= 3'd0;
            max_bytes  <= 3'd2;
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
                    db9_spi_clk  <= 1'b1;
                    db9_spi_mosi <= 1'b0;
                    db9_spi_cs   <= 1'b1;
                    bit_cnt <= 3'd0;
                    byte_cnt <= 3'd0;
                    
                    if (vsync_trig) begin
                        // VBlank Poll: Always 2 Bytes (Command 0x02)
                        max_bytes <= 3'd2;
                        tx_byte   <= 8'h02;
                        state     <= S_CS_LOW;
                    end else if (hsync_trig && !in_vsync && paddle_mode) begin
                        // Fast Scanline Poll: 4 Bytes of Paddles (Command 0x01), only if paddle_mode active
                        max_bytes <= 3'd4;
                        tx_byte   <= 8'h01;
                        state     <= S_CS_LOW;
                    end
                end

                S_CS_LOW: begin
                    db9_spi_cs <= 1'b0; // Activate CS
                    state <= S_CLK_LOW;
                end

                S_CLK_LOW: begin
                    db9_spi_clk  <= 1'b0; // SCLK Falling Edge (Shift out MOSI)
                    // MSB-first transmission
                    db9_spi_mosi <= tx_byte[7 - bit_cnt];
                    state   <= S_CLK_HIGH;
                end

                S_CLK_HIGH: begin
                    db9_spi_clk <= 1'b1; // SCLK Rising Edge (Sample MISO)
                    // MSB-first reception
                    rx_byte[7 - bit_cnt] <= db9_spi_miso;
                    
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
                    db9_spi_cs   <= 1'b1; // Deactivate CS
                    db9_spi_mosi <= 1'b0;
                    
                    if (max_bytes == 3'd2) begin
                        // Parse VBlank Poll: Byte 0 (Joy1 + Fires) and Byte 1 (Joy2 directions)
                        joy1_up    <= ~rx_buffer[0][0];
                        joy1_down  <= ~rx_buffer[0][1];
                        joy1_left  <= ~rx_buffer[0][2];
                        joy1_right <= ~rx_buffer[0][3];
                        joy1_fire  <= ~rx_buffer[0][4];
                        joy2_fire  <= ~rx_buffer[0][5];

                        joy2_up    <= ~rx_buffer[1][0];
                        joy2_down  <= ~rx_buffer[1][1];
                        joy2_left  <= ~rx_buffer[1][2];
                        joy2_right <= ~rx_buffer[1][3];
                    end else if (max_bytes == 3'd4) begin
                        // Parse Fast Scanline Poll: Bytes 0..3 are Paddles 1..4
                        paddle1 <= rx_buffer[0];
                        paddle2 <= rx_buffer[1];
                        paddle3 <= rx_buffer[2];
                        paddle4 <= rx_buffer[3];
                    end

                    state <= S_IDLE;
                end
                
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
