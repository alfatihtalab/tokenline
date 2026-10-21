import 'dart:convert';
import 'dart:io';

import '../errors.dart';

/// Figma's variables at one moment, in one shape whatever the source
/// (plugin export, Variables REST API). This is also the file format the
/// Tokenline plugin exports.
class FigmaSnapshot {
  FigmaSnapshot({
    required this.source,
    required this.collections,
    required this.variables,
    this.fileKey,
    this.fileName,
    this.exportedAt,
  });

  static const format = 'tokenline.figma-snapshot';
  static const formatVersion = 1;

  /// `plugin` or `variables-api`.
  final String source;
  final String? fileKey;
  final String? fileName;
  final String? exportedAt;
  final List<FigmaCollection> collections;
  final List<FigmaVariable> variables;

  FigmaCollection? collectionNamed(String name) {
    for (final c in collections) {
      if (c.name == name) return c;
    }
    return null;
  }

  late final Map<String, FigmaVariable> byId = {
    for (final v in variables) v.id: v,
  };

  factory FigmaSnapshot.fromJson(Map<String, Object?> json) {
    if (json['format'] != format) {
      throw TokenlineException('not a Tokenline Figma export '
          '(expected "format": "$format", got "${json['format']}")');
    }
    final version = json['version'];
    if (version is! int || version > formatVersion) {
      throw TokenlineException('export format version $version is newer than '
          'this tokenline understands ($formatVersion) — upgrade tokenline');
    }
    List<Map<String, Object?>> list(String key) =>
        ((json[key] as List?) ?? const []).cast<Map<String, Object?>>();
    return FigmaSnapshot(
      source: json['source'] as String? ?? 'plugin',
      fileKey: json['fileKey'] as String?,
      fileName: json['fileName'] as String?,
      exportedAt: json['exportedAt'] as String?,
      collections: [
        for (final c in list('collections')) FigmaCollection.fromJson(c)
      ],
      variables: [for (final v in list('variables')) FigmaVariable.fromJson(v)],
    );
  }

  static FigmaSnapshot readFile(String path) {
    final file = File(path);
    if (!file.existsSync()) throw TokenlineException('file not found: $path');
    try {
      return FigmaSnapshot.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
    } on FormatException catch (e) {
      throw TokenlineException('$path is not valid JSON: ${e.message}');
    } on TypeError {
      throw TokenlineException('$path is not a Tokenline Figma export');
    }
  }

  Map<String, Object?> toJson() => {
        'format': format,
        'version': formatVersion,
        'source': source,
        if (fileKey != null) 'fileKey': fileKey,
        if (fileName != null) 'fileName': fileName,
        if (exportedAt != null) 'exportedAt': exportedAt,
        'collections': [for (final c in collections) c.toJson()],
        'variables': [for (final v in variables) v.toJson()],
      };

  void writeFile(String path) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(toJson())}\n');
  }
}

class FigmaCollection {
  FigmaCollection(
      {required this.id,
      required this.name,
      required this.modes,
      this.hiddenFromPublishing = false});

  final String id;
  final String name;

  /// Mode names, in Figma's order.
  final List<String> modes;
  final bool hiddenFromPublishing;

  factory FigmaCollection.fromJson(Map<String, Object?> j) => FigmaCollection(
        id: j['id'] as String? ?? j['name'] as String,
        name: j['name'] as String,
        modes: (j['modes'] as List).cast<String>(),
        hiddenFromPublishing: j['hiddenFromPublishing'] as bool? ?? false,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'modes': modes,
        if (hiddenFromPublishing) 'hiddenFromPublishing': true,
      };
}

/// Figma variable types.
abstract final class FigmaType {
  static const color = 'COLOR';
  static const float = 'FLOAT';
  static const string = 'STRING';
  static const boolean = 'BOOLEAN';
}

class FigmaVariable {
  FigmaVariable({
    required this.id,
    required this.name,
    required this.collection,
    required this.type,
    required this.values,
    this.description = '',
    this.scopes,
    this.hiddenFromPublishing,
    this.codeSyntax = const {},
  });

  final String id;

  /// Slash name as shown in Figma, e.g. `text/primary`.
  final String name;

  /// Collection name.
  final String collection;

  /// One of [FigmaType].
  final String type;
  final String description;
  final List<String>? scopes;
  final bool? hiddenFromPublishing;
  final Map<String, String> codeSyntax;

  /// Mode name -> value.
  final Map<String, FigmaValue> values;

  factory FigmaVariable.fromJson(Map<String, Object?> j) => FigmaVariable(
        id: j['id'] as String,
        name: j['name'] as String,
        collection: j['collection'] as String,
        type: j['type'] as String,
        description: j['description'] as String? ?? '',
        scopes: (j['scopes'] as List?)?.cast<String>(),
        hiddenFromPublishing: j['hiddenFromPublishing'] as bool?,
        codeSyntax:
            ((j['codeSyntax'] as Map?) ?? const {}).cast<String, String>(),
        values: {
          for (final e in ((j['values'] as Map?) ?? const {}).entries)
            e.key as String: FigmaValue.fromJson(e.value),
        },
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'collection': collection,
        'type': type,
        if (description.isNotEmpty) 'description': description,
        if (scopes != null) 'scopes': scopes,
        if (hiddenFromPublishing != null)
          'hiddenFromPublishing': hiddenFromPublishing,
        if (codeSyntax.isNotEmpty) 'codeSyntax': codeSyntax,
        'values': {for (final e in values.entries) e.key: e.value.toJson()},
      };
}

/// A variable's value in one mode: a typed value or a link to a variable.
sealed class FigmaValue {
  const FigmaValue();

  factory FigmaValue.fromJson(Object? j) {
    if (j is Map && j['type'] == 'alias') {
      return FigmaAlias(j['id'] as String,
          name: j['name'] as String?, collection: j['collection'] as String?);
    }
    if (j is String || j is num || j is bool) return FigmaRaw(j!);
    throw TokenlineException('unexpected variable value in export: $j');
  }

  Object? toJson();
}

/// A typed value: `#RRGGBB[AA]` for colors, a number, a string or a bool.
class FigmaRaw extends FigmaValue {
  const FigmaRaw(this.value);

  final Object value;

  @override
  Object? toJson() => value;

  @override
  String toString() => '$value';
}

class FigmaAlias extends FigmaValue {
  const FigmaAlias(this.id, {this.name, this.collection});

  final String id;
  final String? name;
  final String? collection;

  @override
  Object? toJson() => {
        'type': 'alias',
        'id': id,
        if (name != null) 'name': name,
        if (collection != null) 'collection': collection,
      };

  @override
  String toString() =>
      '→ ${collection == null ? '' : '$collection:'}${name ?? id}';
}

/// Figma `{r, g, b, a}` (0..1) -> `#RRGGBB` or `#RRGGBBAA`.
String figmaColorToHex(Map<Object?, Object?> c) {
  String h(Object? n) => ((n as num) * 255)
      .round()
      .toRadixString(16)
      .padLeft(2, '0')
      .toUpperCase();
  final s = '#${h(c['r'])}${h(c['g'])}${h(c['b'])}';
  final a = c['a'] as num? ?? 1;
  return a < 1 ? '$s${h(a)}' : s;
}
