// A small in-memory stand-in for the Figma Plugin API variables surface —
// enough to run core.js (apply, export, fix) in Node.
'use strict';

function createMockFigma(fileName) {
  var nextId = 1;
  var collections = [];
  var variables = [];
  var shared = {};

  function makeCollection(name) {
    var c = {
      id: 'VariableCollectionId:' + nextId++,
      name: name,
      hiddenFromPublishing: false,
      modes: [{ modeId: nextId++ + ':0', name: 'Mode 1' }],
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

  function makeVariable(name, collection, type) {
    var v = {
      id: 'VariableID:' + nextId++,
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

  return {
    fileKey: undefined,
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
    _collection: function (name) { return collections.filter(function (x) { return x.name === name; })[0]; },
    _create: function (name, collectionName, type) { return makeVariable(name, this._collection(collectionName), type); },
  };
}

module.exports = { createMockFigma: createMockFigma };
