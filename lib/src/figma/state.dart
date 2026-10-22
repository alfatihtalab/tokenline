import 'dart:convert';
import 'dart:io';

import '../config.dart';
import 'snapshot.dart';

/// Saves what Figma held after a pull or sync: the snapshot (the base for
/// the next sync) and the path -> variable id map (to spot renames).
void saveFigmaState(
    TokenlineConfig config, FigmaSnapshot snapshot, Map<String, String> ids) {
  final figma = config.figma!;
  snapshot.writeFile(config.resolve(figma.snapshotFile));
  final sorted = Map.fromEntries(
      ids.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  File(config.resolve(figma.idsFile))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
}

/// The last saved snapshot, or null before the first sync.
FigmaSnapshot? readFigmaBase(TokenlineConfig config) {
  final f = File(config.resolve(config.figma!.snapshotFile));
  return f.existsSync() ? FigmaSnapshot.readFile(f.path) : null;
}

Map<String, String> readFigmaIds(TokenlineConfig config) {
  final f = File(config.resolve(config.figma!.idsFile));
  if (!f.existsSync()) return const {};
  return (jsonDecode(f.readAsStringSync()) as Map).cast<String, String>();
}
