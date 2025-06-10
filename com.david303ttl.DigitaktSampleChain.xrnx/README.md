# Digitakt Sample Chain
Renoise tool designed to export selected instrument samples into a single, monophonic WAV file, formatted as a sample chain suitable for Elektron Digitakt.

## Features

* **Export Modes:**
    * **Spaced (Digitakt Grid):** Exports samples into fixed-length slots, ideal for Digitakt's sample slicing grid. You can choose from "Auto" (slot length based on the longest sample, adjusted to fit all samples into a specified number of slots) or predefined slot counts (4, 8, 16, 30, 32, 64).
    * **Chain (Direct Concatenation):** Exports samples one after another without forced padding, creating a continuous audio stream.
* **Mono Conversion:**
    * **Average (Sum):** Converts stereo samples to mono by averaging the left and right channels (default).
    * **Left Channel:** Uses only the left channel for mono conversion.
    * **Right Channel:** Uses only the right channel for mono conversion.
* **Audio Processing Options:**
    * **Apply Short Fade-out:** Adds a small fade-out to the end of each exported sample slice to prevent clicks.
    * **Apply Dither (TPDF):** Applies Triangular Probability Distribution Function (TPDF) dither when converting to 16-bit, which can reduce quantization noise.
    * **Pad each slot with 64 samples of zero:** Adds a short silence at the beginning and end of each sample slot in "Spaced" mode.
* **WAV Export:** Exports standard 48kHz, 16-bit mono WAV files, optimized for Digitakt import.
* **Duration Info:** Displays the length of individual slots and the total chain duration after export.

## Usage

1.  **Select an Instrument:** In Renoise, select the instrument containing the samples you wish to export as a chain.
2.  **Open the Exporter Dialog:**
    * `Sample Editor` > `Export Digitakt Sample Chain`
3.  **Configure Export Options:**
    * In the dialog box, choose your desired "Export Mode" ("Spaced" or "Chain").
    * If "Spaced" mode is selected, choose your preferred "Slot Count" ("Auto", 4, 8, 16, 30, 32, 64).
    * Select your "Mono Conversion" method ("Average", "Left Channel", "Right Channel").
    * Check or uncheck the options for "Apply short fade-out", "Apply Dither", and "Pad each slot with 64 samples of zero" as needed.
4.  **Export the Chain:**
    * Click the "Export Chain" button.
    * You will be prompted to choose a filename and location for your exported WAV file.
    * After export, the dialog will display the duration of a single slot and the total chain duration.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.