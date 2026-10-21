import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'errors.dart';
import 'names.dart';

const configFileName = 'tokenline.yaml';

/// Everything tokenline needs to know about one project, read from
/// `tokenline.yaml` at the project root.
class TokenlineConfig {
  TokenlineConfig({
    required this.root,
    required this.name,
    required this.version,
    required this.tokens,
    required this.flutter,
    required this.figma,
    required this.icons,
    required this.lint,
  });

  /// Absolute project root; every relative path below resolves against it.
  final String root;

  /// Shown in generated file headers, e.g. `rezme-design-tokens`.
  final String name;
  final String version;
  final TokensConfig tokens;
  final FlutterConfig flutter;
  final FigmaConfig? figma;
  final IconsConfig? icons;
  final LintConfig lint;

  String resolve(String relative) => p.normalize(p.join(root, relative));

  /// Reads `tokenline.yaml` from [root] (or [configPath] when given).
  static TokenlineConfig load({String? root, String? configPath}) {
    final file = File(configPath ?? p.join(root ?? '.', configFileName));
    if (!file.existsSync()) {
      throw TokenlineException('no ${p.basename(file.path)} in '
          '${p.absolute(file.parent.path)} — run `dart run tokenline init` '
          'to create one');
    }
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on YamlException catch (e) {
      throw TokenlineException('${file.path}: ${e.message}');
    }
    if (doc is! YamlMap) {
      throw TokenlineException('${file.path} must be a YAML map');
    }
    return TokenlineConfig.fromMap(_plain(doc) as Map<String, Object?>,
        root: p.normalize(p.absolute(root ?? file.parent.path)));
  }

  factory TokenlineConfig.fromMap(Map<String, Object?> m,
      {required String root}) {
    final r = _Reader(m, '');
    final tokens = TokensConfig._(r.map('tokens'));
    final flutter = FlutterConfig._(r.map('flutter'));
    final figmaMap = r.mapOrNull('figma');
    final iconsMap = r.mapOrNull('icons');
    final config = TokenlineConfig(
      root: root,
      name: r.string('name', fallback: 'design-tokens'),
      version: r.string('version', fallback: '0.0.0'),
      tokens: tokens,
      flutter: flutter,
      figma: figmaMap == null ? null : FigmaConfig._(figmaMap, tokens),
      icons: iconsMap == null ? null : IconsConfig._(iconsMap, flutter),
      lint: LintConfig._(r.map('lint')),
    );
    r.rejectUnknown(
        {'name', 'version', 'tokens', 'flutter', 'figma', 'icons', 'lint'});
    return config;
  }
}

class TokensConfig {
  TokensConfig._(_Reader r)
      : dir = r.string('dir', fallback: 'design_tokens'),
        primitives = r.stringList('primitives',
            fallback: const ['primitives/*.tokens.json']),
        modes = r.stringMap('modes'),
        components = r.stringList('components', fallback: const []) {
    r.rejectUnknown({'dir', 'primitives', 'modes', 'components'});
    if (primitives.isEmpty) {
      throw TokenlineException('tokens.primitives must list at least one file');
    }
  }

  /// Directory holding the token files, relative to the project root.
  final String dir;

  /// File patterns (relative to [dir]); `*` matches within one segment.
  final List<String> primitives;

  /// Theme name -> semantic token file, in theme order (e.g. light, dark).
  final Map<String, String> modes;

  /// File patterns for component tokens.
  final List<String> components;
}

class FlutterConfig {
  FlutterConfig._(_Reader r)
      : outputDir = r.string('output_dir',
            fallback: 'lib/design_system/foundations/generated'),
        classPrefix = r.string('class_prefix', fallback: 'App'),
        classNames = r.stringMap('class_names'),
        docs = r.stringMap('docs') {
    r.rejectUnknown({'output_dir', 'class_prefix', 'class_names', 'docs'});
    if (!RegExp(r'^[A-Z][A-Za-z0-9]*$').hasMatch(classPrefix)) {
      throw TokenlineException(
          'flutter.class_prefix must be UpperCamelCase, got "$classPrefix"');
    }
  }

  final String outputDir;

  /// Prefix for every generated class (`App` -> `AppColors`).
  final String classPrefix;

  /// Token group -> class name overrides, e.g. `opacity: AppOpacities`.
  final Map<String, String> classNames;

  /// Class name -> doc comment overrides.
  final Map<String, String> docs;

  /// File name stem for generated files: `App` -> `app`.
  String get fileStem => snakeCase(classPrefix);
}

/// Where the pull reads Figma from.
enum FigmaSource {
  /// The Tokenline plugin's export: a local file or the copy it stores in
  /// the Figma file. Works on every plan; keeps aliases and ids.
  plugin,

  /// Legacy: a frame whose rectangles are bound to variables, read through
  /// the files REST endpoint. Values only — no aliases, no descriptions.
  syncFrame,

  /// Figma's Variables REST API (Enterprise plans only).
  variablesApi;

  static FigmaSource parse(String? s) => switch (s) {
        null || 'plugin' => FigmaSource.plugin,
        'sync-frame' => FigmaSource.syncFrame,
        'variables-api' => FigmaSource.variablesApi,
        _ => throw TokenlineException('figma.source must be plugin, '
            'sync-frame or variables-api, got "$s"'),
      };
}

class FigmaConfig {
  FigmaConfig._(_Reader r, TokensConfig tokens)
      : fileKey = r.stringOrNull('file_key'),
        source = FigmaSource.parse(r.stringOrNull('source')),
        nameCase = NameCase.parse(r.stringOrNull('name_case')),
        primitiveMode = r.string('primitive_mode', fallback: 'Base'),
        componentMode = r.string('component_mode', fallback: 'Base'),
        hidePrimitives = r.boolean('hide_primitives', fallback: true),
        syncFrameId = r.stringOrNull('sync_frame_id'),
        envFile = r.string('env_file', fallback: '.tokenline.env'),
        snapshotFile = r.string('snapshot_file',
            fallback: p.join(tokens.dir, 'figma-sync', 'figma-snapshot.json')),
        idsFile = r.string('ids_file',
            fallback: p.join(tokens.dir, 'figma-sync', 'figma-ids.json')),
        pushScript = r.string('push_script',
            fallback: p.join(tokens.dir, 'figma-sync', 'push.figma.js')) {
    final c = r.map('collections');
    collections = {
      Level.primitives: c.string('primitives', fallback: 'Primitives'),
      if (tokens.modes.isNotEmpty)
        Level.semantic: c.string('semantic', fallback: 'Semantic'),
      if (tokens.components.isNotEmpty)
        Level.components: c.string('components', fallback: 'Component'),
    };
    c.rejectUnknown({'primitives', 'semantic', 'components'});

    final modeNames = r.stringMap('modes');
    modes = {
      for (final mode in tokens.modes.keys)
        mode: modeNames[mode] ?? pascalCase(mode),
    };
    final unknownModes =
        modeNames.keys.toSet().difference(tokens.modes.keys.toSet());
    if (unknownModes.isNotEmpty) {
      throw TokenlineException('figma.modes names $unknownModes, which are '
          'not in tokens.modes (${tokens.modes.keys.join(', ')})');
    }

    final cs = r.raw('code_syntax');
    if (cs == false) {
      codeSyntax = const {};
    } else {
      final cr = _Reader(
          cs is Map<String, Object?> ? cs : const {}, 'figma.code_syntax.');
      codeSyntax = {
        Level.primitives: cr.string('primitives', fallback: '{class}.{name}'),
        Level.semantic: cr.string('semantic', fallback: '{name}'),
        Level.components: cr.string('components', fallback: '{name}'),
      };
      cr.rejectUnknown({'primitives', 'semantic', 'components'});
    }

    r.rejectUnknown({
      'file_key', 'source', 'collections', 'primitive_mode', //
      'component_mode', 'modes', 'name_case', 'hide_primitives',
      'sync_frame_id', 'env_file', 'snapshot_file', 'ids_file',
      'push_script', 'code_syntax',
    });
    if (source == FigmaSource.syncFrame && syncFrameId == null) {
      throw TokenlineException(
          'figma.source is sync-frame but figma.sync_frame_id is missing');
    }
  }

  final String? fileKey;
  final FigmaSource source;
  final NameCase nameCase;
  final String primitiveMode;
  final String componentMode;

  /// Hide primitives from property pickers and from library publishing.
  final bool hidePrimitives;
  final String? syncFrameId;

  /// KEY=VALUE file for FIGMA_ACCESS_TOKEN (gitignored). Never the app's
  /// own `.env`, which Flutter apps often bundle into the binary.
  final String envFile;

  /// Last pulled Figma snapshot (kept for review and offline lint).
  final String snapshotFile;

  /// Token path -> Figma variable id; lets the pull spot renames.
  final String idsFile;
  final String pushScript;

  /// Level -> Figma collection name.
  late final Map<Level, String> collections;

  /// Token mode -> Figma mode name (e.g. light -> Light).
  late final Map<String, String> modes;

  /// Level -> template for the variable's code-syntax field; empty = off.
  /// `{class}` and `{name}` are the generated Dart class and member.
  late final Map<Level, String> codeSyntax;

  Level? levelForCollection(String collectionName) {
    for (final e in collections.entries) {
      if (e.value == collectionName) return e.key;
    }
    return null;
  }
}

class IconsConfig {
  IconsConfig._(_Reader r, FlutterConfig flutter)
      : manifest = r.string('manifest',
            fallback: 'design_tokens/icons/icons-manifest.json'),
        output = r.string('output',
            fallback:
                p.join(flutter.outputDir, '${flutter.fileStem}_icons.g.dart')),
        className =
            r.string('class_name', fallback: '${flutter.classPrefix}Icons') {
    r.rejectUnknown({'manifest', 'output', 'class_name'});
  }

  final String manifest;
  final String output;
  final String className;
}

class LintConfig {
  LintConfig._(_Reader r)
      : groups = {
          ...defaultNumberGroups,
          ...r.stringList('groups', fallback: const []),
        } {
    r.rejectUnknown({'groups'});
  }

  /// Allowed first segments (token-path spelling) for number and string
  /// primitives. Color variables are free to use any family name.
  final Set<String> groups;

  static const defaultNumberGroups = [
    'space', 'radius', 'opacity', 'borderWidth', 'iconSize', //
    'controlHeight', 'contentWidth', 'size', 'font', 'lineHeight',
    'letterSpacing', 'motion', 'elevation', 'breakpoint', 'zIndex',
  ];
}

/// Small typed reader over a YAML map with path-aware error messages.
class _Reader {
  _Reader(this._m, this._prefix);

  final Map<String, Object?> _m;
  final String _prefix;
  final Set<String> _seen = {};

  Object? raw(String key) {
    _seen.add(key);
    return _m[key];
  }

  Never _bad(String key, String want, Object? got) => throw TokenlineException(
      '$configFileName: $_prefix$key must be $want, got ${got.runtimeType} "$got"');

  String string(String key, {required String fallback}) =>
      stringOrNull(key) ?? fallback;

  String? stringOrNull(String key) {
    final v = raw(key);
    if (v == null) return null;
    if (v is String) return v;
    if (v is num) return '$v';
    _bad(key, 'a string', v);
  }

  bool boolean(String key, {required bool fallback}) {
    final v = raw(key);
    if (v == null) return fallback;
    if (v is bool) return v;
    _bad(key, 'true or false', v);
  }

  List<String> stringList(String key, {required List<String> fallback}) {
    final v = raw(key);
    if (v == null) return fallback;
    if (v is String) return [v];
    if (v is List && v.every((e) => e is String)) return v.cast<String>();
    _bad(key, 'a list of strings', v);
  }

  Map<String, String> stringMap(String key) {
    final v = raw(key);
    if (v == null) return {};
    if (v is Map<String, Object?> && v.values.every((e) => e is String)) {
      return v.cast<String, String>();
    }
    _bad(key, 'a map of strings', v);
  }

  _Reader map(String key) =>
      _Reader(mapOrNull(key)?._m ?? const {}, '$_prefix$key.');

  _Reader? mapOrNull(String key) {
    final v = raw(key);
    if (v == null) return null;
    if (v is Map<String, Object?>) return _Reader(v, '$_prefix$key.');
    _bad(key, 'a map', v);
  }

  void rejectUnknown(Set<String> known) {
    final unknown = _m.keys.where((k) => !known.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw TokenlineException('$configFileName: unknown key(s) '
          '${unknown.map((k) => '$_prefix$k').join(', ')}');
    }
  }
}

/// YAML nodes -> plain Dart maps/lists (keeps key order).
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return <String, Object?>{
      for (final e in node.entries) '${e.key}': _plain(e.value),
    };
  }
  if (node is YamlList) return [for (final e in node) _plain(e)];
  return node;
}
