import '../config.dart';
import '../emit/emitter.dart';
import '../errors.dart';
import '../loader.dart';
import '../names.dart';
import '../tokens.dart';
import 'snapshot.dart';

/// What one token should look like as a Figma variable.
class PlannedVariable {
  PlannedVariable({
    required this.path,
    required this.level,
    required this.tokenType,
    required this.figmaType,
    required this.name,
    required this.collection,
    required this.values,
    required this.description,
    required this.deprecation,
    required this.scopes,
    required this.hiddenFromPublishing,
    required this.codeSyntax,
  });

  final String path;
  final Level level;
  final String tokenType;

  /// One of [FigmaType].
  final String figmaType;
  final String name;
  final String collection;

  /// Figma mode name -> value.
  final Map<String, PlannedValue> values;

  /// The token's own `$description` (without the deprecation line).
  final String description;

  /// First description line in Figma for a deprecated token, else null.
  final String? deprecation;
  final List<String> scopes;
  final bool hiddenFromPublishing;

  /// Text for the variable's Web code-syntax field, or null.
  final String? codeSyntax;

  /// The full Figma description: deprecation line, then the description.
  String get figmaDescription => [
        if (deprecation != null) deprecation!,
        if (description.isNotEmpty) description
      ].join('\n');
}

sealed class PlannedValue {
  const PlannedValue();
}

class PlannedRaw extends PlannedValue {
  const PlannedRaw(this.value);

  /// `#RRGGBB[AA]`, a number or a string, as Figma stores it.
  final Object value;

  @override
  String toString() => '$value';
}

class PlannedAlias extends PlannedValue {
  const PlannedAlias(this.targetPath, this.targetName, this.targetCollection);

  final String targetPath;
  final String targetName;
  final String targetCollection;

  @override
  String toString() => '{$targetPath}';
}

/// Token type -> Figma variable type; null = not synced (shadows).
String? figmaTypeFor(String tokenType) => switch (tokenType) {
      'color' => FigmaType.color,
      'dimension' || 'number' || 'fontWeight' || 'duration' => FigmaType.float,
      'fontFamily' || 'cubicBezier' => FigmaType.string,
      _ => null,
    };

/// A resolved token value -> the value Figma stores.
Object figmaValueFor(String tokenType, Object? v) => switch (tokenType) {
      'color' => (v as String).toUpperCase(),
      'dimension' => _num(double.parse(v as String)),
      'number' => _num(v as num),
      'fontWeight' => v as int,
      'duration' => int.parse((v as String).replaceAll('ms', '')),
      'fontFamily' => v as String,
      'cubicBezier' => (v as List).join(', '),
      _ => throw TokenlineException('type $tokenType does not sync to Figma'),
    };

num _num(num n) => n == n.roundToDouble() ? n.round() : n;

final _deprecatedTarget = RegExp(r'^Use \{?([A-Za-z0-9_.\-]+)\}? instead\.?$');

/// Builds the Figma state the token files describe.
class FigmaPlan {
  FigmaPlan._(this.variables);

  final List<PlannedVariable> variables;

  late final Map<(Level, String), PlannedVariable> byKey = {
    for (final v in variables) (v.level, v.path): v,
  };

  factory FigmaPlan.build(TokenlineConfig config, TokenModel model) {
    final figma = config.figma;
    if (figma == null) {
      throw TokenlineException('tokenline.yaml has no figma section');
    }
    final refs = emit(config, model).refs;
    final out = <PlannedVariable>[];

    String nameOf(String path, Level level) =>
        figmaNameFor(path, level, figma.nameCase);

    PlannedValue valueOf(Token t, {required bool flatten}) {
      if (t.isAlias && !flatten) {
        final target = t.aliasTarget;
        final level = model.levelOf(target);
        if (level == null) {
          throw TokenlineException('${t.path} links to unknown {$target}');
        }
        return PlannedAlias(
            target, nameOf(target, level), figma.collections[level]!);
      }
      return PlannedRaw(figmaValueFor(t.type, t.resolved));
    }

    String? deprecationLine(Token t) {
      if (!t.isDeprecated) return null;
      final msg = t.deprecated is String ? (t.deprecated as String).trim() : '';
      final m = _deprecatedTarget.firstMatch(msg);
      final targetLevel = m == null ? null : model.levelOf(m[1]!);
      if (m != null && targetLevel != null) {
        return '@deprecated → ${nameOf(m[1]!, targetLevel)}';
      }
      return msg.isEmpty ? '@deprecated' : '@deprecated — $msg';
    }

    String? codeSyntaxOf(String path, Level level) {
      final template = figma.codeSyntax[level];
      final ref = refs[path];
      if (template == null || template.isEmpty || ref == null) return null;
      return template
          .replaceAll('{class}', ref.className)
          .replaceAll('{name}', ref.member);
    }

    void add(Token t, Level level, Map<String, PlannedValue> values) {
      final figmaType = figmaTypeFor(t.type)!;
      final hidden = level == Level.primitives && figma.hidePrimitives;
      out.add(PlannedVariable(
        path: t.path,
        level: level,
        tokenType: t.type,
        figmaType: figmaType,
        name: nameOf(t.path, level),
        collection: figma.collections[level]!,
        values: values,
        description: t.description?.trim() ?? '',
        deprecation: deprecationLine(t),
        scopes: hidden ? const [] : scopesFor(t.path, figmaType),
        hiddenFromPublishing: hidden,
        codeSyntax: codeSyntaxOf(t.path, level),
      ));
    }

    for (final t in model.primitives.tokens.values) {
      if (figmaTypeFor(t.type) == null) continue;
      add(t, Level.primitives,
          {figma.primitiveMode: valueOf(t, flatten: true)});
    }

    if (model.semantic.isNotEmpty) {
      final first = model.semantic.values.first;
      for (final path in first.tokens.keys) {
        final t = first.tokens[path]!;
        if (figmaTypeFor(t.type) == null) continue;
        add(t, Level.semantic, {
          for (final mode in model.modes)
            figma.modes[mode]!:
                valueOf(model.semantic[mode]!.tokens[path]!, flatten: false),
        });
      }
    }

    if (model.components.isNotEmpty) {
      final first = model.components.values.first;
      for (final t in first.tokens.values) {
        if (figmaTypeFor(t.type) == null) continue;
        add(t, Level.components,
            {figma.componentMode: valueOf(t, flatten: false)});
      }
    }
    return FigmaPlan._(out);
  }
}

/// Which property pickers a variable appears in.
List<String> scopesFor(String path, String figmaType) {
  final parts = path.split('.');
  bool has(String s) => parts.contains(s);
  switch (figmaType) {
    case FigmaType.color:
      return const ['ALL_FILLS', 'STROKE_COLOR', 'EFFECT_COLOR'];
    case FigmaType.string:
      return has('family') ? const ['FONT_FAMILY'] : const [];
    case FigmaType.float:
      if (has('space')) return const ['GAP', 'WIDTH_HEIGHT'];
      if (has('radius')) return const ['CORNER_RADIUS'];
      if (has('opacity')) return const ['OPACITY'];
      if (has('weight')) return const ['FONT_WEIGHT'];
      if (has('size') && has('font')) return const ['FONT_SIZE'];
      if (has('lineHeight')) return const ['LINE_HEIGHT'];
      if (has('letterSpacing')) return const ['LETTER_SPACING'];
      if (has('borderWidth')) return const ['STROKE_FLOAT'];
      if (has('duration') || has('motion')) return const [];
      return const ['WIDTH_HEIGHT', 'GAP'];
  }
  return const [];
}
