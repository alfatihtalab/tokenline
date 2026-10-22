import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../figma/adopt.dart';
import '../figma/diff.dart';
import '../figma/plan.dart';
import '../figma/push.dart';
import '../figma/snapshot.dart';
import '../figma/state.dart';
import '../figma/sync.dart';
import '../lint/rules.dart';
import '../lint/token_rules.dart';
import '../loader.dart';
import 'base.dart';

/// The port the Tokenline plugin calls (fixed: Figma's manifest names it).
const syncPort = 4747;

/// `tokenline sync`: waits for the Tokenline plugin, then syncs both ways.
class SyncCommand extends TokenlineCommand {
  SyncCommand() {
    argParser
      ..addOption('prefer',
          allowed: ['figma', 'code'],
          help: 'Settle every conflict this way instead of asking.')
      ..addFlag('watch',
          negatable: false,
          help: 'Keep waiting for more syncs instead of stopping after one.')
      ..addFlag('allow-removals',
          negatable: false,
          help: 'Accept tokens removed or renamed in Figma without being '
              'deprecated first (breaks code that uses them).')
      ..addOption('port', defaultsTo: '$syncPort', hide: true)
      ..addFlag('exit-on-error', negatable: false, hide: true); // tests
  }

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Sync Figma and the token files both ways (then open the Tokenline plugin).';

  TokenModel? _model;
  FigmaPlan? _plan;
  List<String> _generated = const [];

  @override
  Future<int> run() async {
    if (config.figma == null) {
      throw TokenlineException('tokenline.yaml has no figma section');
    }
    TokenModel.load(config); // fail early on broken token files
    final port = int.parse(argResults!['port'] as String);
    final watch = argResults!['watch'] as bool;

    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException {
      throw TokenlineException('port $port is busy — is another '
          '`tokenline sync` running? Stop it (Ctrl+C) and try again.');
    }
    info('Waiting for Figma… open the Tokenline plugin in your Figma file '
        '(Plugins → Development → Tokenline; ⌥⌘P runs it again).\n'
        'Press Ctrl+C to stop.');

    final finished = Completer<void>();
    final sub = server.listen((request) async {
      try {
        await _handle(request, () {
          if (!watch && !finished.isCompleted) finished.complete();
        });
      } on Object catch (e) {
        stderr.writeln('error: $e');
        await _reply(request, {'ok': false, 'error': '$e'});
      }
    });
    await finished.future;
    // Force: the plugin's fetch keeps its connection open, and a polite
    // close would wait for it to time out.
    await server.close(force: true);
    await sub.cancel();
    return 0;
  }

  Future<void> _handle(HttpRequest request, void Function() onDone) async {
    if (request.method == 'OPTIONS') return _reply(request, null);
    switch ((request.method, request.uri.path)) {
      case ('GET', '/hello'):
        return _reply(request, {
          'ok': true,
          'project': config.name,
          'version': config.version,
        });
      case ('POST', '/sync'):
        final body = await _body(request);
        try {
          final result = _syncPlan(
              FigmaSnapshot.fromJson(body['snapshot'] as Map<String, Object?>),
              body['fileName'] as String? ?? 'Figma');
          return await _reply(request, result);
        } on TokenlineException catch (e) {
          stderr.writeln(
              '\n✗ ${e.message}\n\nFix it, then click Sync in the plugin again.');
          await _reply(request, {'ok': false, 'error': e.message});
          if (argResults!['exit-on-error'] as bool) onDone();
          return;
        }
      case ('POST', '/done'):
        final body = await _body(request);
        final result = _finish(
            FigmaSnapshot.fromJson(body['snapshot'] as Map<String, Object?>));
        await _reply(request, result);
        if (result['ok'] == true) onDone();
        return;
    }
    request.response.statusCode = HttpStatus.notFound;
    await _reply(request, {'ok': false, 'error': 'unknown request'});
  }

  /// Step 1: decide, update the token files, answer with what Figma needs.
  Map<String, Object?> _syncPlan(FigmaSnapshot figma, String fileName) {
    info(
        '\nSyncing with "$fileName" (${figma.variables.length} variables in Figma)…');
    var model = TokenModel.load(config);
    var plan = FigmaPlan.build(config, model);

    final figmaIssues = lintSnapshot(figma, config.figma!, config.lint);
    final figmaErrors =
        figmaIssues.where((i) => i.severity == Severity.error).toList();
    if (figmaErrors.isNotEmpty) {
      throw TokenlineException('${figmaErrors.length} rule error(s) in Figma '
          '(the plugin\'s Lint shows each one):\n'
          '${figmaErrors.map((i) => '  ${i.message}').join('\n')}');
    }
    final codeIssues = lintTokens(config, model);
    if (codeIssues.isNotEmpty) {
      throw TokenlineException(
          '${codeIssues.length} rule error(s) in the token files:\n'
          '${codeIssues.map((i) => '  ${i.message}').join('\n')}');
    }

    final decision =
        decideSync(config, model, plan, figma, readFigmaBase(config));
    for (final w in decision.warnings) {
      warn(w);
    }
    if (decision.firstSync) {
      info('First sync: where Figma and the code disagree, you choose.');
    }
    _settleConflicts(decision);

    if (decision.breaking.isNotEmpty) {
      if (argResults!['allow-removals'] as bool) {
        decision.adopt.addAll(decision.breaking);
      } else {
        throw TokenlineException('${decision.breaking.length} token(s) were '
            'removed or renamed in Figma without being deprecated first:\n'
            '${decision.breaking.map((c) => '  ${c.describe()}').join('\n')}\n'
            'Code that uses them would stop compiling. In Figma, restore them '
            'and mark them "@deprecated → new/name" instead — or run '
            '`tokenline sync --allow-removals` to accept the break.');
      }
    }

    final lines = describeDecision(decision);
    for (final l in lines) {
      info('  $l');
    }
    if (decision.adopt.isNotEmpty) {
      adoptChanges(config, model, decision.adopt);
      model = TokenModel.load(config);
      plan = FigmaPlan.build(config, model);
    }
    _generated = regenerate(check: false, quiet: true);
    _model = model;
    _plan = plan;
    final payload = buildPushPayload(config, plan)
      ..['delete'] = decision.deleteInFigma;
    return {
      'ok': true,
      'payload': payload,
      'summary': {
        'lines': lines.isEmpty ? ['No changes on either side'] : lines,
      },
      'warnings': [
        ...decision.warnings,
        for (final i in figmaIssues) i.message,
      ],
    };
  }

  void _settleConflicts(SyncDecision decision) {
    if (decision.conflicts.isEmpty) return;
    final prefer = argResults!['prefer'] as String?;
    if (prefer != null) {
      final side = prefer == 'figma' ? Side.figma : Side.code;
      for (final c in decision.conflicts) {
        decision.resolve(c, side);
      }
      info('${decision.conflicts.length} conflict(s) settled: keeping $prefer');
      return;
    }
    if (!stdin.hasTerminal) {
      throw TokenlineException('${decision.conflicts.length} token(s) changed '
          'on both sides:\n'
          '${decision.conflicts.map((c) => '  ${c.question}').join('\n')}\n'
          'Run sync in a terminal to choose, or pass --prefer figma|code.');
    }
    info('\n${decision.conflicts.length} token(s) changed on both sides. '
        'For each, keep Figma (f) or code (c). F or C settles all the rest.');
    Side? all;
    for (final c in decision.conflicts) {
      var side = all;
      while (side == null) {
        stdout.write('  ${c.question}\n    keep [f]igma or [c]ode? ');
        switch (stdin.readLineSync()?.trim()) {
          case 'f':
            side = Side.figma;
          case 'c':
            side = Side.code;
          case 'F':
            side = all = Side.figma;
          case 'C':
            side = all = Side.code;
          case null:
            throw TokenlineException('${decision.conflicts.length} token(s) '
                'changed on both sides and no answer came from the terminal:\n'
                '${decision.conflicts.map((c) => '  ${c.question}').join('\n')}\n'
                'Run sync in a terminal to choose, or pass --prefer figma|code.');
        }
      }
      decision.resolve(c, side);
    }
  }

  /// Step 2: Figma applied the payload; check and remember the result.
  Map<String, Object?> _finish(FigmaSnapshot after) {
    final model = _model, plan = _plan;
    if (model == null || plan == null) {
      return {
        'ok': false,
        'error': 'click Sync again — this run lost track of the sync'
      };
    }
    final diff = diffSnapshot(config, model, plan, after);
    final left = diff.changes.where((c) => c.kind != ChangeKind.added).toList();
    if (left.isNotEmpty) {
      final msg = 'Figma still differs in ${left.length} place(s):\n'
          '${left.map((c) => '  ${c.describe()}').join('\n')}';
      stderr.writeln('\n✗ $msg');
      return {'ok': false, 'error': msg};
    }
    saveFigmaState(config, after, diff.ids);
    final generated = _generated;
    final message =
        '✓ In sync.${generated.isEmpty ? '' : ' Updated ${generated.length} Dart file(s).'}'
        ' Review the changes (git diff) and commit them, including '
        '${config.figma!.snapshotFile} — it is the starting point for the next sync.';
    info('\n$message');
    return {'ok': true, 'message': message};
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    return jsonDecode(text) as Map<String, Object?>;
  }

  Future<void> _reply(HttpRequest request, Map<String, Object?>? json) async {
    final r = request.response;
    r.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..set('Access-Control-Allow-Private-Network', 'true');
    if (json == null) {
      r.statusCode = HttpStatus.noContent;
    } else {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(json));
    }
    await r.close();
  }
}
