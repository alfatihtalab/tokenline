import 'dart:io';

import 'package:path/path.dart' as p;

import '../figma/plugin_assets.g.dart';
import 'base.dart';

class PluginCommand extends TokenlineCommand {
  PluginCommand() {
    argParser.addOption('out',
        defaultsTo: 'figma_plugin', help: 'Folder to write the plugin into.');
  }

  @override
  String get name => 'plugin';

  @override
  String get description =>
      'Write the Tokenline Figma plugin (Lint, Fix, Export, Import).';

  @override
  int run() {
    final root = globalResults?['root'] as String? ?? '.';
    final out = Directory(p.join(root, argResults!['out'] as String))
      ..createSync(recursive: true);
    final files = {
      'manifest.json': pluginManifestJson,
      'code.js': pluginCodeJs,
      'ui.html': pluginUiHtml,
    };
    files.forEach((name, content) {
      File(p.join(out.path, name)).writeAsStringSync(content);
    });
    info('wrote the plugin to ${p.normalize(out.path)}/\n'
        'In Figma: Plugins → Development → Import plugin from manifest… → '
        '${p.normalize(p.join(out.path, 'manifest.json'))}\n'
        'The plugin reads its rules from the Figma file; run '
        '`dart run tokenline push` and apply it once to store them.');
    return 0;
  }
}
