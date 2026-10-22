// Two-way sync: decide, per token and per aspect (a theme's value, the
// description, the deprecation, existence), which side changed since the
// last sync. The base is the Figma snapshot saved after the last sync, when
// Figma and the token files matched.
import 'dart:convert';

import '../config.dart';
import '../loader.dart';
import 'diff.dart';
import 'plan.dart';
import 'snapshot.dart';

enum Side { figma, code }

/// Both sides changed the same aspect of a token differently.
class SyncConflict {
  SyncConflict(this.change);

  /// The change that would make the token files match Figma.
  final TokenChange change;

  String get question {
    final c = change;
    final where = '${c.path}${c.mode == null ? '' : ' (${c.mode})'}';
    return switch (c.kind) {
      ChangeKind.added => '$where was deleted in code but changed in Figma',
      ChangeKind.removed => '$where was deleted in Figma but changed in code',
      ChangeKind.description =>
        '$where description — Figma: "${c.after}", code: "${c.before}"',
      ChangeKind.deprecation =>
        '$where deprecation — Figma: ${c.after ?? 'none'}, code: ${c.before ?? 'none'}',
      _ => '$where — Figma: ${c.after}, code: ${c.before}',
    };
  }
}

class SyncDecision {
  /// Changes to write into the token files (Figma wins).
  final List<TokenChange> adopt = [];

  /// `collection|name` of Figma variables to delete (deleted in code).
  final List<String> deleteInFigma = [];

  /// Removals and renames that would break code; the sync stops on these.
  final List<TokenChange> breaking = [];
  final List<SyncConflict> conflicts = [];
  final List<String> warnings = [];

  /// Aspects where the code wins and Figma gets updated.
  int codeWins = 0;

  /// Tokens that exist only in code and will be created in Figma.
  int newInCode = 0;

  bool get firstSync => _firstSync;
  bool _firstSync = false;

  void resolve(SyncConflict conflict, Side side) {
    final c = conflict.change;
    if (side == Side.code) {
      if (c.kind == ChangeKind.added) deleteInFigma.add(_figmaKey!(c));
      codeWins++;
      return;
    }
    if (c.isBreaking) {
      breaking.add(c);
    } else {
      adopt.add(c);
    }
  }

  String Function(TokenChange)? _figmaKey;
}

String _aspect(TokenChange c) => switch (c.kind) {
      ChangeKind.value => 'value:${c.mode}',
      ChangeKind.description => 'description',
      ChangeKind.deprecation => 'deprecation',
      _ => 'exists',
    };

String _key(TokenChange c) => '${c.level.name}|${c.path}|${_aspect(c)}';

/// What Figma holds for that aspect, comparable across two diffs.
String _figmaSide(TokenChange c) => jsonEncode([
      c.kind == ChangeKind.removed ? 'absent' : 'present',
      {for (final e in c.jsonValues.entries) '${e.key}': e.value},
      c.description,
      c.deprecated,
    ]);

/// Decides what goes where. [base] is null on the first sync: then every
/// difference that is not a pure addition is a conflict.
SyncDecision decideSync(TokenlineConfig config, TokenModel model,
    FigmaPlan plan, FigmaSnapshot figma, FigmaSnapshot? base) {
  final d = SyncDecision();
  final figmaConfig = config.figma!;
  bool hasCollections(FigmaSnapshot s) =>
      s.collections.any((c) => figmaConfig.levelForCollection(c.name) != null);

  if (!hasCollections(figma)) {
    // Empty Figma file: everything comes from code.
    d.newInCode = plan.variables.length;
    d._firstSync = base == null;
    return d;
  }

  final baseDiff = base != null && hasCollections(base)
      ? diffSnapshot(config, model, plan, base)
      : null;
  d._firstSync = baseDiff == null;
  final baseIds = baseDiff?.ids ?? const <String, String>{};
  final baseChanges = {
    for (final c in baseDiff?.changes ?? const <TokenChange>[]) _key(c): c
  };

  final fd = diffSnapshot(config, model, plan, figma, knownIds: baseIds);
  d.warnings.addAll(fd.warnings.where((w) => !w.contains('not in Figma yet')));
  d.newInCode = plan.variables.where((v) => !fd.ids.containsKey(v.path)).length;
  d._figmaKey = (c) {
    final v = figma.byId[fd.ids[c.path]]!;
    return '${v.collection}|${v.name}';
  };

  for (final c in fd.changes) {
    if (c.kind == ChangeKind.renamed) {
      d.breaking.add(c);
      continue;
    }
    final b = baseChanges[_key(c)];

    if (d.firstSync) {
      // No base: an addition is safe, a disagreement needs a person.
      if (c.kind == ChangeKind.added) {
        d.adopt.add(c);
      } else {
        d.conflicts.add(SyncConflict(c));
      }
      continue;
    }

    switch (c.kind) {
      case ChangeKind.removed:
        // Figma deleted a token the last sync saw.
        if (b == null && c.isBreaking) {
          d.breaking.add(c);
        } else if (b == null) {
          d.adopt.add(c);
        } else {
          d.conflicts.add(SyncConflict(c));
        }
      case ChangeKind.added:
        if (!baseIds.containsKey(c.path)) {
          d.adopt.add(c); // new in Figma
        } else if (b != null && _figmaSide(b) == _figmaSide(c)) {
          d.deleteInFigma
              .add(d._figmaKey!(c)); // deleted in code, untouched in Figma
        } else {
          d.conflicts.add(SyncConflict(c));
        }
      default:
        if (b == null) {
          d.adopt.add(c); // code unchanged since the last sync: Figma changed
        } else if (_figmaSide(b) == _figmaSide(c)) {
          d.codeWins++; // Figma unchanged since the last sync: code changed
        } else {
          d.conflicts.add(SyncConflict(c));
        }
    }
  }
  return d;
}

/// One line per change for the terminal and the plugin.
List<String> describeDecision(SyncDecision d) => [
      for (final c in d.adopt)
        'From Figma: ${c.describe().replaceAll(RegExp(r'\s+'), ' ')}',
      if (d.codeWins > 0) 'To Figma: ${d.codeWins} change(s) made in code',
      if (d.newInCode > 0) 'To Figma: ${d.newInCode} new token(s) from code',
      for (final k in d.deleteInFigma)
        'To Figma: delete ${k.replaceFirst('|', ': ')}',
    ];
