# Measure

In-house macOS software for live sound, acoustic analysis and commissioning. It is meant to feel familiar to REW users and adds what REW lacks for our work. The scope and plan for the first prototype are in the [scope document](https://claude.ai/artifact/Wzym5NS47yjfWYJbQySCdb).

The first prototype covers sweep measurement and ISO 3382 room acoustics. The fast real-time mode, the iPad remote, commissioning reports and STI come later.

## What's here

| Part | Contents |
| --- | --- |
| `Sources/MeasureDSP` | The analysis core. It has no user interface and no audio hardware code, so it can be tested on its own. |
| `Sources/MeasureAudio` | Core Audio device list and sweep playback and recording (macOS only). |
| `Sources/Measure` | The Mac app (SwiftUI). |
| `Sources/measure-cli` | A command-line tool for measuring, analysing files and making sweeps before the app exists. |
| `Tests/MeasureDSPTests` | Tests on generated signals with known answers. Comparisons with MATLAB and the measurement database come later. |

The analysis core provides:

- **Files:** WAV read and write (PCM 8 to 32 bit, float 32 and 64 bit, multichannel). Import of REW text exports and mic calibration files, including the sensitivity line.
- **Sweeps:** exponential sine sweeps (Farina) with fades. Deconvolution by regularised spectral division against the generated sweep, a loopback recording or any imported test signal. Delay estimation by cross-correlation.
- **Filters:** IEC 61260 base-ten octave and third-octave bands. These are sixth-order Butterworth band-pass filters, run forward or time-reversed.
- **Echo criterion** after Dietsch and Kraak (speech and music).
- **STI** (IEC 60268-16:2020) from the impulse response, with noise, auditory masking and the reception threshold.
- **ISO 3382-1 results:** EDT, T20, T30, C50, C80, D50 and Ts per band and broadband. Onset is detected at -20 dB. Lundeby truncation finds the noise floor and adds the estimated energy of the lost tail. Results also include the Schroeder decay curve and the fitted lines.
- **Views (data only):** frequency response within an adjustable window around the direct sound, with fractional-octave smoothing, energy-time curve (Hilbert envelope), spectrogram and waterfall (cumulative spectral decay).

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

## The Mac app

```sh
./scripts/build-app.sh      # builds build/Measure.app
open build/Measure.app
```

`swift run Measure` also starts it during development. In that case macOS asks for microphone access for Terminal rather than for the app.

- **Setup** (toolbar): output device and sweep channel, an optional second output for the loopback cable, input device, up to 4 mic inputs, loopback input, sample rate, sweep range, length, silence and level, and a position label. Microphones and their calibration files are set up here too. Each calibration belongs to a mic, not to an input. Settings are remembered, with devices found again by their UID.
- **Measure** (⌘M): plays the sweep and adds one trace per mic to the library. The status bar warns about clipping or low level.
- **Import** (⌘I): WAV impulse responses and REW text frequency responses.
- **Trace library** (sidebar): tick traces to overlay them, and right-click to edit name, position, mic and notes, or to delete. Traces are saved as WAV and JSON in `~/Documents/Measure Projects/Default`. Use ⌘O to choose another project folder.
- **Modes** (toolbar, ⌥⌘1 and ⌥⌘2): the app has two modes that share the trace library, so an impulse response measured in one can be analysed in the other. ⌘1 to ⌘7 pick a view within the current mode, and the app remembers the last mode and view.
  - **System tuning:** measure with a sweep (the live cross-spectrum mode comes later), then look at
    - **Impulse:** impulse response or ETC over 20 ms to the full length, aligned to the selected trace's direct sound. The shaded area is the selected trace's frequency response window: drag its edges, or type how many ms before and after the direct sound it covers. Each side has its own shape (rectangular, Hann, Hamming, Blackman or Tukey with a taper percentage), drawn as a dashed line. The default is Hann on the left and Tukey with a 25 % taper on the right. A small frequency response under the chart shows the result, and while you drag an edge it shows the new window's response over the current one in grey. "Apply to All Shown" copies the window to every ticked trace. The span and ETC/Impulse choice are remembered. The default is 5 ms before to 1 s after, and windows are saved with each trace.
    - **Frequency:** within each trace's window, with 1/3 to 1/48 octave smoothing and mic calibration. The Virtual EQ panel is a placeholder for now.
    - **Phase:** wrapped phase within each trace's window, with the delay to the direct sound removed.
    - **Delay:** arrival time of each shown trace, relative to the selected one in ms and metres, with the ETC below.
    - **STI:** see Acoustic analysis.
  - **Acoustic analysis:** Record (a sweep now, plain recordings later) or Load files, then look at
    - **Reverb:** Schroeder curve per band with the EDT, T20 and T30 fit lines and the noise floor, above the EDT/T20/T30 table and a band-by-band comparison of the shown traces.
    - **Clarity:** C50, C80, D50 and Ts table and comparison. "Copy All as CSV" copies every ISO 3382 parameter.
    - **Echo:** echo criterion after Dietsch and Kraak for the shown traces, for speech (n = 2/3, Δτ = 9 ms) or music (n = 1, Δτ = 14 ms), on the 1 kHz octave (as in the original method), the 2 kHz octave or broadband. The chart shows EK against time with the limits at which 10 % and 50 % of listeners hear an echo, and the table lists every echo of each trace (each stretch of EK above the 10 % limit, at its peak) with its EK, time and verdict, or the largest EK for a trace without any. Echoes are also marked on the chart.
    - **STI** (also in System tuning): Speech Transmission Index per IEC 60268-16:2020 (edition 5, indirect method, male speech, backward band filtering) for each shown trace, with its qualification band (A+ to U) and the modulation transfer index per octave for the selected trace. Set the speech level in dB(A) (male speech spectrum) or your own octave levels, optional background noise levels per octave, and whether auditory masking and the reception threshold apply. Each band's response is cut where it meets its noise floor. A note warns when a response is shorter than 1.6 s or has under 20 dB SNR in a band, as the standard requires.
    - **Levels** (statistical levels) and **Noise** (NR/NC): placeholders that say what each will need.
    - **Spectrogram and waterfall.**

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
