import 'dart:typed_data';

import '../config.dart';
import '../errors.dart';
import '../loader.dart';
import '../names.dart';
import 'plan.dart';
import 'snapshot.dart';

enum ChangeKind { added, removed, renamed, value, description, deprecation }

/// One difference between Figma and the token files, with what the token
/// files need to become to match Figma.
class TokenChange {
  TokenChange({
    required this.kind,
    required this.level,
    required this.path,
    this.mode,
    this.before,
    this.after,
    this.tokenType,
    this.jsonValues = const {},
    this.description,
    this.deprecated,
    this.fromPath,
    this.wasDeprecated = false,
  });

  final ChangeKind kind;
  final Level level;
  final String path;

  /// Theme for a semantic value change; null for single-mode levels.
  final String? mode;

  /// Display text for the report.
  final String? before;
  final String? after;

  /// For [ChangeKind.added].
  final String? tokenType;

  /// Theme (or null) -> new JSON `$value`.
  final Map<String?, Object> jsonValues;

  /// New `$description` (null = none).
  final String? description;

  /// New `$deprecated` (null = not deprecated).
  final Object? deprecated;

  /// For [ChangeKind.renamed]: the old path.
  final String? fromPath;

  /// For [ChangeKind.removed]: the token was already deprecated.
  final bool wasDeprecated;

  /// Removing (or renaming) a token that was not deprecated breaks code.
  bool get isBreaking =>
      kind == ChangeKind.renamed ||
      (kind == ChangeKind.removed && !wasDeprecated);

  String describe() {
    final where = '${level.name}: $path${mode == null ? '' : ' ($mode)'}';
    return switch (kind) {
      ChangeKind.added => 'ADD     $where = $after',
      ChangeKind.removed =>
        'REMOVE  $where${wasDeprecated ? ' (was deprecated)' : ' — not deprecated first'}',
      ChangeKind.renamed => 'RENAME  ${level.name}: $fromPath -> $path',
      ChangeKind.value => 'CHANGE  $where: $before -> $after',
      ChangeKind.description =>
        'DOC     $where: "${before ?? ''}" -> "${after ?? ''}"',
      ChangeKind.deprecation =>
        after == null ? 'UNDEPRECATE $where' : 'DEPRECATE   $where: $after',
    };
  }
}

class SnapshotDiff {
  SnapshotDiff(this.changes, this.warnings, this.ids);

  final List<TokenChange> changes;
  final List<String> warnings;

  /// Token path -> Figma variable id, for every synced variable.
  final Map<String, String> ids;

  List<TokenChange> get breaking => changes.where((c) => c.isBreaking).toList();
}

/// Compares a full snapshot (plugin export or Variables API) with the plan
/// built from the token files. [knownIds] is the last pull's path -> id map,
/// used to tell a rename from an unrelated add + remove.
SnapshotDiff diffSnapshot(TokenlineConfig config, TokenModel model,
    FigmaPlan plan, FigmaSnapshot snapshot,
    {Map<String, String> knownIds = const {}}) {
  final figma = config.figma!;
  final warnings = <String>[];

  // ---- collections and modes ------------------------------------------
  final modeFor =
      <Level, Map<String?, String>>{}; // level -> token mode -> figma mode
  final missing = <Level>{};
  for (final MapEntry(key: level, value: name) in figma.collections.entries) {
    final c = snapshot.collectionNamed(name);
    if (c == null) {
      final count = plan.variables.where((v) => v.level == level).length;
      warnings.add('Figma has no collection "$name" yet — $count '
          '${level.name} token(s) not compared; run push to create it');
      missing.add(level);
      continue;
    }
    if (level == Level.semantic) {
      final map = <String?, String>{};
      for (final MapEntry(key: mode, value: figmaMode) in figma.modes.entries) {
        if (!c.modes.contains(figmaMode)) {
          throw TokenlineException('collection "$name" has no mode '
              '"$figmaMode" (it has: ${c.modes.join(', ')})');
        }
        map[mode] = figmaMode;
      }
      final extra = c.modes.where((m) => !figma.modes.containsValue(m));
      if (extra.isNotEmpty) {
        warnings.add('collection "$name" has mode(s) ${extra.join(', ')} '
            'that are not in tokens.modes — ignored');
      }
      modeFor[level] = map;
    } else {
      final wanted =
          level == Level.primitives ? figma.primitiveMode : figma.componentMode;
      if (c.modes.length > 1) {
        warnings.add('collection "$name" should have one mode, has '
            '${c.modes.join(', ')} — reading "${c.modes.contains(wanted) ? wanted : c.modes.first}"');
      }
      modeFor[level] = {
        null: c.modes.contains(wanted) ? wanted : c.modes.first
      };
    }
  }

  if (missing.length == figma.collections.length) {
    throw TokenlineException('Figma file has none of the collections in '
        'tokenline.yaml (it has: ${snapshot.collections.map((c) => c.name).join(', ')}). '
        'Check figma.collections, or run push first.');
  }

  // ---- index Figma variables by token path -----------------------------
  // Known names map through the plan, so a token whose path does not
  // survive the name round trip (kebab keys, capitals) is still itself.
  final planPath = {for (final v in plan.variables) (v.level, v.name): v.path};
  String pathOf(FigmaVariable v, Level level) =>
      planPath[(level, v.name)] ??
      pathForFigmaName(v.name, level, figma.nameCase,
          isColor: v.type == FigmaType.color);
  final byKey = <(Level, String), FigmaVariable>{};
  final pathOfId = <String, String>{};
  for (final v in snapshot.variables) {
    final level = figma.levelForCollection(v.collection);
    if (level == null || isDraftName(v.name)) continue;
    if (v.type == FigmaType.boolean) {
      warnings.add(
          '${v.collection}: ${v.name} is a boolean — booleans do not sync');
      continue;
    }
    final path = pathOf(v, level);
    final clash = byKey[(level, path)];
    if (clash != null) {
      throw TokenlineException('Figma variables "${clash.name}" and '
          '"${v.name}" in ${v.collection} both map to token $path — rename one');
    }
    byKey[(level, path)] = v;
    pathOfId[v.id] = path;
  }

  // ---- value conversion -------------------------------------------------
  String targetPathOf(FigmaAlias a, FigmaVariable from) {
    final target = snapshot.byId[a.id];
    if (target == null) {
      throw TokenlineException('${from.collection}: ${from.name} links to a '
          'variable outside this file (${a.name ?? a.id}); link to a local variable');
    }
    final level = figma.levelForCollection(target.collection);
    if (level == null || isDraftName(target.name)) {
      throw TokenlineException('${from.collection}: ${from.name} links to '
          '${target.collection}: ${target.name}, which does not sync '
          '(a draft, or a collection not in tokenline.yaml)');
    }
    return pathOfId[target.id]!;
  }

  /// Follows aliases to a typed value (used where links are not kept).
  FigmaRaw resolveRaw(FigmaVariable v, String mode, [int depth = 0]) {
    if (depth > 16) throw TokenlineException('alias loop at ${v.name}');
    final value = v.values[mode];
    if (value == null) {
      throw TokenlineException(
          '${v.collection}: ${v.name} has no value in mode "$mode"');
    }
    if (value is FigmaRaw) return value;
    final alias = value as FigmaAlias;
    final target = snapshot.byId[alias.id] ??
        (throw TokenlineException('${v.name} links outside this file'));
    final targetLevel = figma.levelForCollection(target.collection);
    final targetMode = targetLevel == null
        ? target.values.keys.first
        : (modeFor[targetLevel]![targetLevel == Level.semantic
                ? _tokenModeOf(modeFor[Level.semantic]!, mode)
                : null] ??
            target.values.keys.first);
    return resolveRaw(target, targetMode, depth + 1);
  }

  /// Figma value -> (display text, JSON `$value`).
  (String, Object) jsonOf(FigmaVariable v, String mode, String tokenType,
      {required bool keepLinks}) {
    final value = v.values[mode];
    if (value == null) {
      throw TokenlineException(
          '${v.collection}: ${v.name} has no value in mode "$mode"');
    }
    if (value is FigmaAlias && keepLinks) {
      final target = targetPathOf(value, v);
      return ('{$target}', '{$target}');
    }
    final raw = value is FigmaRaw ? value : resolveRaw(v, mode);
    final json =
        jsonValueFor(tokenType, raw.value, where: '${v.collection}: ${v.name}');
    return ('$json', json);
  }

  // ---- compare ----------------------------------------------------------
  final changes = <TokenChange>[];
  final ids = <String, String>{};
  for (final MapEntry(key: key, value: v) in byKey.entries) {
    final (level, path) = key;
    ids[path] = v.id;
    final keepLinks = level != Level.primitives;
    final (deprecation, plain) = splitDescription(v.description);
    final deprecated = deprecation == null
        ? null
        : deprecatedJsonFor(deprecation, v, snapshot, figma, pathOf);
    final planned = plan.byKey[key];

    if (planned == null) {
      final type = inferTokenType(path, v.type, model);
      final values = <String?, Object>{};
      var display = '';
      for (final MapEntry(key: mode, value: figmaMode)
          in modeFor[level]!.entries) {
        final (text, json) = jsonOf(v, figmaMode, type, keepLinks: keepLinks);
        values[mode] = json;
        display +=
            mode == null ? text : '${display.isEmpty ? '' : ', '}$mode $text';
      }
      changes.add(TokenChange(
          kind: ChangeKind.added,
          level: level,
          path: path,
          after: display,
          tokenType: type,
          jsonValues: values,
          description: plain.isEmpty ? null : plain,
          deprecated: deprecated));
      continue;
    }

    if (figmaTypeFor(planned.tokenType) != v.type) {
      throw TokenlineException('${v.collection}: ${v.name} is a ${v.type} '
          'variable but token $path is ${planned.tokenType}; change the '
          'type back, or delete it and create a new token');
    }
    for (final MapEntry(key: mode, value: figmaMode)
        in modeFor[level]!.entries) {
      // Single-mode collections: one planned value, whatever the mode's name.
      final want = level == Level.semantic
          ? planned.values[figmaMode]
          : planned.values.values.firstOrNull;
      if (want == null) continue;
      final (text, json) =
          jsonOf(v, figmaMode, planned.tokenType, keepLinks: keepLinks);
      if (!_same(want, json)) {
        changes.add(TokenChange(
            kind: ChangeKind.value,
            level: level,
            path: path,
            mode: mode,
            before: '$want',
            after: text,
            jsonValues: {mode: json}));
      }
    }
    // An empty Figma description never erases one written in the token
    // files (older pushes did not send descriptions).
    if (plain.isNotEmpty && plain != planned.description) {
      changes.add(TokenChange(
          kind: ChangeKind.description,
          level: level,
          path: path,
          before: planned.description,
          after: plain,
          description: plain.isEmpty ? null : plain));
    }
    if (deprecation != planned.deprecation) {
      changes.add(TokenChange(
          kind: ChangeKind.deprecation,
          level: level,
          path: path,
          before: planned.deprecation,
          after: deprecation,
          deprecated: deprecated));
    }
  }

  // Missing from Figma counts as removed only if an earlier pull saw it
  // there; otherwise it simply has not been pushed yet.
  final notPushed = <String>[];
  for (final planned in plan.variables) {
    if (missing.contains(planned.level)) continue;
    if (byKey.containsKey((planned.level, planned.path))) continue;
    if (!knownIds.containsKey(planned.path)) {
      notPushed.add(planned.path);
      continue;
    }
    changes.add(TokenChange(
        kind: ChangeKind.removed,
        level: planned.level,
        path: planned.path,
        wasDeprecated: planned.deprecation != null));
  }

  if (notPushed.isNotEmpty) {
    warnings.add('${notPushed.length} token(s) are not in Figma yet — run push '
        'to create them: ${notPushed.take(6).join(', ')}${notPushed.length > 6 ? ', …' : ''}');
  }

  // An added variable whose id was a removed token's id is a rename.
  final removedById = {
    for (final c in changes)
      if (c.kind == ChangeKind.removed && knownIds[c.path] != null)
        knownIds[c.path]!: c,
  };
  final renames = <TokenChange>[];
  for (final added
      in changes.where((c) => c.kind == ChangeKind.added).toList()) {
    final removed = removedById[ids[added.path]];
    if (removed == null || removed.level != added.level) continue;
    // Keep the old token's type; re-read the values with it.
    final type = plan.byKey[(removed.level, removed.path)]?.tokenType ??
        added.tokenType!;
    final v = byKey[(added.level, added.path)]!;
    renames.add(TokenChange(
        kind: ChangeKind.renamed,
        level: added.level,
        path: added.path,
        fromPath: removed.path,
        tokenType: type,
        jsonValues: {
          for (final MapEntry(key: mode, value: figmaMode)
              in modeFor[added.level]!.entries)
            mode: jsonOf(v, figmaMode, type,
                    keepLinks: added.level != Level.primitives)
                .$2,
        },
        description: added.description,
        deprecated: added.deprecated));
    changes
      ..remove(added)
      ..remove(removed);
  }
  changes.addAll(renames);

  changes.sort((a, b) {
    final byPath = a.path.compareTo(b.path);
    return byPath != 0 ? byPath : (a.mode ?? '').compareTo(b.mode ?? '');
  });
  return SnapshotDiff(changes, warnings, ids);
}

String? _tokenModeOf(Map<String?, String> modes, String figmaMode) {
  for (final e in modes.entries) {
    if (e.value == figmaMode) return e.key;
  }
  return modes.keys.first;
}

bool _same(PlannedValue want, Object json) {
  if (want is PlannedAlias) return json == '{${want.targetPath}}';
  final w = (want as PlannedRaw).value;
  if (json is String && json.startsWith('{')) return false;
  return sameValue(w, json);
}

/// Loose equality for values that went through Figma (float noise, hex case,
/// opaque alpha).
bool sameValue(Object a, Object b) {
  num? asNum(Object o) {
    if (o is num) return o;
    if (o is String) {
      if (o.endsWith('ms')) return num.tryParse(o.substring(0, o.length - 2));
      return num.tryParse(o);
    }
    return null;
  }

  final an = asNum(a), bn = asNum(b);
  // Figma stores numbers as float32: equal there means equal.
  if (an != null && bn != null) return _f32(an) == _f32(bn);
  if (a is List || b is List) {
    final al = a is List
        ? a
        : '$a'.split(',').map((s) => num.tryParse(s.trim())).toList();
    final bl = b is List
        ? b
        : '$b'.split(',').map((s) => num.tryParse(s.trim())).toList();
    if (al.length != bl.length) return false;
    for (var i = 0; i < al.length; i++) {
      if (al[i] == null ||
          bl[i] == null ||
          !sameValue(al[i] as Object, bl[i] as Object)) {
        return false;
      }
    }
    return true;
  }
  String norm(Object o) {
    final s = '$o'.trim().toUpperCase();
    return s.length == 9 && s.startsWith('#') && s.endsWith('FF')
        ? s.substring(0, 7)
        : s;
  }

  return norm(a) == norm(b);
}

/// A value Figma stores -> the JSON `$value` for [tokenType].
Object jsonValueFor(String tokenType, Object value, {required String where}) {
  Never bad() => throw TokenlineException(
      '$where: value "$value" does not fit token type $tokenType');
  switch (tokenType) {
    case 'color':
      if (value is! String || !value.startsWith('#')) bad();
      final hex = value.toUpperCase();
      return hex.length == 9 && hex.endsWith('FF') ? hex.substring(0, 7) : hex;
    case 'dimension':
      if (value is! num) bad();
      return _numString(value);
    case 'number':
      if (value is! num) bad();
      return shortestFloat32(value);
    case 'fontWeight':
      if (value is! num) bad();
      final w = value.round();
      if (w < 100 || w > 900 || w % 100 != 0) {
        throw TokenlineException('$where: font weight $value must be 100–900 '
            'in steps of 100 (Flutter has no other FontWeight)');
      }
      return w;
    case 'duration':
      if (value is! num) bad();
      return '${value.round()}ms';
    case 'fontFamily':
      if (value is! String) bad();
      return value.trim();
    case 'cubicBezier':
      final parts =
          '$value'.split(',').map((s) => num.tryParse(s.trim())).toList();
      if (parts.length != 4 || parts.contains(null)) bad();
      return [for (final n in parts) shortestFloat32(n!)];
  }
  bad();
}

double _f32(num n) => (Float32List(1)..[0] = n.toDouble())[0];

/// The shortest decimal that is the same float32 as [n]: Figma's
/// 0.6000000238 -> 0.6, -0.0125 stays -0.0125; whole numbers become ints.
num shortestFloat32(num n) {
  if (n is int) return n;
  final f = _f32(n);
  if (f.isFinite && f == f.roundToDouble() && f.abs() < 1e15) return f.round();
  for (var p = 1; p <= 9; p++) {
    final d = double.parse(f.toStringAsPrecision(p));
    if (_f32(d) == f) return d;
  }
  return f;
}

String _numString(num n) => '${shortestFloat32(n)}';

/// Picks a token type for a variable that only exists in Figma.
String inferTokenType(String path, String figmaType, TokenModel model) {
  final parts = path.split('.');
  if (figmaType == FigmaType.color) return 'color';
  // A sibling's type is the best guess.
  final parent = parts.sublist(0, parts.length - 1).join('.');
  for (final set in [
    model.primitives,
    ...model.semantic.values,
    ...model.components.values,
  ]) {
    for (final t in set.tokens.values) {
      final tp = t.path.split('.');
      if (tp.sublist(0, tp.length - 1).join('.') == parent &&
          figmaTypeFor(t.type) == figmaType) {
        return t.type;
      }
    }
  }
  if (figmaType == FigmaType.string) {
    if (parts.contains('family')) return 'fontFamily';
    if (parts.contains('easing')) return 'cubicBezier';
    throw TokenlineException('string variable $path: only font families '
        '(font/family/...) and easing curves (motion/easing/...) sync');
  }
  if (parts.contains('weight')) return 'fontWeight';
  if (parts.contains('duration')) return 'duration';
  if (parts.any(const {'opacity', 'lineHeight', 'zIndex'}.contains)) {
    return 'number';
  }
  return 'dimension';
}

/// Splits a Figma description into its `@deprecated` line and the rest.
(String?, String) splitDescription(String description) {
  final lines = description.trim().split('\n');
  if (lines.first.trim().startsWith('@deprecated')) {
    return (lines.first.trim(), lines.skip(1).join('\n').trim());
  }
  return (null, description.trim());
}

/// `@deprecated → text/secondary` -> `Use color.text.secondary instead.`
Object deprecatedJsonFor(String line, FigmaVariable v, FigmaSnapshot snapshot,
    FigmaConfig figma, String Function(FigmaVariable, Level) pathOf) {
  final arrow = RegExp(r'^@deprecated\s*(?:→|->)\s*(.+)$').firstMatch(line);
  if (arrow != null) {
    final targetName = arrow[1]!.trim();
    final candidates = snapshot.variables
        .where((t) => t.name == targetName)
        .toList()
      ..sort((a, b) => (a.collection == v.collection ? 0 : 1)
          .compareTo(b.collection == v.collection ? 0 : 1));
    if (candidates.isNotEmpty) {
      final t = candidates.first;
      final level = figma.levelForCollection(t.collection);
      if (level != null) return 'Use ${pathOf(t, level)} instead.';
    }
    return 'Use $targetName instead.';
  }
  final rest =
      line.replaceFirst(RegExp(r'^@deprecated\s*[—\-:]*\s*'), '').trim();
  return rest.isEmpty ? true : rest;
}
