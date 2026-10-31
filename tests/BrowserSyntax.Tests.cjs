// Node.js regression check; no runtime dependency for end users.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const web=path.join(__dirname,'../web');
const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
const js=fs.readFileSync(path.join(web,'app.js'),'utf8');
const css=fs.readFileSync(path.join(web,'app.css'),'utf8');
const shell=fs.readFileSync(path.join(web,'shell.js'),'utf8');
const icons=fs.readFileSync(path.join(web,'icons.js'),'utf8');

// The CSP is script-src 'self'; style-src 'self': nothing inline may remain.
const scripts=[...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
// shell.js applies the remembered theme before the first paint; icons.js (generated Lucide icons) and app.js are deferred.
assert.deepEqual(scripts.map(x=>(/src="([^"]+)"/.exec(x[1])||[])[1]),['shell.js','icons.js','app.js'],'Expected only the external shell.js, icons.js and app.js');
for(const x of scripts)assert.equal(x[2].trim(),'','No inline script allowed');
assert.match(scripts[2][1],/\bdefer\b/,'app.js must be deferred');
assert.doesNotMatch(html,/<style\b/i,'No inline <style> allowed');
assert.doesNotMatch(html,/\sstyle="/i,'No inline style attributes allowed');
assert.doesNotMatch(html,/\son[a-z]+=/i,'No inline event handlers allowed');
assert.doesNotMatch(html+js,/__GANGPLANK_(CSRF|NONCE)__/,'Old CSRF/nonce placeholders must be gone');
for(const code of [js,shell,icons])assert.doesNotMatch(code,/\.innerHTML|insertAdjacentHTML|document\.write|\beval\(/,'Use textContent/DOM APIs only');
assert.match(html,/<link rel="stylesheet" href="vendor\/fleet\/fleet\.css">\s*<link rel="stylesheet" href="app\.css">/,'fleet.css must be linked before app.css');
// Fleet Unified UI (docs/UNIFIED-UI.md): teak accent, colours only through --fl-* tokens, the Gangplank mark.
assert.match(html,/<html[^>]*\sdata-app="gangplank"/,'<html data-app="gangplank"> sets the accent');
assert.doesNotMatch(css.replace(/\/\*[\s\S]*?\*\//g,''),/#[0-9a-f]{3,8}\b|\brgba?\(|\bhsla?\(/i,'app.css must use --fl-* tokens, not raw colours');
assert.doesNotMatch(css,/\bInter\b/,'No Inter (section 4)');
const lf=p=>fs.readFileSync(p,'utf8').split('\r\n').join('\n');
assert.equal(lf(path.join(web,'logo.svg')),lf(path.join(__dirname,'../assets/brand/mark.svg')),'web/logo.svg must be the Gangplank mark (assets/brand/mark.svg)');
assert.match(lf(path.join(web,'vendor/fleet/fleet.css')),/\[data-app='gangplank'\]/,'Vendored fleet.css missing');

new vm.Script(js,{filename:'web/app.js'});
new vm.Script(shell,{filename:'web/shell.js'});
new vm.Script(icons,{filename:'web/icons.js'});
for(const ref of html.matchAll(/data-icon="([^"]+)"/g))assert.ok(icons.includes(' '+ref[1]+':['),'Missing icon: '+ref[1]);
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
for(const ref of js.matchAll(/\bel\('([^']+)'\)/g)) assert.ok(ids.has(ref[1]),'Missing element ID: '+ref[1]);
for(const tab of ['overview','changes','branches','compare','activity','reviews','security','integrations','help']){
 assert.match(html,new RegExp('data-tab="'+tab+'"'),'Missing navigation: '+tab);
 assert.ok(ids.has(tab),'Missing section: '+tab);
}
for(const route of ['/api/branches','/api/history','/api/compare','/api/reviews','/api/insights','/api/sentinel','/api/session','/api/jobs/','/api/credentials','/api/integrations/lazarette','/api/audit','/api/chat','/api/settings','/api/settings/workspace','/api/settings/intelligence','/api/ai/detect','/api/ai/test'])
 assert.ok(js.includes(route),'UI missing route: '+route);
assert.match(js,/'X-Gangplank-Client'/,'API calls must send the client header');
// Lifecycle: the tab owns the local service (heartbeat, unload beacon, End session).
for(const piece of ["'/api/heartbeat'","sendBeacon","'pagehide'","'/api/session/stop'","'X-Gangplank-Intent':'end-session'","new Worker('/heartbeat-worker.js')"]) assert.ok(js.includes(piece),'UI missing lifecycle piece: '+piece);
assert.match(html,/<aside class="side[^"]*"[^>]*>[\s\S]*id="endSession"[\s\S]*<\/aside>/,'End session must be in the sidebar');
assert.match(js,/setInterval\(beatNow,5000\)/,'Fallback heartbeat must run every 5 s');
assert.ok(!/[?&](session|client)=/.test(js),'Session secrets must never go in a query string');
assert.match(js,/if\(await bootstrap\(\)\)\{startHeartbeat\(\)/,'Heartbeat starts only once the tab has a session');
const worker=fs.readFileSync(path.join(web,'heartbeat-worker.js'),'utf8');
new vm.Script(worker,{filename:'web/heartbeat-worker.js'});
// Run the worker against a fake fetch: it beats at once, then every interval, with the client header.
(async()=>{
 const calls=[],timers=[],sent=[];
 const ctx={fetch:(u,o)=>{calls.push({u,o});return Promise.resolve({ok:true,status:200})},setInterval:(f,ms)=>{timers.push({f,ms});return timers.length},clearInterval:()=>{timers.length=0},postMessage:m=>sent.push(m)};
 vm.createContext(ctx);new vm.Script(worker).runInContext(ctx);
 ctx.onmessage({data:{type:'start',token:'tok',tab:'t1',interval:5000}});
 assert.equal(calls.length,1,'worker beats immediately');
 assert.equal(timers[0].ms,5000,'worker beats every 5 s');
 assert.equal(calls[0].u,'/api/heartbeat');
 assert.equal(calls[0].o.headers['X-Gangplank-Client'],'tok');
 assert.equal(calls[0].o.credentials,'same-origin','worker heartbeat must send the session cookie');
 assert.deepEqual(JSON.parse(calls[0].o.body),{tab:'t1',leaving:false});
 timers[0].f();assert.equal(calls.length,1,'only one heartbeat in flight (the host serves one request at a time)');
 await new Promise(r=>setImmediate(r));assert.ok(sent.length>=1&&sent[0].ok,'worker reports heartbeat results to the page');
 timers[0].f();assert.equal(calls.length,2,'next tick beats again once the previous one answered');
 ctx.onmessage({data:{type:'stop'}});assert.equal(timers.length,0,'worker stops beating');
 // Spoken status: opt-in, results and errors only (never progress), degrades to silence without local voices.
 {
  const m=/function speakable\([^\n]*\}\r?\n/.exec(js);assert.ok(m,'speakable() decides what is spoken');
  const speakable=vm.runInNewContext('('+m[0].trim()+')');
  assert.equal(speakable('ok','Saved 2 files',true),true,'results are spoken when the setting is on');
  assert.equal(speakable('error','It failed',true),true,'errors are spoken when the setting is on');
  assert.equal(speakable('','Downloading...',true),false,'progress is never spoken');
  assert.equal(speakable('ok','Saved',false),false,'nothing is spoken while the setting is off');
  assert.equal(speakable('ok','',true),false,'an empty message is not spoken');
  assert.match(js,/localStorage\.getItem\('gp\.speak'\)==='1'/,'spoken status is off unless the viewer turned it on');
  assert.match(js,/window\.speechSynthesis&&window\.SpeechSynthesisUtterance/,'local voices are feature-detected');
  assert.doesNotMatch(html,/id="speakToggle"[^>]*checked/,'the toggle is off by default');
 }
 console.log('Browser markup, element references, lifecycle heartbeat, and JavaScript syntax passed.');
})().catch(e=>{console.error(e);process.exit(1)});
