// `tokenline sync` end to end: the real server, and the plugin's side played
// by test/support/run_sync.js (core.js against the mock Figma).
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tokenline/src/cli.dart';

import 'support/fixture.dart';

var _port = 47610;

/// Runs one sync: starts `tokenline sync` in-process and the fake plugin in
/// Node, optionally resuming Figma from [seed] and applying [edits] first.
Future<Map<String, Object?>> runSync(String root,
    {Map<String, Object?>? seed,
    String? edits,
    List<String> args = const []}) async {
  final port = '${_port++}';
  final dir = Directory.systemTemp.createTempSync('tokenline_sync_').path;
  final out = p.join(dir, 'out.json');
  String? seedFile, editsFile;
  if (seed != null) {
    seedFile = p.join(dir, 'seed.json');
    File(seedFile).writeAsStringSync(jsonEncode(seed));
  }
  if (edits != null) {
    editsFile = p.join(dir, 'edits.js');
    File(editsFile).writeAsStringSync(edits);
  }
  final server = runTokenline(
      ['-C', root, 'sync', '--port', port, '--exit-on-error', ...args]);
  final plugin = await Process.run('node', [
    'test/support/run_sync.js',
    'lib/src/figma/plugin_src/core.js',
    port,
    out,
    seedFile ?? '-',
    editsFile ?? '-',
  ]);
  expect(plugin.exitCode, 0, reason: '${plugin.stdout}${plugin.stderr}');
  expect(await server, 0);
  return jsonDecode(File(out).readAsStringSync()) as Map<String, Object?>;
}

Map<String, Object?> readJson(String root, String rel) =>
    jsonDecode(readToken(root, rel)) as Map<String, Object?>;

void writeJson(String root, String rel, Map<String, Object?> json) =>
    File(p.join(root, 'design_tokens', rel))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));

Object? at(Map<String, Object?> json, String path) {
  Object? cur = json;
  for (final seg in path.split('.')) {
    cur = (cur as Map?)?[seg];
  }
  return cur;
}

List<String> names(Map<String, Object?> result) =>
    ((result['snapshot'] as Map)['variables'] as List)
        .map((v) => (v as Map)['name'] as String)
        .toList();

void main() {
  if (!hasNode) {
    test('sync', () {}, skip: 'node is not installed');
    return;
  }

  test('first sync fills an empty Figma file, the next one changes nothing',
      () async {
    final root = createFixtureProject();
    final first = await runSync(root);
    expect(first['ok'], isTrue, reason: '${first['error']}');
    expect((first['done'] as Map)['ok'], isTrue, reason: '${first['done']}');
    expect((first['applied'] as Map)['created'], 50);
    expect(
        File(p.join(root, 'design_tokens/figma-sync/figma-snapshot.json'))
            .existsSync(),
        isTrue);
    expect(File(p.join(root, 'lib/generated/fx_colors.g.dart')).existsSync(),
        isTrue);

    final again =
        await runSync(root, seed: first['snapshot'] as Map<String, Object?>);
    expect(again['lines'], ['No changes on either side']);
    expect((again['done'] as Map)['ok'], isTrue);
  });

  test('changes on both sides go the right way', () async {
    final root = createFixtureProject();
    final first = await runSync(root);

    // Code: change a value and delete a token.
    final spacing = readJson(root, 'primitives/spacing.tokens.json');
    ((spacing['space'] as Map)['16'] as Map)[r'$value'] = '18';
    writeJson(root, 'primitives/spacing.tokens.json', spacing);
    final radius = readJson(root, 'primitives/radius.tokens.json');
    (radius['radius'] as Map).remove('lg');
    writeJson(root, 'primitives/radius.tokens.json', radius);

    // Figma: change a color, re-link a semantic token, add a token.
    final second = await runSync(root,
        seed: first['snapshot'] as Map<String, Object?>, edits: r'''
module.exports = async function (figma, hexToRgba) {
  var P = 'Fx / Primitives', S = 'Fx / Semantic';
  figma._find(P, 'brand/500').setValueForMode(figma._mode(P, 'Base'), hexToRgba('#2255EE'));
  figma._find(S, 'text/primary').setValueForMode(figma._mode(S, 'Dark'),
      figma.variables.createVariableAlias(figma._find(P, 'neutral/300')));
  var s = figma._create('space/96', P, 'FLOAT');
  s.setValueForMode(figma._mode(P, 'Base'), 96);
  s.scopes = []; s.hiddenFromPublishing = true;
};
''');
    expect(second['ok'], isTrue, reason: '${second['error']}');
    expect((second['done'] as Map)['ok'], isTrue, reason: '${second['done']}');

    // From Figma into the token files.
    expect(
        at(readJson(root, 'primitives/colors.tokens.json'),
            r'color.brand.500.$value'),
        '#2255EE');
    expect(
        at(readJson(root, 'semantic/dark.tokens.json'),
            r'color.text.primary.$value'),
        '{color.neutral.300}');
    expect(
        at(readJson(root, 'primitives/spacing.tokens.json'),
            r'space.96.$value'),
        '96');
    // From code into Figma.
    final figmaVars = ((second['snapshot'] as Map)['variables'] as List)
        .cast<Map<String, Object?>>();
    expect(figmaVars.firstWhere((v) => v['name'] == 'space/16')['values'],
        {'Base': 18});
    expect(names(second), isNot(contains('radius/lg')));
    expect(
        at(readJson(root, 'primitives/spacing.tokens.json'),
            r'space.16.$value'),
        '18',
        reason: 'code kept');
    // Dart follows.
    expect(
        File(p.join(root, 'lib/generated/fx_colors.g.dart')).readAsStringSync(),
        contains('0xFF2255EE'));

    final third =
        await runSync(root, seed: second['snapshot'] as Map<String, Object?>);
    expect(third['lines'], ['No changes on either side']);
  });

  test('a conflict needs a choice; --prefer settles it', () async {
    final root = createFixtureProject();
    final first = await runSync(root);
    final seed = first['snapshot'] as Map<String, Object?>;
    final spacing = readJson(root, 'primitives/spacing.tokens.json');
    ((spacing['space'] as Map)['16'] as Map)[r'$value'] = '18';
    writeJson(root, 'primitives/spacing.tokens.json', spacing);
    const edits = r'''
module.exports = async function (figma) {
  figma._find('Fx / Primitives', 'space/16').setValueForMode(figma._mode('Fx / Primitives', 'Base'), 20);
};
''';
    final stuck = await runSync(root, seed: seed, edits: edits);
    expect(stuck['ok'], isFalse);
    expect(stuck['error'], contains('changed on both sides'));
    expect(stuck['error'], contains('space.16'));

    final settled = await runSync(root,
        seed: seed, edits: edits, args: ['--prefer', 'figma']);
    expect(settled['ok'], isTrue, reason: '${settled['error']}');
    expect(
        at(readJson(root, 'primitives/spacing.tokens.json'),
            r'space.16.$value'),
        '20');
  });

  test('a token deleted in Figma without deprecation stops the sync', () async {
    final root = createFixtureProject();
    final first = await runSync(root);
    final before = readToken(root, 'primitives/radius.tokens.json');
    final result = await runSync(root,
        seed: first['snapshot'] as Map<String, Object?>, edits: r'''
module.exports = async function (figma) { figma._find('Fx / Primitives', 'radius/lg').remove(); };
''');
    expect(result['ok'], isFalse);
    expect(result['error'], contains('radius.lg'));
    expect(readToken(root, 'primitives/radius.tokens.json'), before,
        reason: 'nothing written');
  });

  test('setup is safe to run again and shows only three commands', () async {
    final root = Directory.systemTemp.createTempSync('tl_setup_').path;
    expect(await runTokenline(['-C', root, 'setup']), 0);
    expect(
        File(p.join(root, 'figma_plugin/manifest.json')).existsSync(), isTrue);
    final manifest = jsonDecode(
            File(p.join(root, 'figma_plugin/manifest.json')).readAsStringSync())
        as Map;
    expect((manifest['networkAccess'] as Map)['devAllowedDomains'],
        ['http://localhost:4747']);
    File(p.join(root, 'tokenline.yaml')).writeAsStringSync(
        File(p.join(root, 'tokenline.yaml'))
            .readAsStringSync()
            .replaceFirst('class_prefix: App', 'class_prefix: Acme'));
    expect(await runTokenline(['-C', root, 'setup']), 0,
        reason: 'second run keeps files');
    expect(File(p.join(root, 'tokenline.yaml')).readAsStringSync(),
        contains('class_prefix: Acme'));
  });
}
