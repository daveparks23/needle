/// Decodes the `SH` filter-width index into an actual bandwidth.
///
/// `SH0;` answers with a **table index**, not a frequency, and the same index
/// means different things in different modes — index 14 is 2400 Hz in wide SSB
/// but 1700 Hz in wide CW. Showing the raw index (`SH:14`) tells an operator
/// nothing, so this transcribes the bandwidth table from the FT-891 CAT
/// Operation Reference Book (`docs/ft891_cat_reference.pdf`, "SH WIDTH").
///
/// A dash in the printed table means that index is not offered for that
/// combination; those are null here rather than guessed.
library;

import 'commands.dart';

/// The three filter families the reference book tabulates.
enum FilterGroup { ssb, cw, rttyPsk }

// Index 0 is the mode's default. Lists are indexed by the SH P3 value, 0-21.
const List<int?> _ssbNarrow = [
  1500, 200, 400, 600, 850, 1100, 1350, 1500, 1650, 1800, //
  null, null, null, null, null, null, null, null, null, null, null, null,
];

const List<int?> _ssbWide = [
  2400, null, null, null, null, null, null, null, null, 1800, //
  1950, 2100, 2200, 2300, 2400, 2500, 2600, 2700, 2800, 2900, 3000, 3200,
];

const List<int?> _cwNarrow = [
  500, 50, 100, 150, 200, 250, 300, 350, 400, 450, //
  500, null, null, null, null, null, null, null, null, null, null, null,
];

const List<int?> _cwWide = [
  2400, null, null, null, null, null, null, null, null, null, //
  500, 800, 1200, 1400, 1700, 2000, 2400, 3000, null, null, null, null,
];

const List<int?> _rttyNarrow = [
  300, 50, 100, 150, 200, 250, 300, 350, 400, 450, //
  500, null, null, null, null, null, null, null, null, null, null, null,
];

const List<int?> _rttyWide = [
  500, null, null, null, null, null, null, null, null, null, //
  500, 800, 1200, 1400, 1700, 2000, 2400, 3000, null, null, null, null,
];

/// Which filter family a mode uses, or null when `SH` does not apply.
///
/// AM and FM have fixed filters and are absent from the table entirely.
FilterGroup? filterGroupFor(RigMode mode) => switch (mode) {
  RigMode.lsb || RigMode.usb => FilterGroup.ssb,
  RigMode.cw || RigMode.cwReverse => FilterGroup.cw,
  // DATA shares the RTTY/PSK filter set on this radio; the reference book
  // tabulates the two together under "RTTY/PSK".
  RigMode.rtty ||
  RigMode.rttyReverse ||
  RigMode.data ||
  RigMode.dataReverse => FilterGroup.rttyPsk,
  RigMode.am || RigMode.amNarrow || RigMode.fm || RigMode.fmNarrow => null,
  RigMode.unknown => null,
};

/// Resolves an `SH` index to a bandwidth in Hz.
///
/// Returns null when the mode has no filter table, the index is out of range,
/// or that index is not offered for the mode and narrow setting.
int? filterWidthHz({
  required RigMode mode,
  required bool narrow,
  required int index,
}) {
  final group = filterGroupFor(mode);
  if (group == null) return null;

  final table = switch ((group, narrow)) {
    (FilterGroup.ssb, true) => _ssbNarrow,
    (FilterGroup.ssb, false) => _ssbWide,
    (FilterGroup.cw, true) => _cwNarrow,
    (FilterGroup.cw, false) => _cwWide,
    (FilterGroup.rttyPsk, true) => _rttyNarrow,
    (FilterGroup.rttyPsk, false) => _rttyWide,
  };

  if (index < 0 || index >= table.length) return null;
  return table[index];
}
