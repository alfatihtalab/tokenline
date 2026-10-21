import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../errors.dart';
import '../loader.dart';
import '../names.dart';
import 'diff.dart';

/// Rewrites the token files so they match Figma. Returns the changed files
/// (relative to the tokens directory).
///
/// Files keep their key order, indentation and trailing-newline style, so
/// the git diff shows only what Figma changed.
List<String> adoptChanges(
    TokenlineConfig config, TokenModel model, List<TokenChange> changes) {
  final files = _JsonFiles(config.resolve(config.tokens.dir));
  final modeFiles = config.tokens.modes;

  String sourceOf(Level level, String path, {String? mode}) {
    final token = switch (level) {
      Level.primitives => model.primitives.tokens[path],
      Level.semantic => model.semantic[mode ?? model.modes.first]?.tokens[path],
      Level.components => model.components.values.first.tokens[path],
    };
    if (token == null) {
      throw TokenlineException(
          'cannot find ${level.name} token $path in the token files');
    }
    return level == Level.semantic && mode != null
        ? modeFiles[mode]!
        : token.source;
  }

  /// Files that hold a token of [level] (all themes for semantic tokens).
  List<String> filesFor(Level level, String path) => level == Level.semantic
      ? modeFiles.values.toList()
      : [sourceOf(level, path)];

  String homeFor(Level level, String path) {
    final candidates =
        level == Level.primitives ? model.primitiveFiles : model.componentFiles;
    if (candidates.isEmpty) {
      throw TokenlineException('no ${level.name} token files to add $path to');
    }
    // The file that already holds the deepest part of the path wins.
    final parts = path.split('.');
    for (var depth = parts.length - 1; depth > 0; depth--) {
      final group = parts.sublist(0, depth);
      for (final f in candidates) {
        if (files.nodeAt(f, group) != null) return f;
      }
    }
    return candidates.first;
  }

  void addToken(TokenChange c) {
    final targets = c.level == Level.semantic
        ? {for (final e in modeFiles.entries) e.value: c.jsonValues[e.key]}
        : {homeFor(c.level, c.path): c.jsonValues[null]};
    for (final MapEntry(key: file, value: value) in targets.entries) {
      files.setToken(file, c.path.split('.'), {
        r'$type': c.tokenType,
        r'$value': value,
        if (c.description != null) r'$description': c.description,
        if (c.deprecated != null) r'$deprecated': c.deprecated,
      });
    }
  }

  void removeToken(Level level, String path) {
    for (final f in filesFor(level, path)) {
      files.remove(f, path.split('.'));
    }
  }

  for (final c in changes) {
    switch (c.kind) {
      case ChangeKind.value:
        final file = sourceOf(c.level, c.path, mode: c.mode);
        files.update(file, c.path.split('.'), r'$value', c.jsonValues[c.mode]);
      case ChangeKind.description:
        for (final f in filesFor(c.level, c.path)) {
          files.update(f, c.path.split('.'), r'$description', c.description);
        }
      case ChangeKind.deprecation:
        for (final f in filesFor(c.level, c.path)) {
          files.update(f, c.path.split('.'), r'$deprecated', c.deprecated);
        }
      case ChangeKind.added:
        addToken(c);
      case ChangeKind.removed:
        removeToken(c.level, c.path);
      case ChangeKind.renamed:
        removeToken(c.level, c.fromPath!);
        addToken(c);
    }
  }
  return files.save();
}

/// Lazily loaded token files with in-place edits.
class _JsonFiles {
  _JsonFiles(this.dir);

  final String dir;
  final Map<String, Map<String, Object?>> _json = {};
  final Map<String, bool> _trailingNewline = {};
  final Set<String> _dirty = {};

  Map<String, Object?> _load(String rel) => _json.putIfAbsent(rel, () {
        final text = File(p.join(dir, rel)).readAsStringSync();
        _trailingNewline[rel] = text.endsWith('\n');
        return jsonDecode(text) as Map<String, Object?>;
      });

  Map<String, Object?>? nodeAt(String rel, List<String> path) {
    Object? cur = _load(rel);
    for (final seg in path) {
      if (cur is! Map<String, Object?>) return null;
      cur = cur[seg];
    }
    return cur is Map<String, Object?> ? cur : null;
  }

  void update(String rel, List<String> path, String key, Object? value) {
    final node = nodeAt(rel, path);
    if (node == null || !node.containsKey(r'$value')) {
      throw TokenlineException('cannot find token ${path.join('.')} in $rel');
    }
    if (value == null) {
      if (node.remove(key) != null) _dirty.add(rel);
    } else if (node[key] != value) {
      node[key] = value;
      _dirty.add(rel);
    }
  }

  void setToken(String rel, List<String> path, Map<String, Object?> token) {
    var cur = _load(rel);
    for (final seg in path.sublist(0, path.length - 1)) {
      final next = cur.putIfAbsent(seg, () => <String, Object?>{});
      if (next is! Map<String, Object?> || next.containsKey(r'$value')) {
        throw TokenlineException(
            'cannot add ${path.join('.')} in $rel: $seg is a token, not a group');
      }
      cur = next;
    }
    if (cur.containsKey(path.last)) {
      throw TokenlineException('${path.join('.')} already exists in $rel');
    }
    cur[path.last] = token;
    _dirty.add(rel);
  }

  void remove(String rel, List<String> path) {
    final chain = <Map<String, Object?>>[_load(rel)];
    for (final seg in path.sublist(0, path.length - 1)) {
      final next = chain.last[seg];
      if (next is! Map<String, Object?>) return;
      chain.add(next);
    }
    if (chain.last.remove(path.last) == null) return;
    _dirty.add(rel);
    // Drop groups left with no tokens or subgroups.
    for (var i = chain.length - 1; i > 0; i--) {
      if (chain[i].keys.any((k) => !k.startsWith(r'$'))) break;
      chain[i - 1].remove(path[i - 1]);
    }
  }

  List<String> save() {
    for (final rel in _dirty) {
      final text = const JsonEncoder.withIndent('  ').convert(_json[rel]);
      File(p.join(dir, rel))
          .writeAsStringSync(_trailingNewline[rel]! ? '$text\n' : text);
    }
    return _dirty.toList()..sort();
  }
}
