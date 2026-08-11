# Context for Claude working on `needle`

Read this before touching anything. It records what is built, what was learned
from the physical radio, and the rules that are easy to break by accident and
expensive to debug afterwards.

The three markdown files here do different jobs:

- **`needle_info.md`** — the original handoff spec. Treat it as intent, not
  fact: several of its technical claims turned out to be wrong on real
  hardware (see "Where the spec is wrong" below).
- **`README.md`** — for a human operator: install, radio menu setup, usage.
- **`CLAUDE.md`** (this file) — for the next agent session.

---

## What this is

A pure-Dart CLI that talks CAT to a Yaesu FT-891 over serial and renders a
real-time audio waterfall in the terminal. It is a **proof of concept** whose
purpose was to retire two risks before a Flutter touchscreen app gets built on
top of it:

1. Can Dart hold a reliable CAT request/response loop against a radio in use?
2. Can Dart run a real-time FFT of receiver audio fast enough?

**Both are answered yes, with numbers.** CAT round trips are 5–13 ms at 38400
and the FFT runs ~5700 fps across the isolate boundary against a 15 fps target.

Status: 25 commits, 204 tests, `dart analyze --fatal-infos` clean, CI green on
GitHub at `daveparks23/needle` (public, MIT).

### Success criteria (from spec §3)

| # | Criterion | Status |
|---|---|---|
| 3.1 | `ports` identifies the CP2105 Enhanced port | pass |
| 3.2 | `cat --watch` survives 60 s of knob spinning | pass — 1164 responses, 0 desyncs |
| 3.3 | recovers from a mid-run power cycle | pass |
| 3.4 | `audio --peak` tracks a real signal | **open** — superseded in practice by 3.5 |
| 3.5 | FT8 visible as discrete lines on 14.074 | pass — `docs/waterfall.png` |
| 3.6 | `scope --mock` runs with no hardware | pass |
| 3.7 | clean analysis, tests, malformed-input coverage | pass |

---

## Hardware truths (do not relearn these the hard way)

Every one of these was measured on the physical radio. They are the most
valuable thing in this repo.

**There is no `RX` command on the FT-891.** The command table runs RA, RC, RD,
RG, RI, RL, RM, RS, RU — no RX — and the radio answers `?;` to it. Un-keying is
`TX0;` (`kUnkey`). Spec §7 says to send `RX;` from the transmit watchdog, the
SIGINT handler and on transport close; doing that leaves the transmitter keyed
in exactly those situations. `test/tx_safety_test.dart` greps `lib/` to prove
no file can send it.

**After the radio answers `?;` it ignores CAT for a full second.** Measured:
commands at 0.4–0.9 s after a rejection were silently discarded; 1.0 s+ always
worked. That threshold is menu 05-07 CAT TOT. A rejection therefore costs far
more than the rejected command — the queue must go *quiet* (`kRejectionRecovery`),
not merely skip a retry. Corollary: **never send a bare `;` to flush the link**;
it is itself invalid, so it triggers the dead window it was meant to clear.

**A wrong baud rate is not silent.** It returns plausible framing garbage
(`\xf8\x80...`). "No response" and "wrong rate" must stay distinguishable, which
is why `ports --probe` sweeps all four supported rates.

**`libserialport` (0.3.0+1) has three traps**, all found by bisecting a SIGABRT
that printed no diagnostic:
- Calling `SerialPortConfig.dispose()` *and* `SerialPort.dispose()` aborts the
  process. Either alone is safe. We build a fresh config per open and never
  dispose it.
- A config cannot be reused across ports; the second apply fails `ETIMEDOUT`.
- `SerialPortReader` hands a raw `Pointer<sp_port>` to a spawned isolate and
  only stops it asynchronously, so closing the port frees the struct mid-read.
  We run our own 2 ms read pump (`kSerialPollInterval`) instead. **This matters
  because resync is built on close/reopen.**

**`ready` must mean the radio is answering, not that the port opened.** The
CP2105 node can survive a power cycle, so a successful reopen proves nothing.
Only a matched response may promote the phase.

**A failed reopen must schedule another attempt.** With the transport closed
nothing is sent, so no timeout fires, so nothing would ever retry — the
controller wedges in `degraded` forever.

**Auto-information mode is measured worse, not merely unproven.** 20 s each,
same radio: polling 390 responses / 0 desyncs / 0 unsolicited; `--auto-info`
375 / 7 desyncs / 54 unsolicited. The cause is structural — one command in
flight matched by prefix, so a pushed update mid-exchange completes the wrong
request. Benefiting from AI needs a controller designed around pushed state.
The flag restores `AI0;` on exit; AI otherwise persists until power-off and
will confuse the next program the operator opens.

**`SH` returns a table index, not Hz**, and the index means different things per
mode (14 = 2400 Hz wide SSB, 1700 Hz wide CW, unavailable in narrow SSB). Table
transcribed in `lib/src/cat/filter_widths.dart`.

### Where the spec is wrong

- §7's `RX;` (above) — the most dangerous error in it.
- §5.2 claims `IF;` carries TX/RX. It does not. Poll `TX;`. Its payload is 25
  chars and mode sits at offset **19**, not 20.
- §5.7's S-meter zero glitch did not occur once in 118 reads under hard knob
  spinning. It is specific to auto-info bursts, which polling never enters. The
  debouncer stays as insurance; the zeros live in a clearly-labelled
  **synthetic** fixture rather than being faked into a real capture.
- §5.4 says use `/dev/tty.*`. On macOS use `/dev/cu.*` — `tty.` blocks on open
  awaiting carrier detect. `SerialPort.availablePorts` already returns only
  `cu.`.

---

## Architecture

```
lib/src/cat/   protocol, transports, the command queue, transmit guard
lib/src/dsp/   PCM sources, STFT, noise floor, isolate host
lib/src/cli/   every command; the ONLY layer allowed to print
```

Invariants, all enforced by `test/layering_test.dart`:

- `dsp/` never imports `cat/`. They meet only in `scope_command.dart`, which
  subscribes to `Stream<RigState>` and gates its own rendering.
- Nothing in `lib/` mentions Flutter. The Flutter app consumes this package
  unchanged via a path dependency.
- Nothing outside `cli/` writes to the console.
- No file can send `RX;`.

`RigController` is the heart: **exactly one command in flight, ever**. The radio
does not pipeline, and a desync mis-attributes every later response. An
`_outstanding` set stops a poll group stacking duplicates; a prefix mismatch
drops the response rather than completing the wrong request.

Everything host-specific about audio lives in `lib/src/dsp/capture_backend.dart`
— one class per platform, and `verified` is part of the type. **macOS is the
only host this has ever run on.** Linux (arecord) and Windows (dshow) are
written from documentation and untested; `needle devices` says so out loud.

---

## Running it

```bash
export LIBSERIALPORT_PATH=/opt/homebrew/lib/libserialport.dylib   # macOS: required
dart analyze --fatal-infos && dart test

needle ports --probe                                   # find the CAT port
needle scope --port /dev/cu.usbserial-00B61C5C0 --device 0
needle scope --mock                                    # no hardware
```

The dylib export is required because dyld does not search `/opt/homebrew/lib` on
Apple Silicon. It is set permanently in
`~/development/davesdotrepo/shell/conf.d/20-hamradio.zsh`.

`needle` is installed globally via `dart pub global activate --source path .`.
Re-run that after changes if testing the global binary. **`--mock` must not read
from `test/`** — the fixture is compiled in (`mock_fixture.dart`) precisely so
the installed binary works from any directory.

On this machine: CAT port `/dev/cu.usbserial-00B61C5C0`, audio device `0`.

---

## Open items

- **§3.4** — tune slowly across a steady carrier in USB with `audio --peak`;
  the pitch should sweep, not step. Low value now that 3.5 passes.
- **Better screenshot** — `docs/waterfall.png` was captured audio-only (header
  reads `no CAT`) and predates the Ctrl-C fix, so it shows a stale exception
  line. A run with `--port` would show live frequency/mode/S-meter above the
  waterfall, which is the better demonstration.
- **Linux bring-up** — the largest genuine unknown. `arecord` capture and
  enumeration have never executed.
- **S-meter calibration** — `sMeterSUnits` is deliberately null. The reference
  book documents `SM` as only `P2 000 - 255`; no curve exists to transcribe.
  Deriving one needs a signal generator stepping known levels.
- **The Flutter app** — nothing blocks it. See spec §12.

## Working preferences

Target is macOS for now, with an eye toward Android, Linux and Windows — keep
the platform seams honest rather than implementing untested paths as though
they work. Prefer measuring the radio over trusting the spec: most of the value
above came from doing that. If a spec claim and the hardware disagree, the
hardware wins and the finding belongs in this file.
