// A small in-memory stand-in for the Figma Plugin API variables surface —
// enough to run core.js (apply, export, fix) in Node.
'use strict';

function createMockFigma(fileName) {
  var nextId = 1;
  var collections = [];
  var variables = [];
  var shared = {};

  function makeCollection(name, id, modeNames) {
    var c = {
      id: id || 'VariableCollectionId:' + nextId++,
      name: name,
      hiddenFromPublishing: false,
      modes: (modeNames || ['Mode 1']).map(function (m) { return { modeId: nextId++ + ':0', name: m }; }),
      renameMode: function (modeId, newName) {
        c.modes.forEach(function (m) { if (m.modeId === modeId) m.name = newName; });
      },
      addMode: function (n) {
        var id = nextId++ + ':0';
        c.modes.push({ modeId: id, name: n });
        return id;
      },
    };
    collections.push(c);
    return c;
  }

  function makeVariable(name, collection, type, id) {
    var v = {
      id: id || 'VariableID:' + nextId++,
      name: name,
      variableCollectionId: collection.id,
      resolvedType: type,
      valuesByMode: {},
      description: '',
      scopes: ['ALL_SCOPES'],
      hiddenFromPublishing: false,
      codeSyntax: {},
      setValueForMode: function (modeId, value) {
        if (!collection.modes.some(function (m) { return m.modeId === modeId; })) {
          throw new Error('mode ' + modeId + ' not in ' + collection.name);
        }
        v.valuesByMode[modeId] = value;
      },
      setVariableCodeSyntax: function (platform, value) { v.codeSyntax[platform] = value; },
      remove: function () { variables.splice(variables.indexOf(v), 1); },
    };
    collection.modes.forEach(function (m) {
      v.valuesByMode[m.modeId] = type === 'COLOR' ? { r: 0, g: 0, b: 0, a: 1 } : type === 'FLOAT' ? 0 : type === 'STRING' ? '' : false;
    });
    variables.push(v);
    return v;
  }

  var nodes = {};
  function makeNode(type) {
    var n = { id: nextId++ + ':1', type: type, name: '', children: [], fills: [], width: 0, bound: null,
      resize: function (w) { n.width = w; },
      setBoundVariable: function (field, v) { n.bound = v.id; },
      appendChild: function (c) { n.children.push(c); c.parent = n; },
      setExplicitVariableModeForCollection: function (c, modeId) { n.explicitMode = modeId; },
      remove: function () { if (n.parent) n.parent.children.splice(n.parent.children.indexOf(n), 1); },
    };
    nodes[n.id] = n;
    return n;
  }

  return {
    fileKey: undefined,
    createFrame: function () { return makeNode('FRAME'); },
    createRectangle: function () { return makeNode('RECTANGLE'); },
    getNodeByIdAsync: async function (id) { return nodes[id] || null; },
    _nodes: nodes,
    root: {
      name: fileName || 'Mock file',
      getSharedPluginData: function (ns, key) { return (shared[ns] || {})[key] || ''; },
      setSharedPluginData: function (ns, key, value) {
        shared[ns] = shared[ns] || {};
        if (value === '') delete shared[ns][key]; else shared[ns][key] = value;
      },
      getSharedPluginDataKeys: function (ns) { return Object.keys(shared[ns] || {}); },
    },
    variables: {
      getLocalVariableCollectionsAsync: async function () { return collections.slice(); },
      getLocalVariablesAsync: async function () { return variables.slice(); },
      getVariableByIdAsync: async function (id) { return variables.filter(function (v) { return v.id === id; })[0] || null; },
      createVariableCollection: makeCollection,
      createVariable: function (name, collection, type) {
        if (typeof collection === 'string') throw new Error('pass the collection object, not its id');
        return makeVariable(name, collection, type);
      },
      createVariableAlias: function (v) { return { type: 'VARIABLE_ALIAS', id: v.id }; },
      setBoundVariableForPaint: function (paint, field, v) { return Object.assign({}, paint, { boundVariables: { color: { id: v.id } } }); },
    },
    _shared: shared,
    _find: function (collectionName, name) {
      var c = collections.filter(function (x) { return x.name === collectionName; })[0];
      return c && variables.filter(function (v) { return v.variableCollectionId === c.id && v.name === name; })[0];
    },
    _mode: function (collectionName, modeName) {
      var c = collections.filter(function (x) { return x.name === collectionName; })[0];
      return c.modes.filter(function (m) { return m.name === modeName; })[0].modeId;
    },
    // Recreate a file from a snapshot (ids kept) so tests can resume it.
    _load: function (snap) {
      snap.collections.forEach(function (c) {
        nextId = Math.max(nextId, (+String(c.id).replace(/\D+/g, '') || 0) + 1);
        makeCollection(c.name, c.id, c.modes);
      });
      snap.variables.forEach(function (sv) {
        nextId = Math.max(nextId, (+String(sv.id).replace(/\D+/g, '') || 0) + 1);
      });
      snap.variables.forEach(function (sv) {
        var c = collections.filter(function (x) { return x.name === sv.collection; })[0];
        var v = makeVariable(sv.name, c, sv.type, sv.id);
        v.description = sv.description || '';
        v.scopes = sv.scopes || [];
        v.hiddenFromPublishing = !!sv.hiddenFromPublishing;
        Object.keys(sv.values).forEach(function (mode) {
          var modeId = c.modes.filter(function (m) { return m.name === mode; })[0].modeId;
          var val = sv.values[mode];
          if (val && typeof val === 'object') v.valuesByMode[modeId] = { type: 'VARIABLE_ALIAS', id: val.id };
          else if (sv.type === 'COLOR') {
            var h = val.replace('#', '');
            var n = function (i) { return parseInt(h.slice(i, i + 2), 16) / 255; };
            v.valuesByMode[modeId] = { r: n(0), g: n(2), b: n(4), a: h.length === 8 ? n(6) : 1 };
          } else v.valuesByMode[modeId] = val;
        });
      });
    },
    _collection: function (name) { return collections.filter(function (x) { return x.name === name; })[0]; },
    _create: function (name, collectionName, type) { return makeVariable(name, this._collection(collectionName), type); },
  };
}

module.exports = { createMockFigma: createMockFigma };
