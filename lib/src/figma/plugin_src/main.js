// Tokenline plugin — UI wiring around core.js (concatenated before this).

var DEFAULT_CONFIG = {
  collections: { primitives: 'Primitives', semantic: 'Semantic', components: 'Component' },
  modes: { light: 'Light', dark: 'Dark' },
  primitiveMode: 'Base',
  componentMode: 'Base',
  nameCase: 'kebab',
  hidePrimitives: true,
  groups: ['space', 'radius', 'opacity', 'borderWidth', 'iconSize', 'controlHeight',
    'contentWidth', 'size', 'font', 'lineHeight', 'letterSpacing', 'motion',
    'elevation', 'breakpoint', 'zIndex'],
};

var MAX_NODE_ISSUES = 300;

figma.showUI(__html__, { width: 440, height: 600, themeColors: true });

function currentConfig() {
  var stored = figmaReadConfig();
  return { config: stored || DEFAULT_CONFIG, stored: !!stored };
}

function post(msg) { figma.ui.postMessage(msg); }

// Components should paint with semantic or component variables only.
async function lintNodes(config, variablesById) {
  var issues = [];
  await figma.loadAllPagesAsync();
  var components = figma.root.findAllWithCriteria({ types: ['COMPONENT'] });
  function check(node, componentName) {
    if (issues.length >= MAX_NODE_ISSUES) return;
    ['fills', 'strokes'].forEach(function (prop) {
      var paints = node[prop];
      if (!paints || paints === figma.mixed) return;
      paints.forEach(function (p) {
        if (p.type !== 'SOLID' || p.visible === false) return;
        var bound = p.boundVariables && p.boundVariables.color;
        if (!bound) {
          issues.push({ code: 'typed-color', severity: 'error', nodeId: node.id,
            message: componentName + ' › ' + node.name + ' has a typed ' + prop.slice(0, -1) + ' color ' + rgbaToHex(p.color) + '; pick a variable.' });
          return;
        }
        var v = variablesById[bound.id];
        if (v && v.collection === config.collections.primitives) {
          issues.push({ code: 'primitive-on-layer', severity: 'error', nodeId: node.id,
            message: componentName + ' › ' + node.name + ' uses primitive ' + v.name + '; use a semantic token.' });
        }
      });
    });
    if (node.type === 'INSTANCE') return; // checked in its own component
    if ('children' in node) node.children.forEach(function (c) { check(c, componentName); });
  }
  components.forEach(function (c) {
    var name = c.parent && c.parent.type === 'COMPONENT_SET' ? c.parent.name + '/' + c.name : c.name;
    check(c, name);
  });
  if (issues.length >= MAX_NODE_ISSUES) {
    issues.push({ code: 'truncated', severity: 'warning', message: 'Stopped after ' + MAX_NODE_ISSUES + ' layer issues.' });
  }
  return issues;
}

figma.ui.onmessage = async function (msg) {
  try {
    var cfg = currentConfig();
    if (msg.type === 'init') {
      post({ type: 'config', config: cfg.config, stored: cfg.stored, fileName: figma.root.name });
    } else if (msg.type === 'lint') {
      post({ type: 'status', text: 'Checking variables and components…' });
      var snapshot = await figmaExportSnapshot();
      var byId = {};
      snapshot.variables.forEach(function (v) { byId[v.id] = v; });
      var issues = lintSnapshot(snapshot, cfg.config).concat(await lintNodes(cfg.config, byId));
      post({ type: 'lint-result', issues: issues });
    } else if (msg.type === 'fix') {
      var fixed = await figmaFix(cfg.config);
      post({ type: 'status', text: fixed.hidden ? 'Hid ' + fixed.hidden + ' primitive(s) from pickers and publishing.' : 'Nothing to fix.' });
    } else if (msg.type === 'export') {
      var snap = await figmaExportSnapshot();
      var errors = lintSnapshot(snap, cfg.config).filter(function (i) { return i.severity === 'error'; });
      if (errors.length && !msg.force) {
        post({ type: 'lint-result', issues: errors, blockedExport: true });
        return;
      }
      var chunks = figmaStoreSnapshot(snap);
      post({ type: 'export-result', json: JSON.stringify(snap, null, 2), chunks: chunks, count: snap.variables.length });
    } else if (msg.type === 'import') {
      var payload = msg.payload;
      if (!payload || payload.format !== 'tokenline.figma-push') throw new Error('Not a Tokenline push file (tokenline push writes one).');
      var summary = await figmaApplyPayload(payload, { prune: !!msg.prune });
      post({ type: 'import-result', summary: summary });
      cfg = currentConfig();
      post({ type: 'config', config: cfg.config, stored: cfg.stored, fileName: figma.root.name });
    } else if (msg.type === 'select' && msg.nodeId) {
      var node = await figma.getNodeByIdAsync(msg.nodeId);
      if (!node) return;
      var page = node;
      while (page && page.type !== 'PAGE') page = page.parent;
      if (page) await figma.setCurrentPageAsync(page);
      figma.currentPage.selection = [node];
      figma.viewport.scrollAndZoomIntoView([node]);
    }
  } catch (e) {
    post({ type: 'error', message: String(e && e.message ? e.message : e) });
  }
};
