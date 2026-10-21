/// Design tokens for Flutter, synced with Figma.
///
/// Most projects only use the command line (`dart run tokenline`); these
/// exports are for tools that want to drive tokenline from Dart.
library;

export 'src/cli.dart' show runTokenline;
export 'src/config.dart' show TokenlineConfig, FigmaSource;
export 'src/emit/emitter.dart' show emit, EmitResult, GeneratedFile;
export 'src/errors.dart' show TokenlineException;
export 'src/figma/diff.dart'
    show diffSnapshot, SnapshotDiff, TokenChange, ChangeKind;
export 'src/figma/plan.dart' show FigmaPlan;
export 'src/figma/snapshot.dart' show FigmaSnapshot;
export 'src/lint/rules.dart' show lintSnapshot, LintIssue, Severity;
export 'src/loader.dart' show TokenModel;
export 'src/names.dart' show Level, NameCase;
