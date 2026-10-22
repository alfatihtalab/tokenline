// Plays the Tokenline plugin's side of `tokenline sync` against the mock
// Figma: read Figma, POST /sync, apply the reply, POST /done.
//
//   node run_sync.js <core.js> <port> <out.json> [seed-snapshot.json|-] [edits.js|-]
'use strict';
var fs = require('fs');
var path = require('path');
var createMockFigma = require('./mock_figma.js').createMockFigma;

async function main() {
  var a = process.argv;
  var corePath = a[2], port = a[3], outPath = a[4], seed = a[5], edits = a[6];
  global.figma = createMockFigma('Fixture');
  var core = require(path.resolve(corePath));
  if (seed && seed !== '-') global.figma._load(JSON.parse(fs.readFileSync(seed, 'utf8')));
  if (edits && edits !== '-') await require(path.resolve(edits))(global.figma, core.hexToRgba);

  var server = 'http://127.0.0.1:' + port;
  function post(p, body) {
    return fetch(server + p, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(body) })
      .then(function (r) { return r.json(); });
  }
  var hello;
  for (var i = 0; i < 100 && !hello; i++) {
    try { hello = await (await fetch(server + '/hello')).json(); }
    catch (e) { await new Promise(function (r) { setTimeout(r, 100); }); }
  }
  if (!hello) throw new Error('tokenline sync never answered');

  var before = await core.figmaExportSnapshot();
  var plan = await post('/sync', { snapshot: before, fileName: 'Fixture' });
  var out = { hello: hello, ok: plan.ok, error: plan.error, lines: plan.summary && plan.summary.lines,
    deletes: plan.payload ? plan.payload.delete : [] };
  if (plan.ok) {
    var applied = await core.figmaApplyPayload(plan.payload, { prune: false });
    var after = await core.figmaExportSnapshot();
    var done = await post('/done', { snapshot: after, summary: applied });
    out.applied = applied;
    out.done = done;
    out.snapshot = after;
  } else {
    out.snapshot = before;
  }
  fs.writeFileSync(outPath, JSON.stringify(out, null, 2));
}

main().catch(function (e) { console.error(e && e.stack || e); process.exit(1); });
