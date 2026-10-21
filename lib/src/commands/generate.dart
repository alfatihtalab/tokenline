import '../emit/emitter.dart';
import '../errors.dart';
import '../loader.dart';
import 'base.dart';

class GenerateCommand extends TokenlineCommand {
  GenerateCommand() {
    argParser.addFlag('check',
        negatable: false,
        help: 'Only verify the generated files are current; exit 2 if not.');
  }

  @override
  String get name => 'generate';

  @override
  String get description =>
      'Regenerate the Dart token classes from the token files.';

  @override
  int run() {
    final check = argResults!['check'] as bool;
    final changed = regenerate(check: check);
    if (check) return reportCheck(changed);
    info(changed.isEmpty
        ? 'no changes — generated files are current'
        : 'wrote ${changed.length} file(s):\n  ${changed.join('\n  ')}');
    return 0;
  }

  int reportCheck(List<String> changed) {
    if (changed.isEmpty) {
      info('generated files are current');
      return 0;
    }
    throw TokenlineException(
        'out of date — run `dart run tokenline generate`:\n  '
        '${changed.join('\n  ')}',
        exitCode: 2);
  }
}

class CheckCommand extends GenerateCommand {
  @override
  String get name => 'check';

  @override
  String get description =>
      'CI gate: tokens are valid and generated files are current.';

  @override
  int run() => reportCheck(regenerate(check: true));
}

class ValidateCommand extends TokenlineCommand {
  @override
  String get name => 'validate';

  @override
  String get description =>
      'Check token files: types, values, aliases, cycles, themes and names.';

  @override
  int run() {
    final model = TokenModel.load(config);
    final result = emit(config, model); // also catches name clashes
    for (final s in result.skipped) {
      warn('$s is not emitted by any generated class');
    }
    final themes = model.modes.isEmpty ? '' : ', themes: ${model.modes.join(', ')}';
    info('valid — ${model.primitives.tokens.length} primitives, '
        '${model.semantic.values.firstOrNull?.tokens.length ?? 0} semantic, '
        '${model.components.values.firstOrNull?.tokens.length ?? 0} component tokens'
        '$themes');
    return 0;
  }
}
