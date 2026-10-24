// Node.js regression check; no runtime dependency for end users.
'use strict';
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const web=path.join(__dirname,'../web');
const html=fs.readFileSync(path.join(web,'index.html'),'utf8');
const js=fs.readFileSync(path.join(web,'app.js'),'utf8');
fs.readFileSync(path.join(web,'app.css'),'utf8');

// The CSP is script-src 'self'; style-src 'self': nothing inline may remain.
const scripts=[...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
assert.equal(scripts.length,1,'Expected exactly one script tag');
assert.match(scripts[0][1],/src="app\.js"/,'Script must be the external app.js');
assert.equal(scripts[0][2].trim(),'','No inline script allowed');
assert.doesNotMatch(html,/<style\b/i,'No inline <style> allowed');
assert.doesNotMatch(html,/\sstyle="/i,'No inline style attributes allowed');
assert.doesNotMatch(html,/\son[a-z]+=/i,'No inline event handlers allowed');
assert.doesNotMatch(html+js,/__KEYSTONE_(CSRF|NONCE)__/,'Old CSRF/nonce placeholders must be gone');
assert.doesNotMatch(js,/\.innerHTML|insertAdjacentHTML|document\.write|\beval\(/,'Use textContent/DOM APIs only');
assert.match(html,/<link rel="stylesheet" href="app\.css">/,'Stylesheet link missing');

new vm.Script(js,{filename:'web/app.js'});
const ids=new Set([...html.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
for(const ref of js.matchAll(/\bel\('([^']+)'\)/g)) assert.ok(ids.has(ref[1]),'Missing element ID: '+ref[1]);
for(const tab of ['overview','changes','branches','compare','activity','reviews','security','integrations','help']){
 assert.match(html,new RegExp('data-tab="'+tab+'"'),'Missing navigation: '+tab);
 assert.ok(ids.has(tab),'Missing section: '+tab);
}
for(const route of ['/api/branches','/api/history','/api/compare','/api/reviews','/api/insights','/api/sentinel','/api/session','/api/jobs/','/api/credentials','/api/integrations/arc','/api/audit','/api/chat'])
 assert.ok(js.includes(route),'UI missing route: '+route);
assert.match(js,/'X-Keystone-Client'/,'API calls must send the client header');
console.log('Browser markup, element references, and JavaScript syntax passed.');
