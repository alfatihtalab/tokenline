// Regression tests for bugs found in review (one group per finding).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tokenline/src/cli.dart';
import 'package:tokenline/src/emit/emitter.dart';
import 'package:tokenline/src/errors.dart';
import 'package:tokenline/src/figma/adopt.dart';
import 'package:tokenline/src/figma/diff.dart';
import 'package:tokenline/src/figma/legacy_sync_frame.dart';
import 'package:tokenline/src/figma/plan.dart';
import 'package:tokenline/src/figma/push.dart';
import 'package:tokenline/src/figma/snapshot.dart';
import 'package:tokenline/src/lint/rules.dart';
import 'package:tokenline/src/loader.dart';
import 'package:tokenline/src/names.dart';
import 'package:tokenline/src/tokens.dart';

import 'support/fixture.dart';

void writeJson(String root, String rel, Object json) =>
    File(p.join(root, 'design_tokens', rel))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

Map<String, Object?> readJson(String root, String rel) =>
    jsonDecode(readToken(root, rel)) as Map<String, Object?>;

/// Adds [tokens] under `color` in both theme files.
void addSemantic(String root, Map<String, Object?> tokens) {
  for (final mode in ['light', 'dark']) {
    final rel = 'semantic/$mode.tokens.json';
    final json = readJson(root, rel);
    json.addAll(tokens);
    writeJson(root, rel, json);
  }
}

FigmaSnapshot snapshotIn(String dir) =>
    FigmaSnapshot.readFile(p.join(dir, 'snapshot.json'));

double f32(num n) => (Float32List(1)..[0] = n.toDouble())[0];

void main() {
  final node = hasNode;

  test('names that do not round-trip still map to their own token', () {
    if (!node) return markTestSkipped('node is not installed');
    final root =
        createFixtureProject(extraConfig: 'lint:\n  groups: [border-width]\n');
    writeJson(root, 'primitives/extra.tokens.json', {
      'border-width': {
        'thin': {r'$type': 'dimension', r'$value': '1'},
      },
      'radius': {
        'XL': {r'$type': 'dimension', r'$value': '24'},
      },
    });
    addSemantic(root, {
      'bg': {
        'raised': {r'$type': 'color', r'$value': '{color.neutral.0}'},
      },
    });
    final config = loadFixture(root);
    final model = TokenModel.load(config);
    final plan = FigmaPlan.build(config, model);
    final out = runMockFigma(buildPushPayload(config, plan));
    final diff = diffSnapshot(config, model, plan, snapshotIn(out));
    expect(diff.changes.map((c) => c.describe()), isEmpty);
    expect(diff.ids.keys,
        containsAll(['border-width.thin', 'radius.XL', 'bg.raised']));
  });

  test('a single-mode collection with another mode name is compared and reused',
      () {
    if (!node) return markTestSkipped('node is not installed');
    final root = createFixtureProject();
    final config = loadFixture(root);
    final model = TokenModel.load(config);
    final plan = FigmaPlan.build(config, model);
    final out = runMockFigma(buildPushPayload(config, plan), setup: r'''
module.exports = async function (figma) { figma.variables.createVariableCollection('Fx / Primitives'); };
''', edits: r'''
module.exports = async function (figma) {
  figma._find('Fx / Primitives', 'space/16').setValueForMode(figma._mode('Fx / Primitives', 'Mode 1'), 20);
};
''');
    final snapshot = snapshotIn(out);
    expect(snapshot.collectionNamed('Fx / Primitives')!.modes, ['Mode 1'],
        reason: 'push must not add a "Base" mode');
    final diff = diffSnapshot(config, model, plan, snapshot);
    expect(diff.changes.map((c) => c.describe()),
        ['CHANGE  primitives: space.16: 16 -> 20']);
  });

  test('token names with a dot or braces are refused', () {
    final dir = Directory.systemTemp.createTempSync('tl_dot_').path;
    File(p.join(dir, 'a.json')).writeAsStringSync(jsonEncode({
      'space': {
        '1.5': {r'$type': 'dimension', r'$value': '1.5'},
      },
    }));
    expect(
        () => TokenSet().addFile('a.json', root: dir),
        throwsA(isA<TokenlineException>().having((e) => e.message, 'message',
            contains('cannot be empty or contain'))));
  });

  test('a rename keeps the type and the extra keys of the token', () {
    if (!node) return markTestSkipped('node is not installed');
    final root = createFixtureProject();
    final typo = readJson(root, 'primitives/typography.tokens.json');
    (((typo['font'] as Map)['lineHeight'] as Map)['tight']
        as Map)[r'$extensions'] = {
      'com.example': {'note': 'keep me'},
    };
    writeJson(root, 'primitives/typography.tokens.json', typo);
    final config = loadFixture(root);
    var model = TokenModel.load(config);
    var plan = FigmaPlan.build(config, model);
    final payload = buildPushPayload(config, plan);
    final known =
        diffSnapshot(config, model, plan, snapshotIn(runMockFigma(payload)))
            .ids;
    final out = runMockFigma(payload, edits: r'''
module.exports = async function (figma) { figma._find('Fx / Primitives', 'font/line-height/tight').name = 'font/leading/tight'; };
''');
    final diff =
        diffSnapshot(config, model, plan, snapshotIn(out), knownIds: known);
    expect(diff.changes.single.describe(),
        'RENAME  primitives: font.lineHeight.tight -> font.leading.tight');
    adoptChanges(config, model, diff.changes);
    final font =
        readJson(root, 'primitives/typography.tokens.json')['font'] as Map;
    expect((font['leading'] as Map)['tight'], {
      r'$value': 1.2,
      r'$extensions': {
        'com.example': {'note': 'keep me'},
      },
      r'$type': 'number',
    });
    expect((font['lineHeight'] as Map).containsKey('tight'), isFalse);
    model = TokenModel.load(config);
    plan = FigmaPlan.build(config, model);
    expect(
        diffSnapshot(config, model, plan, snapshotIn(out), knownIds: known)
            .changes
            .map((c) => c.describe()),
        isEmpty);
  });

  test('push sends linked-to variables first', () {
    final root = createFixtureProject();
    final config = loadFixture(root);
    final payload = buildPushPayload(
        config, FigmaPlan.build(config, TokenModel.load(config)));
    final seen = <String>{};
    for (final v
        in (payload['variables'] as List).cast<Map<String, Object?>>()) {
      for (final value in (v['values'] as Map).values) {
        if (value is Map) {
          expect(seen, contains('${value['collection']}|${value['alias']}'),
              reason: '${v['name']} comes before its target');
        }
      }
      seen.add('${v['collection']}|${v['name']}');
    }
  });

  test('a prune too big for use_figma scripts is a clear error', () {
    final root = createFixtureProject();
    final config = loadFixture(root);
    final payload = buildPushPayload(
        config, FigmaPlan.build(config, TokenModel.load(config)));
    expect(
        () => buildPushScripts(payload, prune: true, maxChars: 9000),
        throwsA(isA<TokenlineException>()
            .having((e) => e.message, 'message', contains("plugin's Import"))));
  });

  test('validate and push refuse token files that break the level rules',
      () async {
    final root = createFixtureProject();
    for (final mode in ['light', 'dark']) {
      final rel = 'semantic/$mode.tokens.json';
      final json = readJson(root, rel);
      (((json['color'] as Map)['text'] as Map)['primary'] as Map)[r'$value'] =
          '#111111';
      writeJson(root, rel, json);
    }
    expect(await runTokenline(['-C', root, 'validate']), 1);
    expect(await runTokenline(['-C', root, 'push']), 1);
    expect(await runTokenline(['-C', root, 'generate']), 0,
        reason: 'generation still works');
  });

  test('font weights must be multiples of 100', () async {
    final root = createFixtureProject();
    final typo = readJson(root, 'primitives/typography.tokens.json');
    (((typo['font'] as Map)['weight'] as Map)['medium'] as Map)[r'$value'] =
        450;
    writeJson(root, 'primitives/typography.tokens.json', typo);
    expect(await runTokenline(['-C', root, 'validate']), 1);
    expect(() => jsonValueFor('fontWeight', 450, where: 'x'),
        throwsA(isA<TokenlineException>()));
  });

  test('shadow parts may link to colors', () {
    final root = createFixtureProject();
    writeJson(root, 'primitives/elevation.tokens.json', {
      'elevation': {
        'low': {
          r'$type': 'shadow',
          r'$value': {
            'color': '{color.neutral.900}',
            'offsetX': 0,
            'offsetY': 1,
            'blur': 2,
            'spread': 0
          },
        },
      },
    });
    final config = loadFixture(root);
    final colors = emit(config, TokenModel.load(config))
        .files
        .firstWhere((f) => f.path.endsWith('fx_colors.g.dart'))
        .content;
    final elevation = colors.substring(colors.indexOf('class FxElevation'));
    expect(elevation, contains('color: Color(0xFF1B1C21)'));
    expect(elevation, contains('blurRadius: 2'));
  });

  test('lint does not crash on an empty name segment and matches the plugin',
      () {
    if (!node) return markTestSkipped('node is not installed');
    final root = createFixtureProject();
    final config = loadFixture(root);
    final out = runMockFigma(
        buildPushPayload(
            config, FigmaPlan.build(config, TokenModel.load(config))),
        edits: r'''
module.exports = async function (figma) {
  figma._create('font/family/', 'Fx / Primitives', 'STRING').setValueForMode(figma._mode('Fx / Primitives', 'Base'), 'Inter');
};
''');
    final dart = lintSnapshot(snapshotIn(out), config.figma!, config.lint)
        .map((i) => '${i.code} ${i.variable?.name}')
        .toSet();
    final js =
        (jsonDecode(File(p.join(out, 'lint.json')).readAsStringSync()) as List)
            .map((i) => '${(i as Map)['code']} ${i['name']}')
            .toSet();
    expect(dart, js);
    expect(dart, contains('name-format font/family/'));
    expect(dartNameGuess('font.family.', Level.primitives), '');
  });

  test('legacy sync frame skips numbers a width cannot carry', () {
    final root = createFixtureProject();
    final typo = readJson(root, 'primitives/typography.tokens.json');
    (typo['font'] as Map)['letterSpacing'] = {
      'tight': {r'$type': 'dimension', r'$value': '-0.2'},
    };
    writeJson(root, 'primitives/typography.tokens.json', typo);
    final config = loadFixture(root);
    final result = diffResolved(config, TokenModel.load(config), {
      'font.letterSpacing.tight': {'value': '0'},
    });
    expect(result.changes, isEmpty);
    expect(result.skipped, ['font.letterSpacing.tight']);
  });

  test('numbers keep float32 precision', () {
    expect(jsonValueFor('number', f32(-0.0125), where: 'x'), -0.0125);
    expect(jsonValueFor('dimension', 0.6000000238418579, where: 'x'), '0.6');
    expect(jsonValueFor('dimension', 16.0, where: 'x'), '16');
    expect(sameValue(-0.01, -0.0125), isFalse);
    expect(sameValue('0.6', 0.6000000238418579), isTrue);
    expect(sameValue(1.15, f32(1.15)), isTrue);
  });
}
