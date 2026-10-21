# Measure

In-house macOS software for live sound, acoustic analysis and commissioning. It is meant to feel familiar to REW users and adds what REW lacks for our work. The scope and plan for the first prototype are in the [scope document](https://claude.ai/artifact/Wzym5NS47yjfWYJbQySCdb).

The first prototype covers sweep measurement and ISO 3382 room acoustics. The fast real-time mode, the iPad remote, commissioning reports and STI come later.

## What's here

| Part | Contents |
| --- | --- |
| `Sources/MeasureDSP` | The analysis core. It has no user interface and no audio hardware code, so it can be tested on its own. |
| `Sources/MeasureAudio` | Core Audio device list and sweep playback and recording (macOS only). |
| `Sources/measure-cli` | A command-line tool for measuring, analysing files and making sweeps before the app exists. |
| `Tests/MeasureDSPTests` | Tests on generated signals with known answers. Comparisons with MATLAB and the measurement database come later. |

The analysis core provides:

- **Files:** WAV read and write (PCM 8 to 32 bit, float 32 and 64 bit, multichannel). Import of REW text exports and mic calibration files, including the sensitivity line.
- **Sweeps:** exponential sine sweeps (Farina) with fades. Deconvolution by regularised spectral division against the generated sweep, a loopback recording or any imported test signal. Delay estimation by cross-correlation.
- **Filters:** IEC 61260 base-ten octave and third-octave bands. These are sixth-order Butterworth band-pass filters, run forward or time-reversed.
- **ISO 3382-1 results:** EDT, T20, T30, C50, C80, D50 and Ts per band and broadband. Onset is detected at -20 dB. Lundeby truncation finds the noise floor and adds the estimated energy of the lost tail. Results also include the Schroeder decay curve and the fitted lines.
- **Views (data only):** frequency response with fractional-octave smoothing, energy-time curve (Hilbert envelope), spectrogram and waterfall (cumulative spectral decay).

The FFT uses Apple's Accelerate (vDSP) on macOS. On other platforms it uses a portable radix-2 FFT, so the same tests can run on Linux CI.

## Getting started on your Mac

You need Xcode 16 or later (Swift 5.9+), on macOS 14 or later.

```sh
git clone https://github.com/LAMJLAMJLAMJ/Measure.git
cd Measure
swift test                # run all tests
swift build -c release    # build the command-line tool
```

To work in Xcode, open the folder (`File > Open...` and choose `Package.swift`). Choose the `MeasureDSP` scheme and press ⌘U to run the tests.

## Measuring from Terminal

```sh
# List audio devices: number, name, channels, sample rates, latency
.build/release/measure-cli devices

# Sweep out of output 1 of device 3 (and also output 8, cabled to input 8); record mics on inputs 1 and 2
.build/release/measure-cli measure --out 3 --out-ch 1 --loopback-out 8 --loopback 8 --mics 1,2 --level -12 --save room1
```

- **Devices:** `--out` and `--in` take the number from `devices`, the device UID, or part of its name (`--out Scarlett`). `--in` defaults to the output device.
- **Loopback:** cable a spare output of the interface to a spare input. Use `--loopback-out` to play the sweep on that output too, and `--loopback` to record it on that input. Delays are then absolute, because the interface latency cancels. Without a loopback, delays include the latency.
- **Separate devices** (for example a USB mic and a Dante Virtual Soundcard output): create an aggregate device in Audio MIDI Setup with drift correction on, and measure through it.
- **Results:** for each mic the tool prints the peak level (with a warning if it clips or is too quiet), the arrival time of the direct sound and the ISO 3382 table. `--save room1` writes `room1-raw.wav` (all recorded channels) and `room1-mic1.wav`, `room1-mic2.wav` (impulse responses).
- **Microphone permission:** the first run asks for microphone access for Terminal. If you declined it, turn it on in System Settings > Privacy & Security > Microphone.

## Command-line tool

```sh
# Make a 3 s sweep from 20 Hz to 20 kHz at -6 dBFS with 2 s of silence after it
.build/release/measure-cli sweep sweep.wav --length 3 --silence 2

# Turn a recording into an impulse response. The reference can be the sweep file,
# or (better) a loopback recording of it, which also removes the interface latency.
.build/release/measure-cli deconvolve recording.wav sweep.wav ir.wav

# ISO 3382 results per octave band (add --third for third octaves, --csv results.csv to save)
.build/release/measure-cli analyze ir.wav

# Delay between two recordings
.build/release/measure-cli delay mic.wav loopback.wav
```

Example output for a simulated room with a 0.9 s reverberation time:

```
Band       EDT s  T20 s  T30 s  C50 dB  C80 dB  D50 %  Ts ms  PNR dB
500         0.93   0.90   0.89    -0.6     2.8   46.7     69     111
1k          0.84   0.90   0.92     1.5     3.9   58.3     64     110
2k          0.88   0.91   0.92     1.1     3.7   56.3     65     106
Broadband   0.89   0.90   0.90     0.8     4.0   54.8     64      89
```

## Known limitations

- The onset is found once, on the unfiltered response, and used for every band. In low third-octave bands the filter's delay pushes early energy past the 50 and 80 ms limits. That makes C50, C80, D50 and EDT unreliable below about 100 Hz. Whether to use a separate onset per band will be decided against the MATLAB reference.
- Results have only been checked on generated signals so far. They are not yet checked against MATLAB or REW on real measurements.
