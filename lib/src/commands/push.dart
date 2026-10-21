import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../errors.dart';
import '../figma/plan.dart';
import '../figma/push.dart';
import '../loader.dart';
import 'base.dart';

class PushCommand extends TokenlineCommand {
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
    final plan = FigmaPlan.build(config, model);
    final payload = buildPushPayload(config, plan);

    final script = File(config.resolve(figma.pushScript));
    final json = File(p.setExtension(script.path, '.json'));
    script.parent.createSync(recursive: true);
    script.writeAsStringSync(buildPushScript(payload, prune: prune));
    json.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(payload)}\n');

    String rel(File f) => p.relative(f.path, from: config.root);
    info('${plan.variables.length} variables in '
        '${figma.collections.length} collection(s)${prune ? ' (prune: deletes extras)' : ''}\n'
        'Apply in Figma, either:\n'
        '  • Tokenline plugin → Import push file… → ${rel(json)}\n'
        '  • ask Claude to run ${rel(script)} with use_figma');
    return 0;
  }
}
