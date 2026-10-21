import 'errors.dart';

/// Words Dart never accepts as an identifier.
const dartReservedWords = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', //
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally',
  'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super',
  'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// `color.neutral.900` -> `neutral900`; `font.size.2xl` (drop 2) -> `v2xl`.
///
/// Segments are joined in lowerCamelCase. A name that would start with a
/// digit gets a `v` prefix. Throws when the result is not a valid Dart
/// identifier or is a reserved word.
String dartName(String path, {int dropPrefixSegments = 1}) {
  final parts = path.split('.').skip(dropPrefixSegments).toList();
  if (parts.isEmpty) {
    throw TokenlineException('token "$path" has no name left after dropping '
        '$dropPrefixSegments group segment(s)');
  }
  final buf = StringBuffer();
  for (var i = 0; i < parts.length; i++) {
    final p = kebabToCamel(parts[i]);
    if (p.isEmpty) {
      throw TokenlineException('token "$path" has an empty segment');
    }
    buf.write(i == 0
        ? p[0].toLowerCase() + p.substring(1)
        : p[0].toUpperCase() + p.substring(1));
  }
  var name = buf.toString();
  if (RegExp(r'^[0-9]').hasMatch(name)) name = 'v$name';
  if (!_identifier.hasMatch(name)) {
    throw TokenlineException(
        'token "$path" becomes "$name", which is not a valid Dart name');
  }
  if (dartReservedWords.contains(name)) {
    throw TokenlineException(
        'token "$path" becomes "$name", a reserved word in Dart — rename it');
  }
  return name;
}

/// `border-width` -> `borderWidth`. Only a hyphen before a letter joins;
/// `1-5` stays as it is (and is later refused as a Dart name).
String kebabToCamel(String s) =>
    s.replaceAllMapped(RegExp(r'-([a-z])'), (m) => m[1]!.toUpperCase());

/// `borderWidth` -> `border-width`; `2xl` and `900` are unchanged.
String camelToKebab(String s) => s
    .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}-${m[2]!.toLowerCase()}')
    .toLowerCase();

/// `app` -> `App`; `rezme_ui` -> `RezmeUi`.
String pascalCase(String s) => s
    .split(RegExp(r'[_\-\s]+'))
    .where((p) => p.isNotEmpty)
    .map((p) => p[0].toUpperCase() + p.substring(1))
    .join();

/// `App` -> `app`; `RezmeUI` -> `rezme_ui`.
String snakeCase(String s) => s
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .replaceAllMapped(RegExp(r'([A-Z])([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase();

/// How token paths are spelled as Figma variable names.
enum NameCase {
  /// `font/line-height/tight` (recommended for new files).
  kebab,

  /// `font/lineHeight/tight` (path segments unchanged).
  camel;

  static NameCase parse(String? s) => switch (s) {
        null || 'kebab' => NameCase.kebab,
        'camel' => NameCase.camel,
        _ => throw TokenlineException(
            'figma.name_case must be "kebab" or "camel", got "$s"'),
      };
}

/// The three token levels, each a Figma collection.
enum Level {
  primitives,
  semantic,
  components;

  /// Primitives and semantic colors live under `color.` in token paths, but
  /// the Figma type already says "color", so the prefix is dropped there.
  bool get dropsColorPrefix => this != Level.components;
}

/// Token path -> Figma variable name.
String figmaNameFor(String path, Level level, NameCase nameCase) {
  var parts = path.split('.');
  if (level.dropsColorPrefix && parts.first == 'color' && parts.length > 1) {
    parts = parts.sublist(1);
  }
  if (nameCase == NameCase.kebab) parts = parts.map(camelToKebab).toList();
  return parts.join('/');
}

/// Figma variable name -> token path. [isColor] is the variable's type.
String pathForFigmaName(String name, Level level, NameCase nameCase,
    {required bool isColor}) {
  var parts = name.split('/').map((s) => s.trim()).toList();
  if (nameCase == NameCase.kebab) parts = parts.map(kebabToCamel).toList();
  if (level.dropsColorPrefix && isColor) parts = ['color', ...parts];
  return parts.join('.');
}

/// Drafts (`_draft/...`, or any segment starting with `_`) never sync.
bool isDraftName(String figmaName) =>
    figmaName.split('/').any((s) => s.trim().startsWith('_'));
