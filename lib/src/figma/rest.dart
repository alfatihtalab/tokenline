import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../errors.dart';
import 'snapshot.dart';

/// Namespace for the plugin's data stored in the Figma file.
const pluginDataNamespace = 'tokenline';

/// Credentials, from the environment first, then the tool's env file.
///
/// The env file is tokenline's own (`.tokenline.env` by default, gitignored)
/// and never the app's `.env`, which Flutter apps often ship as an asset.
class FigmaCredentials {
  FigmaCredentials(this.token, this.fileKey);

  final String token;
  final String fileKey;

  static FigmaCredentials resolve(TokenlineConfig config) {
    final figma = config.figma;
    if (figma == null) {
      throw TokenlineException('tokenline.yaml has no figma section');
    }
    final fromFile = _readEnvFile(config.resolve(figma.envFile));
    String? lookup(String key) {
      final env = Platform.environment[key];
      if (env != null && env.isNotEmpty) return env;
      return fromFile[key];
    }

    final token = lookup('FIGMA_ACCESS_TOKEN');
    final fileKey = lookup('FIGMA_FILE_KEY') ?? figma.fileKey;
    if (token == null) {
      throw TokenlineException('FIGMA_ACCESS_TOKEN is not set. Create a '
          'personal access token in Figma (Settings → Security, file read '
          'scope) and export it, or put FIGMA_ACCESS_TOKEN=... in '
          '${figma.envFile} (keep that file out of git).');
    }
    if (fileKey == null) {
      throw TokenlineException('no Figma file: set figma.file_key in '
          'tokenline.yaml or FIGMA_FILE_KEY');
    }
    return FigmaCredentials(token, fileKey);
  }
}

Map<String, String> _readEnvFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return const {};
  final out = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final eq = t.indexOf('=');
    if (eq <= 0) continue;
    var value = t.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isNotEmpty) out[t.substring(0, eq).trim()] = value;
  }
  return out;
}

/// Minimal read-only client for the Figma REST API.
class FigmaRest {
  FigmaRest(this.credentials, {HttpClient? client})
      : _client = client ?? HttpClient();

  final FigmaCredentials credentials;
  final HttpClient _client;

  void close() => _client.close(force: true);

  Future<Map<String, Object?>> getJson(String pathAndQuery) async {
    final uri = Uri.parse('https://api.figma.com$pathAndQuery');
    final request = await _client.getUrl(uri);
    request.headers.set('X-Figma-Token', credentials.token);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    switch (response.statusCode) {
      case 200:
        return jsonDecode(body) as Map<String, Object?>;
      case 403:
        throw TokenlineException('Figma refused access (403) to $pathAndQuery. '
            'Check that the token can open this file and has file read scope'
            '${pathAndQuery.contains('/variables/') ? '; the Variables API also needs an Enterprise plan — use figma.source: plugin instead' : ''}.');
      case 404:
        throw TokenlineException('Figma file or node not found (404): '
            '$pathAndQuery — check figma.file_key');
      case 429:
        final retry = response.headers.value('retry-after');
        final type = response.headers.value('x-figma-rate-limit-type');
        throw TokenlineException('Figma rate limit reached'
            '${type == null ? '' : ' (limit type: $type)'}'
            '${retry == null ? '' : '; retry after ${retry}s'}. File reads '
            'from View or Collab seats, or files on the Starter plan, are '
            'capped at 6 a month. Export from the Tokenline plugin and run '
            '`dart run tokenline pull --from-file <export.json>` instead.');
      default:
        throw TokenlineException('Figma API ${response.statusCode} for '
            '$pathAndQuery: ${body.length > 300 ? body.substring(0, 300) : body}');
    }
  }

  Future<String> download(Uri url) async {
    final response = await (await _client.getUrl(url)).close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw TokenlineException(
          'download failed (${response.statusCode}): $url');
    }
    return body;
  }

  /// The snapshot the plugin's Export stored in the file (one request).
  Future<FigmaSnapshot> pluginSnapshot() async {
    final json = await getJson(
        '/v1/files/${credentials.fileKey}?depth=1&plugin_data=shared');
    return pluginDataToSnapshot(json['document'] as Map<String, Object?>,
        fileKey: credentials.fileKey);
  }

  /// Local variables through the Variables API (Enterprise only).
  Future<FigmaSnapshot> variablesSnapshot() async {
    final json =
        await getJson('/v1/files/${credentials.fileKey}/variables/local');
    return variablesApiToSnapshot(json, fileKey: credentials.fileKey);
  }
}

/// Reads the plugin's chunked export from a document node's shared data.
FigmaSnapshot pluginDataToSnapshot(Map<String, Object?> document,
    {String? fileKey}) {
  final shared = (document['sharedPluginData'] as Map?)?[pluginDataNamespace];
  if (shared is! Map) {
    throw TokenlineException('this Figma file has no Tokenline export yet — '
        'open the Tokenline plugin in Figma and click Export, then pull again');
  }
  final meta = jsonDecode(shared['snapshot.meta'] as String? ?? '{}') as Map;
  final chunks = meta['chunks'];
  if (chunks is! int || chunks < 1) {
    throw TokenlineException('the Tokenline export in this file is incomplete '
        '— click Export in the plugin again');
  }
  final buf = StringBuffer();
  for (var i = 0; i < chunks; i++) {
    final part = shared['snapshot.$i'];
    if (part is! String) {
      throw TokenlineException('the Tokenline export in this file is missing '
          'part $i of $chunks — click Export in the plugin again');
    }
    buf.write(part);
  }
  final snapshot = FigmaSnapshot.fromJson(
      jsonDecode(buf.toString()) as Map<String, Object?>);
  return fileKey == null || snapshot.fileKey != null
      ? snapshot
      : FigmaSnapshot(
          source: snapshot.source,
          collections: snapshot.collections,
          variables: snapshot.variables,
          fileKey: fileKey,
          fileName: snapshot.fileName,
          exportedAt: snapshot.exportedAt);
}

/// `GET /v1/files/:key/variables/local` -> snapshot.
FigmaSnapshot variablesApiToSnapshot(Map<String, Object?> json,
    {String? fileKey}) {
  final meta = json['meta'] as Map<String, Object?>;
  final rawCollections =
      (meta['variableCollections'] as Map).cast<String, Map<String, Object?>>();
  final rawVariables =
      (meta['variables'] as Map).cast<String, Map<String, Object?>>();

  final modeNames = <String, String>{}; // modeId -> name
  final collections = <String, FigmaCollection>{};
  for (final c in rawCollections.values) {
    if (c['remote'] == true) continue;
    final modes = (c['modes'] as List).cast<Map<String, Object?>>();
    for (final m in modes) {
      modeNames[m['modeId'] as String] = m['name'] as String;
    }
    collections[c['id'] as String] = FigmaCollection(
      id: c['id'] as String,
      name: c['name'] as String,
      modes: [for (final m in modes) m['name'] as String],
      hiddenFromPublishing: c['hiddenFromPublishing'] as bool? ?? false,
    );
  }

  final variables = <FigmaVariable>[];
  for (final v in rawVariables.values) {
    final collection = collections[v['variableCollectionId']];
    if (v['remote'] == true ||
        v['deletedButReferenced'] == true ||
        collection == null) {
      continue;
    }
    final values = <String, FigmaValue>{};
    (v['valuesByMode'] as Map).forEach((modeId, value) {
      final mode = modeNames[modeId];
      if (mode == null) return;
      if (value is Map && value['type'] == 'VARIABLE_ALIAS') {
        final target = rawVariables[value['id']];
        values[mode] = FigmaAlias(value['id'] as String,
            name: target?['name'] as String?,
            collection: collections[target?['variableCollectionId']]?.name);
      } else if (value is Map) {
        values[mode] = FigmaRaw(figmaColorToHex(value));
      } else if (value != null) {
        values[mode] = FigmaRaw(value as Object);
      }
    });
    variables.add(FigmaVariable(
      id: v['id'] as String,
      name: v['name'] as String,
      collection: collection.name,
      type: v['resolvedType'] as String,
      description: v['description'] as String? ?? '',
      scopes: (v['scopes'] as List?)?.cast<String>(),
      hiddenFromPublishing: v['hiddenFromPublishing'] as bool?,
      codeSyntax:
          ((v['codeSyntax'] as Map?) ?? const {}).cast<String, String>(),
      values: values,
    ));
  }
  return FigmaSnapshot(
    source: 'variables-api',
    fileKey: fileKey,
    collections: collections.values.toList(),
    variables: variables,
  );
}
