`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name:    spi_loader_san
// By Sandro Benigno (EvilPlaymobil)
// Description:
//   Dedicated SPI ROM loader for custom Companion MCU integration.
//
//   This module replaces the standard SD card loading mechanism used by the
//   A2600 Nano core, where the companion MCU and FPGA share access to the SD
//   card SPI bus.
//
//   In this custom architecture:
//   - The SD card is connected directly to the companion MCU.
//   - The MCU reads the ROM file externally.
//   - ROM data is streamed directly into FPGA RAM via SPI.
//   - This removes the need for SD controller modules inside the FPGA,
//     saving logic resources.
//
//   Additional capability:
//   - Allows the companion MCU to interface with physical cartridge
//     dumpers/readers.
//   - Cartridge ROMs can be dumped externally and streamed into FPGA RAM,
//     enabling real hardware cartridge loading.
//
//   Protocol Overview:
//   CMD 4 - IMAGE INSERTED
//     Receives ROM metadata including total image size.
//
//   CMD 8 - ROM STREAM
//     Streams ROM data sequentially into FPGA memory space.
//
//   This module acts as an IOCTL bridge between the SPI input stream and the
//   internal ROM loading interface.
//
//////////////////////////////////////////////////////////////////////////////////

module spi_loader_san (
    input             clk,
    input             rstn,

    // SPI Slave Interface (connected to companion MCU SPI master)
    input             data_strobe,
    input             data_start,
    input [7:0]       data_in,
    output reg [7:0]  data_out,

    input             spi_ss,       // FPGA chip select (active low)

    // ROM image information
    output reg [31:0] image_size,
    output reg        image_mounted,

    // IOCTL interface for direct RAM writes
    output reg        ioctl_download,
    output reg [22:0] ioctl_addr,
    output reg [7:0]  ioctl_data,
    output reg        ioctl_wr
);

reg [7:0] command;
reg [3:0] byte_cnt;

always @(posedge clk) begin
    // Clear write pulse by default every clock cycle
    ioctl_wr <= 1'b0;

    // Increment write address on the cycle after a write pulse
    if (ioctl_wr) begin
        ioctl_addr <= ioctl_addr + 1'd1;
    end

    // Reset transfer state when SPI chip select is inactive or global reset is asserted
    if (!rstn || spi_ss) begin
        ioctl_download <= 1'b0;
        command <= 8'hFF;
        byte_cnt <= 4'd15;

    end else if (data_strobe) begin
        if (data_start) begin
            // First byte of a packet is always the command
            command <= data_in;
            byte_cnt <= 4'd0;
            data_out <= 8'h00; // Default generic response

            // CMD 8: Start ROM download and reset write pointer
            if (data_in == 8'd8) begin
                ioctl_download <= 1'b1;
                ioctl_addr <= 23'd0;
            end

        end else begin
            // CMD 4: IMAGE INSERTED (receives 4-byte image size)
            if (command == 8'd4) begin
                if (byte_cnt == 4'd0) begin
                    // Byte 0: Drive ID (typically 0), ignored here
                end
                if (byte_cnt == 4'd1) image_size[31:24] <= data_in;
                if (byte_cnt == 4'd2) image_size[23:16] <= data_in;
                if (byte_cnt == 4'd3) image_size[15:8]  <= data_in;
                if (byte_cnt == 4'd4) begin
                    image_size[7:0] <= data_in;
                    image_mounted <= 1'b1; // Pulse indicates ROM image is mounted
                end
            end

            // CMD 8: ROM STREAM (sequential ROM bytes)
            if (command == 8'd8) begin
                ioctl_data <= data_in;
                ioctl_wr <= 1'b1;
            end

            // Advance command payload byte counter
            if (byte_cnt != 4'd15)
                byte_cnt <= byte_cnt + 4'd1;
        end

    end else begin
        // Clear mount pulse on the next clock cycle
        image_mounted <= 1'b0;
    end
end

endmodule