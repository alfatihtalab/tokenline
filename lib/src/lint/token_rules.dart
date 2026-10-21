// The level rules from lint/rules.dart, applied to the token files, so
// `validate` and `push` refuse what the Figma-side lint would reject later.
import '../config.dart';
import '../loader.dart';
import '../names.dart';
import '../tokens.dart';
import 'rules.dart';

List<LintIssue> lintTokens(TokenlineConfig config, TokenModel model) {
  final issues = <LintIssue>[];
  void error(String code, String message) =>
      issues.add(LintIssue(code, Severity.error, message));

  for (final t in model.primitives.tokens.values) {
    final group = t.path.split('.').first;
    if (t.type != 'color' &&
        t.type != 'shadow' &&
        !config.lint.groups.contains(group)) {
      error(
          'name-group',
          '${t.path} (${t.source}) — number and text '
              'primitives must start with one of: ${config.lint.groups.join(', ')} '
              '(add more under lint.groups)');
    }
  }

  for (final MapEntry(key: mode, value: set) in model.semantic.entries) {
    for (final t in set.tokens.values) {
      if (!t.isAlias) {
        error('semantic-raw',
            '${t.path} ($mode) has a typed value; link it to a primitive');
      } else if (model.levelOf(t.aliasTarget) != Level.primitives) {
        error('semantic-link-target',
            '${t.path} ($mode) links to {${t.aliasTarget}}; semantic tokens link to primitives');
      }
    }
  }

  // Component values do not change per theme; check them once.
  final components = model.components.values.firstOrNull;
  for (final Token t in components?.tokens.values ?? const <Token>[]) {
    if (!t.isAlias) {
      error('component-raw',
          '${t.path} has a typed value; link it to a semantic token or a primitive');
      continue;
    }
    final target = model.levelOf(t.aliasTarget);
    if (t.type == 'color' && target != Level.semantic) {
      error('component-link-target',
          '${t.path} is a color and must link to a semantic token, not {${t.aliasTarget}}');
    } else if (target != Level.semantic && target != Level.primitives) {
      error('component-link-target',
          '${t.path} must link to a semantic token or a primitive, not {${t.aliasTarget}}');
    }
  }
  return issues;
}
