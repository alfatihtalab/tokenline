import 'dart:io';

import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../errors.dart';
import '../loader.dart';
import '../names.dart';
import '../tokens.dart';
import 'layout.dart';

/// One generated file.
class GeneratedFile {
  GeneratedFile(this.path, this.content);

  /// Relative to the project root.
  final String path;
  final String content;
}

/// Where a token ended up in the generated code.
class DartRef {
  const DartRef(this.className, this.member);

  final String className;
  final String member;
}

class EmitResult {
  EmitResult(this.files, this.refs, this.skipped);

  final List<GeneratedFile> files;

  /// Token path -> its first generated constant.
  final Map<String, DartRef> refs;

  /// Tokens no class picked up (e.g. a semantic dimension).
  final List<String> skipped;
}

/// Turns the token model into formatted Dart source.
EmitResult emit(TokenlineConfig config, TokenModel model,
    {List<FileSpec>? layout}) {
  final files = <GeneratedFile>[];
  final refs = <String, DartRef>{};
  final emitted = <String>{};
  final header = generatedHeader(config);

  for (final file in layout ?? defaultLayout(config, model)) {
    final classes = <String>[];
    final used = <String>{};
    for (final spec in file.classes) {
      final source =
          _emitClass(spec, _setFor(model, spec), used, (path, member) {
        emitted.add(path);
        refs.putIfAbsent(path, () => DartRef(spec.name, member));
      });
      if (source != null) classes.add(source);
    }
    if (classes.isEmpty) continue;

    final b = StringBuffer()
      ..write(header)
      ..writeln();
    final import = _importFor(used);
    if (import != null) {
      b
        ..writeln("import '$import';")
        ..writeln();
    }
    b.write(classes.join('\n'));
    files.add(GeneratedFile(p.join(config.flutter.outputDir, file.fileName),
        formatDart(b.toString(), file.fileName, root: config.root)));
  }

  final all = [
    ...model.primitives.tokens.keys,
    for (final s in model.semantic.values) ...s.tokens.keys,
    for (final s in model.components.values) ...s.tokens.keys,
  ];
  final skipped = {
    for (final k in all)
      if (!emitted.contains(k)) k
  }.toList()
    ..sort();
  return EmitResult(files, refs, skipped);
}

String generatedHeader(TokenlineConfig config) => '''
// GENERATED CODE — DO NOT MODIFY BY HAND.
// Source: ${config.tokens.dir}/  (${config.name} v${config.version})
// Run: ${config.flutter.runCommand}
''';

TokenSet _setFor(TokenModel model, ClassSpec spec) => switch (spec.level) {
      Level.primitives => model.primitives,
      Level.semantic => model.semantic[spec.mode]!,
      Level.components => model.components[spec.mode]!,
    };

String? _emitClass(ClassSpec spec, TokenSet set, Set<String> usedTypes,
    void Function(String path, String member) onEmit) {
  final members = <Token>[];
  final seenPaths = <String>{};
  for (final prefix in spec.prefixes) {
    for (final t in set.byPrefix(prefix)) {
      if (spec.types.contains(t.type) && seenPaths.add(t.path)) members.add(t);
    }
  }
  if (members.isEmpty) return null;

  final b = StringBuffer();
  if (spec.doc != null) {
    for (final line in spec.doc!.trimRight().split('\n')) {
      b.writeln('/// $line'.trimRight());
    }
  }
  b.writeln('abstract final class ${spec.name} {');
  final ids = <String, String>{};
  final radiusIds = <String>[];
  for (final t in members) {
    final id = dartName(t.path, dropPrefixSegments: spec.drop);
    final clash = ids[id];
    if (clash != null) {
      throw TokenlineException(
          '${t.path} and $clash both become ${spec.name}.$id — rename one');
    }
    ids[id] = t.path;
    if (t.description != null) {
      for (final line in t.description!.trim().split('\n')) {
        b.writeln('  /// $line'.trimRight());
      }
    }
    if (t.isDeprecated) {
      b.writeln('  @Deprecated(${_dartString(t.deprecationMessage!)})');
    }
    final (type, value) = _member(t);
    usedTypes.add(type);
    b.writeln('  static const $type $id = $value;');
    if (spec.radiusHelpers) radiusIds.add(id);
    onEmit(t.path, id);
  }
  if (radiusIds.isNotEmpty) {
    usedTypes.add('BorderRadius');
    b.writeln();
    for (final id in radiusIds) {
      b.writeln('  static const BorderRadius ${id}Br = '
          'BorderRadius.all(Radius.circular($id));');
    }
  }
  b.writeln('}');
  return b.toString();
}

(String, String) _member(Token t) {
  final v = t.resolved;
  return switch (t.type) {
    'color' => ('Color', colorToDart(v as String)),
    'dimension' => ('double', '${double.parse(v as String)}'),
    'number' => ('double', '${(v as num).toDouble()}'),
    'fontFamily' => ('String', _dartString(v as String)),
    'fontWeight' => ('FontWeight', 'FontWeight.w$v'),
    'duration' => (
        'Duration',
        'Duration(milliseconds: ${int.parse((v as String).replaceAll('ms', ''))})'
      ),
    'cubicBezier' => ('Curve', 'Cubic(${(v as List).join(', ')})'),
    'shadow' => ('List<BoxShadow>', _shadow(v as Map<Object?, Object?>)),
    _ => throw TokenlineException('cannot emit type ${t.type} (${t.path})'),
  };
}

String _shadow(Map<Object?, Object?> v) => '[BoxShadow('
    'color: ${colorToDart(v['color'] as String)}, '
    'offset: Offset(${v['offsetX']}, ${v['offsetY']}), '
    'blurRadius: ${v['blur']}, spreadRadius: ${v['spread']})]';

String? _importFor(Set<String> used) {
  const widgets = {'Color', 'List<BoxShadow>', 'BorderRadius', 'FontWeight'};
  if (used.any(widgets.contains)) return 'package:flutter/widgets.dart';
  if (used.contains('Curve')) return 'package:flutter/animation.dart';
  return null;
}

String _dartString(String s) =>
    "'${s.replaceAll(r'\', r'\\').replaceAll("'", r"\'").replaceAll(r'$', r'\$')}'";

/// `#RRGGBB` / `#RRGGBBAA` -> `Color(0xAARRGGBB)`.
String colorToDart(String hex) {
  final h = hex.substring(1);
  final argb = h.length == 8 ? h.substring(6) + h.substring(0, 6) : 'FF$h';
  return 'Color(0x${argb.toUpperCase()})';
}

final _formatters = <String, DartFormatter>{};

/// A formatter that matches `dart format` in the project at [root]: its
/// language version comes from the pubspec's SDK constraint and its page
/// width from analysis_options.yaml. Output then never depends on which
/// Dart SDK runs tokenline, and `dart format` leaves generated files alone.
DartFormatter formatterFor(String root) => _formatters.putIfAbsent(root, () {
      var version = DartFormatter.latestLanguageVersion;
      final pubspec = File(p.join(root, 'pubspec.yaml'));
      if (pubspec.existsSync()) {
        try {
          final sdk = ((loadYaml(pubspec.readAsStringSync())
              as Map?)?['environment'] as Map?)?['sdk'];
          final constraint =
              sdk is String ? VersionConstraint.parse(sdk) : null;
          final min = constraint is VersionRange ? constraint.min : null;
          if (min != null) {
            final v = Version(min.major, min.minor, 0);
            if (v < version) version = v;
          }
        } on Object {
          // Unreadable pubspec: keep the latest style.
        }
      }
      int? pageWidth;
      final options = File(p.join(root, 'analysis_options.yaml'));
      if (options.existsSync()) {
        try {
          final width = ((loadYaml(options.readAsStringSync())
              as Map?)?['formatter'] as Map?)?['page_width'];
          if (width is int) pageWidth = width;
        } on Object {
          // Unreadable options: default width.
        }
      }
      return DartFormatter(languageVersion: version, pageWidth: pageWidth);
    });

/// Formats generated source as `dart format` would in the project.
String formatDart(String source, String name, {required String root}) {
  try {
    return formatterFor(root).format(source, uri: name);
  } on FormatterException catch (e) {
    throw TokenlineException(
        'generated $name is not valid Dart (bug in tokenline):\n${e.message()}');
  }
}
