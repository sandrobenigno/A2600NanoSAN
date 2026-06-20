# A2600Nano

The A2600NanoSAN is a custom core implementation based on the great [A2600Nano](https://github.com/MiSTle-Dev/A2600Nano) core wich is a port of the [MiSTer](https://github.com/MiSTer-devel/Atari2600_MiSTer) FPGA core components of the [Atari 2600 VCS](https://en.wikipedia.org/wiki/Atari_2600). It is targeted for:<br>

| Board      | FPGA       | support |Note|
| ---        |        -   | -     |-|
| [Tang Nano 20k](https://wiki.sipeed.com/nano20k)     | [GW2AR](https://www.gowinsemi.com/en/product/detail/38/)  |HDMI  |FPGABuddy Companion Board + DB9-to-SPI Board |

This project relies on my own custom firmware and board being connected to the FPGA. --> [FPGABuddy](https://github.com/sandrobenigno/FPGABuddy) <--  

Our customized version of A2600Nano Core adds some nice features:

* External phisical Cartridge reading through the custom FPGABuddy Board
* A cool navigation by a rotary encoder and LCD on the FPGABuddy Board
* It's able to read two [legacy D9 Joystick](https://en.wikipedia.org/wiki/Atari_CX40_joystick) and four paddles (ultra-low lattency db9_to_spi_san.v module and a custom hardware)
* A custom internal ROM loader as a splash-screen, waiting for other game loading.

## Core Details & Custom Modules

### 1. FPGABuddy SD Card & Cartridge Reader Integration

The **A2600NanoSAN** core relies on **FPGABuddy**, an external companion board built around a **Raspberry Pi Pico (RP2040)** microcontroller. Instead of using complex logic on the FPGA to handle the FAT32 filesystem and SD card, the RP2040 serves as the absolute SPI Master:

* **Direct ROM Streaming ([spi_loader_san.v](file:///x:/ATARI/A2600NanoSAN/src/spi_loader_san.v))**: When a game is selected, FPGABuddy pulls the FPGA's Chip Select line (`GP17` on Pico, Pin 56 on Tang Nano 20k) LOW and sends **Target 0x03 (SDC)** followed by **Command 0x08 (ROM_STREAM)**.
* **FPGA Reset Control**: The FPGA slave module (`spi_loader_san.v`) intercepts this command, activates `ioctl_download` to keep the Atari CPU in Reset, and streams ROM data directly into the FPGA mapper RAM ([Gowin_SDPB](file:///x:/ATARI/A2600NanoSAN/src/gowin_sdpb/gowin_sdpb_san.vhd)).
* **Auto Boot**: Once transmission completes and Chip Select goes HIGH, the FPGA takes the Atari CPU out of Reset, booting the game instantly.
* **Physical Cartridge Reading**: FPGABuddy includes dedicated cartridge reader pins (**GP8 to GP11** on the RP2040) configured in Slave mode to dump physical Atari 2600 cartridges externally. These dumps are streamed to the FPGA RAM using the same SPI streaming protocol, allowing real physical cartridges to run on the FPGA.
* **MISO Tri-state Resolution**: The FPGA's MISO output is held in high-impedance (`'Z'`) whenever Chip Select is inactive (HIGH), allowing FPGABuddy to share the SPI0 bus with its onboard SD card reader without electrical conflicts.

### 2. Ultra-Low Latency DB9-to-SPI Controller

Physical controller input is handled by a custom external **DB9-to-SPI board** running an **Arduino** SPI Slave. This replaces the standard DualShock 2 controller logic to interface with two legacy Atari DB9 joysticks and four analog paddles.

The master controller module [db9_to_spi_san.v](file:///x:/ATARI/A2600NanoSAN/src/db9_to_spi_san.v) on the FPGA operates at **~1.03 MHz** (derived from the 28.8 MHz core clock divided by 14, MSB-first, SPI Mode 3) and uses an **Optimized Dual-Mode Polling** mechanism:

* **Fast Scanline Poll (Command 0x01, 5 Bytes)**: Triggered on every rising edge of **HSYNC**. It reads Joystick 1 directions/fire, Joystick 2 fire (Byte 0), and all 4 analog paddles (Bytes 1-4). The transmission takes just **53.33 µs**, executing safely within the **63.5 µs** scanline window.
* **Full VBlank Poll (Command 0x02, 6 Bytes)**: Triggered on every rising edge of **VSYNC**. It reads the full controller state, including Joystick 2 directions (Byte 1) and all 4 paddles (Bytes 2-5).

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

Source code can be synthesized, fitted and programmed with GOWIN IDE Windows or Linux.  
Alternatively use the command line build script **gw_sh.exe** build_tn20k.tcl  

---

## HW Circuit Considerations

### Pinmap Tang Nano 20k to FPGABuddy (PMOD SPI)
| FPGA Pin | Core Signal Name | Function | Direction |
| :--- | :--- | :--- | :--- |
| **41** | `pmod_companion_din` | SPI MOSI | Input |
| **42** | `pmod_companion_dout`| SPI MISO | Output |
| **54** | `pmod_companion_clk` | SPI SCK | Input |
| **56** | `pmod_companion_ss`  | SPI CSn | Input |
| **51** | `pmod_companion_intn`| Interrupt IRQn | Output |

### Pinmap Tang Nano 20k to DB9-to-SPI Board (Gamepad 1 Port)
| FPGA Pin | Core Signal Name | Function | Direction |
| :--- | :--- | :--- | :--- |
| **52** | `ds_clk` | SPI SCK | Output |
| **53** | `ds_mosi`| SPI MOSI | Output |
| **71** | `ds_miso`| SPI MISO | Input |
| **72** | `ds_cs`  | SPI CSn | Output |

*Note: The second physical gamepad port pins (`ds_clk_ms20k`, etc.) are left disconnected in the FPGA core, as both joysticks and four paddles are multiplexed over the main SPI bus.*