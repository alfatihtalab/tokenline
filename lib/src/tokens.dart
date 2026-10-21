import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// Token types tokenline understands (DTCG names).
const supportedTypes = {
  'color',
  'dimension',
  'number',
  'fontFamily',
  'fontWeight',
  'duration',
  'cubicBezier',
  'shadow',
};

/// One design token as written in a `.tokens.json` file.
class Token {
  Token(this.path, this.type, this.value,
      {this.description, this.deprecated, required this.source});

  /// Dot path, e.g. `color.neutral.900`.
  final String path;
  final String type;

  /// Raw value; may be an alias string like `{color.neutral.900}`.
  final Object? value;
  final String? description;

  /// DTCG `$deprecated`: `true` or a message.
  final Object? deprecated;

  /// File it came from, relative to the tokens directory.
  final String source;

  /// Value after following aliases (set by [TokenSet.resolve]).
  Object? resolved;

  bool get isAlias => value is String && _aliasPattern.hasMatch(value as String);

  String get aliasTarget => _aliasPattern.firstMatch(value as String)![1]!;

  bool get isDeprecated => deprecated != null && deprecated != false;

  String? get deprecationMessage => !isDeprecated
      ? null
      : deprecated is String
          ? deprecated as String
          : 'Deprecated token $path';
}

final _aliasPattern = RegExp(r'^\{([^{}]+)\}$');

/// A flat map of tokens from one or more files.
class TokenSet {
  final Map<String, Token> tokens = {};

  /// Loads [relPath] (relative to [root]) into this set.
  void addFile(String relPath, {required String root}) {
    final file = File(p.join(root, relPath));
    if (!file.existsSync()) {
      throw TokenlineException('missing token file: ${p.join(root, relPath)}');
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw TokenlineException('invalid JSON in $relPath: ${e.message}');
    }
    if (json is! Map<String, dynamic>) {
      throw TokenlineException('$relPath must contain a JSON object');
    }
    _walk(json, [], relPath, inheritedType: null);
  }

  void _walk(Map<String, dynamic> node, List<String> path, String source,
      {required String? inheritedType}) {
    // DTCG lets a group set `$type` for everything inside it.
    final groupType = node[r'$type'] as String? ?? inheritedType;
    if (node.containsKey(r'$value')) {
      final key = path.join('.');
      final type = groupType;
      if (type == null) {
        throw TokenlineException('token $key in $source has no \$type');
      }
      if (!supportedTypes.contains(type)) {
        throw TokenlineException(
            'unsupported \$type "$type" at $key in $source '
            '(supported: ${supportedTypes.join(', ')})');
      }
      final existing = tokens[key];
      if (existing != null) {
        throw TokenlineException(
            'duplicate token $key ($source and ${existing.source})');
      }
      tokens[key] = Token(key, type, node[r'$value'],
          description: node[r'$description'] as String?,
          deprecated: node[r'$deprecated'],
          source: source);
      return;
    }
    node.forEach((k, v) {
      if (k.startsWith(r'$')) return;
      if (v is! Map<String, dynamic>) {
        throw TokenlineException(
            'unexpected value at ${[...path, k].join('.')} in $source');
      }
      _walk(v, [...path, k], source, inheritedType: groupType);
    });
  }

  /// Follows aliases, detecting cycles and dangling references.
  void resolve() {
    Object? resolvePath(String path, List<String> stack) {
      final token = tokens[path];
      if (token == null) {
        throw TokenlineException('unresolved alias {$path} '
            '(referenced from ${stack.isEmpty ? '?' : stack.last})');
      }
      if (stack.contains(path)) {
        throw TokenlineException(
            'alias cycle: ${[...stack, path].join(' -> ')}');
      }
      if (token.resolved != null) return token.resolved;
      token.resolved = token.isAlias
          ? resolvePath(token.aliasTarget, [...stack, path])
          : token.value;
      return token.resolved;
    }

    for (final key in tokens.keys) {
      resolvePath(key, const []);
    }
  }

  /// Checks each resolved value against its type.
  void validateValues() {
    for (final t in tokens.values) {
      final v = t.resolved;
      Never fail(String why) =>
          throw TokenlineException('${t.path} (${t.source}): $why');
      switch (t.type) {
        case 'color':
          if (v is! String ||
              !RegExp(r'^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$').hasMatch(v)) {
            fail('color must be #RRGGBB or #RRGGBBAA, got $v');
          }
        case 'dimension':
          if (v is! String || double.tryParse(v) == null) {
            fail('dimension must be a numeric string (logical pixels), got $v');
          }
        case 'number':
          if (v is! num) fail('number expected, got $v');
        case 'fontWeight':
          if (v is! int || v < 100 || v > 900) {
            fail('fontWeight must be 100-900, got $v');
          }
        case 'fontFamily':
          if (v is! String || v.isEmpty) fail('fontFamily string expected');
        case 'duration':
          if (v is! String || !RegExp(r'^\d+ms$').hasMatch(v)) {
            fail('duration must be "<n>ms", got $v');
          }
        case 'cubicBezier':
          if (v is! List || v.length != 4 || v.any((e) => e is! num)) {
            fail('cubicBezier must be [x1, y1, x2, y2]');
          }
        case 'shadow':
          if (v is! Map ||
              !const {'color', 'offsetX', 'offsetY', 'blur', 'spread'}
                  .every(v.containsKey)) {
            fail('shadow must define color, offsetX, offsetY, blur, spread');
          }
      }
    }
  }

  /// Tokens whose path starts with [prefix], sorted by path.
  List<Token> byPrefix(String prefix) =>
      tokens.values.where((t) => t.path.startsWith(prefix)).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
}
