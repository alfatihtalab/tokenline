import '../config.dart';
import '../errors.dart';
import '../figma/rest.dart';
import '../figma/snapshot.dart';
import '../lint/rules.dart';
import 'base.dart';

class LintCommand extends TokenlineCommand {
  @override
  bool get hidden => true;

  LintCommand() {
    argParser.addOption('from-file',
        valueHelp: 'export.json',
        help: 'Lint a plugin export instead of reading Figma.');
  }

  @override
  String get name => 'lint';

  @override
  String get description =>
      'Check Figma variables against the token rules (same rules as the plugin).';

  @override
  Future<int> run() async {
    final figma = config.figma ??
        (throw TokenlineException('tokenline.yaml has no figma section'));
    final fromFile = argResults!['from-file'] as String?;
    final FigmaSnapshot snapshot;
    if (fromFile != null) {
      snapshot = FigmaSnapshot.readFile(fromFile);
    } else {
      if (figma.source == FigmaSource.syncFrame) {
        throw TokenlineException('lint needs the plugin export or the '
            'Variables API; the legacy sync frame has no names or links. '
            'Use --from-file with a plugin export.');
      }
      final rest = FigmaRest(FigmaCredentials.resolve(config));
      try {
        snapshot = figma.source == FigmaSource.plugin
            ? await rest.pluginSnapshot()
            : await rest.variablesSnapshot();
      } finally {
        rest.close();
      }
    }
    final issues = lintSnapshot(snapshot, figma, config.lint);
    for (final i in issues) {
      info('  $i');
    }
    final errors = issues.where((i) => i.severity == Severity.error).length;
    info('${snapshot.variables.length} variables: $errors error(s), '
        '${issues.length - errors} warning(s)');
    return errors > 0 ? 1 : 0;
  }
}
