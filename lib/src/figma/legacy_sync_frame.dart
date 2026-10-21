// Legacy pull: a Figma frame whose rectangles are bound to variables, read
// through the plain files endpoint. Colors come back as fills and numbers
// as widths, already resolved — so this path cannot see links,
// descriptions, added or removed variables. Prefer `figma.source: plugin`.
import '../config.dart';
import '../errors.dart';
import '../loader.dart';
import '../names.dart';
import '../tokens.dart';
import 'diff.dart';
import 'rest.dart';
import 'snapshot.dart';

/// Token path -> `{value}` (single mode) or `{<theme>: value, ...}`.
typedef ResolvedValues = Map<String, Map<String, String>>;

/// Fetches the sync frame [frameId] and parses it.
Future<ResolvedValues> fetchSyncFrame(FigmaRest rest, String frameId) async {
  final json = await rest.getJson(
      '/v1/files/${rest.credentials.fileKey}/nodes?ids=${Uri.encodeQueryComponent(frameId)}');
  final nodes = json['nodes'] as Map<String, Object?>;
  final frame = (nodes.values.first as Map<String, Object?>?)?['document']
      as Map<String, Object?>?;
  if (frame == null) {
    throw TokenlineException('sync frame $frameId not found — check '
        'figma.sync_frame_id, or switch to figma.source: plugin');
  }
  return parseSyncFrame(frame);
}

/// Pure parser for the sync frame subtree.
///
/// Children named after a theme (e.g. `light`, `dark`) hold that theme's
/// rectangles; other rectangles are primitives. Rectangles named
/// `color.*` are read by fill, the rest by width.
ResolvedValues parseSyncFrame(Map<String, Object?> frame) {
  String? rectColor(Map<String, Object?> n) {
    final fills = n['fills'] as List?;
    if (fills == null || fills.isEmpty) return null;
    final f = fills.first as Map<String, Object?>;
    final c = Map<Object?, Object?>.from(f['color'] as Map);
    final opacity = f['opacity'] as num? ?? 1;
    if (opacity < 1) c['a'] = ((c['a'] as num? ?? 1) * opacity);
    return figmaColorToHex(c);
  }

  String width(Map<String, Object?> n) =>
      '${(n['absoluteBoundingBox'] as Map)['width'] as num}';

  final out = <String, Map<String, String>>{};
  for (final child
      in (frame['children'] as List).cast<Map<String, Object?>>()) {
    final name = child['name'] as String;
    if (child['type'] == 'FRAME' && child['children'] is List) {
      for (final r
          in (child['children'] as List).cast<Map<String, Object?>>()) {
        final path = r['name'] as String;
        final value = path.startsWith('color.') ? rectColor(r) : width(r);
        if (value != null) (out[path] ??= {})[name] = value;
      }
    } else if (name.startsWith('color.')) {
      final value = rectColor(child);
      if (value != null) out[name] = {'value': value};
    } else if (child['type'] == 'RECTANGLE') {
      out[name] = {'value': width(child)};
    }
  }
  return out;
}

/// Compares resolved values with the token files. Semantic changes link to
/// whichever primitive now has that color (raw hex when none does).
///
/// Figma draws a rectangle bound to any value below 1 (0, -0.2, 0.6) at
/// width 1, so a width of 1 or less says nothing about the real value: such
/// differences are skipped and returned in `skipped`, never adopted.
({List<TokenChange> changes, List<String> skipped}) diffResolved(
    TokenlineConfig config, TokenModel model, ResolvedValues values) {
  final changes = <TokenChange>[];
  final skipped = <String>[];

  // Primitive colors after this pull, for re-linking semantic tokens.
  final hexToPrimitive = <String, String>{};
  for (final t in model.primitives.tokens.values) {
    if (t.type != 'color') continue;
    final figmaHex = values[t.path]?['value'];
    hexToPrimitive.putIfAbsent(
        (figmaHex ?? t.resolved as String).toUpperCase(), () => t.path);
  }

  values.forEach((path, byMode) {
    final primitive = model.primitives.tokens[path];
    if (primitive != null && byMode.containsKey('value')) {
      if (figmaTypeForLegacy(primitive) == null) return;
      if (primitive.type != 'color') {
        final figmaWidth = num.tryParse(byMode['value']!) ?? 0;
        if (figmaWidth <= 1 &&
            !sameValue(primitive.resolved!, byMode['value']!)) {
          skipped.add(path);
          return;
        }
      }
      final json = jsonValueFor(
          primitive.type, _parse(primitive.type, byMode['value']!),
          where: 'sync frame $path');
      if (!sameValue(primitive.resolved!, json)) {
        changes.add(TokenChange(
            kind: ChangeKind.value,
            level: Level.primitives,
            path: path,
            before: '${primitive.value}',
            after: '$json',
            jsonValues: {null: json}));
      }
      return;
    }
    for (final MapEntry(key: mode, value: figmaValue) in byMode.entries) {
      final token = model.semantic[mode]?.tokens[path];
      if (token == null || token.type != 'color') continue;
      if (sameValue(token.resolved!, figmaValue)) continue;
      final hex = figmaValue.toUpperCase();
      final linked = hexToPrimitive[hex];
      final json = linked == null ? hex : '{$linked}';
      changes.add(TokenChange(
          kind: ChangeKind.value,
          level: Level.semantic,
          path: path,
          mode: mode,
          before: '${token.value} (${token.resolved})',
          after: json,
          jsonValues: {mode: json}));
    }
  });
  changes.sort((a, b) => a.path.compareTo(b.path));
  return (changes: changes, skipped: skipped..sort());
}

Object _parse(String type, String v) =>
    type == 'color' ? v : (num.tryParse(v) ?? v);

String? figmaTypeForLegacy(Token t) =>
    const {'color', 'dimension', 'number'}.contains(t.type) ? t.type : null;
