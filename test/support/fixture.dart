import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tokenline/src/commands/init.dart';
import 'package:tokenline/src/config.dart';

/// A temp project with the starter tokens, a component file and a figma
/// section. Returns its root.
String createFixtureProject({String nameCase = 'kebab', String? extraConfig}) {
  final root = Directory.systemTemp.createTempSync('tokenline_test_').path;
  starterTokens.forEach((rel, json) {
    File(p.join(root, 'design_tokens', rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  });
  File(p.join(root, 'design_tokens', 'components', 'button.tokens.json'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'button': {
        'primary': {
          'background': {
            r'$type': 'color',
            r'$value': '{color.action.primary}'
          },
          'content': {r'$type': 'color', r'$value': '{color.action.onPrimary}'},
        },
        'radius': {r'$type': 'dimension', r'$value': '{radius.md}'},
      },
    }));
  File(p.join(root, configFileName)).writeAsStringSync('''
name: fixture-tokens
version: 1.2.3
tokens:
  dir: design_tokens
  primitives: [primitives/*.tokens.json]
  modes:
    light: semantic/light.tokens.json
    dark: semantic/dark.tokens.json
  components: [components/*.tokens.json]
flutter:
  output_dir: lib/generated
  class_prefix: Fx
figma:
  file_key: FIXTUREKEY
  name_case: $nameCase
  collections:
    primitives: Fx / Primitives
    semantic: Fx / Semantic
    components: Fx / Component
${extraConfig ?? ''}''');
  return root;
}

TokenlineConfig loadFixture(String root) => TokenlineConfig.load(root: root);

String readToken(String root, String rel) =>
    File(p.join(root, 'design_tokens', rel)).readAsStringSync();

bool get hasNode {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// Runs core.js in the mock Figma: apply [payload], then [edits] (JS source
/// of `module.exports = async function (figma, hexToRgba) {...}`), then
/// export. Returns the out dir.
String runMockFigma(Map<String, Object?> payload,
    {String? edits, bool prune = false}) {
  final out = Directory.systemTemp.createTempSync('tokenline_figma_').path;
  final payloadFile = File(p.join(out, 'payload.json'))
    ..writeAsStringSync(jsonEncode(payload));
  String? editsFile;
  if (edits != null) {
    editsFile = p.join(out, 'edits.js');
    File(editsFile).writeAsStringSync(edits);
  }
  final result = Process.runSync('node', [
    'test/support/run_figma.js',
    'lib/src/figma/plugin_src/core.js',
    payloadFile.path,
    out,
    if (editsFile != null) editsFile,
  ], environment: {
    if (prune) 'PRUNE': '1'
  });
  if (result.exitCode != 0) {
    throw StateError('mock figma failed:\n${result.stdout}\n${result.stderr}');
  }
  return out;
}
