// Node.js regression check; no runtime dependency for end users.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const html=fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8');
const blocks=[...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)];
assert.equal(blocks.length,1,'Expected one local nonce-protected script (no external JS dependency)');
new vm.Script(blocks[0][1],{filename:'web/index.html'});
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
for(const ref of blocks[0][1].matchAll(/\bel\('([^']+)'\)/g)) assert.ok(ids.has(ref[1]),'Missing element ID: '+ref[1]);
for(const tab of ['overview','changes','branches','compare','activity','reviews','security','integrations','help']){
 assert.match(html,new RegExp('data-tab="'+tab+'"'),'Missing navigation: '+tab);
 assert.ok(ids.has(tab),'Missing section: '+tab);
}
const routes=['/api/branches','/api/history','/api/compare','/api/reviews','/api/insights','/api/sentinel'];
for(const route of routes) assert.ok(blocks[0][1].includes(route),'UI missing route: '+route);
// Lifecycle: the tab owns the local service (heartbeat, unload beacon, End session).
const script=blocks[0][1];
for(const piece of ["'/api/heartbeat'","sendBeacon","'pagehide'","'/api/session/stop'","'X-Keystone-Intent':'end-session'","new Worker('/heartbeat-worker.js')"]) assert.ok(script.includes(piece),'UI missing lifecycle piece: '+piece);
assert.match(html,/<nav[^>]*>[\s\S]*id="endSession"[\s\S]*<\/nav>/,'End session must be in the main navigation');
assert.match(script,/setInterval\(beatNow,5000\)/,'Fallback heartbeat must run every 5 s');
assert.ok(!/[?&]session=/.test(script),'Session token must never go in a query string');
const worker=fs.readFileSync(path.join(__dirname,'../web/heartbeat-worker.js'),'utf8');
new vm.Script(worker,{filename:'web/heartbeat-worker.js'});
// Run the worker against a fake fetch: it beats at once, then every interval, with the session header.
(async()=>{
 const calls=[],timers=[],sent=[];
 const ctx={fetch:(u,o)=>{calls.push({u,o});return Promise.resolve({ok:true,status:200})},setInterval:(f,ms)=>{timers.push({f,ms});return timers.length},clearInterval:()=>{timers.length=0},postMessage:m=>sent.push(m)};
 vm.createContext(ctx);new vm.Script(worker).runInContext(ctx);
 ctx.onmessage({data:{type:'start',token:'tok',tab:'t1',interval:5000}});
 assert.equal(calls.length,1,'worker beats immediately');
 assert.equal(timers[0].ms,5000,'worker beats every 5 s');
 assert.equal(calls[0].u,'/api/heartbeat');
 assert.equal(calls[0].o.headers['X-Keystone-Session'],'tok');
 assert.deepEqual(JSON.parse(calls[0].o.body),{tab:'t1',leaving:false});
 timers[0].f();assert.equal(calls.length,1,'only one heartbeat in flight (the host serves one request at a time)');
 await new Promise(r=>setImmediate(r));assert.ok(sent.length>=1&&sent[0].ok,'worker reports heartbeat results to the page');
 timers[0].f();assert.equal(calls.length,2,'next tick beats again once the previous one answered');
 ctx.onmessage({data:{type:'stop'}});assert.equal(timers.length,0,'worker stops beating');
 console.log('Browser markup, element references, lifecycle heartbeat, and JavaScript syntax passed.');
})().catch(e=>{console.error(e);process.exit(1)});
