import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../errors.dart';
import '../figma/adopt.dart';
import '../figma/diff.dart';
import '../figma/legacy_sync_frame.dart';
import '../figma/plan.dart';
import '../figma/rest.dart';
import '../figma/snapshot.dart';
import '../lint/rules.dart';
import '../loader.dart';
import 'base.dart';

class PullCommand extends TokenlineCommand {
  PullCommand() {
    argParser
      ..addFlag('check',
          negatable: false,
          help: 'Only report differences; exit 2 if Figma and the token '
              'files differ. Writes nothing.')
      ..addOption('from-file',
          valueHelp: 'export.json',
          help: 'Read the Tokenline plugin export from a file instead of '
              'calling the Figma API.')
      ..addFlag('allow-removals',
          negatable: false,
          help: 'Accept tokens removed or renamed in Figma without being '
              'deprecated first (breaks code that uses them).')
      ..addFlag('lint',
          defaultsTo: true,
          help: 'Refuse to pull when Figma breaks the token rules.');
  }

  @override
  String get name => 'pull';

  @override
  String get description =>
      'Pull Figma variables into the token files and regenerate Dart.';

  @override
  Future<int> run() async {
    final figma = config.figma ??
        (throw TokenlineException('tokenline.yaml has no figma section'));
    final check = argResults!['check'] as bool;
    final fromFile = argResults!['from-file'] as String?;
    final model = TokenModel.load(config);

    if (fromFile == null && figma.source == FigmaSource.syncFrame) {
      return _pullLegacy(model, check: check);
    }

    final snapshot = await _snapshot(figma, fromFile);
    info('read ${snapshot.variables.length} variables from Figma '
        '(${fromFile ?? snapshot.source}'
        '${snapshot.exportedAt == null ? '' : ', exported ${snapshot.exportedAt}'})');

    final issues = lintSnapshot(snapshot, figma, config.lint);
    final errors = issues.where((i) => i.severity == Severity.error).toList();
    for (final i in issues) {
      (i.severity == Severity.error ? stderr : stdout).writeln('  $i');
    }
    if (errors.isNotEmpty && argResults!['lint'] as bool) {
      throw TokenlineException('${errors.length} rule error(s) in Figma — fix '
          'them (the plugin\'s Lint shows each one), or pass --no-lint');
    }

    final plan = FigmaPlan.build(config, model);
    final diff = diffSnapshot(config, model, plan, snapshot,
        knownIds: _readIds(config.resolve(figma.idsFile)));
    for (final w in diff.warnings) {
      warn(w);
    }

    if (diff.changes.isEmpty) {
      info('Figma matches the token files — nothing to pull');
      if (!check) _saveState(figma, snapshot, diff.ids);
      return 0;
    }
    for (final c in diff.changes) {
      info('  ${c.describe()}');
    }
    if (check) {
      throw TokenlineException(
          '${diff.changes.length} difference(s) between Figma and the token files',
          exitCode: 2);
    }
    final breaking = diff.breaking;
    if (breaking.isNotEmpty && !(argResults!['allow-removals'] as bool)) {
      throw TokenlineException('${breaking.length} token(s) were removed or '
          'renamed in Figma without being deprecated first:\n'
          '${breaking.map((c) => '  ${c.describe()}').join('\n')}\n'
          'Code that uses them would stop compiling. In Figma, restore them '
          'and mark them "@deprecated → new/name" instead — or pass '
          '--allow-removals to accept the break.');
    }

    final files = adoptChanges(config, model, diff.changes);
    _saveState(figma, snapshot, diff.ids);
    final generated = regenerate(check: false, quiet: true);
    info('\nupdated ${files.length} token file(s) and ${generated.length} '
        'Dart file(s) — review the diff, then commit them together');
    return 0;
  }

  Future<FigmaSnapshot> _snapshot(FigmaConfig figma, String? fromFile) async {
    if (fromFile != null) return FigmaSnapshot.readFile(fromFile);
    final rest = FigmaRest(FigmaCredentials.resolve(config));
    try {
      return switch (figma.source) {
        FigmaSource.plugin => await rest.pluginSnapshot(),
        FigmaSource.variablesApi => await rest.variablesSnapshot(),
        FigmaSource.syncFrame => throw StateError('handled by _pullLegacy'),
      };
    } finally {
      rest.close();
    }
  }

  void _saveState(
      FigmaConfig figma, FigmaSnapshot snapshot, Map<String, String> ids) {
    snapshot.writeFile(config.resolve(figma.snapshotFile));
    final sorted = Map.fromEntries(
        ids.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    File(config.resolve(figma.idsFile))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(sorted)}\n');
  }

  Future<int> _pullLegacy(TokenModel model, {required bool check}) async {
    final figma = config.figma!;
    final rest = FigmaRest(FigmaCredentials.resolve(config));
    final ResolvedValues values;
    try {
      values = await fetchSyncFrame(rest, figma.syncFrameId!);
    } finally {
      rest.close();
    }
    info('read ${values.length} values from the sync frame '
        '(legacy: links, descriptions, added and removed variables are not visible)');
    final changes = diffResolved(config, model, values);
    if (changes.isEmpty) {
      info('Figma matches the token files — nothing to pull');
      return 0;
    }
    for (final c in changes) {
      info('  ${c.describe()}');
    }
    if (check) {
      throw TokenlineException(
          '${changes.length} difference(s) between Figma and the token files',
          exitCode: 2);
    }
    final files = adoptChanges(config, model, changes);
    final generated = regenerate(check: false, quiet: true);
    info('\nupdated ${files.length} token file(s) and ${generated.length} '
        'Dart file(s) — review the diff, then commit them together');
    return 0;
  }
}

Map<String, String> _readIds(String path) {
  final f = File(path);
  if (!f.existsSync()) return const {};
  return (jsonDecode(f.readAsStringSync()) as Map).cast<String, String>();
}
