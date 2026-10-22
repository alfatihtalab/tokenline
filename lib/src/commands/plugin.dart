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
  bool get hidden => true;

  @override
  int run() {
    final root = globalResults?['root'] as String? ?? '.';
    final manifest = writePlugin(p.join(root, argResults!['out'] as String));
    info('wrote the plugin. In Figma: Plugins → Development → '
        'Import plugin from manifest… → $manifest');
    return 0;
  }
}

/// Writes the plugin into [dir]; returns the manifest's absolute path.
String writePlugin(String dir) {
  final out = Directory(dir)..createSync(recursive: true);
  final files = {
    'manifest.json': pluginManifestJson,
    'code.js': pluginCodeJs,
    'ui.html': pluginUiHtml,
  };
  files.forEach((name, content) {
    File(p.join(out.path, name)).writeAsStringSync(content);
  });
  return p.normalize(p.absolute(out.path, 'manifest.json'));
}
