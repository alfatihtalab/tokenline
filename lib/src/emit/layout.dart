import '../config.dart';
import '../loader.dart';
import '../names.dart';

/// One generated Dart class: which tokens go in, and how they are named.
class ClassSpec {
  const ClassSpec({
    required this.name,
    required this.level,
    required this.prefixes,
    required this.types,
    this.mode,
    this.doc,
    this.drop = 1,
    this.radiusHelpers = false,
  });

  final String name;
  final String? doc;
  final Level level;

  /// Theme for semantic and component classes.
  final String? mode;

  /// Token path prefixes, emitted in this order; `''` takes every token.
  final List<String> prefixes;

  /// Token types this class accepts.
  final Set<String> types;

  /// Leading path segments dropped from member names.
  final int drop;

  /// Adds a `BorderRadius` constant per member (`mdBr`).
  final bool radiusHelpers;
}

class FileSpec {
  const FileSpec(this.fileName, this.classes);

  final String fileName;
  final List<ClassSpec> classes;
}

const _numberTypes = {'dimension', 'number'};

/// Leading path segments the default layout drops from a member name.
int defaultDropFor(String path, Level level) {
  if (level == Level.components) return 0;
  return switch (path.split('.').first) {
    'space' => 0,
    'font' || 'motion' => 2,
    _ => 1,
  };
}

/// The standard file and class layout, adapted to the groups a project has.
///
/// Groups with a fixed home (color, space, radius, font, motion, elevation)
/// get their own classes; every other number group becomes one class in the
/// spacing file, in the order the groups first appear in the token files.
List<FileSpec> defaultLayout(TokenlineConfig config, TokenModel model) {
  final f = config.flutter;
  final px = f.classPrefix;
  String cls(String group, String fallback) => f.classNames[group] ?? fallback;
  String? doc(String className, String? fallback) =>
      f.docs[className] ?? fallback;

  ClassSpec spec(String name, String? defaultDoc,
          {required Level level,
          required List<String> prefixes,
          required Set<String> types,
          String? mode,
          int drop = 1,
          bool radiusHelpers = false}) =>
      ClassSpec(
          name: name,
          doc: doc(name, defaultDoc),
          level: level,
          mode: mode,
          prefixes: prefixes,
          types: types,
          drop: drop,
          radiusHelpers: radiusHelpers);

  final colors = cls('color', '${px}Colors');
  final colorClasses = [
    spec(
        colors,
        'Primitive color scales. Feature code must NOT import these directly —\n'
        'use semantic colors via the theme/context extensions instead.',
        level: Level.primitives,
        prefixes: ['color.'],
        types: {'color'}),
    for (final mode in model.modes)
      spec('$colors${pascalCase(mode)}', 'Semantic colors — $mode mode.',
          level: Level.semantic,
          mode: mode,
          prefixes: ['color.'],
          types: {'color'}),
    for (final mode in model.components.keys)
      spec('${px}ComponentColors${pascalCase(mode)}',
          'Component colors resolved for $mode mode.',
          level: Level.components,
          mode: mode,
          prefixes: [''],
          types: {'color'},
          drop: 0),
    spec(cls('elevation', '${px}Elevation'),
        'Elevation shadows (primitive `elevation.*`).',
        level: Level.primitives, prefixes: ['elevation.'], types: {'shadow'}),
  ];

  const fixedGroups = {
    'color',
    'space',
    'radius',
    'font',
    'motion',
    'elevation'
  };
  final otherGroups = <String>[];
  for (final t in model.primitives.tokens.values) {
    final group = t.path.split('.').first;
    if (!fixedGroups.contains(group) &&
        _numberTypes.contains(t.type) &&
        !otherGroups.contains(group)) {
      otherGroups.add(group);
    }
  }
  final spacingClasses = [
    spec(
        cls('space', '${px}Spacing'),
        'Spacing scale (`space.*`) — logical pixels.\n'
        'Gap/padding scale. Use instead of raw EdgeInsets numbers.',
        level: Level.primitives,
        prefixes: ['space.'],
        types: _numberTypes,
        drop: 0),
    for (final g in otherGroups)
      spec(cls(g, '$px${pascalCase(g)}'), null,
          level: Level.primitives, prefixes: ['$g.'], types: _numberTypes),
  ];

  final radius = spec(
      cls('radius', '${px}Radius'), 'Corner radii (`radius.*`).',
      level: Level.primitives,
      prefixes: ['radius.'],
      types: _numberTypes,
      radiusHelpers: true);

  const fixedFont = {'family', 'weight', 'size', 'lineHeight', 'letterSpacing'};
  final otherFont = <String>[];
  for (final t in model.primitives.tokens.values) {
    final parts = t.path.split('.');
    if (parts.length > 2 &&
        parts.first == 'font' &&
        !fixedFont.contains(parts[1]) &&
        !otherFont.contains(parts[1])) {
      otherFont.add(parts[1]);
    }
  }
  final typographyClasses = [
    spec(cls('font', '${px}Fonts'), 'Typography foundations (`font.*`).',
        level: Level.primitives,
        prefixes: ['font.family.', 'font.weight.'],
        types: {'fontFamily', 'fontWeight'},
        drop: 2),
    spec('${px}FontSize', null,
        level: Level.primitives,
        prefixes: ['font.size.'],
        types: _numberTypes,
        drop: 2),
    spec('${px}LineHeight', null,
        level: Level.primitives,
        prefixes: ['font.lineHeight.'],
        types: _numberTypes,
        drop: 2),
    spec('${px}LetterSpacing', null,
        level: Level.primitives,
        prefixes: ['font.letterSpacing.'],
        types: _numberTypes,
        drop: 2),
    for (final sub in otherFont)
      spec('${px}Font${pascalCase(sub)}', null,
          level: Level.primitives,
          prefixes: ['font.$sub.'],
          types: _numberTypes,
          drop: 2),
  ];

  final motion = spec(
      cls('motion', '${px}Motion'), 'Motion foundations (`motion.*`).',
      level: Level.primitives,
      prefixes: ['motion.duration.', 'motion.easing.'],
      types: {'duration', 'cubicBezier'},
      drop: 2);

  final stem = f.fileStem;
  return [
    FileSpec('${stem}_colors.g.dart', colorClasses),
    FileSpec('${stem}_spacing.g.dart', spacingClasses),
    FileSpec('${stem}_radius.g.dart', [radius]),
    FileSpec('${stem}_typography.g.dart', typographyClasses),
    FileSpec('${stem}_motion.g.dart', [motion]),
  ];
}
