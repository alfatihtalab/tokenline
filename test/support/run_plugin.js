// Smoke-tests the plugin's main file (core.js + main.js, as embedded) by
// sending it the UI's messages against the mock Figma.
//
//   node run_plugin.js <code.js> <payload.json> <out.json>
'use strict';
var fs = require('fs');
var createMockFigma = require('./mock_figma.js').createMockFigma;

async function main() {
  var code = fs.readFileSync(process.argv[2], 'utf8');
  var payload = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  var figma = createMockFigma('Plugin smoke');
  var posted = [];
  var component = {
    id: '9:1', type: 'COMPONENT', name: 'Button', parent: { type: 'PAGE' },
    fills: [{ type: 'SOLID', visible: true, color: { r: 1, g: 0, b: 0 } }],
    strokes: [], children: [],
  };
  figma.showUI = function () {};
  figma.ui = { postMessage: function (m) { posted.push(m); }, onmessage: null };
  figma.loadAllPagesAsync = async function () {};
  figma.mixed = Symbol('mixed');
  figma.root.findAllWithCriteria = function () { return [component]; };
  global.figma = figma;
  global.__html__ = '<html></html>';
  (0, eval)(code);

  async function send(msg) { await figma.ui.onmessage(msg); }
  await send({ type: 'init' });
  await send({ type: 'import', payload: payload, prune: false });
  await send({ type: 'lint' });
  await send({ type: 'fix' });
  await send({ type: 'export' });
  fs.writeFileSync(process.argv[4], JSON.stringify(posted.map(function (m) {
    return m.type === 'export-result' ? { type: m.type, count: m.count, chunks: m.chunks } : m;
  }), null, 2));
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
