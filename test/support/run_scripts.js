// Runs push scripts the way use_figma does (body of an async function with a
// `figma` global), in order, against one mock file; then exports.
//
//   node run_scripts.js <core.js> <out-dir> <script1.js> [script2.js ...]
'use strict';
var fs = require('fs');
var path = require('path');
var createMockFigma = require('./mock_figma.js').createMockFigma;
var AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

async function main() {
  var corePath = process.argv[2], outDir = process.argv[3], scripts = process.argv.slice(4);
  global.figma = createMockFigma('Fixture');
  // Pre-existing extra variable: only a pruning push may delete it.
  var c = global.figma.variables.createVariableCollection('Fx / Primitives');
  c.renameMode(c.modes[0].modeId, 'Base');
  global.figma.variables.createVariable('legacy/old', c, 'FLOAT');
  global.figma.variables.createVariable('_draft/keep-me', c, 'FLOAT');
  var frame = global.figma.createFrame();
  if (process.env.FRAME_ID_FILE) fs.writeFileSync(process.env.FRAME_ID_FILE, frame.id);

  var results = [];
  for (var i = 0; i < scripts.length; i++) {
    var fn = new AsyncFunction('figma', fs.readFileSync(scripts[i], 'utf8'));
    results.push(await fn(global.figma));
  }
  var core = require(path.resolve(corePath));
  fs.writeFileSync(path.join(outDir, 'results.json'), JSON.stringify(results, null, 2));
  fs.writeFileSync(path.join(outDir, 'snapshot.json'), JSON.stringify(await core.figmaExportSnapshot(), null, 2));
  fs.writeFileSync(path.join(outDir, 'stored-config.json'), global.figma.root.getSharedPluginData('tokenline', 'config'));
  fs.writeFileSync(path.join(outDir, 'frame.json'), JSON.stringify({
    rects: frame.children.filter(function (n) { return n.type === 'RECTANGLE'; }).map(function (n) { return n.name; }),
    subframes: frame.children.filter(function (n) { return n.type === 'FRAME'; }).map(function (n) { return { name: n.name, rects: n.children.length }; }),
  }));
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
