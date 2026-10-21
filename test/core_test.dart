import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tokenline/src/config.dart';
import 'package:tokenline/src/emit/emitter.dart';
import 'package:tokenline/src/errors.dart';
import 'package:tokenline/src/figma/legacy_sync_frame.dart';
import 'package:tokenline/src/figma/rest.dart';
import 'package:tokenline/src/figma/snapshot.dart';
import 'package:tokenline/src/loader.dart';
import 'package:tokenline/src/names.dart';
import 'package:tokenline/src/tokens.dart';

import 'support/fixture.dart';

Matcher throwsTokenline(Object message) => throwsA(
    isA<TokenlineException>().having((e) => e.message, 'message', message));

void main() {
  group('names', () {
    test('dart names', () {
      expect(dartName('color.neutral.900'), 'neutral900');
      expect(dartName('color.text.primary'), 'textPrimary');
      expect(dartName('font.size.2xl', dropPrefixSegments: 2), 'v2xl');
      expect(dartName('space.16', dropPrefixSegments: 0), 'space16');
      expect(dartName('border-width.thin', dropPrefixSegments: 0),
          'borderWidthThin');
      expect(() => dartName('text.default'),
          throwsTokenline(contains('reserved word')));
      expect(() => dartName('space.1-5'),
          throwsTokenline(contains('not a valid Dart name')));
    });

    test('figma names round-trip in both cases', () {
      for (final c in NameCase.values) {
        for (final (path, level, isColor) in [
          ('color.neutral.900', Level.primitives, true),
          ('color.text.primary', Level.semantic, true),
          ('font.lineHeight.tight', Level.primitives, false),
          ('borderWidth.thin', Level.primitives, false),
          ('button.primary.background', Level.components, true),
        ]) {
          final name = figmaNameFor(path, level, c);
          expect(pathForFigmaName(name, level, c, isColor: isColor), path,
              reason: '$c $name');
        }
      }
      expect(
          figmaNameFor(
              'font.lineHeight.tight', Level.primitives, NameCase.kebab),
          'font/line-height/tight');
      expect(figmaNameFor('color.text.primary', Level.semantic, NameCase.kebab),
          'text/primary');
      expect(
          figmaNameFor(
              'button.primary.background', Level.components, NameCase.kebab),
          'button/primary/background');
    });

    test('drafts', () {
      expect(isDraftName('_draft/surface/glass'), isTrue);
      expect(isDraftName('surface/_scratch'), isTrue);
      expect(isDraftName('surface/glass'), isFalse);
    });

    test('case helpers', () {
      expect(snakeCase('App'), 'app');
      expect(snakeCase('RezmeUI'), 'rezme_ui');
      expect(pascalCase('high_contrast'), 'HighContrast');
    });
  });

  group('config', () {
    TokenlineConfig parse(String yaml) {
      final dir = Directory.systemTemp.createTempSync('tl_cfg_').path;
      File(p.join(dir, configFileName)).writeAsStringSync(yaml);
      return TokenlineConfig.load(root: dir);
    }

    test('defaults', () {
      final c = parse(
          'name: x\ntokens:\n  modes:\n    light: l.json\n    high_contrast: h.json\nfigma:\n  file_key: K\n');
      expect(c.flutter.classPrefix, 'App');
      expect(c.flutter.runCommand, 'dart run tokenline generate');
      expect(
          c.figma!.modes, {'light': 'Light', 'high_contrast': 'HighContrast'});
      expect(c.figma!.source, FigmaSource.plugin);
      expect(c.figma!.nameCase, NameCase.kebab);
      expect(c.figma!.collections[Level.semantic], 'Semantic');
      expect(c.figma!.collections.containsKey(Level.components), isFalse);
    });

    test('rejects typos and bad values', () {
      expect(() => parse('tokenz: {}\n'),
          throwsTokenline(contains('unknown key(s) tokenz')));
      expect(() => parse('figma:\n  colections: {}\n'),
          throwsTokenline(contains('figma.colections')));
      expect(() => parse('flutter:\n  class_prefix: app\n'),
          throwsTokenline(contains('UpperCamelCase')));
      expect(() => parse('figma:\n  source: sync-frame\n'),
          throwsTokenline(contains('sync_frame_id')));
      expect(() => parse('figma:\n  name_case: snake\n'),
          throwsTokenline(contains('name_case')));
      expect(
          () => parse(
              'tokens:\n  modes: {light: l.json}\nfigma:\n  modes: {dark: Dark}\n'),
          throwsTokenline(contains('not in tokens.modes')));
    });

    test('missing file explains init', () {
      expect(
          () => TokenlineConfig.load(
              root: Directory.systemTemp.createTempSync().path),
          throwsTokenline(contains('tokenline init')));
    });
  });

  group('tokens', () {
    TokenSet setOf(Map<String, (String, Object)> entries) {
      final s = TokenSet();
      entries.forEach((path, tv) =>
          s.tokens[path] = Token(path, tv.$1, tv.$2, source: 'test'));
      return s;
    }

    test('alias cycles, dangling links and bad values are rejected', () {
      expect(
          setOf({'a.x': ('color', '{a.y}'), 'a.y': ('color', '{a.x}')}).resolve,
          throwsTokenline(contains('alias cycle')));
      expect(setOf({'a.x': ('color', '{missing.token}')}).resolve,
          throwsTokenline(contains('unresolved alias')));
      expect((setOf({'a.x': ('color', 'teal')})..resolve()).validateValues,
          throwsTokenline(contains('#RRGGBB')));
      expect((setOf({'a.x': ('duration', '2s')})..resolve()).validateValues,
          throwsTokenline(contains('<n>ms')));
    });

    test('group \$type is inherited (DTCG)', () {
      final root = createFixtureProject();
      final model = TokenModel.load(loadFixture(root));
      expect(model.primitives.tokens['color.neutral.900']!.type, 'color');
      expect(model.primitives.tokens['space.16']!.type, 'dimension');
    });

    test('themes must define the same tokens', () {
      final root = createFixtureProject();
      final dark =
          File(p.join(root, 'design_tokens', 'semantic', 'dark.tokens.json'));
      final json = jsonDecode(dark.readAsStringSync()) as Map<String, Object?>;
      ((json['color'] as Map)['text'] as Map).remove('secondary');
      dark.writeAsStringSync(jsonEncode(json));
      expect(() => TokenModel.load(loadFixture(root)),
          throwsTokenline(contains('missing in dark: color.text.secondary')));
    });

    test('patterns expand in sorted order', () {
      final root = createFixtureProject();
      expect(
          expandPatterns(
              p.join(root, 'design_tokens'), ['primitives/*.tokens.json']),
          [
            'primitives/colors.tokens.json',
            'primitives/motion.tokens.json',
            'primitives/radius.tokens.json',
            'primitives/spacing.tokens.json',
            'primitives/typography.tokens.json',
          ]);
      expect(
          () => expandPatterns(p.join(root, 'design_tokens'), ['nope/*.json']),
          throwsTokenline(contains('no token files match')));
    });
  });

  group('emitter', () {
    test('layout, names and imports', () {
      final root = createFixtureProject();
      final config = loadFixture(root);
      final result = emit(config, TokenModel.load(config));
      final byName = {
        for (final f in result.files) p.basename(f.path): f.content
      };
      expect(byName.keys, [
        'fx_colors.g.dart',
        'fx_spacing.g.dart',
        'fx_radius.g.dart',
        'fx_typography.g.dart',
        'fx_motion.g.dart'
      ]);
      final colors = byName['fx_colors.g.dart']!;
      expect(colors, contains("import 'package:flutter/widgets.dart';"));
      expect(colors, contains('abstract final class FxColors {'));
      expect(colors, contains('abstract final class FxColorsLight {'));
      expect(colors, contains('abstract final class FxComponentColorsDark {'));
      expect(colors,
          contains('static const Color neutral900 = Color(0xFF1B1C21);'));
      expect(colors, contains('/// App background.'));
      expect(byName['fx_spacing.g.dart'], isNot(contains('import')));
      expect(byName['fx_motion.g.dart'],
          contains("import 'package:flutter/animation.dart';"));
      expect(byName['fx_motion.g.dart'], contains('Cubic(0.2, 0, 0, 1)'));
      expect(byName['fx_radius.g.dart'],
          contains('static const BorderRadius mdBr'));
      expect(byName['fx_typography.g.dart'],
          contains('static const double v2xl = 24.0;'));
      expect(
          colors,
          startsWith('// GENERATED CODE — DO NOT MODIFY BY HAND.\n'
              '// Source: design_tokens/  (fixture-tokens v1.2.3)\n'));
      // The component radius has no generated home yet: reported, not lost.
      expect(result.skipped, ['button.radius']);
    });

    test('name clashes are refused', () {
      final root = createFixtureProject();
      final f = File(
          p.join(root, 'design_tokens', 'primitives', 'spacing.tokens.json'));
      final json = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      (json['space'] as Map)['1'] = {
        '6': {r'$value': '16'},
      };
      f.writeAsStringSync(jsonEncode(json));
      final config = loadFixture(root);
      expect(() => emit(config, TokenModel.load(config)),
          throwsTokenline(contains('both become')));
    });
  });

  group('figma sources', () {
    test('legacy sync frame: zero widths read as 0, semantic re-links by hex',
        () {
      final values = parseSyncFrame({
        'children': [
          {
            'name': 'color.brand.500',
            'type': 'RECTANGLE',
            'fills': [
              {
                'type': 'SOLID',
                'color': {'r': 0, 'g': 0, 'b': 1, 'a': 1}
              },
            ],
          },
          {
            'name': 'space.0',
            'type': 'RECTANGLE',
            'absoluteBoundingBox': {'width': 0.01}
          },
          {
            'name': 'light',
            'type': 'FRAME',
            'children': [
              {
                'name': 'color.text.primary',
                'type': 'RECTANGLE',
                'fills': [
                  {
                    'type': 'SOLID',
                    'color': {'r': 0, 'g': 0, 'b': 1, 'a': 1}
                  },
                ],
              },
            ],
          },
        ],
      });
      expect(values['space.0'], {'value': '0'});
      expect(values['color.brand.500'], {'value': '#0000FF'});

      final root = createFixtureProject();
      final config = loadFixture(root);
      final changes =
          diffResolved(config, TokenModel.load(config), values).changes;
      expect(changes.map((c) => c.describe()), [
        'CHANGE  primitives: color.brand.500: #1B6FE8 -> #0000FF',
        'CHANGE  semantic: color.text.primary (light): {color.neutral.900} (#1B1C21) -> {color.brand.500}',
      ]);
    });

    test('variables API response converts with links', () {
      final s = variablesApiToSnapshot({
        'meta': {
          'variableCollections': {
            'C1': {
              'id': 'C1',
              'name': 'Primitives',
              'modes': [
                {'modeId': 'm1', 'name': 'Base'},
              ],
            },
            'C2': {
              'id': 'C2',
              'name': 'Semantic',
              'modes': [
                {'modeId': 'm2', 'name': 'Light'},
              ],
            },
          },
          'variables': {
            'V1': {
              'id': 'V1',
              'name': 'neutral/900',
              'variableCollectionId': 'C1',
              'resolvedType': 'COLOR',
              'valuesByMode': {
                'm1': {'r': 0.1, 'g': 0.2, 'b': 0.3, 'a': 0.5},
              },
            },
            'V2': {
              'id': 'V2',
              'name': 'text/primary',
              'variableCollectionId': 'C2',
              'resolvedType': 'COLOR',
              'valuesByMode': {
                'm2': {'type': 'VARIABLE_ALIAS', 'id': 'V1'},
              },
            },
          },
        },
      });
      expect(s.variables.first.values['Base']!.toJson(), '#1A334D80');
      final alias = s.variables.last.values['Light'] as FigmaAlias;
      expect([alias.id, alias.name, alias.collection],
          ['V1', 'neutral/900', 'Primitives']);
    });

    test('plugin data reassembles chunks and explains a missing export', () {
      final snap =
          FigmaSnapshot(source: 'plugin', collections: [], variables: []);
      final text = jsonEncode(snap.toJson());
      final half = text.length ~/ 2;
      final s = pluginDataToSnapshot({
        'sharedPluginData': {
          'tokenline': {
            'snapshot.meta': jsonEncode({'chunks': 2}),
            'snapshot.0': text.substring(0, half),
            'snapshot.1': text.substring(half),
          },
        },
      }, fileKey: 'K');
      expect(s.fileKey, 'K');
      expect(() => pluginDataToSnapshot({}),
          throwsTokenline(contains('click Export')));
    });
  });

  test('embedded plugin assets are current', () {
    final r = Process.runSync(Platform.resolvedExecutable,
        ['run', 'tool/embed_plugin.dart', '--check']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
  });
}
