import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tokenline/src/cli.dart';
import 'package:tokenline/src/figma/plan.dart';
import 'package:tokenline/src/figma/push.dart';
import 'package:tokenline/src/loader.dart';

import 'support/fixture.dart';

void main() {
  test('init creates a working project', () async {
    final root = Directory.systemTemp.createTempSync('tl_init_').path;
    expect(
        await runTokenline(
            ['-C', root, 'init', '--prefix', 'Acme', '--file-key', 'ABC']),
        0);
    expect(
        File(p.join(root,
                'lib/design_system/foundations/generated/acme_colors.g.dart'))
            .existsSync(),
        isTrue);
    expect(File(p.join(root, '.gitignore')).readAsStringSync(),
        contains('.tokenline.env'));
    expect(File(p.join(root, 'tokenline.yaml')).readAsStringSync(),
        contains('file_key: ABC'));
    expect(await runTokenline(['-C', root, 'check']), 0);
    expect(await runTokenline(['-C', root, 'init']), 1,
        reason: 'refuses to overwrite');
  });

  test('check exits 2 when a token changes, generate fixes it', () async {
    final root = createFixtureProject();
    expect(await runTokenline(['-C', root, 'generate']), 0);
    expect(await runTokenline(['-C', root, 'check']), 0);
    final f =
        File(p.join(root, 'design_tokens/primitives/spacing.tokens.json'));
    f.writeAsStringSync(f.readAsStringSync().replaceFirst('"16"', '"18"'));
    expect(await runTokenline(['-C', root, 'check']), 2);
    expect(await runTokenline(['-C', root, 'generate']), 0);
    expect(await runTokenline(['-C', root, 'check']), 0);
  });

  test('push writes the script and the plugin import file', () async {
    final root = createFixtureProject();
    expect(await runTokenline(['-C', root, 'push']), 0);
    final js = File(p.join(root, 'design_tokens/figma-sync/push.figma.js'))
        .readAsStringSync();
    expect(
        js,
        contains(
            'return await figmaApplyPayload(TOKENLINE_PAYLOAD, { prune: false });'));
    final json = jsonDecode(
        File(p.join(root, 'design_tokens/figma-sync/push.figma.json'))
            .readAsStringSync()) as Map;
    expect(json['format'], 'tokenline.figma-push');
    expect((json['config'] as Map)['nameCase'], 'kebab');
  });

  test('plugin writes manifest, code and UI', () async {
    final root = createFixtureProject();
    expect(await runTokenline(['-C', root, 'plugin', '--out', 'plug']), 0);
    for (final f in ['manifest.json', 'code.js', 'ui.html']) {
      expect(File(p.join(root, 'plug', f)).existsSync(), isTrue, reason: f);
    }
    if (hasNode) {
      expect(
          Process.runSync('node', ['--check', p.join(root, 'plug', 'code.js')])
              .exitCode,
          0);
    }
  });

  test('pull --from-file adopts, regenerates and records ids', () async {
    if (!hasNode) return markTestSkipped('node is not installed');
    final root = createFixtureProject();
    expect(await runTokenline(['-C', root, 'generate']), 0);
    final config = loadFixture(root);
    final payload = buildPushPayload(
        config, FigmaPlan.build(config, TokenModel.load(config)));
    final out = runMockFigma(payload, edits: r'''
module.exports = async function (figma, hexToRgba) {
  figma._find('Fx / Primitives', 'space/16').setValueForMode(figma._mode('Fx / Primitives', 'Base'), 20);
};
''');
    final export = p.join(out, 'snapshot.json');

    expect(
        await runTokenline(
            ['-C', root, 'pull', '--check', '--from-file', export]),
        2);
    expect(await runTokenline(['-C', root, 'pull', '--from-file', export]), 0);
    expect(readToken(root, 'primitives/spacing.tokens.json'), contains('"20"'));
    expect(
        File(p.join(root, 'lib/generated/fx_spacing.g.dart'))
            .readAsStringSync(),
        contains('space16 = 20.0'));
    expect(
        File(p.join(root, 'design_tokens/figma-sync/figma-ids.json'))
            .existsSync(),
        isTrue);
    expect(
        await runTokenline(
            ['-C', root, 'pull', '--check', '--from-file', export]),
        0);
    expect(await runTokenline(['-C', root, 'check']), 0);
    expect(await runTokenline(['-C', root, 'lint', '--from-file', export]), 0);
  });

  test('pull refuses removals that were not deprecated first', () async {
    if (!hasNode) return markTestSkipped('node is not installed');
    final root = createFixtureProject();
    final config = loadFixture(root);
    final payload = buildPushPayload(
        config, FigmaPlan.build(config, TokenModel.load(config)));
    // A first pull records which tokens Figma has.
    expect(
        await runTokenline([
          '-C',
          root,
          'pull',
          '--from-file',
          p.join(runMockFigma(payload), 'snapshot.json')
        ]),
        0);
    final out = runMockFigma(payload, edits: r'''
module.exports = async function (figma) { figma._find('Fx / Primitives', 'radius/lg').remove(); };
''');
    final export = p.join(out, 'snapshot.json');
    final before = readToken(root, 'primitives/radius.tokens.json');
    expect(await runTokenline(['-C', root, 'pull', '--from-file', export]), 1);
    expect(readToken(root, 'primitives/radius.tokens.json'), before,
        reason: 'nothing written');
    expect(
        await runTokenline(
            ['-C', root, 'pull', '--from-file', export, '--allow-removals']),
        0);
    expect(readToken(root, 'primitives/radius.tokens.json'),
        isNot(contains('"lg"')));
  });
}
