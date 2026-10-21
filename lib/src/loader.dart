import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'errors.dart';
import 'names.dart';
import 'tokens.dart';

/// All tokens of a project, loaded, resolved and validated.
class TokenModel {
  TokenModel._({
    required this.primitiveFiles,
    required this.componentFiles,
    required this.primitives,
    required this.semantic,
    required this.components,
  });

  /// Primitive files, relative to the tokens directory, in load order.
  final List<String> primitiveFiles;
  final List<String> componentFiles;

  /// Primitives only (single mode).
  final TokenSet primitives;

  /// Theme -> semantic tokens only, resolved against the primitives.
  final Map<String, TokenSet> semantic;

  /// Theme -> component tokens only, resolved through that theme.
  final Map<String, TokenSet> components;

  List<String> get modes => semantic.keys.toList();

  /// Loads every token file named in [config].
  static TokenModel load(TokenlineConfig config) {
    final dir = config.resolve(config.tokens.dir);
    if (!Directory(dir).existsSync()) {
      throw TokenlineException('tokens directory not found: $dir');
    }
    final primitiveFiles = expandPatterns(dir, config.tokens.primitives);
    final componentFiles = expandPatterns(dir, config.tokens.components);

    TokenSet withPrimitives() {
      final s = TokenSet();
      for (final f in primitiveFiles) {
        s.addFile(f, root: dir);
      }
      return s;
    }

    final base = withPrimitives()
      ..resolve()
      ..validateValues();

    final semantic = <String, TokenSet>{};
    final components = <String, TokenSet>{};
    for (final MapEntry(key: mode, value: file) in config.tokens.modes.entries) {
      final withSemantic = withPrimitives()..addFile(file, root: dir);
      withSemantic
        ..resolve()
        ..validateValues();
      semantic[mode] = _only(withSemantic, (t) => t.source == file);

      if (componentFiles.isNotEmpty) {
        final all = withPrimitives()..addFile(file, root: dir);
        for (final f in componentFiles) {
          all.addFile(f, root: dir);
        }
        all
          ..resolve()
          ..validateValues();
        final compSources = componentFiles.toSet();
        components[mode] = _only(all, (t) => compSources.contains(t.source));
      }
    }

    if (config.tokens.modes.isEmpty && componentFiles.isNotEmpty) {
      final all = withPrimitives();
      for (final f in componentFiles) {
        all.addFile(f, root: dir);
      }
      all
        ..resolve()
        ..validateValues();
      final compSources = componentFiles.toSet();
      components['base'] = _only(all, (t) => compSources.contains(t.source));
    }

    _checkModesMatch(semantic);
    return TokenModel._(
      primitiveFiles: primitiveFiles,
      componentFiles: componentFiles,
      primitives: base,
      semantic: semantic,
      components: components,
    );
  }

  static TokenSet _only(TokenSet from, bool Function(Token) keep) {
    final s = TokenSet();
    for (final t in from.tokens.values) {
      if (keep(t)) s.tokens[t.path] = t;
    }
    return s;
  }

  /// Every theme must define exactly the same semantic tokens.
  static void _checkModesMatch(Map<String, TokenSet> semantic) {
    if (semantic.length < 2) return;
    final first = semantic.entries.first;
    final firstKeys = first.value.tokens.keys.toSet();
    for (final e in semantic.entries.skip(1)) {
      final keys = e.value.tokens.keys.toSet();
      final missingHere = firstKeys.difference(keys);
      final extraHere = keys.difference(firstKeys);
      if (missingHere.isNotEmpty || extraHere.isNotEmpty) {
        throw TokenlineException('themes differ — '
            '${missingHere.isEmpty ? '' : 'missing in ${e.key}: ${missingHere.join(', ')}; '}'
            '${extraHere.isEmpty ? '' : 'missing in ${first.key}: ${extraHere.join(', ')}'}');
      }
    }
  }

  /// Which level a token path belongs to, or null if unknown.
  Level? levelOf(String path) {
    if (primitives.tokens.containsKey(path)) return Level.primitives;
    if (semantic.values.any((s) => s.tokens.containsKey(path))) {
      return Level.semantic;
    }
    if (components.values.any((s) => s.tokens.containsKey(path))) {
      return Level.components;
    }
    return null;
  }
}

/// Expands file patterns relative to [dir]. `*` matches inside one path
/// segment; matches are sorted so output never depends on the file system.
List<String> expandPatterns(String dir, List<String> patterns) {
  final out = <String>[];
  for (final pattern in patterns) {
    if (!pattern.contains('*')) {
      if (!File(p.join(dir, pattern)).existsSync()) {
        throw TokenlineException('missing token file: ${p.join(dir, pattern)}');
      }
      if (!out.contains(pattern)) out.add(pattern);
      continue;
    }
    final segments = p.posix.split(pattern);
    final re = RegExp('^${segments.map(_segmentRegex).join('/')}\$');
    final matches = Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => p.posix.joinAll(p.split(p.relative(f.path, from: dir))))
        .where(re.hasMatch)
        .toList()
      ..sort();
    if (matches.isEmpty) {
      throw TokenlineException('no token files match "$pattern" in $dir');
    }
    for (final m in matches) {
      if (!out.contains(m)) out.add(m);
    }
  }
  return out;
}

String _segmentRegex(String segment) =>
    segment.split('*').map(RegExp.escape).join('[^/]*');
