# A2600Nano

The A2600NanoSAN is a custom core implementation based on the great [A2600Nano](https://github.com/MiSTle-Dev/A2600Nano) core wich is a port of the [MiSTer](https://github.com/MiSTer-devel/Atari2600_MiSTer) FPGA core components of the [Atari 2600 VCS](https://en.wikipedia.org/wiki/Atari_2600). It is targeted for:<br>

| Board      | FPGA       | support |Note|
| ---        |        -   | -     |-|
| [Tang Nano 20k](https://wiki.sipeed.com/nano20k)     | [GW2AR](https://www.gowinsemi.com/en/product/detail/38/)  |HDMI / LCD  |twin Dualshock<br> MiSTeryShield20k spare header + Joy to DIP |

This project relies on my own custom firmware and board being connected to the FPGA. --> [FPGABuddy](https://github.com/sandrobenigno/FPGABuddy) <--  

Our customized version of A2600Nano Core adds some nice features:

* External phisical Cartridge reading through the custom FPGABuddy Board
* A cool navigation by a rotary encoder and LCD on the FPGABuddy Board
* It's able to read two [legacy D9 Joystick](https://en.wikipedia.org/wiki/Atari_CX40_joystick) and four paddles (ultra-low lattency db9_to_spi_san.v module and a custom hardware)
* A custom internal ROM loader as a splash-screen, waiting for other game loading.

Notes!

<+> talk about the external cartridge reader and/or FPGABuddy's SD card and our spi_loader_san.v module

<+> talk about the external DB9toSPI board and our db9_to_spi_san.v module

**Multicolor RGB LED**

<+> talk about the RGB LED and the State machine of the three states from FPGABuddy

## Powering

<+> talk about powering on the USB-C on the FPGABuddy or TangNano 20K with 5V 2A power source

## Synthesis

Source code can be synthesized, fitted and programmed with GOWIN IDE Windows or Linux.  
Alternatively use the command line build script **gw_sh.exe** build_tn20k.tcl  

## HW circuit considerations

**Pinmap TN20k Interfaces**

<+> talk about FPGABuddy pins

<+> talk about DB9toSPI pins