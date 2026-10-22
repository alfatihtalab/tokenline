import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../figma/plan.dart';
import '../figma/push.dart';
import '../lint/token_rules.dart';
import '../loader.dart';
import 'base.dart';

class PushCommand extends TokenlineCommand {
  @override
  bool get hidden => true;

  PushCommand() {
    argParser.addFlag('prune',
        negatable: false,
        help: 'Also delete Figma variables (in the managed collections) that '
            'are not in the token files. Drafts are never deleted.');
  }

  @override
  String get name => 'push';

  @override
  String get description =>
      'Write the files that apply the token files to Figma.';

  @override
  int run() {
    final figma = config.figma ??
        (throw TokenlineException('tokenline.yaml has no figma section'));
    final prune = argResults!['prune'] as bool;
    final model = TokenModel.load(config);
    final issues = lintTokens(config, model);
    if (issues.isNotEmpty) {
      throw TokenlineException('not pushing: the token files break '
          '${issues.length} rule(s) Figma would reject:\n'
          '${issues.map((i) => '  ${i.message} [${i.code}]').join('\n')}');
    }
    final plan = FigmaPlan.build(config, model);
    final payload = buildPushPayload(config, plan);

    final scriptPath = config.resolve(figma.pushScript);
    final dir = Directory(p.dirname(scriptPath))..createSync(recursive: true);
    final json = File(p.setExtension(scriptPath, '.json'))
      ..writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(payload)}\n');

    // Drop parts left over from an earlier, bigger push.
    final stem = p.basenameWithoutExtension(scriptPath);
    final partName = RegExp('^${RegExp.escape(stem)}\\.\\d+\\.js\$');
    for (final f in dir.listSync().whereType<File>()) {
      if (partName.hasMatch(p.basename(f.path))) f.deleteSync();
    }
    final scripts = buildPushScripts(payload, prune: prune);
    final written = <File>[];
    if (scripts.length == 1) {
      written.add(File(scriptPath)..writeAsStringSync(scripts.single));
    } else {
      final single = File(scriptPath);
      if (single.existsSync()) single.deleteSync();
      for (var i = 0; i < scripts.length; i++) {
        written.add(File(p.join(dir.path, '$stem.${i + 1}.js'))
          ..writeAsStringSync(scripts[i]));
      }
    }

    String rel(File f) => p.relative(f.path, from: config.root);
    info('${plan.variables.length} variables in '
        '${figma.collections.length} collection(s)${prune ? ' (prune: deletes extras)' : ''}\n'
        'Apply in Figma, either:\n'
        '  • Tokenline plugin → Import push file… → ${rel(json)}\n'
        '  • ask Claude to run ${written.length == 1 ? rel(written.single) : '${written.map(rel).join(', ')} (in order)'} with use_figma');
    return 0;
  }
}
