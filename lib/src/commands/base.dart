import 'dart:io';

import 'package:args/command_runner.dart';

import '../config.dart';
import '../emit/emitter.dart';
import '../emit/writer.dart';
import '../loader.dart';

/// Shared plumbing: config loading and console output.
abstract class TokenlineCommand extends Command<int> {
  TokenlineConfig? _config;

  TokenlineConfig get config => _config ??= TokenlineConfig.load(
        root: globalResults?['root'] as String?,
        configPath: globalResults?['config'] as String?,
      );

  void info(String message) => stdout.writeln(message);
  void warn(String message) => stderr.writeln('warning: $message');

  /// Loads tokens, emits Dart and writes it (or only checks, with [check]).
  /// Returns the changed paths.
  List<String> regenerate({required bool check, bool quiet = false}) {
    final model = TokenModel.load(config);
    final result = emit(config, model);
    if (!quiet && result.skipped.isNotEmpty) {
      warn('${result.skipped.length} token(s) have no generated class '
          '(${result.skipped.take(3).join(', ')}${result.skipped.length > 3 ? ', …' : ''}) '
          '— `tokenline validate` lists them');
    }
    return writeGenerated(config, result.files, check: check);
  }
}
