// Token files -> push -> (mock) Figma -> export -> pull, end to end.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tokenline/src/emit/emitter.dart';
import 'package:tokenline/src/emit/writer.dart';
import 'package:tokenline/src/figma/adopt.dart';
import 'package:tokenline/src/figma/diff.dart';
import 'package:tokenline/src/figma/plan.dart';
import 'package:tokenline/src/figma/push.dart';
import 'package:tokenline/src/figma/snapshot.dart';
import 'package:tokenline/src/lint/rules.dart';
import 'package:tokenline/src/loader.dart';

import 'support/fixture.dart';

FigmaSnapshot snapshotIn(String dir) =>
    FigmaSnapshot.readFile(p.join(dir, 'snapshot.json'));

void main() {
  if (!hasNode) {
    test('round trip', () {}, skip: 'node is not installed');
    return;
  }

  for (final nameCase in ['kebab', 'camel']) {
    test('push then export gives zero differences ($nameCase names)', () {
      final root = createFixtureProject(nameCase: nameCase);
      final config = loadFixture(root);
      final model = TokenModel.load(config);
      final plan = FigmaPlan.build(config, model);
      final out = runMockFigma(buildPushPayload(config, plan));

      final apply =
          jsonDecode(File(p.join(out, 'apply.json')).readAsStringSync()) as Map;
      expect(apply['errors'], isEmpty);
      expect(apply['created'], plan.variables.length);

      final snapshot = snapshotIn(out);
      final diff = diffSnapshot(config, model, plan, snapshot);
      expect(diff.changes.map((c) => c.describe()), isEmpty);
      expect(lintSnapshot(snapshot, config.figma!, config.lint), isEmpty);
      expect(jsonDecode(File(p.join(out, 'lint.json')).readAsStringSync()),
          isEmpty);

      // The chunked copy stored in the file reassembles to the same export.
      expect(jsonDecode(File(p.join(out, 'stored.json')).readAsStringSync()),
          jsonDecode(File(p.join(out, 'snapshot.json')).readAsStringSync()));

      // Names follow the configured case.
      final names = snapshot.variables.map((v) => v.name).toSet();
      expect(
          names,
          contains(nameCase == 'kebab'
              ? 'font/line-height/tight'
              : 'font/lineHeight/tight'));
      expect(names, contains('text/primary'));
      expect(names, contains('button/primary/background'));
    });
  }

  test('designer edits come back as changes and adopt makes them match', () {
    final root = createFixtureProject();
    final config = loadFixture(root);
    var model = TokenModel.load(config);
    var plan = FigmaPlan.build(config, model);
    final out = runMockFigma(buildPushPayload(config, plan), edits: r'''
module.exports = async function (figma, hexToRgba) {
  var P = 'Fx / Primitives', S = 'Fx / Semantic';
  var base = figma._mode(P, 'Base'), light = figma._mode(S, 'Light'), dark = figma._mode(S, 'Dark');
  figma._find(P, 'brand/500').setValueForMode(base, hexToRgba('#2255EE'));
  figma._find(S, 'text/primary').setValueForMode(light,
      figma.variables.createVariableAlias(figma._find(P, 'neutral/700')));
  var space48 = figma._create('space/48', P, 'FLOAT');
  space48.setValueForMode(base, 48);
  space48.scopes = []; space48.hiddenFromPublishing = true;
  var raised = figma._create('surface/raised', S, 'COLOR');
  raised.setValueForMode(light, figma.variables.createVariableAlias(figma._find(P, 'neutral/0')));
  raised.setValueForMode(dark, figma.variables.createVariableAlias(figma._find(P, 'neutral/700')));
  raised.description = 'Cards above the surface.';
  figma._find(S, 'text/secondary').description = '@deprecated → text/primary';
  figma._find(S, 'background/base').description = 'Main background.';
};
''');
    final snapshot = snapshotIn(out);
    final diff = diffSnapshot(config, model, plan, snapshot);
    expect(
        diff.changes
            .map((c) => '${c.kind.name} ${c.path} ${c.mode ?? ''}'.trim())
            .toList(),
        [
          'description color.background.base',
          'value color.brand.500',
          'added color.surface.raised',
          'value color.text.primary light',
          'deprecation color.text.secondary',
          'added space.48',
        ]);
    expect(diff.breaking, isEmpty);

    final changedFiles = adoptChanges(config, model, diff.changes);
    expect(
        changedFiles,
        containsAll([
          'primitives/colors.tokens.json',
          'primitives/spacing.tokens.json',
          'semantic/light.tokens.json',
          'semantic/dark.tokens.json'
        ]));

    // Links stay links, values keep their JSON types.
    final light =
        jsonDecode(readToken(root, 'semantic/light.tokens.json')) as Map;
    final color = light['color'] as Map;
    expect((color['text'] as Map)['primary'],
        containsPair(r'$value', '{color.neutral.700}'));
    expect((color['surface'] as Map)['raised'], {
      r'$type': 'color',
      r'$value': '{color.neutral.0}',
      r'$description': 'Cards above the surface.',
    });
    expect((color['text'] as Map)['secondary'],
        containsPair(r'$deprecated', 'Use color.text.primary instead.'));
    final spacing =
        jsonDecode(readToken(root, 'primitives/spacing.tokens.json')) as Map;
    expect((spacing['space'] as Map)['48'],
        {r'$type': 'dimension', r'$value': '48'});

    // Re-reading the files gives a plan that matches Figma exactly.
    model = TokenModel.load(config);
    plan = FigmaPlan.build(config, model);
    expect(
        diffSnapshot(config, model, plan, snapshot)
            .changes
            .map((c) => c.describe()),
        isEmpty);

    // And the generated Dart carries the deprecation.
    final colors = emit(config, model)
        .files
        .firstWhere((f) => f.path.endsWith('fx_colors.g.dart'));
    expect(colors.content,
        contains("@Deprecated('Use color.text.primary instead.')"));
    expect(colors.content, contains('surfaceRaised'));
    expect(writeGenerated(config, emit(config, model).files, check: false),
        isNotEmpty);
  });

  test('removal without deprecation is breaking; renames are spotted by id',
      () {
    final root = createFixtureProject();
    final config = loadFixture(root);
    final model = TokenModel.load(config);
    final plan = FigmaPlan.build(config, model);
    final payload = buildPushPayload(config, plan);
    final first =
        diffSnapshot(config, model, plan, snapshotIn(runMockFigma(payload)));

    final out = runMockFigma(payload, edits: r'''
module.exports = async function (figma) {
  var P = 'Fx / Primitives';
  figma._find(P, 'radius/lg').remove();
  figma._find(P, 'radius/sm').name = 'radius/small';
};
''');
    // Mock ids restart per run, so reuse the ids of this run's push.
    final again = diffSnapshot(config, model, plan, snapshotIn(out), knownIds: {
      ...first.ids,
      'radius.sm': snapshotIn(out)
          .variables
          .firstWhere((v) => v.name == 'radius/small')
          .id
    });
    expect(again.breaking.map((c) => c.describe()), [
      'REMOVE  primitives: radius.lg — not deprecated first',
      'RENAME  primitives: radius.sm -> radius.small',
    ]);
  });

  test('Dart and plugin lint agree on rule violations', () {
    final root = createFixtureProject();
    final config = loadFixture(root);
    final model = TokenModel.load(config);
    final out = runMockFigma(
        buildPushPayload(config, FigmaPlan.build(config, model)),
        edits: r'''
module.exports = async function (figma, hexToRgba) {
  var P = 'Fx / Primitives', S = 'Fx / Semantic', C = 'Fx / Component';
  var base = figma._mode(P, 'Base'), light = figma._mode(S, 'Light');
  figma._create('Primary Blue', P, 'COLOR').setValueForMode(base, hexToRgba('#0000FF'));
  figma._create('bogus/1', P, 'FLOAT').setValueForMode(base, 1);
  figma._create('note/label', P, 'STRING').setValueForMode(base, 'hi');
  figma._create('space/1-5', P, 'FLOAT').setValueForMode(base, 1.5);
  figma._create('space/15', P, 'FLOAT').setValueForMode(base, 15);
  figma._find(S, 'text/primary').setValueForMode(light, hexToRgba('#111111'));
  figma._find(C, 'button/primary/background').setValueForMode(figma._mode(C, 'Base'),
      figma.variables.createVariableAlias(figma._find(P, 'brand/500')));
  figma._find(P, 'neutral/0').setValueForMode(base,
      figma.variables.createVariableAlias(figma._find(P, 'neutral/50')));
  figma._find(S, 'border/subtle').description = '@deprecated → border/gone';
  figma._find(P, 'brand/50').scopes = ['ALL_FILLS'];
};
''');
    final snapshot = snapshotIn(out);
    final dart = lintSnapshot(snapshot, config.figma!, config.lint)
        .map((i) => '${i.code} ${i.variable?.name ?? ''}'.trim())
        .toSet();
    final js =
        (jsonDecode(File(p.join(out, 'lint.json')).readAsStringSync()) as List)
            .cast<Map<String, Object?>>()
            .map((i) => '${i['code']} ${i['name'] ?? ''}'.trim())
            .toSet();
    expect(dart, js);
    expect(
        dart,
        containsAll([
          'name-format Primary Blue',
          'name-group bogus/1',
          'type-group note/label',
          'name-group note/label',
          'name-collision space/15',
          'semantic-raw text/primary',
          'component-link-target button/primary/background',
          'primitive-link neutral/0',
          'deprecated-target border/subtle',
          'primitive-scopes brand/50',
        ]));
  });
}
