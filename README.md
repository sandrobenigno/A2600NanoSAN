# A2600NanoSAN

The **A2600NanoSAN** is a custom Atari 2600 VCS core implementation. It is based on the [A2600Nano](https://github.com/MiSTle-Dev/A2600Nano) core, which is a port of the [MiSTer Atari 2600](https://github.com/MiSTer-devel/Atari2600_MiSTer) FPGA core components. 

It is designed for the following hardware configuration:

| Board | FPGA | Video Output | Support / Notes |
| --- | --- | --- | --- |
| [Tang Nano 20k](https://wiki.sipeed.com/nano20k) | [GW2AR](https://www.gowinsemi.com/en/product/detail/38/) | HDMI | FPGABuddy Companion Board + DB9-to-SPI Board |

This project requires connecting a custom coprocessor board running dedicated firmware: [FPGABuddy](https://github.com/sandrobenigno/FPGABuddy).

![#wiring](images/pin_wiring.jpg)

## Key Features

This customized version of the A2600Nano core introduces several key features:
* **Physical Cartridge Support**: Ability to read physical Atari 2600 cartridges using the FPGABuddy cartridge slots.
* **On-Screen Navigation**: Fluid user interface navigated via a rotary encoder and character LCD hosted on the FPGABuddy board.
* **Legacy Controllers**: Dual DB9 joystick ports and support for up to four analog paddles with ultra-low latency via the custom [db9_to_spi_san.v](file:///x:/ATARI/A2600NanoSAN/src/db9_to_spi_san.v) module.
* **Splash Screen**: A custom internal ROM that acts as a splash screen while waiting for external game images to stream.

---

## Core Details & Custom Modules

### 1. FPGABuddy SD Card & Cartridge Reader Integration

The **A2600NanoSAN** core relies on **FPGABuddy**, an external companion board built around a **Raspberry Pi Pico (RP2040)** microcontroller. Instead of implementing complex FAT32 filesystem and SD card logic on the FPGA, the RP2040 acts as the SPI Master:

* **Direct ROM Streaming ([spi_loader_san.v](file:///x:/ATARI/A2600NanoSAN/src/spi_loader_san.v))**: When a game is selected, FPGABuddy pulls the FPGA's Chip Select line (`GP17` on Pico, Pin 56 on Tang Nano 20k) LOW and sends **Target 0x03 (SDC)** followed by **Command 0x08 (ROM_STREAM)**.
* **FPGA Reset Control**: The FPGA slave module (`spi_loader_san.v`) intercepts this command, activates `ioctl_download` to keep the Atari CPU in Reset, and streams ROM data directly into the FPGA mapper RAM ([Gowin_SDPB](file:///x:/ATARI/A2600NanoSAN/src/gowin_sdpb/gowin_sdpb_san.vhd)).
* **Auto Boot**: Once transmission completes and Chip Select goes HIGH, the FPGA takes the Atari CPU out of Reset, booting the game instantly.
* **Physical Cartridge Reading**: FPGABuddy features dedicated cartridge reader pins on the RP2040 configured in slave mode. Physical cartridge ROMs are dumped externally and streamed to the FPGA's internal RAM over SPI, enabling support for real Atari 2600 cartridges.
* **MISO Tri-state Resolution**: The FPGA's MISO output is held in high-impedance (`'Z'`) whenever Chip Select is inactive (HIGH), allowing FPGABuddy to share the SPI0 bus with its onboard SD card reader without electrical conflicts.

### 2. Ultra-Low Latency DB9-to-SPI Controller

Physical controller input is handled by a custom external **DB9-to-SPI board** running an **Arduino** SPI Slave. This replaces the standard DualShock 2 controller logic to interface with two legacy Atari DB9 joysticks and four analog paddles.

The master controller module [db9_to_spi_san.v](file:///x:/ATARI/A2600NanoSAN/src/db9_to_spi_san.v) on the FPGA operates at **~720 kHz** (derived from the 28.8 MHz core clock divided by 20, MSB-first, SPI Mode 3) and implements **Aggressive Smart Polling**:

* **VBlank Poll (Command 0x02, 2 Bytes)**: Triggered on every rising edge of **VSYNC** (always, in both joystick and paddle modes). It reads all joystick directions and fire buttons (Byte 0: Joy1+Fires, Byte 1: Joy2 directions/fires). The transmission takes just **22.2 µs**.
* **Fast Scanline Poll (Command 0x01, 4 Bytes)**: Triggered on every rising edge of **HSYNC** (only if `paddle_mode` is active). It reads only the 4 analog paddle positions, completely omitting button data to minimize transmission time down to **44.4 µs** (creating a comfortable **19 µs** safety margin inside the **63.5 µs** scanline window). Joystick Mode turns HSync polling off completely, reducing SPI interrupts by **99.8%**.

### 3. Multicolor RGB Status LED (WS2812)

The companion board updates the FPGA's onboard WS2812 status LED (Pin 79) by sending a 5-byte SPI packet (Target 0, Command 2) to [sysctrl.v](file:///x:/ATARI/A2600NanoSAN/src/misc/sysctrl.v) containing a 24-bit color value. The color reflects the current state of FPGABuddy's global state machine:

1. **STATE_SELECIONANDO (ROM Menu)**: Onboard LED glows **Green** (`rgb(0, 127, 0)`).
2. **STATE_JOGANDO (Active Console)**: Onboard LED glows **Blue** (`rgb(0, 0, 127)`).
3. **STATE_CONFIGURANDO (OSD Settings)**: Onboard LED glows **Red** (`rgb(127, 0, 0)`).

---

## Powering

The system must be powered using a **5V, 2A power supply** connected via USB-C to either the FPGABuddy board or the Tang Nano 20k. This ensures sufficient current to power the FPGA core, HDMI output, RP2040, LCD screen, and the external cartridge reader.

---

## Synthesis

The source code can be synthesized, fitted, and programmed using the GOWIN IDE on Windows or Linux. Alternatively, use the command-line build script: `gw_sh.exe build_tn20k_san.tcl`.

---

## HW Circuit Considerations

### Pinmap Tang Nano 20k to FPGABuddy (MCU SPI)
| FPGA Pin | Core Signal Name | Function | Direction |
| :--- | :--- | :--- | :--- |
| **41** | `fpgabuddy_mosi` | SPI MOSI | Input |
| **42** | `fpgabuddy_miso` | SPI MISO | Output |
| **54** | `fpgabuddy_sclk` | SPI SCK | Input |
| **56** | `fpgabuddy_csn`  | SPI CSn | Input |
| **51** | `fpgabuddy_irqn` | Interrupt IRQn | Output |

### Pinmap Tang Nano 20k to DB9-to-SPI Board (Game Controller SPI)
| FPGA Pin | Core Signal Name | Function | Direction |
| :--- | :--- | :--- | :--- |
| **52** | `db9_spi_sclk` | SPI SCK | Output |
| **53** | `db9_spi_mosi` | SPI MOSI | Output |
| **71** | `db9_spi_miso` | SPI MISO | Input |
| **72** | `db9_spi_csn`  | SPI CSn | Output |

*Note: The second physical gamepad port pins (previously `ds_clk_ms20k`, etc. on pins 73, 74, 77, and 31) have been completely removed and released from the FPGA core.*
