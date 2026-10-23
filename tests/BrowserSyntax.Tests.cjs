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
console.log('Browser markup, element references, and JavaScript syntax passed.');
