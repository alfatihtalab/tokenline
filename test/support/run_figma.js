// Drives core.js against the mock Figma for the Dart tests.
//
//   node run_figma.js <core.js> <payload.json> <out-dir> [edits.js]
//
// Applies the push payload, optionally runs designer edits (a module that
// exports function(figma, hexToRgba)), then writes:
//   <out-dir>/snapshot.json   figmaExportSnapshot()
//   <out-dir>/lint.json       lintSnapshot(snapshot, payload.config)
//   <out-dir>/apply.json      the apply summary
//   <out-dir>/stored.json     the chunked copy, reassembled from plugin data
'use strict';
var fs = require('fs');
var path = require('path');
var createMockFigma = require('./mock_figma.js').createMockFigma;

async function main() {
  var corePath = process.argv[2], payloadPath = process.argv[3], outDir = process.argv[4], editsPath = process.argv[5];
  global.figma = createMockFigma('Fixture');
  var core = require(path.resolve(corePath));
  var payload = JSON.parse(fs.readFileSync(payloadPath, 'utf8'));

  var summary = await core.figmaApplyPayload(payload, { prune: !!process.env.PRUNE });
  if (editsPath) await require(path.resolve(editsPath))(global.figma, core.hexToRgba);

  var snapshot = await core.figmaExportSnapshot();
  core.figmaStoreSnapshot(snapshot);
  var shared = global.figma._shared.tokenline;
  var meta = JSON.parse(shared['snapshot.meta']);
  var text = '';
  for (var i = 0; i < meta.chunks; i++) text += shared['snapshot.' + i];

  fs.writeFileSync(path.join(outDir, 'snapshot.json'), JSON.stringify(snapshot, null, 2));
  fs.writeFileSync(path.join(outDir, 'stored.json'), text);
  fs.writeFileSync(path.join(outDir, 'lint.json'), JSON.stringify(core.lintSnapshot(snapshot, payload.config), null, 2));
  fs.writeFileSync(path.join(outDir, 'apply.json'), JSON.stringify(summary, null, 2));
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
