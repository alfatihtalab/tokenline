// Lint rules over a Figma snapshot. Mirrors lintSnapshot() in
// lib/src/figma/plugin_src/core.js rule for rule — the shared fixtures in
// test/fixtures/lint keep the two in step.
import '../config.dart';
import '../emit/layout.dart';
import '../figma/snapshot.dart';
import '../names.dart';

enum Severity { error, warning }

class LintIssue {
  LintIssue(this.code, this.severity, this.message, [this.variable]);

  final String code;
  final Severity severity;
  final String message;
  final FigmaVariable? variable;

  @override
  String toString() => '${severity.name}: $message [$code]';
}

final _camelSegment = RegExp(r'^[a-z0-9][a-zA-Z0-9]*$');
final _kebabSegment = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
final _deprecatedArrow = RegExp(r'^@deprecated\s*(?:→|->)\s*(.+)$');

List<LintIssue> lintSnapshot(
    FigmaSnapshot snapshot, FigmaConfig figma, LintConfig lint) {
  final issues = <LintIssue>[];
  void add(String code, Severity s, String message, [FigmaVariable? v]) =>
      issues.add(LintIssue(code, s, message, v));
  final segmentOk =
      figma.nameCase == NameCase.camel ? _camelSegment : _kebabSegment;
  final groups = lint.groups;

  for (final MapEntry(key: level, value: name) in figma.collections.entries) {
    final c = snapshot.collectionNamed(name);
    if (c == null) {
      add('collection-missing', Severity.error,
          'No collection "$name" (${level.name}).');
      continue;
    }
    if (level == Level.semantic) {
      for (final figmaMode in figma.modes.values) {
        if (!c.modes.contains(figmaMode)) {
          add('mode-missing', Severity.error,
              'Collection "$name" has no mode "$figmaMode".');
        }
      }
    }
  }

  final seenKeys = <String, String>{};
  for (final v in snapshot.variables) {
    final level = figma.levelForCollection(v.collection);
    if (level == null || isDraftName(v.name) || v.type == FigmaType.boolean) {
      continue;
    }
    final where = '${v.collection}: ${v.name}';

    final badSegment =
        v.name.split('/').where((s) => !segmentOk.hasMatch(s)).firstOrNull;
    if (badSegment != null) {
      add(
          'name-format',
          Severity.error,
          '$where — "$badSegment" should be ${figma.nameCase == NameCase.camel ? 'lowerCamelCase' : 'lowercase words joined by -'}, with / between parts.',
          v);
    }
    final path = pathForFigmaName(v.name, level, figma.nameCase,
        isColor: v.type == FigmaType.color);
    final first = path.split('.').first;
    if (level == Level.primitives &&
        v.type != FigmaType.color &&
        !groups.contains(first)) {
      add(
          'name-group',
          Severity.error,
          '$where — number and text primitives must start with one of: ${groups.join(', ')}.',
          v);
    }
    if (v.type == FigmaType.string &&
        !path.contains('.family.') &&
        !path.contains('.easing.')) {
      add(
          'type-group',
          Severity.error,
          '$where — text variables sync only as font/family/... or motion/easing/....',
          v);
    }
    final key =
        '${v.collection}|${path.replaceAll(RegExp(r'[.\-_]'), '').toLowerCase()}';
    final clash = seenKeys[key];
    if (clash != null) {
      add('name-collision', Severity.error,
          '$where and $clash become the same name in code.', v);
    } else {
      seenKeys[key] = v.name;
    }
    final dart = dartNameGuess(path, level);
    if (dartReservedWords.contains(dart)) {
      add('reserved-word', Severity.error,
          '$where becomes "$dart", a reserved word in Dart.', v);
    }

    final c = snapshot.collectionNamed(v.collection)!;
    final modes = level == Level.semantic
        ? figma.modes.values.where(c.modes.contains).toList()
        : [c.modes.first];
    for (final mode in modes) {
      final value = v.values[mode];
      if (value == null) {
        add('missing-value', Severity.error,
            '$where has no value in mode "$mode".', v);
        continue;
      }
      final alias = value is FigmaAlias ? value : null;
      final target = alias == null ? null : snapshot.byId[alias.id];
      final targetLevel =
          target == null ? null : figma.levelForCollection(target.collection);
      if (level == Level.primitives && alias != null) {
        add(
            'primitive-link',
            Severity.error,
            '$where links to another variable; primitives hold typed values only.',
            v);
      }
      if (level == Level.semantic) {
        if (alias == null) {
          add('semantic-raw', Severity.error,
              '$where ($mode) has a typed value; link it to a primitive.', v);
        } else if (targetLevel != Level.primitives) {
          add('semantic-link-target', Severity.error,
              '$where ($mode) must link to a primitive.', v);
        }
      }
      if (level == Level.components) {
        if (alias == null) {
          add('component-raw', Severity.error,
              '$where has a typed value; link it to a semantic token.', v);
        } else if (v.type == FigmaType.color && targetLevel != Level.semantic) {
          add('component-link-target', Severity.error,
              '$where is a color and must link to a semantic token.', v);
        } else if (targetLevel != Level.semantic &&
            targetLevel != Level.primitives) {
          add('component-link-target', Severity.error,
              '$where must link to a semantic token or a primitive.', v);
        }
      }
      if (target != null && isDraftName(target.name)) {
        add('draft-link', Severity.error,
            '$where links to draft ${target.name}.', v);
      }
      if (alias != null && target == null) {
        add('external-link', Severity.error,
            '$where links to a variable outside this file.', v);
      }
    }

    if (level == Level.primitives && figma.hidePrimitives) {
      if (v.scopes != null && v.scopes!.isNotEmpty) {
        add('primitive-scopes', Severity.warning,
            '$where appears in property pickers; Fix hides it.', v);
      }
      if (v.hiddenFromPublishing == false) {
        add('primitive-published', Severity.warning,
            '$where is published with the library; Fix hides it.', v);
      }
    }

    final firstLine = v.description.trim().split('\n').first;
    if (firstLine.startsWith('@deprecated')) {
      final m = _deprecatedArrow.firstMatch(firstLine);
      if (m == null) {
        add(
            'deprecated-format',
            Severity.warning,
            '$where is deprecated without a replacement; write "@deprecated → new/name".',
            v);
      } else {
        final targetName = m[1]!.trim();
        final exists = snapshot.variables
            .any((t) => t.name == targetName && !isDraftName(t.name));
        if (!exists) {
          add('deprecated-target', Severity.error,
              '$where points to "$targetName", which does not exist.', v);
        }
      }
    }
  }
  return issues;
}

/// The Dart member name a token gets in the default layout (best effort,
/// for lint only — the emitter is the source of truth).
String dartNameGuess(String path, Level level) {
  final parts = path
      .split('.')
      .skip(defaultDropFor(path, level))
      .map(kebabToCamel)
      .toList();
  if (parts.isEmpty) return '';
  final name = [
    for (var i = 0; i < parts.length; i++)
      i == 0
          ? parts[i][0].toLowerCase() + parts[i].substring(1)
          : parts[i][0].toUpperCase() + parts[i].substring(1),
  ].join();
  return RegExp(r'^[0-9]').hasMatch(name) ? 'v$name' : name;
}
