import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/generate.dart';
import 'errors.dart';

/// Runs the `tokenline` command line and returns the exit code.
Future<int> runTokenline(List<String> args) async {
  final runner = CommandRunner<int>('tokenline',
      'Design tokens for Flutter, synced with Figma.')
    ..argParser.addOption('root',
        abbr: 'C', help: 'Project root (default: current directory).')
    ..argParser.addOption('config',
        help: 'Path to tokenline.yaml (default: <root>/tokenline.yaml).')
    ..addCommand(ValidateCommand())
    ..addCommand(GenerateCommand())
    ..addCommand(CheckCommand());
  try {
    return await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on TokenlineException catch (e) {
    stderr.writeln(e.exitCode == 2 ? e.message : 'error: ${e.message}');
    return e.exitCode;
  }
}
