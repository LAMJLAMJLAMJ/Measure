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

- **Setup** (toolbar): output device and sweep channel, an optional second output for the loopback cable, input device, up to 4 mic inputs, loopback input, sample rate, sweep range, length, silence and level, and a position label. Microphones and their calibration files are set up here too. Each calibration belongs to a mic, not to an input. "Calibrate…" records a 94 dB or 114 dB sound level calibrator for 3 s on the mic's input and sets its SPL offset, so plain recordings read in dB SPL; the offset can also be typed in. It holds only while the interface gain stays where it was. Settings are remembered, with devices found again by their UID.
- **Measure** (⌘M): plays the sweep and adds one trace per mic to the library. The status bar warns about clipping or low level.
- **Import** (⌘I): WAV impulse responses and REW text frequency responses.
- **Trace library** (sidebar): tick traces to overlay them, click a trace's colour dot to choose a palette colour or any other, double-click its name (or right-click > Rename) to rename it, and right-click to edit name, position, mic and notes, or to delete. Traces are saved as WAV and JSON in `~/Documents/Measure Projects/Default`. Use ⌘O to choose another project folder.
- **Modes** (toolbar, ⌥⌘1 and ⌥⌘2): the app has two modes that share the trace library, so an impulse response measured in one can be analysed in the other. ⌘1 to ⌘7 pick a view within the current mode, and the app remembers the last mode and view.
  - **System tuning:** measure with a sweep, or switch the Source in the toolbar to **Live** (cross-spectrum), then look at
    - **Live (cross-spectrum):** on the Frequency and Phase views while the source is Cross-spectrum. A dual-channel analyser. The reference is either internal (the generated pink noise itself, as in Smaart, so each mic needs only one input and no loopback cable; input and output should be one device so they share a clock, and the found delay includes the interface latency) or the loopback input set in Setup (the signal fed to the system, which also works with programme). Each mic's transfer function is the averaged cross spectrum over the reference's power spectrum, so any signal works. Pink noise (periodic, 20 Hz to 20 kHz) plays on the measurement output and the loopback output when "Pink noise" is on; turn it off to measure with programme. It draws magnitude (with the mic's calibration), coherence and phase for every mic, updating with half-overlapping blocks. Choose the FFT size (8k to 64k) and the number of averages. "Find Delay" lines the reference up with each mic from its impulse response peak. "Capture" adds each mic's current response to the list as an impulse response (direct sound 10 ms in), so every other view works on it. Live curves are drawn thick; ticked traces are drawn with them in their own colours. Stopping clears the live curve, so capture while running.
    - **Impulse:** impulse response or ETC over 20 ms to the full length, aligned to the selected trace's direct sound. The shaded area is the selected trace's frequency response window: drag its edges, or type how many ms before and after the direct sound it covers. Each side has its own shape (rectangular, Hann, Hamming, Blackman or Tukey with a taper percentage), drawn as a dashed line. The default is Hann on the left and Tukey with a 25 % taper on the right. A small frequency response under the chart shows the result, and while you drag an edge it shows the new window's response over the current one in grey. "Apply to All Shown" copies the window to every ticked trace. The span and ETC/Impulse choice are remembered. The default is 5 ms before to 1 s after, and windows are saved with each trace.
    - **Frequency:** within each trace's window, with 1/3 to 1/48 octave smoothing and mic calibration. "Average" adds a trace with the average of the ticked traces' responses, each within its window and with its mic calibration applied: a power (RMS) average, as for a spatial average of mic positions, or a dB average. Responses on the same frequency grid are averaged bin by bin; others are smoothed to 1/48 octave and averaged over the range they share. The average's name (for up to three traces), its line in the list and its notes say which measurements were used; hover over a trace in the list to see its notes. The Virtual EQ panel (toolbar button) lets you try parametric filters on the selected trace: peak, low and high shelf, high-pass, low-pass and notch, each with frequency, gain and Q, and a tick to turn it off. The filters are the Audio EQ Cookbook biquads at the trace's sample rate, which is how most processors implement them. The panel shows the filters' combined curve, and the Frequency view draws the selected trace with the EQ added as a dashed line. "More" copies the filter list as text for typing into a processor, or adds the predicted response as a trace of its own. Prediction only: nothing is sent to a processor, and the EQ is saved with the trace.
    - **Phase:** wrapped phase within each trace's window, with the delay to the direct sound removed.
    - **Delay:** arrival time of each shown trace, relative to the selected one in ms and metres, with the ETC below.
    - **STI:** see Acoustic analysis.
  - **Acoustic analysis:** Record a sweep (for an impulse response) or a plain recording of every mic input for a set time (for levels and noise), or Load impulse responses or WAV recordings (Measurement > Import Recordings…), then look at
    - **Reverb:** Schroeder curve per band with the EDT, T20 and T30 fit lines and the noise floor, above the EDT/T20/T30 table and a band-by-band comparison of the shown traces.
    - **Clarity:** C50, C80, D50 and Ts table and comparison. "Copy All as CSV" copies every ISO 3382 parameter.
    - **Echo:** echo criterion after Dietsch and Kraak for the shown traces, for speech (n = 2/3, Δτ = 9 ms) or music (n = 1, Δτ = 14 ms), on the 1 kHz octave (as in the original method), the 2 kHz octave or broadband. The chart shows EK against time with the limits at which 10 % and 50 % of listeners hear an echo, and the table lists every echo of each trace (each stretch of EK above the 10 % limit, at its peak) with its EK, time and verdict, or the largest EK for a trace without any. Echoes are also marked on the chart.
    - **STI** (also in System tuning): Speech Transmission Index per IEC 60268-16:2020 (edition 5, indirect method, male speech, backward band filtering) for each shown trace, with its qualification band (A+ to U) and the modulation transfer index per octave for the selected trace. Set the speech level in dB(A) (male speech spectrum) or your own octave levels, optional background noise levels per octave, and whether auditory masking and the reception threshold apply. Each band's response is cut where it meets its noise floor. A note warns when a response is shorter than 1.6 s or has under 20 dB SNR in a band, as the standard requires.
    - **Levels:** Leq, Lmax, Lmin, L10, L50, L90 and L95 of each shown recording (the CSV adds L1 and L5), A, C or Z weighted (IEC 61672) with Fast or Slow time weighting, and the level over time of the selected one. Levels are dB SPL when the mic is calibrated, otherwise re full scale. The Offset field (also on the Noise tab) sets the dB added to the selected recording's level to give dB SPL, for a recording made without a calibrated mic or one that was imported; clearing it uses the mic's calibration again. "Copy All as CSV" copies the table.
    - **Noise:** octave-band Leq of the selected recording from 31.5 Hz to 8 kHz, with its NR (ISO R1996) and NC (Beranek 1957) ratings by the tangency method, the matching curves drawn over the bands, and LAeq. "Use as STI Speech" and "Use as STI Noise" copy the 125 Hz to 8 kHz levels to the STI speech levels (switching STI to custom speech levels) or to its background noise.
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
