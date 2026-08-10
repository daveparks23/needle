/// Pure-Dart CAT control and audio spectrum tooling for the Yaesu FT-891.
///
/// This package contains **no Flutter dependency of any kind** and must not
/// acquire one: the eventual Flutter touchscreen app consumes this package
/// unchanged via a path dependency. Nothing here may assume a single process,
/// a single transport, or a console.
library;

export 'src/cat/codec.dart';
export 'src/cat/mock_transport.dart';
export 'src/cat/recording_transport.dart';
export 'src/cat/commands.dart';
export 'src/cat/rig_controller.dart';
export 'src/cat/rig_state.dart';
export 'src/cat/transport.dart';
export 'src/constants.dart';
export 'src/dsp/audio_source.dart';
export 'src/dsp/mock_source.dart';
export 'src/dsp/process_pcm_source.dart';
export 'src/dsp/spectrum.dart';
