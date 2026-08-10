/// Every timing value, buffer size, and threshold in the project.
///
/// Handoff spec §10: all tunables live in one place so poll cadences and DSP
/// parameters can be adjusted without hunting through call sites.
library;

// ---------------------------------------------------------------------------
// CAT
// ---------------------------------------------------------------------------

/// Target CAT rate. Requires radio menu 05-06 CAT RATE = 38400.
///
/// The dev radio was measured at 9600 on 2026-08-10 — a wrong-baud port is not
/// silent, it returns plausible-looking framing garbage, so port probing sweeps
/// [kSupportedBauds] rather than trusting this value.
const int kDefaultBaud = 38400;

/// Every CAT rate the FT-891 menu offers, slowest first.
const List<int> kSupportedBauds = [4800, 9600, 19200, 38400];

const Duration kCommandTimeout = Duration(milliseconds: 500);
const int kMaxRetriesPerCommand = 1;
const int kTimeoutsBeforeResync = 3;
const Duration kReconnectBackoff = Duration(seconds: 2);

/// Poll group cadences (spec §5.5). If the measured round-trip cannot sustain
/// both, reduce the medium group before the fast group — meter responsiveness
/// is what the operator actually sees.
const Duration kFastPollPeriod = Duration(milliseconds: 100); // ~10 Hz, meters
const Duration kMediumPollPeriod = Duration(milliseconds: 250); // ~4 Hz, IF;
const Duration kSlowPollPeriod = Duration(seconds: 2); // 0.5 Hz, filter/NB/NR

/// Spec §5.7: during VFO motion the radio intermittently answers `SM0;` with a
/// bogus `000`. Believe a zero only after this many consecutive zero readings;
/// let any non-zero reading through instantly.
const int kSMeterZerosBeforeBelieved = 3;

/// Silicon Labs CP2105 USB descriptor. Measured via `ioreg -p IOUSB` on the dev
/// Mac with the FT-891 attached: VID 4292 / PID 60016 decimal.
const int kSiliconLabsVendorId = 0x10C4;
const int kCp2105ProductId = 0xEA70;

/// CP2105 interface 0 is the Enhanced (CAT) UART; interface 1 is Standard
/// (PTT/RTS). Confirmed by probe: interface 0 answers `FA;`, interface 1 is
/// silent at every supported baud.
const int kEnhancedInterfaceIndex = 0;

// ---------------------------------------------------------------------------
// DSP
// ---------------------------------------------------------------------------

/// Digirig native rate, and what the C-Media codec already reports.
const int kSampleRate = 48000;

/// 5.86 Hz per bin — WSJT-X territory.
const int kFftSize = 8192;

/// 50% overlap.
const int kFftHop = 4096;

/// Display range. Bins 0..512; the other 94% of the spectrum is discarded
/// before it ever crosses the isolate boundary.
const double kDisplayMaxHz = 3000.0;

const int kTargetFps = 15;
const double kDefaultDynamicRangeDb = 40.0;
const double kNoiseFloorPercentile = 0.25;
const Duration kNoiseFloorWindow = Duration(seconds: 5);

/// Added to magnitudes before the log so silence yields a finite floor rather
/// than negative infinity.
const double kLogEpsilon = 1e-12;

// ---------------------------------------------------------------------------
// Safety (spec §7)
// ---------------------------------------------------------------------------

/// Hard maximum key-down. A watchdog sends `RX;` unconditionally at this point.
const Duration kMaxKeyDown = Duration(seconds: 10);
