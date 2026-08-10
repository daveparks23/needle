import 'dart:io';

import 'package:test/test.dart';

/// Architectural rules the handoff spec states outright. They are cheap to
/// break by accident during a refactor and expensive to discover later.
void main() {
  test('the DSP layer never imports the CAT layer', () {
    // Spec 6.6: the scope command subscribes to both and gates its own
    // rendering. The coupling is one-directional and lives in the CLI.
    // Match import directives only — a doc comment that *mentions* the rule
    // must not trip it.
    final importsCat = RegExp(r'''^\s*import\s+['"].*cat/''', multiLine: true);
    for (final f in Directory('lib/src/dsp').listSync().whereType<File>()) {
      expect(
        importsCat.hasMatch(f.readAsStringSync()),
        isFalse,
        reason: '${f.path} must not depend on the CAT layer',
      );
    }
  });

  test('nothing in lib/ imports Flutter', () {
    // The Flutter app consumes this package unchanged via a path dependency.
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      expect(
        f.readAsStringSync(),
        isNot(contains('package:flutter')),
        reason: '${f.path} broke the no-Flutter rule',
      );
    }
  });

  test('only the CLI layer writes to the console', () {
    // Spec 10: no bare print outside cli/. bin/ and cli/ opt out explicitly.
    for (final f in Directory('lib/src').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.contains('/cli/')) continue;
      final src = f.readAsStringSync();
      expect(src, isNot(contains('print(')), reason: '${f.path} prints');
      expect(src, isNot(contains('stdout.')), reason: '${f.path} writes stdout');
    }
  });

  test('no code path sends the non-existent RX command', () {
    // The FT-891 has no RX command; it answers '?;' and stays keyed. Every
    // un-key must go through kUnkey.
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      if (f.path.endsWith('commands.dart')) continue; // documents the trap
      expect(
        f.readAsStringSync(),
        isNot(contains("'RX;'")),
        reason: '${f.path} would leave the transmitter keyed',
      );
    }
  });
}
