# Hardware-Accelerated ANC (Active Noise Cancellation) Engine

**Difficulty:**  
**Uses MCU:** Yes  
**External Hardware:** None (for PC-Streamed Testbench) / 2x INMP441 & 1x MAX98357A (for Live Audio)  

## Overview

This project implements a full-stack, hardware-accelerated Active Noise Cancellation (ANC) pipeline on the Shrike platform. It features a custom Application-Specific Integrated Circuit (ASIC) design written in Verilog that natively computes the FxLMS (Filtered-x Least Mean Squares) adaptive filter algorithm in pure silicon with sub-microsecond latency. 

An RP2040 microcontroller acts as the high-speed streaming controller, taking lossless audio payloads and dispatching them to the FPGA via a custom 10 MHz Programmable I/O (PIO) Dual-SPI bus. The repository also includes a comprehensive suite of PC-based Python tools for audio ingest, lossless binary transport, and high-density visual transient analysis.

## Compatibility

| Board | Firmware | Status |
|-------|----------|--------|
| Shrike-Lite (RP2040) | `firmware/micropython/` | ✅ Tested |
| Shrike (RP2350) | `firmware/micropython/` | ✅ Tested |
| Shrike-fi (ESP32-S3) | `firmware/micropython/` | ⬜ Untested |

> FPGA bitstream is the same across all boards.

## Hardware Setup

No external hardware is required for the pre-recorded binary testbench. The configuration utilizes the internal routing between the MCU and the FPGA. 

*(Note: For live bare-metal execution, this architecture supports direct FPGA GPIO wiring to I2S microphones and DACs).*

**FPGA Connections (`anc_engine.v`):**
* **Pin 3:** `spi_sck` (Input) - SPI clock
* **Pin 4:** `spi_ss_in` (Input) - Chip select (active low)
* **Pin 18:** `dual_io[0]` (Inout) - DSPI Data Line 0
* **Pin 17:** `dual_io[1]` (Inout) - DSPI Data Line 1
* **Pin 16:** `led` (Output) - Status LED

**RP2040 / RP2350 Connections (`dspi_bus.py`):**
* **GPIO 2:** `SCK` (Output) - SPI clock
* **GPIO 1:** `CS` (Output) - Chip select
* **GPIO 14:** `DSPI_D0` (Inout) - PIO Data Line 0
* **GPIO 15:** `DSPI_D1` (Inout) - PIO Data Line 1

## How It Works

This rig bridges complex digital logic with robust embedded software to achieve perfectly deterministic phase alignment:

* **The Silicon Engine:** The FPGA executes a 2-tap micro-LUT FxLMS engine. It continuously processes the Reference Mic and Error Mic reality, adjusting its internal gain weights to generate a phase-aligned destructive interference array (the Anti-Wave) entirely within hardware logic.
* **The MCU Controller (`main.py` & `dspi_bus.py`):** The RP2040 utilizes its PIO state machines for half-duplex Dual-SPI communication. It implements a **Sign-Bit Hardware Bypass** using the `struct` library to safely pack 32-bit unsigned words, entirely immunizing the rig against MicroPython integer overflow crashes. It also utilizes **Chunked RAM Buffering** to process massive binary audio streams without triggering `OSError: 28` flash memory limits.
* **The PC Toolchain:** Includes `recorder.py` for standardizing lossless `.wav` files into 8-bit FPGA-ready payloads, `listen.py` to reconstruct the FPGA's raw binary telemetry back into playable `.wav` audio, and `pc_bin_visualizer.py`, a high-density diagnostic plotting tool that dynamically scales line rendering to map thousands of acoustic transients without visual smearing.

---

## Complete Usage Flow (End-to-End Testbench)

To test the ANC engine using real-world room noise, follow this exact pipeline to stream audio through the hardware and reconstruct the output.

### Phase 1: Audio Ingest & Payload Generation (PC)

1. **Record the Noise:** Use your phone or PC to record a few seconds of raw room noise (e.g., a fan, talking, or a machine). Ensure your recording app is set to output uncompressed/lossless audio and save the file as `test.wav` in your project folder.

2. **Compile the Payload:** Run the audio ingest script on your PC:

   ```bash

   python recorder.py

*This script will read `test.wav`, mix it down to a single mono channel, resample it to the 8000 Hz hardware loop target, normalize the volume, and compile it into a raw 8-bit signed binary payload named `real_noise.bin`.*

### Phase 2: Hardware Execution (MCU & FPGA)

1. **Flash the MCU:** Using VS Code (MicroPico) or Thonny, upload the following files directly to the root of your Shrike RP2040 board:

   * `main.py`

   * `dspi_bus.py`

   * `anc_engine.bin`

   * `real_noise.bin` *(The payload you just generated)*

2. **Run the Engine:** Execute `main.py` on the microcontroller. 

   * The RP2040 will boot, flash the FPGA bitstream, load the binary audio chunks into RAM, and blast them across the Dual-SPI bus into the FxLMS engine. 

   * **Do not unplug the board** until the console prints `Done!`. It is currently writing the residual error calculations and anti-wave vectors directly to the flash storage.


### Phase 3: Telemetry Extraction & Acoustic Reconstruction (PC)

1. **Download the Telemetry:** Once the MCU script finishes, download the two newly generated binary files from the RP2040 back into your PC's project folder:

   * `anti_wave.bin` *(The FPGA's cancellation speaker output)*

   * `err_wave.bin` *(The residual error / what the human ear actually hears)*

2. **Reconstruct the Audio:** Run the reconstruction script on your PC:

   ```bash

   python listen.py

*This script bypasses slow CSV parsing and instantly converts the raw MCU memory dumps back into standard 16-bit `.wav` files.*

3. **Analyze the Results:**

   * Put on headphones and play `1_before_anc.wav` followed by `2_after_anc.wav` to physically hear the DSP cancellation floor.

   * Run `python pc_bin_visualizer.py` to open an interactive Matplotlib dashboard. Use the magnifying glass tool to zoom in on specific sub-millisecond transients to analyze how quickly the hardware weights converged on the noise profile.