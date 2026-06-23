# Installation Guide (A2600NanoSAN)

This document explains how to flash and set up the necessary files for the **A2600NanoSAN** core on the **Tang Nano 20k** FPGA and the **FPGABuddy (RP2040)** companion board.

This setup has been tested on Windows 10/11.

---

## 1. Prerequisites & Software Needed

### FPGA Synthesis & Programming
* [Gowin V1.9.11.03 (or newer)](https://www.gowinsemi.com/en/support/home/): Needed to synthesize the core or use the Gowin Programmer tool to flash the FPGA.
* The compiled bitstream: `impl/pnr/a2600nano_tn20k_san.fs`.

### FPGABuddy Firmware & Utilities
* The FPGABuddy firmware binary: `fpgabuddy.uf2` (compiled from the FPGABuddy project repository).
* Python 3.x (to run database generation and renaming scripts).
* *Note: Unlike the generic A2600Nano core, the onboard BL616 microcontroller on the Tang Nano 20k is NOT flashed with companion firmware. It is left with its factory firmware to serve strictly as the USB-JTAG programmer for the FPGA.*

### Storage
* A Micro SD Card (formatted in FAT32) to insert into the **FPGABuddy** board.
* Atari 2600 ROM files (`.bin`, `.a26`).

---

## 2. Flashing the Tang Nano 20k FPGA

### Option A: Using Gowin Programmer GUI
1. Connect the Tang Nano 20k to your PC via USB-C.
2. Open the **Gowin Programmer** tool.
3. Click the **Scan Device** button to detect the FPGA.
4. Set the programming parameters:
   - **Access Mode**: `SRAM Program` (for temporary testing) or `Embedded Flash Mode` (to persist the core).
   - **File name**: Select `impl/pnr/a2600nano_tn20k_san.fs`.
   - **Address**: `0x000000`.
5. Click the **Play** (Program) icon. You should see a progress bar and a "Successful" message.

### Option B: Using Command Line (PowerShell/Cmd)
Run the Gowin Programmer CLI to flash the bitstream directly to the embedded flash:
```bash
programmer_cli -r 36 --fsFile impl/pnr/a2600nano_tn20k_san.fs --spiaddr 0x000000 --cable-index 1 --d GW2AR-18C
```

---

## 3. Flashing the FPGABuddy (RP2040)

The FPGABuddy companion board uses a Raspberry Pi Pico (RP2040) to offload the SD card and OSD menus. Flashing is simple and does not require third-party tools:

1. Unplug the FPGABuddy board from power/USB.
2. Press and hold the **BOOTSEL** button on the Raspberry Pi Pico.
3. Connect the Pico to your PC via USB-C while holding the button, then release it.
4. The PC will detect a new USB mass storage drive named **RPI-RP2**.
5. Copy or drag-and-drop the `fpgabuddy.uf2` file directly onto the **RPI-RP2** drive.
6. Once copied, the Pico will automatically reboot, flash itself, and start the FPGABuddy companion firmware.

---

## 4. Preparing the SD Card

The SD card is handled entirely by the FPGABuddy companion board:

1. Format the Micro SD card to **FAT32**.
2. **Generate the ROM Database**:
   - The FPGABuddy project includes Python scripts to compile a curated SQLite database of Atari 2600 games into a flat binary database file called **`roms.bin`**.
   - Generate this file using the Python scripts and copy **`roms.bin`** to the root of your Micro SD card.
3. **Organize and Rename your ROMs**:
   - Copy your Atari 2600 ROM files (`.bin` or `.a26` files) onto the card (they can be placed in subdirectories).
   - FPGABuddy will also provide Python renaming scripts (to be made available in the FPGABuddy repository) to automatically rename your ROM files using their calculated **MD5 checksum** (e.g., `<calculated_md5>.bin`).
   - FPGABuddy uses the file name (the MD5 hash) to look up the game's official name, mapper type, and other metadata indexed inside **`roms.bin`**.
4. Insert the SD card into the Micro SD slot on the **FPGABuddy board**.

---

## 5. Wiring & Hardware Connection

Ensure the hardware components are connected correctly:
1. **FPGABuddy SPI Link**: Connect the 5-pin PMOD SPI interface on FPGABuddy to the companion pins on the Tang Nano 20k (Pins 41, 42, 51, 54, 56).
2. **DB9-to-SPI Board**: Connect the SPI interface of the DB9-to-SPI board to Gamepad Port 1 on the Tang Nano 20k (Pins 52, 53, 71, 72).
3. **Power Source**: Connect a **5V, 2A USB-C power supply** to either the FPGABuddy board or the Tang Nano 20k.
