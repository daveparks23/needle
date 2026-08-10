# Needle — Dart CLI Proof of Concept

**Handoff spec for the implementing agent.**
Project codename: `needle` (rename freely — check pub.dev/GitHub availability first).

---

## 0. Read this first

You are building a **command-line Dart program**, not a Flutter app. The Flutter
touchscreen UI comes later and is explicitly out of scope. Everything you write in
`lib/` must be **pure Dart with zero Flutter dependencies**, because the Flutter app
will consume this same package unchanged via a path dependency.

If you find yourself reaching for `package:flutter`, stop — you're outside the fence.

---

## 1. Context

The Yaesu FT-891 is an HF/50 MHz amateur transceiver with a small, cramped LCD. It
exposes a documented CAT (Computer Aided Transceiver) serial protocol over USB. A
commercial product (CatTouch7USB) puts a 7" touchscreen on this radio using custom
C++ firmware. The goal of this project is an open, Dart/Flutter equivalent that goes
further — real-time audio-derived spectrum, logging, and network features the
embedded unit can't do.

**This PoC proves the two hard loops work in Dart before any UI is built:**

1. A reliable CAT request/response loop against the real radio.
2. A real-time FFT of the radio's receive audio.

Then it combines them into a terminal waterfall as the payoff demo.

### Hardware in the loop

| Item | Detail |
|---|---|
| Radio | Yaesu FT-891 |
| CAT path | Radio's own rear USB-B → Silicon Labs **Dual CP2105** → two virtual serial ports |
| CAT port | The **Enhanced** port. The Standard port is PTT/RTS — not CAT. |
| Audio path | **Digirig** on the radio's 6-pin mini-DIN DATA jack → USB sound card |
| Dev machine | macOS (Apple Silicon MacBook Pro) |
| Eventual targets | Raspberry Pi (Linux), Android tablet |

### Radio menu settings the operator must set (document these in the README)

| Menu | Setting | Value |
|---|---|---|
| 05-06 | CAT RATE | **38400** (default is 4800 — too slow for meter polling) |
| 05-07 | CAT TOT | 1000 ms or higher |
| 05-08 | CAT RTS | OFF (unless using RTS PTT) |
| 08-05 | DATA LCUT FREQ | OFF |
| 08-07 | DATA HCUT FREQ | OFF |
| 08-11 | DATA OUT LEVEL | Tune for ~50% Digirig input level |

08-05 and 08-07 must be OFF or the DATA output is pre-filtered and the waterfall
loses bandwidth at both ends.

---

## 2. Goals and non-goals

### Goals

- Prove a stable, resyncing CAT command queue at 38400 baud.
- Prove real-time PCM capture + FFT in Dart at ≥15 frames/sec without dropping audio.
- Produce a `RigState` model and transport abstraction that the Flutter app inherits verbatim.
- Ship a mock transport so all UI work later can proceed with no radio attached.
- Produce a terminal waterfall good enough to visually identify FT8 tones on 20m.

### Non-goals (do not build these)

- Any Flutter code, widget, or dependency.
- Hamlib / rigctld integration (a future transport, not this milestone).
- Memory channel read/write, menu editing, DVS voice memory.
- Logging, ADIF, POTA, cloud sync.
- RTL-SDR / wideband panadapter.
- Transmit control beyond a single explicitly-guarded test path (see §7 Safety).

---

## 3. Success criteria

The PoC is done when all of these are true on the real radio:

1. `needle ports` lists serial ports and correctly identifies the CP2105 Enhanced port.
2. `needle cat --watch` prints live frequency, mode, and S-meter, updating smoothly, and **survives the operator spinning the VFO knob rapidly for 60 seconds with zero desyncs and zero stuck states**.
3. `needle cat --watch` recovers automatically if the radio is powered off and back on mid-run.
4. `needle audio --peak` prints the dominant audio frequency; whistling into the DATA path moves the number sensibly.
5. `needle scope` renders a scrolling ANSI-color waterfall in the terminal where FT8 signals on 14.074 MHz are visually identifiable as discrete vertical lines.
6. `needle scope --mock` runs the entire above with no hardware attached.
7. `dart analyze` is clean, `dart test` passes, and the protocol codec has unit tests covering malformed input.

---

## 4. Repository structure

Single Dart package. Structured so `lib/src/cat/` and `lib/src/dsp/` can be split into
separate packages later without touching call sites.

```
needle/
├── analysis_options.yaml
├── pubspec.yaml
├── README.md
├── bin/
│   └── needle.dart               # CLI entrypoint, arg parsing only
├── lib/
│   ├── needle.dart               # public barrel export
│   └── src/
│       ├── cat/
│       │   ├── transport.dart        # abstract CatTransport
│       │   ├── serial_transport.dart # libserialport impl
│       │   ├── mock_transport.dart   # fixture replay impl
│       │   ├── codec.dart            # command build + response parse
│       │   ├── commands.dart         # FT-891 command definitions
│       │   ├── rig_controller.dart   # queue, scheduler, retry, resync
│       │   └── rig_state.dart        # immutable state snapshot
│       ├── dsp/
│       │   ├── audio_source.dart     # abstract PcmSource
│       │   ├── arecord_source.dart   # Linux/macOS process-pipe impl
│       │   ├── mock_source.dart      # synthetic tone generator
│       │   ├── spectrum.dart         # STFT wrapper, windowing, dB scaling
│       │   ├── noise_floor.dart      # rolling percentile tracker
│       │   └── spectrum_isolate.dart # isolate host for the FFT
│       └── cli/
│           ├── ports_command.dart
│           ├── cat_command.dart
│           ├── audio_command.dart
│           └── scope_command.dart
└── test/
    ├── codec_test.dart
    ├── rig_state_test.dart
    ├── spectrum_test.dart
    └── fixtures/
        └── cat_session_20m.txt   # recorded transcript for MockTransport
```

### Dependencies

```yaml
dependencies:
  args: ^2.0.0
  fftea: ^1.0.0            # verify latest on pub.dev
  libserialport: ^0.3.0    # verify latest; pure-Dart FFI, no Flutter
  logging: ^1.0.0
  meta: ^1.9.0

dev_dependencies:
  lints: ^4.0.0
  test: ^1.24.0
```

**Note:** use `libserialport` (the pure Dart FFI package), **not**
`flutter_libserialport`. The latter is a Flutter wrapper that bundles the native C
library via Flutter's build system and is unusable from a CLI. For the CLI you must
have libserialport installed on the host (`brew install libserialport` on macOS,
`apt install libserialport-dev` on Debian/Pi). Document this in the README.

Verify all package versions against pub.dev before pinning — do not trust the numbers
above.

---

## 5. Milestone 1 — CAT

### 5.1 Protocol fundamentals

Yaesu CAT is ASCII, semicolon-terminated, strictly request/response.

- Every command ends with `;`.
- A command with parameters **sets**; the bare command **reads**.
  `FA014074000;` sets VFO-A to 14.074000 MHz. `FA;` reads it.
- Reads return the same prefix plus data plus `;`.
- An unrecognized or currently-invalid command returns `?;`.
- **The radio does not pipeline.** Send one command, wait for its response or a
  timeout, then send the next. Sending a second command before the first responds
  will desync you. This is the single most important rule in the project.
- The radio never notifies you when the operator changes something on the front
  panel. You must poll. (Auto-Information mode exists — see 5.6 — but treat polling
  as the baseline.)

### 5.2 The authoritative reference

Yaesu's official **FT-891 CAT Operation Reference Book** is the source of truth:

`https://rigreference.com/storage/manuals/yaesu/FT-891%20CAT%20Reference%20Book.pdf--5a6a4c01735456.71645851.pdf`

Download it and implement against it. Do not guess command syntax.

The table below is a **starting subset to verify against that PDF**, not a
specification. Where marked ⚠️, the exact parameter encoding must be confirmed
before you rely on it.

| Cmd | Purpose | Notes |
|---|---|---|
| `FA;` | Read VFO-A frequency | 9-digit Hz, zero-padded |
| `FB;` | Read VFO-B frequency | 9-digit Hz |
| `IF;` | Read information | Composite: freq, clarifier, mode, VFO, TX/RX. **Cheapest way to get most state in one round trip — prefer this over polling FA/MD separately.** ⚠️ verify field offsets |
| `MD0;` | Read mode | Single-char mode code ⚠️ |
| `SM0;` | Read S-meter | `SM0ddd`, 000–255 |
| `RM<n>;` | Read TX meter | ⚠️ Meter selection index differs by model — confirm which n maps to PO / SWR / ALC / IDD on the 891 |
| `PS;` | Power state | |
| `SH0;` | IF filter width | Use to draw passband edges on the waterfall ⚠️ |
| `NA0;` | Narrow on/off | |
| `AG0;` | AF gain | |
| `RG0;` | RF gain | |
| `PC;` | RF power output | |
| `NB0;` | Noise blanker | |
| `NR0;` | Noise reduction | |
| `PA0;` | IPO / preamp | |
| `RA0;` | Attenuator | |
| `AI;` | Auto-information | See 5.6 |
| `TX;` / `RX;` | Transmit control | **Guarded — see §7** |

### 5.3 Transport abstraction

```dart
abstract class CatTransport {
  Future<void> open();
  Future<void> close();
  Stream<String> get lines;     // already split on ';', ';' stripped
  void send(String command);    // caller supplies trailing ';'
  bool get isOpen;
}
```

Three implementations:

- **`SerialTransport`** — `libserialport`, 38400 8N1, no flow control. Accumulate
  incoming bytes into a buffer and split on `;`. Never assume one read == one
  response; responses arrive fragmented.
- **`MockTransport`** — replays `test/fixtures/cat_session_20m.txt`, a recorded
  transcript with timing. Must be good enough that `needle scope --mock` is a
  convincing demo.
- **`RecordingTransport`** — decorator that wraps another transport and tees all
  traffic to a file. This is how you *make* the fixtures. Build it early; it pays
  for itself immediately.

### 5.4 Port discovery

`SerialPort.availablePorts` will show the CP2105 as **two entries**. Identify the
Enhanced one by USB descriptor (product string / interface index), not by guessing
the lower-numbered device. On macOS these appear as `/dev/tty.usbserial-*` or
`/dev/tty.SLAB_USBtoUART*`; on Linux as `/dev/ttyUSB0` and `/dev/ttyUSB1`.

`needle ports` must print vendor ID, product ID, product string, serial number, and
a heuristic guess flag for each port so the operator can tell them apart.

### 5.5 The command queue

This is the heart of the project. Build it carefully.

```
RigController
├── priority queue of PendingCommand
├── exactly one command in flight at a time
├── response matched by prefix
├── per-command timeout (start at 500ms, tune down)
├── retry once on timeout, then mark that command degraded and continue
├── on '?;' → log, drop the command, do NOT retry blindly
├── on 3 consecutive timeouts → close, reopen, resync
└── emits Stream<RigState>
```

Priorities, highest first:

1. **User-initiated commands** (set frequency, set mode) — immediate.
2. **Fast poll group** — meters. ~10 Hz. During TX this is `RM` variants; during RX it's `SM0;`.
3. **Medium poll group** — `IF;` for frequency/mode/VFO. 3–4 Hz.
4. **Slow poll group** — filter width, NB/NR/AGC/preamp state. 0.5 Hz or on-demand.

Budget check: at 38400 baud a short command plus response is roughly 1 ms of wire
time, but the radio's turnaround dominates. Measure actual round-trip time and print
it under `--verbose`. If you can't sustain 10 Hz meters plus 4 Hz `IF;`, reduce the
medium group before the fast group — needle responsiveness is what the user sees.

### 5.6 Auto-Information mode

`AI1;` asks the radio to push changes unsolicited instead of waiting to be polled.
On the FT-891 this works but is reportedly quirky. **Implement polling first and get
it solid.** Then, behind a `--auto-info` flag, experiment with AI mode and measure
whether it reduces bus load. Keep the polling path as the default until AI is proven
over a long session.

### 5.7 Known landmines

Document each of these in code comments where relevant:

- **Transient S-meter zeros.** During auto-info bursts while the VFO knob is turning,
  the radio intermittently returns a bogus `000` from `SM0;`. The known fix (from the
  Yaesu_Web_Control project) is to debounce **only the zero path** — require three
  consecutive zero readings before believing it, while letting any non-zero reading
  through instantly. This keeps the meter responsive but kills the flicker. Implement
  this from day one; you will otherwise waste an evening on it.
- **`SH` command lockup.** There is a reported firmware bug where the rig stops
  accepting `SH` (filter width) commands and returns `?` until power cycle. Detect
  it, log it clearly, and degrade gracefully rather than retry-storming.
- **Fragmented reads.** Serial data arrives in arbitrary chunks. Always buffer and
  split on `;`.
- **Radio powered off.** The port stays open but nothing responds. Detect via
  consecutive timeouts and enter a clearly-signalled reconnecting state.

### 5.8 RigState

Immutable, `copyWith`, `==`/`hashCode`, no Flutter types. Include a
`DateTime lastUpdated` per field group so the UI can later grey out stale data.

```dart
@immutable
class RigState {
  final int? vfoAHz;
  final int? vfoBHz;
  final RigMode? mode;
  final bool transmitting;
  final int? sMeterRaw;        // 0-255, raw
  final double? sMeterSUnits;  // calibrated, nullable until calibration exists
  final int? filterWidthHz;
  final bool connected;
  final ConnectionPhase phase; // disconnected | connecting | ready | degraded
  // ...
}
```

Keep raw and interpreted values separate. S-meter calibration on Yaesu rigs is
nonlinear and not worth guessing at in the PoC — store the raw 0–255 and add a
calibration table later.

---

## 6. Milestone 2 — Audio and FFT

### 6.1 Audio source abstraction

```dart
abstract class PcmSource {
  Stream<Float64List> get samples;  // mono, normalized -1.0..1.0
  int get sampleRate;
  Future<void> start();
  Future<void> stop();
}
```

Implementations:

- **`ArecordSource`** (Linux/Pi, and works on macOS with `sox`/`ffmpeg` as the
  equivalent) — spawn the process, read raw S16_LE from stdout, convert to
  normalized doubles. This is the pragmatic choice: zero FFI, rock solid, trivially
  debuggable.

  ```
  arecord -D hw:1,0 -f S16_LE -r 48000 -c 1 -t raw
  ```

  Device selection must be a CLI flag with a discovery subcommand (`needle devices`)
  that shells out to `arecord -l` / `system_profiler SPAudioDataType`.

- **`MockSource`** — synthesizes a noise floor plus a few configurable tones. Should
  be able to fake something FT8-shaped so `--mock` looks realistic.

Do not use `record` or `flutter_audio_capture` here — those are Flutter plugins.
Process-pipe capture is the correct CLI approach and keeps `lib/` Flutter-free.

### 6.2 DSP parameters

Start here, expose all of them as CLI flags:

| Parameter | Value | Rationale |
|---|---|---|
| Sample rate | 48000 Hz | Digirig native |
| FFT size | 8192 | 5.86 Hz/bin — WSJT-X territory |
| Window | Hann | `Window.hanning(8192)` |
| Overlap | 50% | hop = 4096 |
| Display range | 0–3000 Hz | bins 0–512; **discard the other 94%** |
| Frame rate | ~15 fps | plenty for a waterfall |
| Magnitude | 20·log₁₀ | dB scale |

### 6.3 Using fftea

`fftea` has a streaming STFT API designed for exactly this:

```dart
final stft = STFT(8192, Window.hanning(8192));
stft.stream(chunk, (Float64x2List freq) {
  final mags = freq.discardConjugates().magnitudes();
  // mags.length == 4097; you want mags[0..512]
});
```

`stft.frequency(index, sampleRate)` maps a bin index back to Hz — use it for axis
labels rather than computing it yourself.

Call `stft.flush()` on shutdown.

### 6.4 Isolate boundary

The FFT runs in a dedicated `Isolate`. The isolate receives raw PCM chunks and sends
back **only the trimmed magnitude array** (513 doubles), never the full 4097-bin
result and never the raw audio. This keeps the port traffic small and is the same
boundary the Flutter app will use.

Use `Isolate.run` for simplicity if it fits, or a long-lived isolate with a
`ReceivePort` pair if you need to avoid per-frame spawn cost. Measure before
optimizing.

### 6.5 Noise floor tracking

Auto-scaling is required or the display washes out the moment conditions change.

Maintain a rolling estimate of the noise floor as a low percentile (start with the
25th) of the magnitude bins over the last ~5 seconds. Map the color scale from
`floor` to `floor + dynamicRange` where `dynamicRange` defaults to 40 dB and is a
CLI flag. Signals above the top clip to the brightest color.

### 6.6 TX blanking

When `RigState.transmitting` is true, stop feeding frames to the display and freeze
the noise floor estimator. Without this, keying up paints a solid bar across the
waterfall and poisons the floor estimate for the next several seconds.

This is the first place the CAT and DSP subsystems talk to each other. Keep the
coupling one-directional and explicit — the scope command subscribes to
`Stream<RigState>` and gates its own rendering. The DSP layer must not import the
CAT layer.

---

## 7. Safety: transmit control

**Default to never transmitting.**

- `TX;` must be unreachable unless the operator passes `--allow-transmit`.
- Even then, require an explicit subcommand — never as a side effect of anything else.
- Enforce a hard maximum key-down duration (10 seconds) with a watchdog timer that
  sends `RX;` unconditionally.
- On any unhandled exception, on SIGINT, and on transport close, send `RX;` before
  exiting.

Accidental transmit can damage equipment, cause interference, and put the operator in
violation of their license conditions. Treat this code path with the seriousness it
deserves.

---

## 8. Milestone 3 — Terminal waterfall

The payoff demo. `needle scope`.

- Scrolling waterfall using ANSI 24-bit color background blocks (or half-block
  characters `▀` for 2× vertical resolution).
- Terminal width auto-detected; bins downsampled to fit columns by max-pooling
  (not averaging — max preserves narrow carriers).
- Header line showing live CAT state: VFO frequency, mode, filter width, S-meter.
- Frequency axis labeled in audio Hz along the bottom.
- Overlay markers for the IF passband edges derived from `SH;`.
- `--mock` runs the whole thing with `MockTransport` + `MockSource`.

**Acceptance test:** tune the radio to 14.074 MHz USB during an active period. FT8
signals must be visually identifiable as discrete vertical lines in the waterfall.
Take a screenshot for the README.

---

## 9. CLI surface

```
needle ports                      # list serial ports, flag likely CAT port
needle devices                    # list audio input devices
needle cat --port <p> --watch     # live CAT state to stdout
needle cat --port <p> --send "FA;"  # one-shot command, print response
needle cat --port <p> --record <file>   # capture a fixture transcript
needle audio --device <d> --peak  # print dominant frequency continuously
needle audio --device <d> --bins  # dump magnitude array as CSV
needle scope --port <p> --device <d>    # the full demo
needle scope --mock               # no hardware required
```

Global flags: `--verbose` (round-trip timings, raw serial traffic), `--log <file>`,
`--baud` (default 38400).

Use `package:args` with subcommands (`CommandRunner`). Keep `bin/needle.dart` to
argument parsing and dispatch only — no logic.

---

## 10. Conventions

- Dart 3, sound null safety, `package:lints/recommended.yaml` plus
  `prefer_final_locals` and `require_trailing_commas`.
- `package:logging` throughout. No bare `print` outside the `cli/` layer.
- All timing values, buffer sizes, and thresholds are named constants in one place —
  not scattered magic numbers.
- Public API in `lib/needle.dart` barrel; everything else under `lib/src/` and not
  exported.
- Commit granularity: one commit per working sub-behavior, with messages that explain
  *why*.

### Testing

- `codec_test.dart` — command construction and response parsing, including malformed
  input: truncated responses, `?;`, unexpected prefixes, embedded garbage bytes,
  responses split across chunk boundaries.
- `rig_state_test.dart` — state transitions, staleness, the zero-debounce logic
  (explicitly test that three zeros are required but one non-zero passes through).
- `spectrum_test.dart` — feed a synthesized 1000 Hz sine at 48 kHz, assert the peak
  bin maps back to 1000 Hz ±6 Hz via `stft.frequency`.
- `RigController` tests run entirely against `MockTransport` — no hardware in CI.

---

## 11. Build order

Do these in sequence. Do not start a milestone before the previous one meets its
criterion.

1. Scaffold package, `analysis_options.yaml`, CI running `dart analyze` + `dart test`.
2. `needle ports` — correctly identifies the CP2105 Enhanced port on macOS.
3. `SerialTransport` + `codec` — `needle cat --send "FA;"` returns the real frequency.
4. `RecordingTransport` — capture a fixture while spinning the VFO knob.
5. `MockTransport` replaying that fixture.
6. `RigController` queue, scheduler, timeouts, resync. Tests against mock.
7. `needle cat --watch` passes the 60-second knob-spinning criterion.
8. `MockSource` + `spectrum.dart` + `spectrum_test.dart` — synthetic sine round-trips correctly.
9. `ArecordSource` + `needle audio --peak` against the real Digirig.
10. Isolate boundary + noise floor tracker.
11. `needle scope` — terminal waterfall.
12. TX blanking wired in. README with screenshot.

---

## 12. What comes after (context only — do not build)

The Flutter app will add this package as a path dependency and add:
`TcpTransport` for rigctld (instant multi-radio support via Hamlib), `CustomPainter`
analog meters with proper needle ballistics, a GPU-side waterfall using a
`Uint32List` ring buffer and `decodeImageFromPixels`, and targets on Raspberry Pi
(flutter-pi, 800×480 DSI touchscreen) and Android tablet (`usb_serial` replacing
`libserialport`).

Design every interface in `lib/` with those futures in mind. In particular: nothing
in `lib/src/` may assume a single process, a single transport, or a console.

---

## 13. Prior art worth reading before you start

| Project | Why |
|---|---|
| `kd-boss/CAT` | C++ Yaesu CAT library with explicit FT-891 support — effectively a typed version of the reference book |
| `mm5agm/Yaesu_Web_Control` | Browser CAT controller; its changelog documents real Yaesu polling quirks including the S-meter zero issue |
| `891ctrl` (DO1ZL) | FT-891-specific control app; documents the `SH` command bug |
| `openRig` (openrig.app) | Dart/Flutter ham suite, MIT — hamlib FFI and rigctld client in Dart. Read `openrig_core` before designing the transport layer; there may be a reason to depend on it instead |
| Hamlib | The universal backend; `rigctld` on TCP 4532 is the future `TcpTransport` target |

**Before writing the transport layer, spend an hour reading `openrig_core`.** If its
rig abstraction is close to what's specified here, propose depending on it or
contributing upstream rather than reimplementing. Report that assessment back before
proceeding.

---

## 14. Open questions to resolve with the operator

- Final project name (`needle` is a placeholder; verify pub.dev + GitHub + domain).
- License. MIT is suggested for consistency with the surrounding ham software ecosystem.
- Whether to target `openrig_core` as a dependency (see §13).
- Whether the eventual appliance target is Raspberry Pi or Android tablet — affects
  how much effort goes into the `arecord` path vs. a plugin-based one.