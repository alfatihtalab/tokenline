// Tokenline core — runs inside Figma (plugin or use_figma) and in Node for
// tests. Pure functions take plain data; the `figma*` functions use the
// Figma Plugin API. Keep this file free of plugin-UI code.

// <apply>
var TOKENLINE_NAMESPACE = 'tokenline';
// </apply>
var SNAPSHOT_FORMAT = 'tokenline.figma-snapshot';
var CHUNK_SIZE = 30000; // chars; entries are capped at 100 kB of UTF-8

var RESERVED = ['assert', 'break', 'case', 'catch', 'class', 'const', 'continue',
  'default', 'do', 'else', 'enum', 'extends', 'false', 'final', 'finally', 'for',
  'if', 'in', 'is', 'new', 'null', 'rethrow', 'return', 'super', 'switch', 'this',
  'throw', 'true', 'try', 'var', 'void', 'while', 'with'];

// ---- names --------------------------------------------------------------

function kebabToCamel(s) {
  return s.replace(/-([a-z])/g, function (_, c) { return c.toUpperCase(); });
}

// <apply>
function isDraftName(name) {
  return name.split('/').some(function (s) { return s.trim().charAt(0) === '_'; });
}
// </apply>

function levelOfCollection(config, collectionName) {
  var c = config.collections;
  if (c.primitives === collectionName) return 'primitives';
  if (c.semantic === collectionName) return 'semantic';
  if (c.components === collectionName) return 'components';
  return null;
}

// Figma name -> token path (mirrors pathForFigmaName in names.dart).
function pathForName(name, level, nameCase, isColor) {
  var parts = name.split('/').map(function (s) { return s.trim(); });
  if (nameCase === 'kebab') parts = parts.map(kebabToCamel);
  if (level !== 'components' && isColor) parts = ['color'].concat(parts);
  return parts.join('.');
}

// Leading segments the generated Dart drops (mirrors defaultDropFor).
function dropFor(path, level) {
  var first = path.split('.')[0];
  if (level === 'components') return 0;
  if (first === 'space') return 0;
  if (first === 'font' || first === 'motion') return 2;
  return 1;
}

function dartNameGuess(path, level) {
  var parts = path.split('.').slice(dropFor(path, level)).map(kebabToCamel);
  if (!parts.length) return '';
  var name = parts.map(function (p, i) {
    return i === 0 ? p.charAt(0).toLowerCase() + p.slice(1) : p.charAt(0).toUpperCase() + p.slice(1);
  }).join('');
  return /^[0-9]/.test(name) ? 'v' + name : name;
}

// ---- colors -------------------------------------------------------------

function rgbaToHex(c) {
  function h(n) { var s = Math.round(n * 255).toString(16).toUpperCase(); return s.length < 2 ? '0' + s : s; }
  var hex = '#' + h(c.r) + h(c.g) + h(c.b);
  var a = c.a === undefined ? 1 : c.a;
  return a < 1 ? hex + h(a) : hex;
}

// <apply>
function hexToRgba(hex) {
  var h = hex.replace('#', '');
  function n(i) { return parseInt(h.slice(i, i + 2), 16) / 255; }
  return { r: n(0), g: n(2), b: n(4), a: h.length === 8 ? n(6) : 1 };
}
// </apply>

// ---- lint (pure; mirrors lib/src/lint/rules.dart) -----------------------

function lintSnapshot(snapshot, config) {
  var issues = [];
  function add(code, severity, message, v) {
    issues.push({ code: code, severity: severity, message: message,
      variableId: v ? v.id : null, name: v ? v.name : null, collection: v ? v.collection : null });
  }
  var segmentOk = config.nameCase === 'camel'
    ? /^[a-z0-9][a-zA-Z0-9]*$/ : /^[a-z0-9]+(-[a-z0-9]+)*$/;
  var groups = config.groups || [];

  var byId = {};
  snapshot.variables.forEach(function (v) { byId[v.id] = v; });
  var collections = {};
  snapshot.collections.forEach(function (c) { collections[c.name] = c; });

  // Collections and modes.
  ['primitives', 'semantic', 'components'].forEach(function (level) {
    var name = config.collections[level];
    if (!name) return;
    var c = collections[name];
    if (!c) { add('collection-missing', 'warning', 'No collection "' + name + '" (' + level + ') yet — run push to create it.'); return; }
    if (level === 'semantic') {
      Object.keys(config.modes).forEach(function (mode) {
        var figmaMode = config.modes[mode];
        if (c.modes.indexOf(figmaMode) < 0) add('mode-missing', 'error', 'Collection "' + name + '" has no mode "' + figmaMode + '".');
      });
    }
  });

  var seenKeys = {};
  snapshot.variables.forEach(function (v) {
    var level = levelOfCollection(config, v.collection);
    if (!level || isDraftName(v.name) || v.type === 'BOOLEAN') return;
    var where = v.collection + ': ' + v.name;

    // Names.
    var badSegment = v.name.split('/').filter(function (s) { return !segmentOk.test(s); })[0];
    if (badSegment !== undefined) {
      add('name-format', 'error', where + ' — "' + badSegment + '" should be ' +
        (config.nameCase === 'camel' ? 'lowerCamelCase' : 'lowercase words joined by -') +
        ', with / between parts.', v);
    }
    var path = pathForName(v.name, level, config.nameCase, v.type === 'COLOR');
    var first = path.split('.')[0];
    if (level === 'primitives' && v.type !== 'COLOR' && groups.indexOf(first) < 0) {
      add('name-group', 'error', where + ' — number and text primitives must start with one of: ' + groups.join(', ') + '.', v);
    }
    if (v.type === 'STRING' && path.indexOf('.family.') < 0 && path.indexOf('.easing.') < 0) {
      add('type-group', 'error', where + ' — text variables sync only as font/family/... or motion/easing/....', v);
    }
    var key = v.collection + '|' + path.replace(/[.\-_]/g, '').toLowerCase();
    if (seenKeys[key]) {
      add('name-collision', 'error', where + ' and ' + seenKeys[key] + ' become the same name in code.', v);
    } else {
      seenKeys[key] = v.name;
    }
    var dart = dartNameGuess(path, level);
    if (RESERVED.indexOf(dart) >= 0) {
      add('reserved-word', 'error', where + ' becomes "' + dart + '", a reserved word in Dart.', v);
    }

    // Values and links.
    var c = collections[v.collection];
    var modes = level === 'semantic'
      ? Object.keys(config.modes).map(function (m) { return config.modes[m]; }).filter(function (m) { return c.modes.indexOf(m) >= 0; })
      : [c.modes[0]];
    modes.forEach(function (mode) {
      var value = v.values[mode];
      if (value === undefined || value === null) {
        add('missing-value', 'error', where + ' has no value in mode "' + mode + '".', v);
        return;
      }
      var isAlias = typeof value === 'object' && value.type === 'alias';
      var target = isAlias ? byId[value.id] : null;
      var targetLevel = target ? levelOfCollection(config, target.collection) : null;
      if (level === 'primitives' && isAlias) {
        add('primitive-link', 'error', where + ' links to another variable; primitives hold typed values only.', v);
      }
      if (level === 'semantic') {
        if (!isAlias) add('semantic-raw', 'error', where + ' (' + mode + ') has a typed value; link it to a primitive.', v);
        else if (targetLevel !== 'primitives') add('semantic-link-target', 'error', where + ' (' + mode + ') must link to a primitive.', v);
      }
      if (level === 'components') {
        if (!isAlias) add('component-raw', 'error', where + ' has a typed value; link it to a semantic token.', v);
        else if (v.type === 'COLOR' && targetLevel !== 'semantic') add('component-link-target', 'error', where + ' is a color and must link to a semantic token.', v);
        else if (targetLevel !== 'semantic' && targetLevel !== 'primitives') add('component-link-target', 'error', where + ' must link to a semantic token or a primitive.', v);
      }
      if (isAlias && target && isDraftName(target.name)) {
        add('draft-link', 'error', where + ' links to draft ' + target.name + '.', v);
      }
      if (isAlias && !target) {
        add('external-link', 'error', where + ' links to a variable outside this file.', v);
      }
    });

    // Primitives stay out of pickers and the published library.
    if (level === 'primitives' && config.hidePrimitives) {
      if (v.scopes && v.scopes.length) add('primitive-scopes', 'warning', where + ' appears in property pickers; Fix hides it.', v);
      if (v.hiddenFromPublishing === false) add('primitive-published', 'warning', where + ' is published with the library; Fix hides it.', v);
    }

    // Deprecation.
    var firstLine = (v.description || '').trim().split('\n')[0];
    if (firstLine.indexOf('@deprecated') === 0) {
      var m = /^@deprecated\s*(?:→|->)\s*(.+)$/.exec(firstLine);
      if (!m) {
        add('deprecated-format', 'warning', where + ' is deprecated without a replacement; write "@deprecated → new/name".', v);
      } else {
        var targetName = m[1].trim();
        var exists = snapshot.variables.some(function (t) { return t.name === targetName && !isDraftName(t.name); });
        if (!exists) add('deprecated-target', 'error', where + ' points to "' + targetName + '", which does not exist.', v);
      }
    }
  });
  return issues;
}

// ---- export (Figma API) --------------------------------------------------

async function figmaExportSnapshot() {
  var collections = await figma.variables.getLocalVariableCollectionsAsync();
  var variables = await figma.variables.getLocalVariablesAsync();
  var collectionById = {};
  var modeName = {};
  collections.forEach(function (c) {
    collectionById[c.id] = c;
    c.modes.forEach(function (m) { modeName[c.id + '|' + m.modeId] = m.name; });
  });
  var varById = {};
  variables.forEach(function (v) { varById[v.id] = v; });

  var outVars = variables.map(function (v) {
    var values = {};
    Object.keys(v.valuesByMode).forEach(function (modeId) {
      var mode = modeName[v.variableCollectionId + '|' + modeId];
      if (!mode) return;
      var value = v.valuesByMode[modeId];
      if (value && typeof value === 'object' && value.type === 'VARIABLE_ALIAS') {
        var t = varById[value.id];
        values[mode] = { type: 'alias', id: value.id,
          name: t ? t.name : undefined,
          collection: t && collectionById[t.variableCollectionId] ? collectionById[t.variableCollectionId].name : undefined };
      } else if (value && typeof value === 'object' && 'r' in value) {
        values[mode] = rgbaToHex(value);
      } else {
        values[mode] = value;
      }
    });
    var codeSyntax = {};
    if (v.codeSyntax) Object.keys(v.codeSyntax).forEach(function (k) { codeSyntax[k] = v.codeSyntax[k]; });
    return { id: v.id, name: v.name, collection: collectionById[v.variableCollectionId].name,
      type: v.resolvedType, description: v.description || '', scopes: v.scopes.slice(),
      hiddenFromPublishing: v.hiddenFromPublishing, codeSyntax: codeSyntax, values: values };
  });

  return {
    format: SNAPSHOT_FORMAT, version: 1, source: 'plugin',
    fileKey: figma.fileKey || undefined, fileName: figma.root.name,
    exportedAt: new Date().toISOString(),
    collections: collections.map(function (c) {
      return { id: c.id, name: c.name, modes: c.modes.map(function (m) { return m.name; }),
        hiddenFromPublishing: c.hiddenFromPublishing };
    }),
    variables: outVars,
  };
}

// Stores the snapshot in the file so `tokenline pull` can read it with one
// REST request (chunked: plugin data entries have a size limit).
function figmaStoreSnapshot(snapshot) {
  var text = JSON.stringify(snapshot);
  var chunks = Math.max(1, Math.ceil(text.length / CHUNK_SIZE));
  var old = figma.root.getSharedPluginDataKeys(TOKENLINE_NAMESPACE);
  old.forEach(function (k) {
    if (k.indexOf('snapshot.') === 0) figma.root.setSharedPluginData(TOKENLINE_NAMESPACE, k, '');
  });
  for (var i = 0; i < chunks; i++) {
    figma.root.setSharedPluginData(TOKENLINE_NAMESPACE, 'snapshot.' + i, text.slice(i * CHUNK_SIZE, (i + 1) * CHUNK_SIZE));
  }
  figma.root.setSharedPluginData(TOKENLINE_NAMESPACE, 'snapshot.meta',
    JSON.stringify({ chunks: chunks, length: text.length, exportedAt: snapshot.exportedAt }));
  return chunks;
}

function figmaReadConfig() {
  var raw = figma.root.getSharedPluginData(TOKENLINE_NAMESPACE, 'config');
  return raw ? JSON.parse(raw) : null;
}

// ---- fix (Figma API) -----------------------------------------------------

async function figmaFix(config) {
  var collections = await figma.variables.getLocalVariableCollectionsAsync();
  var prim = collections.filter(function (c) { return c.name === config.collections.primitives; })[0];
  if (!prim || !config.hidePrimitives) return { hidden: 0 };
  var variables = await figma.variables.getLocalVariablesAsync();
  var hidden = 0;
  variables.forEach(function (v) {
    if (v.variableCollectionId !== prim.id || isDraftName(v.name)) return;
    if (v.scopes.length || !v.hiddenFromPublishing) {
      v.scopes = [];
      v.hiddenFromPublishing = true;
      hidden++;
    }
  });
  return { hidden: hidden };
}

// <apply>
// ---- apply a push payload (Figma API) -------------------------------------

async function figmaApplyPayload(payload, options) {
  var prune = !!(options && options.prune);
  var summary = { collectionsCreated: 0, modesAdded: 0, created: 0, updated: 0, removed: 0, errors: [] };

  var collections = await figma.variables.getLocalVariableCollectionsAsync();
  var byName = {};
  collections.forEach(function (c) { byName[c.name] = c; });
  var modeIds = {}; // collection name -> mode name -> id
  payload.collections.forEach(function (pc) {
    var c = byName[pc.name];
    if (!c) {
      c = figma.variables.createVariableCollection(pc.name);
      c.renameMode(c.modes[0].modeId, pc.modes[0]);
      byName[pc.name] = c;
      summary.collectionsCreated++;
    }
    pc.modes.forEach(function (m) {
      if (!c.modes.some(function (x) { return x.name === m; })) { c.addMode(m); summary.modesAdded++; }
    });
    modeIds[pc.name] = {};
    c.modes.forEach(function (m) { modeIds[pc.name][m.name] = m.modeId; });
  });

  var existing = {};
  (await figma.variables.getLocalVariablesAsync()).forEach(function (v) {
    existing[v.variableCollectionId + '|' + v.name] = v;
  });
  function find(collectionName, name) {
    var c = byName[collectionName];
    return c ? existing[c.id + '|' + name] : undefined;
  }

  // Create everything first so links can point anywhere.
  var wanted = {};
  payload.variables.forEach(function (pv) {
    var c = byName[pv.collection];
    wanted[c.id + '|' + pv.name] = true;
    var v = find(pv.collection, pv.name);
    if (v && v.resolvedType !== pv.type) {
      summary.errors.push(pv.collection + ': ' + pv.name + ' is ' + v.resolvedType + ' in Figma but ' + pv.type + ' in the tokens — delete it in Figma to recreate it.');
      return;
    }
    if (!v) {
      v = figma.variables.createVariable(pv.name, c, pv.type);
      existing[c.id + '|' + pv.name] = v;
      summary.created++;
    }
  });

  payload.variables.forEach(function (pv) {
    var v = find(pv.collection, pv.name);
    if (!v || v.resolvedType !== pv.type) return;
    Object.keys(pv.values).forEach(function (mode) {
      var modeId = modeIds[pv.collection][mode];
      var value = pv.values[mode];
      if (value && typeof value === 'object' && value.alias) {
        var target = find(value.collection, value.alias);
        if (!target) { summary.errors.push(pv.name + ' links to missing ' + value.collection + ': ' + value.alias); return; }
        v.setValueForMode(modeId, figma.variables.createVariableAlias(target));
      } else {
        v.setValueForMode(modeId, pv.type === 'COLOR' ? hexToRgba(value) : value);
      }
    });
    if ((v.description || '') !== (pv.description || '')) v.description = pv.description || '';
    if (pv.scopes) v.scopes = pv.scopes;
    if (typeof pv.hiddenFromPublishing === 'boolean') v.hiddenFromPublishing = pv.hiddenFromPublishing;
    if (pv.codeSyntax) v.setVariableCodeSyntax('WEB', pv.codeSyntax);
    summary.updated++;
  });

  if (prune) {
    // A split push sends the full keep-list with its last part.
    if (payload.keep) {
      wanted = {};
      payload.keep.forEach(function (k) {
        var sep = k.indexOf('|');
        var c = byName[k.slice(0, sep)];
        if (c) wanted[c.id + '|' + k.slice(sep + 1)] = true;
      });
    }
    var managed = {};
    payload.collections.forEach(function (pc) { managed[byName[pc.name].id] = true; });
    Object.keys(existing).forEach(function (key) {
      var v = existing[key];
      if (managed[v.variableCollectionId] && !wanted[key] && !isDraftName(v.name)) { v.remove(); summary.removed++; }
    });
  }

  if (payload.config) {
    try {
      figma.root.setSharedPluginData(TOKENLINE_NAMESPACE, 'config', JSON.stringify(payload.config));
    } catch (e) {
      summary.errors.push('Could not store the plugin rules in the file (' + e.message + '); the plugin will use defaults until a plugin Import runs.');
    }
  }
  if (payload.syncFrame) summary.syncFrame = await figmaBuildSyncFrame(payload, byName, modeIds, find);
  return summary;
}

// Legacy: rebuild the frame `tokenline pull` reads when figma.source is
// sync-frame. Every rectangle is bound to a variable.
async function figmaBuildSyncFrame(payload, byName, modeIds, find) {
  var frame = await figma.getNodeByIdAsync(payload.syncFrame.id);
  if (!frame || frame.type !== 'FRAME') return 'sync frame ' + payload.syncFrame.id + ' not found';
  frame.children.slice().forEach(function (n) { n.remove(); });
  function rect(parent, pv) {
    var v = find(pv.collection, pv.name);
    if (!v) return;
    var r = figma.createRectangle();
    r.name = pv.path;
    r.resize(8, 8);
    if (pv.type === 'COLOR') {
      r.fills = [figma.variables.setBoundVariableForPaint({ type: 'SOLID', color: { r: 0, g: 0, b: 0 } }, 'color', v)];
    } else {
      r.setBoundVariable('width', v);
    }
    parent.appendChild(r);
  }
  var syncable = payload.variables.filter(function (pv) { return pv.type === 'COLOR' || pv.type === 'FLOAT'; });
  syncable.filter(function (pv) { return pv.level === 'primitives'; }).forEach(function (pv) { rect(frame, pv); });
  var sem = byName[payload.syncFrame.semanticCollection];
  Object.keys(payload.syncFrame.modes || {}).forEach(function (mode) {
    var sub = figma.createFrame();
    sub.name = mode;
    frame.appendChild(sub);
    if (sem) sub.setExplicitVariableModeForCollection(sem, modeIds[sem.name][payload.syncFrame.modes[mode]]);
    syncable.filter(function (pv) { return pv.level === 'semantic'; }).forEach(function (pv) { rect(sub, pv); });
  });
  return 'rebuilt';
}

// </apply>

if (typeof module !== 'undefined') {
  module.exports = { lintSnapshot: lintSnapshot, pathForName: pathForName, dartNameGuess: dartNameGuess,
    rgbaToHex: rgbaToHex, hexToRgba: hexToRgba, isDraftName: isDraftName,
    figmaExportSnapshot: figmaExportSnapshot, figmaApplyPayload: figmaApplyPayload,
    figmaStoreSnapshot: figmaStoreSnapshot, figmaFix: figmaFix, figmaReadConfig: figmaReadConfig };
}
