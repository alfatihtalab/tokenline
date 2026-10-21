import 'dart:io';

import '../config.dart';
import 'emitter.dart';

/// Writes [files] under the project root and returns the paths whose
/// content changed. With [check], nothing is written.
List<String> writeGenerated(TokenlineConfig config, List<GeneratedFile> files,
    {required bool check}) {
  final changed = <String>[];
  for (final f in files) {
    final file = File(config.resolve(f.path));
    final current = file.existsSync() ? file.readAsStringSync() : null;
    if (current == f.content) continue;
    changed.add(f.path);
    if (!check) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(f.content);
    }
  }
  return changed;
}
