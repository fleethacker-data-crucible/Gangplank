'use strict';const el=id=>document.getElementById(id);let connected=false,workspace='',changes=[],stale=false,lastSaved=false;
function tab(name){document.querySelectorAll('.section').forEach(x=>x.classList.toggle('active',x.id===name));let navHit=false;document.querySelectorAll('.nav button[data-tab]').forEach(x=>{const on=x.dataset.tab===name;x.classList.toggle('active',on);if(on){navHit=true;x.setAttribute('aria-current','page');el('crumb').textContent=x.querySelector('.navLabel')?.textContent||name}else x.removeAttribute('aria-current')});if(!navHit&&el('crumb'))el('crumb').textContent=(name==='overview'?'Overview':name);el('main').scrollTop=0;if(connected){if(name==='branches')loadBranches();if(name==='compare')loadBranchSelectors();if(name==='activity')loadHistory();if(name==='reviews')loadReviews();}if(name==='integrations'){loadIntegrations();loadAudit();loadSettings()}if(name==='overview'){loadTokenCards().catch(()=>{});loadSettings().catch(()=>{})}}
document.querySelectorAll('.nav button[data-tab]').forEach(x=>x.addEventListener('click',()=>tab(x.dataset.tab)));
function note(id,t,k=''){let x=el(id);x.hidden=!t;x.className='notice '+k;x.textContent=t;if(speakable(k,t,speechOn()))speak(t);}
function log(t){let d=document.createElement('div'),x=document.createElement('time');d.className='activityItem';d.textContent=t;x.textContent=new Date().toLocaleTimeString();d.append(x);el('activityList').prepend(d);}
async function api(path,method='GET',body,timeoutMs){
  const ctrl=typeof timeoutMs==='number'&&timeoutMs>0?new AbortController():null;
  const timer=ctrl?setTimeout(()=>ctrl.abort(),timeoutMs):null;
  try{
    let r=await fetch(path,{method,headers:{'X-Gangplank-Client':clientSecret(),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,cache:'no-store',credentials:'same-origin',signal:ctrl?ctrl.signal:undefined});
    let t=await r.text(),x;
    try{x=JSON.parse(t)}catch{throw Error('Invalid service response')}
    if(r.status===401&&x.error==='SESSION'){ended(x.message);throw Error(x.message)}
    if(!r.ok){const e=Error(plain(x.message||x.error||'Request failed'));e.code=x.error||'';throw e}
    return x;
  }catch(e){
    if(e&&e.name==='AbortError'){const err=Error('Timed out waiting for the local service.');err.code='TIMEOUT';throw err}
    throw e;
  }finally{if(timer)clearTimeout(timer)}
}
function ended(t,state='stopped'){sessionEnded=true;stopHeartbeat();el('ended').hidden=false;if(t)el('endedText').textContent=t;el('online').textContent='Session ended';engine(state);document.querySelector('.shell').inert=true;el('ended').querySelector('[tabindex]').focus()}
// Status bar (docs/UNIFIED-UI.md section 5): engine dot plus a word, never colour alone.
const ENGINE={connecting:'Connecting',running:'Running',disconnected:'Disconnected',stopping:'Stopping',stopped:'Stopped'};
function engine(state){el('engine').className='engine engine-'+state;el('engineWord').textContent=ENGINE[state]}
el('boundAddress').textContent=location.host||'—';
// Small Lucide icon after a label (icons.js); text only if the icon module is missing.
function withIcon(node,label,name){node.append(label);if(typeof window.gangplankIcon==='function')node.append(window.gangplankIcon(name,16));return node}
// Per-session secret from /api/session, kept in this tab only (sessionStorage is per
// origin, so per port; cookies are not). Sent with every API call.
function clientSecret(){try{return sessionStorage.getItem('gangplank-client')||''}catch{return ''}}
function setClientSecret(v){try{sessionStorage.setItem('gangplank-client',v)}catch{}}
function plain(m){return String(m||'').replace(/^[A-Z][A-Z0-9_]{2,40}\|/,'')}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// Long operations run as background jobs on the host: start, then poll.
let activeJob=null;
function jobCancel(show,label=''){el('jobCancel').hidden=!show;el('jobCancelLabel').textContent=label;el('cancelJob').disabled=false}
async function runJob(path,body,onProgress,onChunk){let x=await api(path,'POST',body||{});if(!x.job)return x;activeJob=x.job;jobCancel(true,'Starting...');try{let after=0;for(;;){await sleep(400);const j=await api('/api/jobs/'+x.job+'?after='+after);if(onChunk&&j.chunks)for(const c of j.chunks)onChunk(c);after=j.next;if(onProgress)onProgress(j.progress);el('jobCancelLabel').textContent=j.progress+'...';if(j.state==='succeeded')return j.result||{};if(j.state==='cancelled'){const e=Error('Stopped before it finished. The History tab shows whether the change went through.');e.code='CANCELLED';throw e}if(j.state!=='running'&&j.state!=='cancelling'){const raw=j.error||'The operation failed.',e=Error(plain(raw));e.code=/^[A-Z][A-Z0-9_]{2,40}|/.test(raw)?raw.split('|')[0]:'';throw e}}}finally{activeJob=null;jobCancel(false)}}
el('cancelJob')&&el('cancelJob').addEventListener('click',async()=>{if(!activeJob)return;const b=el('cancelJob');b.disabled=true;el('jobCancelLabel').textContent='Stopping...';try{await api('/api/jobs/'+activeJob+'/cancel','POST',{})}catch(e){b.disabled=false;el('jobCancelLabel').textContent='Could not stop: '+plain(String(e.message||e))}});
async function bootstrap(){const m=/[#&]k=([A-Za-z0-9_-]{20,})/.exec(location.hash);if(m){history.replaceState(null,'',location.pathname);try{const r=await fetch('/api/session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:m[1]}),credentials:'same-origin'});const x=await r.json().catch(()=>({}));if(r.ok&&x.client)setClientSecret(x.client)}catch{}}
 // A reused or expired link is fine if this tab already has a live session.
 const h=await fetch('/api/health',{cache:'no-store',headers:{'X-Gangplank-Client':clientSecret()}}).then(r=>r.json()).catch(()=>({}));if(!h.session){ended();return false}return true}

let lazaretteDiagnosticText='';
el('copyLazaretteDiagnostics')&&el('copyLazaretteDiagnostics').addEventListener('click',async()=>{if(!lazaretteDiagnosticText){await loadIntegrations()}try{await navigator.clipboard.writeText(lazaretteDiagnosticText);note('lazaretteNotice','Safe diagnostics copied. They contain no tokens or passwords.','ok')}catch(e){note('lazaretteNotice','Clipboard access denied. Select and copy the details shown above.','warn')}});
const SOURCE={environment:'environment variable',stored:'saved on this PC',lazarette:'Lazarette vault',none:'not set'};
function credRow(c,storeOk){const row=document.createElement('div');row.className='credRow';const name=document.createElement('strong');name.textContent=c.provider;const body=document.createElement('div');const state=document.createElement('div');state.className='small';state.textContent=c.storedUnreadable&&!c.configured?'The saved token cannot be read by this Windows account. Paste it again.':c.configured?('Ready: '+SOURCE[c.source]+(c.source==='environment'?' ('+c.environmentVariable+')':'')+(c.source==='stored'&&c.storedAt?' since '+new Date(c.storedAt).toLocaleDateString():'')):'Not set. Paste a personal access token below, or set '+c.environmentVariable+'.';body.append(state);
 if(storeOk){const input=document.createElement('input');input.type='password';input.className='field';input.autocomplete='off';input.spellcheck=false;input.placeholder=c.source==='stored'?'Paste a new token to replace the saved one':'Paste token';input.setAttribute('aria-label',name.textContent+' token');const acts=document.createElement('div');acts.className='actions';const save=document.createElement('button');save.className='btn';save.type='button';save.textContent='Save token';save.addEventListener('click',async()=>{const v=input.value.trim();if(!v)return;save.disabled=true;try{await api('/api/credentials','POST',{provider:c.provider,token:v});input.value='';note('credNotice',name.textContent+' token saved and sealed on this PC.','ok');await loadIntegrations()}catch(e){note('credNotice',e.message,'error')}finally{save.disabled=false}});acts.append(save);
  if(c.source==='stored'||c.storedAt){const rm=document.createElement('button');rm.className='btn';rm.type='button';rm.textContent='Remove saved token';rm.addEventListener('click',async()=>{if(!confirm('Remove the saved '+name.textContent+' token from this PC?'))return;try{await api('/api/credentials/remove','POST',{provider:c.provider});note('credNotice','Saved token removed.','ok');await loadIntegrations()}catch(e){note('credNotice',e.message,'error')}});acts.append(rm)}
  body.append(input,acts)}
 row.append(name,body);return row}
async function loadIntegrations(){
 try{const info=await api('/api/integrations');
  el('credStore').textContent=info.storeAvailable?('Saved tokens are protected with '+info.storeProtection+'.'):'Saving tokens needs Windows DPAPI, which is not available here. Use environment variables instead.';
  const list=el('credList');list.replaceChildren();for(const c of info.credentials||[])list.append(credRow(c,info.storeAvailable));
  const laz=info.lazarette||{},st=laz.status||{};el('lazaretteEnabled').checked=!!laz.enabled;el('lazaretteEnabled').disabled=!!laz.fromEnvironment;el('lazarettePath').value=laz.configuredPath||'';el('lazarettePath').disabled=!!laz.fromEnvironment;
  const status=el('lazaretteStatus');
  if(!laz.enabled){status.className='notice';status.textContent='Lazarette is off. Gangplank uses environment variables and tokens saved above.';el('lazaretteDetails').textContent='';lazaretteDiagnosticText='Lazarette: not configured';el('lazaretteMappings').replaceChildren();return}
  const ready=st.lazaretteLoaded&&st.lazaretteUnlocked;status.className='notice '+(ready?'ok':'warn');status.textContent=(laz.fromEnvironment?'Configured by GANGPLANK_LAZARETTE_PATH. ':'')+(st.message||'Lazarette status unavailable.');
  const helper=st.helpers||{};
  lazaretteDiagnosticText=['Status code: '+(st.code||'OK'),'Lazarette version: '+(st.lazaretteVersion||'unknown'),'Lazarette located: '+!!st.lazaretteFound,'Lazarette loaded: '+!!st.lazaretteLoaded,'Vault unlocked: '+!!st.lazaretteUnlocked,'Helpers: '+Object.entries(helper).filter(([k,v])=>v).map(([k])=>k).join(', ')].join('\n');
  el('lazaretteDetails').textContent=ready?'':lazaretteDiagnosticText;
  const box=el('lazaretteMappings');box.replaceChildren();if(!ready)return;const names=Array.isArray(st.itemNames)?st.itemNames:[];
  for(const c of info.credentials||[]){const row=document.createElement('div');row.className='credRow';const n=document.createElement('strong');n.textContent=c.provider;const wrap=document.createElement('div');const sel=document.createElement('select');sel.className='field';for(const name of [...new Set([c.lazaretteItem,...names])].filter(Boolean)){const o=document.createElement('option');o.value=name;o.textContent=name;o.selected=name===c.lazaretteItem;sel.append(o)}const b=document.createElement('button');b.className='btn';b.type='button';b.textContent='Use this Lazarette item';b.addEventListener('click',async()=>{try{await api('/api/integrations/map','POST',{provider:c.provider,item:sel.value});note('lazaretteNotice','Saved. Only the item name was stored.','ok');await loadIntegrations()}catch(e){note('lazaretteNotice',e.message,'error')}});wrap.append(sel,b);row.append(n,wrap);box.append(row)}
 }catch(e){el('lazaretteStatus').className='notice error';el('lazaretteStatus').textContent='Unable to read credential status: '+e.message}
}
el('credRefresh')&&el('credRefresh').addEventListener('click',loadIntegrations);
el('lazaretteSave')&&el('lazaretteSave').addEventListener('click',async()=>{try{await api('/api/integrations/lazarette','POST',{enabled:el('lazaretteEnabled').checked,path:el('lazarettePath').value.trim()});note('lazaretteNotice',el('lazaretteEnabled').checked?'Saved. Restart Gangplank and unlock Lazarette in its PowerShell window to use it.':'Lazarette turned off.','ok');await loadIntegrations()}catch(e){note('lazaretteNotice',e.message,'error')}});
async function loadAudit(){try{const x=await api('/api/audit?last=30');const box=el('auditList');box.replaceChildren();if(!x.entries.length){box.textContent='Nothing recorded yet.';return}for(const a of x.entries){const d=document.createElement('div');d.className='activityItem';d.textContent=a.action+(a.project?' · '+a.project:'')+(a.branch?' · '+a.branch:'')+(a.commit?' · '+String(a.commit).slice(0,10):'')+(a.provider&&!a.project?' · '+a.provider:'');const t=document.createElement('time');t.textContent=new Date(a.time).toLocaleString();d.append(t);box.append(d)}}catch(e){el('auditList').textContent='Unavailable: '+e.message}}
el('auditRefresh')&&el('auditRefresh').addEventListener('click',loadAudit);
function selected(){return [...document.querySelectorAll('#files input:checked')].map(x=>x.value);}
function suggest(){let a=changes.filter(x=>selected().includes(x.Path)),roots=[...new Set(a.map(x=>x.Path.replace(/\\/g,'/').split('/')[0]))],scope=roots.length===1&&!roots[0].includes('.')?roots[0].toLowerCase():'project',type=a.every(x=>x.Kind==='New')?'feat':'chore';return a.length?(type+'('+scope+'): update '+(a.length===1?a[0].Path.split('/').pop():a.length+' files')):'No changes';}
function controls(){
  const branch=el('statBranch')?el('statBranch').textContent:'';
  const title=el('projectTitle')?el('projectTitle').textContent:'';
  if(connected){
    const hp=el('headerProject'),ht=el('headerProjectText');
    if(hp&&ht){hp.hidden=false;ht.textContent=title+(branch&&branch!=='\u2014'?' \u00b7 '+branch:'')}
    if(el('statusProject'))el('statusProject').textContent='Project: '+title;
  }else if(!(pendingSelection&&pendingSelection.path)){
    const hp=el('headerProject');if(hp)hp.hidden=true;
    if(el('statusProject'))el('statusProject').textContent='No project connected';
  }
  const setDis=(id,v)=>{const n=el(id);if(n)n.disabled=!!v};
  setDis('startBtn',!connected);
  setDis('reviewBtn',!lastSaved);
  setDis('downloadBtn',!connected);
  setDis('adoptBtn',!connected);
  setDis('publishFolderBtn',!connected);
  setDis('refreshBtn',!workspace);
  setDis('selectBtn',!changes.length);
  setDis('localBtn',!selected().length);
  setDis('aiBtn',!selected().length||stale);
  setDis('saveBtn',!selected().length||stale);
  setDis('disconnectBtn',!connected);
  const cb=el('connectBtn');
  if(cb){
    const label=connected?'Switch project':'Connect project';
    cb.innerHTML='';
    if(typeof withIcon==='function'){withIcon(cb,label+' ','next')}else{cb.textContent=label}
    cb.title=connected?'Connect a different URL to switch projects. Or Disconnect first.':'Connect opens the session. Header updates after Connect succeeds.';
  }
  paintSelection();
}
function changed(){el('selectedCount').textContent=selected().length+' selected';el('message').value=suggest();controls();}
function render(){closeDiff(false);el('files').replaceChildren();for(let f of changes){let row=document.createElement('div'),main=document.createElement('label'),input=document.createElement('input'),path=document.createElement('span'),tag=document.createElement('span');row.className='file';main.className='fileMain';input.type='checkbox';input.value=f.Path;input.checked=f.Selected&&!f.Blocked;input.disabled=f.Blocked;input.addEventListener('change',changed);path.className='path';path.textContent=f.Path;tag.className='tag';tag.textContent=f.Blocked?'Excluded':f.Kind;main.append(input,path,tag);row.append(main);
 // Excluded files (secrets, oversize) get no viewer; the host refuses them too.
 if(!f.Blocked){const v=document.createElement('button');v.type='button';v.className='btn fl-btn fl-btn--secondary diffBtn';v.textContent='View changes';v.setAttribute('aria-label','View changes in '+f.Path);v.addEventListener('click',()=>showDiff(f,v));row.append(v)}
 if(!f.Blocked&&f.Kind!=='New'){let rv=document.createElement('button');rv.type='button';rv.className='btn fl-btn fl-btn--secondary rowBtn';rv.textContent='Revert';rv.title='Go back to the downloaded version of this file. Your edited copy is saved aside first.';rv.setAttribute('aria-label','Revert '+f.Path);rv.addEventListener('click',ev=>{ev.preventDefault();revertFile(f.Path)});row.append(rv)}
 addExplain(row,f);el('files').append(row);}el('diffSummary').textContent=changes.length?changes.length+' pending files; deletions are never selected automatically.':'No local changes yet.';el('statChanges').textContent=changes.length;el('stale').hidden=!stale;changed();}
let latestChoices={};
function showOverlaps(items){const box=el('latestList');box.replaceChildren();for(const o of items){const row=document.createElement('fieldset'),lg=document.createElement('legend');lg.textContent=o.path+' (online: '+o.online+', yours: '+o.yours+')';row.append(lg);for(const [v,t] of [['mine','Keep my version'],['theirs','Take the online version']]){const lb=document.createElement('label'),rd=document.createElement('input');rd.type='radio';rd.name='ov-'+o.path;rd.value=v;rd.checked=latestChoices[o.path]===v;rd.addEventListener('change',()=>{latestChoices[o.path]=v;el('latestApply').disabled=!items.every(i=>latestChoices[i.path])});lb.append(rd,document.createTextNode(' '+t));row.append(lb)}box.append(row)}el('latestPanel').hidden=false;el('latestApply').disabled=!items.every(i=>latestChoices[i.path])}
async function getLatest(){const b=el('latestBtn'),a=el('latestApply');b.disabled=true;a.disabled=true;try{const r=await runJob('/api/latest',{choices:latestChoices},x=>note('saveNotice',x+'...'));if(r.upToDate){el('latestPanel').hidden=true;latestChoices={};note('saveNotice','Your workspace is already up to date.','ok')}else if(r.needsChoice){note('saveNotice','Some files changed online and on your PC. Choose which version to keep.','warn');showOverlaps(r.overlaps)}else{el('latestPanel').hidden=true;latestChoices={};note('saveNotice','Brought in the online changes: '+r.applied.length+' file(s).','ok');await refresh()}}catch(e){note('saveNotice',e.message,'error')}finally{b.disabled=false}}
el('latestBtn')&&el('latestBtn').addEventListener('click',()=>{latestChoices={};getLatest()});
el('latestApply')&&el('latestApply').addEventListener('click',getLatest);
async function revertFile(p){if(!confirm('Go back to the downloaded version of '+p+'? Your edited copy is saved in a backup folder next to the workspace first.'))return;try{const r=await runJob('/api/revert',{path:p},x=>note('saveNotice',x+'...'));note('saveNotice','Reverted '+p+(r.BackupPath?'. Your edited copy is in '+r.BackupPath:'.'),'ok');await refresh()}catch(e){note('saveNotice',e.message,'error')}}
async function refresh(){if(!workspace)return;try{let x=await api('/api/preview');changes=x.changes||[];stale=!!x.remoteChanged;render();}catch(e){note('saveNotice',e.message,'error')}}
// ---- Diff viewer (Changes tab). The line diff is computed by diff-worker.js in a Web Worker,
// so a big file never freezes the page. If the worker cannot start (blocked, or it fails to
// load), the same function is loaded as a plain script and run on the main thread instead.
// File text is untrusted: every line is shown with textContent.
const DIFF_ROWS=3000;
let diffWorker=null,diffWorkerOff=false,diffNext=0,diffToken=0,diffOpener=null;const diffJobs=new Map();
function diffLocal(before,after){
 const load=window.GangplankDiff?Promise.resolve(window.GangplankDiff):new Promise((ok,no)=>{const s=document.createElement('script');s.src='/diff-worker.js';s.onload=()=>window.GangplankDiff?ok(window.GangplankDiff):no(Error('The comparison code could not be loaded.'));s.onerror=()=>no(Error('The comparison code could not be loaded.'));document.head.append(s)});
 return load.then(d=>new Promise(r=>setTimeout(r,0)).then(()=>d.computeDiff(before,after)));
}
function diffWorkerFailed(){
 diffWorkerOff=true;if(diffWorker){try{diffWorker.terminate()}catch{}diffWorker=null}
 const jobs=[...diffJobs.values()];diffJobs.clear();for(const j of jobs)diffLocal(j.before,j.after).then(j.resolve,j.reject);
}
function diffCancel(){if(diffWorker&&diffJobs.size){try{diffWorker.terminate()}catch{}diffWorker=null}diffJobs.clear()}
function diffCompute(before,after){
 return new Promise((resolve,reject)=>{
  if(!diffWorker&&!diffWorkerOff){
   try{diffWorker=new Worker('/diff-worker.js');diffWorker.onmessage=e=>{const m=e.data||{},j=diffJobs.get(m.id);if(!j)return;diffJobs.delete(m.id);if(m.type==='result')j.resolve(m);else j.reject(Error(m.message||'The comparison failed.'))};diffWorker.onerror=e=>{if(e&&e.preventDefault)e.preventDefault();diffWorkerFailed()}}
   catch{diffWorker=null;diffWorkerOff=true}
  }
  if(!diffWorker){diffLocal(before,after).then(resolve,reject);return}
  const id=++diffNext;diffJobs.set(id,{before,after,resolve,reject});diffWorker.postMessage({type:'diff',id,before,after});
 });
}
function diffStatus(t){el('diffStatus').textContent=t}
function closeDiff(focusBack=true){
 diffToken++;diffCancel();el('diffPanel').hidden=true;el('diffView').hidden=true;el('diffView').replaceChildren();diffStatus('');
 const o=diffOpener;diffOpener=null;if(focusBack&&o&&o.isConnected)o.focus();
}
function renderDiff(r,path){
 const view=el('diffView'),s=r.stats||{};view.replaceChildren();
 if(!r.hunks.length){view.hidden=true;diffStatus(s.endingsOnly?'The text is the same; only line endings or the final newline changed.':'No differences in the text.');return}
 diffStatus(path+': '+s.added+' line'+(s.added===1?'':'s')+' added, '+s.removed+' removed. A + marks an added line and a - a removed line.');
 let shown=0,cut=false;const frag=document.createDocumentFragment();
 outer:for(const h of r.hunks){
  const head=document.createElement('div');head.className='diffHunk';head.textContent='@@ -'+h.aStart+','+h.aCount+' +'+h.bStart+','+h.bCount+' @@';frag.append(head);
  for(const l of h.lines){
   if(shown>=DIFF_ROWS){cut=true;break outer}
   shown++;
   const row=document.createElement('div'),a=document.createElement('span'),b=document.createElement('span'),mark=document.createElement('span'),text=document.createElement('span');
   row.className='diffLine '+(l.t==='+'?'diffAdd':l.t==='-'?'diffDel':'diffCtx');
   a.className='diffNo';a.textContent=l.a||'';b.className='diffNo';b.textContent=l.b||'';
   mark.className='diffMark';mark.textContent=l.t==='+'||l.t==='-'?l.t:' ';
   text.className='diffText';text.textContent=l.text;
   row.append(a,b,mark,text);frag.append(row);
  }
 }
 if(cut){const more=document.createElement('div');more.className='diffHunk';more.textContent='Only the first '+DIFF_ROWS+' lines are shown.';frag.append(more)}
 view.append(frag);view.hidden=false;
}
async function showDiff(f,opener){
 const token=++diffToken;diffCancel();diffOpener=opener;
 el('diffPanel').hidden=false;el('diffView').hidden=true;el('diffView').replaceChildren();
 el('diffTitle').textContent='Changes in '+f.Path;diffStatus('Loading the file...');
 el('diffTitle').focus();el('diffPanel').scrollIntoView({block:'nearest'});
 try{
  const d=await api('/api/diff?'+new URLSearchParams({path:f.Path}).toString());
  if(token!==diffToken)return;
  if(d.excluded){diffStatus('This file is excluded from saving (it may hold secrets), so its contents are not shown.');return}
  if(d.binary){diffStatus('This is not a text file, so there is nothing to compare line by line.');return}
  if(d.truncated){diffStatus('Too large to show: files above '+Math.round((d.limit||524288)/1024)+' KB are not compared here.');return}
  diffStatus('Computing...');
  const r=await diffCompute(d.before||'',d.after||'');
  if(token!==diffToken)return;
  if(r.tooLarge){diffStatus(r.message||'Too large to show.');return}
  renderDiff(r,f.Path);
 }catch(e){if(token===diffToken)diffStatus('Could not show the changes: '+e.message)}
}
el('diffClose')&&el('diffClose').addEventListener('click',()=>closeDiff());
function setLoadingPlaceholder(node, text){
  if(!node)return;
  node.innerHTML='';
  const wrap=document.createElement('div');
  wrap.className='loadingBlock';
  wrap.setAttribute('role','status');
  const spin=document.createElement('span');spin.className='loadingSpin';spin.setAttribute('aria-hidden','true');
  const msg=document.createElement('span');msg.className='loadingText';msg.textContent=text||'Loading…';
  wrap.append(spin,msg);
  node.append(wrap);
}
async function init(){
  try{
    let x=await api('/api/status');
    connected=!!x.connected;workspace=x.workspace||'';lastSaved=!!x.canReview;
    el('online').textContent='Local service connected';engine('running');
    el('projectTitle').textContent=x.project||'Ready when you are';
    el('testBanner').hidden=!x.localDev;
    if(x.localDev&&x.devProvider&&!el('repoUrl').value)el('repoUrl').value=x.devProvider+'/gangplank-demo/sample';
    el('projectHint').textContent=x.restoredWaiting?'Your previous session is saved. Add a token in Credentials to continue it.':connected?(workspace?'Workspace ready. Edit files there, then Smart Save.':'Connected; download a workspace to begin.'):'Add tokens, then pick a writable project or paste any HTTPS URL.';
    if(x.branch)el('branch').value=x.branch;
    el('statProvider').textContent=x.provider||'—';
    el('statBranch').textContent=x.branch||'—';
    el('workspacePath').textContent=workspace||'No workspace downloaded.';
    controls();
    // Placeholders while secondary work runs — do not block the status bar or overview chrome.
    if(el('tokenCards'))setLoadingPlaceholder(el('tokenCards'),'Loading tokens…');
    if(workspace&&el('files'))setLoadingPlaceholder(el('files'),'Checking workspace changes…');
    if(el('diffSummary')&&workspace)el('diffSummary').textContent='Loading change list…';
    if(connected&&el('insightsSummary'))el('insightsSummary').textContent='Loading insights…';
    if(connected&&el('insightsList'))setLoadingPlaceholder(el('insightsList'),'Gathering recommendations…');
    // Run secondary loads in parallel; failures stay local to each section.
    const tasks=[];
    tasks.push(loadTokenCards().catch(e=>{if(el('tokenCards'))el('tokenCards').textContent='Token status unavailable: '+e.message}));
    tasks.push(loadSettings().catch(()=>{}));
    tasks.push(loadIntegrations().catch(()=>{}));
    if(workspace)tasks.push(refresh().catch(e=>{note('saveNotice',e.message,'error')}));
    if(connected)tasks.push(loadInsights().catch(e=>{if(el('insightsSummary'))el('insightsSummary').textContent='Insights unavailable: '+e.message}));
    Promise.all(tasks).finally(()=>controls());
  }catch(e){
    el('online').textContent='Open this page through Start-Gangplank.ps1';
    engine('disconnected');
    note('notice','Start Gangplank using Start-Gangplank.ps1, then open the localhost URL.','warn');
    controls();
  }
}
el('connectBtn')&&el('connectBtn').addEventListener('click',async()=>{let b=el('connectBtn');b.disabled=true;const switching=connected;try{let url=el('repoUrl').value.trim();if(!url&&selectedPaths.size===1){const only=[...selectedPaths][0];const hit=catalogProjects.find(p=>p.path===only);if(hit){url=hit.url||'';el('repoUrl').value=url}}if(!url){note('notice','Paste a project URL, or check exactly one project (or Use), then Connect.','warn');return}if(selectedPaths.size>1&&!el('repoUrl').value.trim()){note('notice','Multiple projects are checked. Set the URL (or Use one project) so Connect knows which session to open.','warn');return}let x=await runJob('/api/connect',{url},p=>note('notice',p+'...'));connected=true;pendingSelection=null;workspace='';changes=[];lastSaved=false;el('workspacePath').textContent='No workspace downloaded.';el('projectTitle').textContent=x.project;el('projectHint').textContent=switching?'Switched. Next: download with Start my safe workspace or Explore this branch.':'Connected. Next: download with Start my safe workspace or Explore this branch.';el('statProvider').textContent=x.provider;el('statBranch').textContent=x.branch;el('statChanges').textContent='—';if(x.branch)el('branch').value=x.branch;setNextStep('<strong>Next:</strong> In section 2, press <strong>Start my safe workspace</strong> (new work branch) or <strong>Explore this branch</strong> (download only).');note('notice',(switching?'Switched to ':'Connected to ')+x.project+'. Now download a workspace in section 2.','ok');log((switching?'Switched to ':'Connected to ')+x.project);await loadInsights()}catch(e){const message=e.message;note('notice',message,'error');if(/^(ARC_|CREDENTIAL_)/.test(e.code||'')){tab('integrations');await loadIntegrations();note('lazaretteNotice',message,'error')}}finally{b.disabled=false;controls()}});
el('disconnectBtn')&&el('disconnectBtn').addEventListener('click',async()=>{if(!connected)return;if(!confirm('Disconnect from the current project? Local workspace folders on disk are kept. You can connect another project afterward.'))return;const b=el('disconnectBtn');b.disabled=true;try{await api('/api/disconnect','POST',{});connected=false;pendingSelection=null;workspace='';changes=[];stale=false;lastSaved=false;el('projectTitle').textContent='Ready when you are';el('projectHint').textContent='Disconnected. Select a writable project or paste a URL, then Connect.';el('statProvider').textContent='—';el('statBranch').textContent='—';el('statChanges').textContent='—';el('workspacePath').textContent='No workspace downloaded.';el('branch').value='';if(el('files'))el('files').replaceChildren();if(el('insightsList'))el('insightsList').replaceChildren();if(el('insightsSummary'))el('insightsSummary').textContent='Connect a project to see intelligent recommendations.';note('notice','Disconnected. Choose another project when ready.','ok');log('Disconnected from project')}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('startBtn')&&el('startBtn').addEventListener('click',async()=>{let b=el('startBtn');b.disabled=true;try{let x=await runJob('/api/start',{name:el('workName').value.trim()},p=>note('notice',p+'...'));el('workName').value='';workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;el('branch').value=x.branch;note('notice','Safe work branch '+x.branch+' created and downloaded. Edit your files, then Smart Save.','ok');log('Started safe branch '+x.branch);await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('publishFolderBtn')&&el('publishFolderBtn').addEventListener('click',async()=>{const b=el('publishFolderBtn');if(!confirm('Create a new work branch and offer the files in this folder for publishing? Nothing goes online until you review the list and use Smart Save.'))return;b.disabled=true;try{let x=await runJob('/api/publish-folder',{folder:el('adoptPath').value.trim(),name:el('workName').value.trim()},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;note('notice','Work branch '+x.branch+' created. '+x.new+' file(s) are ready to review under Changes; nothing is published yet.','ok');log('Publishing folder on '+x.branch);await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('adoptBtn')&&el('adoptBtn').addEventListener('click',async()=>{let b=el('adoptBtn');b.disabled=true;try{let x=await runJob('/api/adopt',{folder:el('adoptPath').value.trim(),branch:el('branch').value.trim()},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;note('notice','Using '+x.folder+' ('+x.source+', branch '+x.branch+'): '+x.modified+' changed, '+x.new+' new, '+x.missing+' not in your folder.'+(x.behind?' The project has newer changes online; use Get latest.':'')+(x.onDefaultBranch?' This is the shared default branch: start a work branch before saving.':''),'ok');log('Using folder on '+x.branch+' at '+x.sha.slice(0,8));await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('downloadBtn')&&el('downloadBtn').addEventListener('click',async()=>{let b=el('downloadBtn');b.disabled=true;try{let x=await runJob('/api/download',{branch:el('branch').value.trim()},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;note('notice','Fresh workspace downloaded. Edit files there and use Smart Save.','ok');log('Downloaded '+x.branch+' at '+x.sha.slice(0,8));await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('refreshBtn')&&el('refreshBtn').addEventListener('click',refresh);el('selectBtn')&&el('selectBtn').addEventListener('click',()=>{document.querySelectorAll('#files input:not(:disabled)').forEach(x=>{x.checked=changes.find(c=>c.Path===x.value).Kind!=='Deleted'});changed()});el('localBtn')&&el('localBtn').addEventListener('click',()=>{el('message').value=suggest()});
el('aiBtn')&&el('aiBtn').addEventListener('click',async()=>{if(!confirm('Send selected filenames and change types to your approved AI gateway?'))return;try{let x=await runJob('/api/commit-message',{paths:selected()});el('message').value=x.title;note('saveNotice','AI provided a proposed title. You can accept or edit it.','ok')}catch(e){note('saveNotice',e.message,'error')}});
el('reviewBtn')&&el('reviewBtn').addEventListener('click',async()=>{if(!confirm('Create a GitHub pull request or GitLab merge request for your saved work?'))return;try{let x=await runJob('/api/review',{},p=>note('saveNotice',p+'...'));note('saveNotice','Review created: '+x.title,'ok');let a=document.createElement('a');a.href=x.url;a.rel='noopener noreferrer';a.target='_blank';withIcon(a,'Open review request ','external');el('saveNotice').append(document.createElement('br'),a);log('Created review request: '+x.url);lastSaved=false;controls()}catch(e){note('saveNotice',e.message,'error')}});
el('saveBtn')&&el('saveBtn').addEventListener('click',async()=>{let paths=selected();if(!paths.length)return;const b=el('saveBtn');b.disabled=true;try{
 const check=await api('/api/sentinel');let publicConfirmed=false;
 if(check.destination.Public){
  if(!check.publicPublishingEnabled)throw Error('This repository is PUBLIC. Publishing is disabled by your Gangplank policy.');
  publicConfirmed=confirm('PUBLIC GITHUB/GITLAB REPOSITORY: Anyone may see the selected files and committed history. Confirm you have authorization to release this information. Continue publishing '+paths.length+' change(s)?');
  if(!publicConfirmed)return;
 }else if(!confirm('Publish '+paths.length+' file change(s) to your online branch? This creates a remote commit.'))return;
 const acks={},reviews=(check.findings||[]).filter(f=>paths.includes(f.Path)&&f.Severity==='Review');for(const p of [...new Set(reviews.map(f=>f.Path))]){const what=reviews.filter(f=>f.Path===p).map(f=>f.Detail).join(' '),why=prompt('Sentinel review: '+p+'\n'+what+'\n\nTo publish this file anyway, type the reason (5 to 300 characters). It is recorded in the audit log. Cancel to stop.');if(why===null||why.trim().length<5)throw Error('Not published: '+p+' needs a reason.');acks[p]=why.trim().slice(0,300)}
 const r=await runJob('/api/save',{paths,message:el('message').value.trim(),publicConfirmed,acknowledgements:acks},p=>note('saveNotice',p+'...')),x=r.saved;
 note('saveNotice','Published '+x.FileCount+' file(s) as '+x.Commit.slice(0,10)+'. '+x.Message,'ok');log('Published '+x.FileCount+' files: '+x.Message);lastSaved=true;await refresh();
 }catch(e){note('saveNotice',e.message,'error')}finally{controls()}});
let consentPath='',consentToken='';
function addExplain(row,f){if(f.Blocked||f.Kind==='Deleted')return;const b=document.createElement('button');b.type='button';b.className='btn fl-btn fl-btn--secondary rowBtn';b.textContent='Explain';b.title='Ask the assistant to explain this file. You see exactly what would be sent first.';b.setAttribute('aria-label','Explain '+f.Path);b.addEventListener('click',ev=>{ev.preventDefault();explainPreview(f.Path)});row.append(b)}
async function explainPreview(p){note('aiAnswer','','');try{const x=await api('/api/ai/explain-preview?path='+encodeURIComponent(p));consentPath=p;consentToken=x.consent;el('aiConsentWhere').textContent='Destination: '+x.destination+(x.loopback?' (this PC)':' (another computer)')+', model '+x.model+'. '+x.characters+' characters'+(x.truncated?'; the file is cut to its first part':'')+'. Nothing is sent until you select Send.';el('aiConsentText').value='[system]\n'+x.system+'\n\n[you]\n'+x.user;el('aiConsent').hidden=false;el('aiConsentSend').focus()}catch(e){note('saveNotice',e.message,'error')}}
el('aiConsentCancel')&&el('aiConsentCancel').addEventListener('click',()=>{el('aiConsent').hidden=true;consentToken=''});
el('aiConsentSend')&&el('aiConsentSend').addEventListener('click',async()=>{const b=el('aiConsentSend');b.disabled=true;try{const r=await runJob('/api/ai/explain',{path:consentPath,consent:consentToken},x=>note('saveNotice',x+'...'));el('aiConsent').hidden=true;consentToken='';note('saveNotice','','');note('aiAnswer','Assistant: '+r.answer,'')}catch(e){note('saveNotice',e.message,'error')}finally{b.disabled=false}});
function chat(who,txt){let wrap=document.createElement('div'),head=document.createElement('span'),body=document.createElement('span');wrap.className='bubble '+(who==='You'?'user':'');head.className='who';head.textContent=who;body.textContent=txt;wrap.append(head,body);el('messages').append(wrap);el('messages').scrollTop=el('messages').scrollHeight;return body}
el('chatForm')&&el('chatForm').addEventListener('submit',async event=>{event.preventDefault();let input=el('chatText'),q=input.value.trim();if(!q)return;input.value='';chat('You',q);let output=chat('Gangplank Assist',''),btn=el('chatBtn');btn.disabled=true;el('chatBtnLabel').textContent='Thinking...';try{await runJob('/api/chat',{message:q},null,t=>{output.textContent+=t;el('messages').scrollTop=el('messages').scrollHeight});if(!output.textContent)output.textContent='(No answer returned.)'}catch(e){output.textContent='Assistant unavailable: '+e.message}finally{btn.disabled=false;el('chatBtnLabel').textContent='Ask assistant'}});

// All provider responses are untrusted. Render user-visible fields with textContent.
function clear(id){const x=el(id);x.replaceChildren();return x}
function itemRow(parent,title,detail,url){
 const row=document.createElement('div');row.className='repoRow';
 const heading=document.createElement('strong');heading.textContent=title;row.append(heading);
 const sub=document.createElement('small');sub.textContent=detail||'';row.append(sub);
 if(url){try{const u=new URL(url);if(u.protocol==='https:'){const a=document.createElement('a');a.href=u.href;a.target='_blank';a.rel='noopener noreferrer';a.className='file-link';withIcon(a,'View on provider ','external');row.append(a)}}catch{}}
 parent.append(row);return row;
}
async function loadBranches(){
 const box=el('branchesList');box.textContent='Reading branches…';
 try{const x=await api('/api/branches');const list=clear('branchesList');
 if(!x.branches.length){list.textContent='No branches found.';return}
 x.branches.forEach(b=>{const row=itemRow(list,b.Name,(b.IsDefault?'Default branch · ':'')+(b.IsCurrent?'Current selection':'Select to download a fresh copy'));const go=document.createElement('button');go.className='btn';withIcon(go,'Use this branch ','next');go.title='Select this branch in the Overview download field. This does not overwrite files.';go.addEventListener('click',()=>{el('branch').value=b.Name;tab('overview');note('notice','Branch '+b.Name+' selected. Choose Explore a branch to download it to a new folder.','ok')});row.append(go)});
 }catch(e){box.textContent='Branches unavailable: '+e.message}
}
async function loadBranchSelectors(){
 el('compareSummary').textContent='Choose branches and select Show differences.';
 try{const x=await api('/api/branches');const a=clear('compareBase'),b=clear('compareHead');
 for(const branch of x.branches){for(const select of [a,b]){const opt=document.createElement('option');opt.value=branch.Name;opt.textContent=branch.Name;select.append(opt)}}
 a.value=x.defaultBranch;b.value=x.branches.find(q=>q.IsCurrent)?.Name||x.defaultBranch;
 }catch(e){el('compareSummary').textContent='Branch choices unavailable: '+e.message}
}
async function loadCompare(){
 const target=el('compareSummary');target.textContent='Comparing versions…';clear('compareFiles');
 try{const p=new URLSearchParams({base:el('compareBase').value,head:el('compareHead').value});const x=await api('/api/compare?'+p.toString());
 target.textContent=x.Base+' → '+x.Head+(x.AheadBy!==null?' · '+x.AheadBy+' commits ahead':'')+(x.BehindBy!==null?' · '+x.BehindBy+' behind':'')+' · '+x.Files.length+' file(s) shown';
 const list=el('compareFiles');if(!x.Files.length)list.textContent='No changed files returned.';
 x.Files.forEach(f=>itemRow(list,f.Path,f.Status+(f.Additions!==null?' · +'+f.Additions+' / -'+f.Deletions:'')));
 if(x.Truncated)itemRow(list,'More files not shown','Showing up to 100 changed files. Open your repository provider for a full comparison.');
 }catch(e){target.textContent='Comparison unavailable: '+e.message}
}
async function loadHistory(){
 const list=el('commitList');list.textContent='Loading saved versions…';
 try{
  let branch=el('historyBranch').value;const x=await api('/api/branches'),picker=clear('historyBranch');
  x.branches.forEach(b=>{const o=document.createElement('option');o.value=b.Name;o.textContent=b.Name;picker.append(o)});
  if(!branch||!x.branches.some(b=>b.Name===branch))branch=x.branches.find(b=>b.IsCurrent)?.Name||x.defaultBranch;
  picker.value=branch;const info=await api('/api/history?'+new URLSearchParams({branch}).toString());clear('commitList');
  if(!info.commits.length)list.textContent='No commits found.';
  info.commits.forEach(c=>itemRow(list,c.Title||'(Untitled commit)',c.Author+' · '+(c.Date||'Date unavailable')+' · '+c.Sha.slice(0,10),c.Url));
 }catch(e){list.textContent='History unavailable: '+e.message}
}
async function loadReviews(){
 const box=el('reviewsList');box.textContent='Loading review requests…';
 try{const x=await api('/api/reviews');const list=clear('reviewsList');
 if(!x.reviews.length)list.textContent='No open review requests.';
 x.reviews.forEach(r=>itemRow(list,'#'+r.Number+' · '+r.Title,r.Source+' → '+r.Target+' · '+r.Author,r.Url));
 }catch(e){box.textContent='Reviews unavailable: '+e.message}
}
async function loadInsights(){
 const box=el('insightsSummary');if(box)box.textContent='Checking repository information…';
 try{
  const x=await api('/api/insights','GET',undefined,8000);
  if(box)box.textContent=(x.BranchCount||0)+' branches · '+(x.OpenReviewCount||0)+' open reviews · '+(x.Branch||'');
  const list=clear('insightsList');
  (x.Suggestions||[]).forEach(s=>itemRow(list,'Suggested next step',s));
 }catch(e){
  if(box)box.textContent='Insights skipped: '+(e.message||'unavailable');
  const list=el('insightsList');if(list)list.textContent='';
 }
}
el('branchesRefresh')&&el('branchesRefresh').addEventListener('click',loadBranches);
el('compareRefresh')&&el('compareRefresh').addEventListener('click',loadBranchSelectors);
el('compareRun')&&el('compareRun').addEventListener('click',loadCompare);
el('historyRefresh')&&el('historyRefresh').addEventListener('click',loadHistory);
el('historyBranch')&&el('historyBranch').addEventListener('change',loadHistory);
el('reviewsRefresh')&&el('reviewsRefresh').addEventListener('click',loadReviews);
el('insightsRefresh')&&el('insightsRefresh').addEventListener('click',loadInsights);
for(const [id,description] of Object.entries({
connectBtn:'Connect Gangplank to a GitHub repository or GitLab project using your configured credentials.',
startBtn:'Make your own branch (named above, or automatically) and download it to a separate folder. The shared default branch is not changed.',
downloadBtn:'Download a fresh copy of an existing branch to look at. Existing local files are not overwritten.',
refreshBtn:'Check your local folder for changes since the downloaded version.',
selectBtn:'Choose safe changed files for publication. You can uncheck any individual file.',
localBtn:'Suggest a brief name describing the changes you made. This does not publish anything.',
aiBtn:'Ask the approved AI provider for a suggested commit title using filenames only.',
saveBtn:'Publish selected changes to the online branch. Gangplank creates a remote commit and updates that branch.',
reviewBtn:'Open a pull request on GitHub or merge request on GitLab so teammates can review your changes.'
})){const button=el(id);if(button)button.title=description}

document.querySelectorAll('[data-jump]').forEach(b=>b.addEventListener('click',()=>tab(b.dataset.jump)));
el('sentinelRefresh')&&el('sentinelRefresh').addEventListener('click',async()=>{
 const box=el('sentinelFindings');box.textContent='Checking…';
 try{
  const r=await api('/api/sentinel');
  el('sentinelDestination').textContent=r.destination.Host+' · '+r.destination.Visibility+(r.destination.Verified?' · Verified':' · Unverified');
  box.replaceChildren();
  if(!r.findings.length)box.textContent='No findings in changed supported files. Not a full history scan.';
  r.findings.forEach(f=>{let p=document.createElement('p');p.textContent=f.Severity+' · '+(f.Path||'Destination')+' · '+f.Code+' — '+f.Detail;box.append(p)});
 }catch(e){box.textContent='Scan unavailable: '+e.message}
});
// Presence: this tab owns the local service. A heartbeat every 5 s says "still here";
// a sendBeacon "leaving" signal on pagehide lets it stop within seconds. A reload sends
// a new heartbeat inside the grace period, so nothing stops. The heartbeat runs in a
// worker because hidden tabs throttle main-thread timers; the page's own timer is the
// fallback. The beacon cannot set headers, so it carries the client secret in its body
// (the session cookie still goes with it); never in a query string.
let sessionEnded=false;
const TAB_ID=(()=>{try{const a=new Uint8Array(12);crypto.getRandomValues(a);return [...a].map(b=>b.toString(16).padStart(2,'0')).join('')}catch{return 't'+Date.now().toString(36)+Math.random().toString(36).slice(2)}})();
let hbWorker=null,hbTimer=0,hbFailures=0,hbInflight=false;
function heartbeatResult(ok,status){if(ok){hbFailures=0;if(!sessionEnded)engine('running');return}if(status!==401&&!sessionEnded)engine('disconnected');if(status===401){ended('This page belongs to an earlier Gangplank session. Use the link in the Gangplank window.');return}if(++hbFailures>=3)ended('Gangplank has stopped. You can close this tab. To keep working, start Gangplank again with Launch-Gangplank.bat.');}
function beatNow(){if(sessionEnded)return;if(hbWorker){hbWorker.postMessage({type:'beat'});return}if(hbInflight)return;hbInflight=true;fetch('/api/heartbeat',{method:'POST',headers:{'Content-Type':'application/json','X-Gangplank-Client':clientSecret()},body:JSON.stringify({tab:TAB_ID,leaving:false}),cache:'no-store',credentials:'same-origin'}).then(r=>{hbInflight=false;heartbeatResult(r.ok,r.status)},()=>{hbInflight=false;heartbeatResult(false,0)});}
function fallbackTimer(){if(hbTimer||sessionEnded)return;beatNow();hbTimer=setInterval(beatNow,5000);}
function startHeartbeat(){
 if(sessionEnded)return;
 try{hbWorker=new Worker('/heartbeat-worker.js');hbWorker.onmessage=e=>heartbeatResult(!!e.data.ok,e.data.status);hbWorker.onerror=()=>{try{hbWorker.terminate()}catch{}hbWorker=null;fallbackTimer()};hbWorker.postMessage({type:'start',token:clientSecret(),tab:TAB_ID,interval:5000});}
 catch{hbWorker=null;fallbackTimer()}
}
function stopHeartbeat(){if(hbWorker){try{hbWorker.postMessage({type:'stop'});hbWorker.terminate()}catch{}hbWorker=null}if(hbTimer){clearInterval(hbTimer);hbTimer=0}}
window.addEventListener('pagehide',()=>{if(sessionEnded||!clientSecret())return;const body=JSON.stringify({tab:TAB_ID,leaving:true,client:clientSecret()});let sent=false;try{sent=navigator.sendBeacon('/api/heartbeat',new Blob([body],{type:'application/json'}))}catch{sent=false}if(!sent){try{fetch('/api/heartbeat',{method:'POST',headers:{'Content-Type':'application/json','X-Gangplank-Client':clientSecret()},body:JSON.stringify({tab:TAB_ID,leaving:true}),keepalive:true,credentials:'same-origin'}).catch(()=>{})}catch{}}});
window.addEventListener('pageshow',e=>{if(e.persisted)beatNow()});
document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible')beatNow()});
el('endSession')&&el('endSession').addEventListener('click',async()=>{
 if(!confirm('End this Gangplank session? The local service stops (after any save or download in progress). Unsaved selections in this page are lost; published work is not affected.'))return;
 const b=el('endSession');b.disabled=true;
 try{const r=await fetch('/api/session/stop',{method:'POST',headers:{'Content-Type':'application/json','X-Gangplank-Client':clientSecret(),'X-Gangplank-Intent':'end-session'},body:'{}',cache:'no-store',credentials:'same-origin'});let x={};try{x=await r.json()}catch{}if(!r.ok)throw Error(plain(x.message||x.error||'Request failed'));ended(x.waitingForJobs?'Gangplank stops as soon as the running task finishes. You can close this tab.':'Gangplank has stopped. You can close this tab. To keep working, start Gangplank again with Launch-Gangplank.bat.',x.waitingForJobs?'stopping':'stopped')}
 catch(e){b.disabled=false;alert('Could not end the session: '+e.message)}
});
function goOverview(ev){if(ev){ev.preventDefault();ev.stopPropagation()}tab('overview')}
if(el('brandHome')){el('brandHome').addEventListener('click',goOverview);el('brandHome').addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();goOverview(e)}})}

if(el('pullLocalCopy'))el('pullLocalCopy').addEventListener('click',async()=>{
  const path=(el('pullLocalPath')&&el('pullLocalPath').textContent||'').trim();
  if(!path||path==='…'){note('notice','Workspace path is not ready yet.','warn');return}
  try{await navigator.clipboard.writeText(path);note('notice','Copied workspace path.','ok')}catch(e){note('notice','Could not copy path.','warn')}
});

(async()=>{if(await bootstrap()){startHeartbeat();init()}})();

// ---- Settings: workspace folder and the Fairlead connection --------------------------------
async function loadSettings(){
 try{const x=await api('/api/settings');const w=x.workspaces||{};if(el('wsRoot'))el('wsRoot').textContent=w.root||'';if(el('pullLocalPath'))el('pullLocalPath').textContent=w.root||'(default workspace root)';if(el('wsRootInput'))el('wsRootInput').disabled=!!w.fixed;if(el('wsSave'))el('wsSave').disabled=!!w.fixed;if(el('wsDefault'))el('wsDefault').disabled=!!w.fixed;if(w.fixed&&el('wsNotice'))note('wsNotice','This folder is set when Gangplank starts (-WorkRoot or GANGPLANK_WORK_ROOT).','');
  const a=x.intelligence||{};el('aiCurrent').textContent='Fairlead route: '+(a.model||'?')+' at '+(a.endpoint||'?')+'. Key for Gangplank ('+(a.credentialName||'Fairlead/Gangplank')+'): '+(a.keyReady?'installed':'not installed - open Fairlead, Clients, install a key for Gangplank')+'.'+(a.problem?' Problem: '+a.problem:'');
 }catch(e){el('aiCurrent').textContent='Settings unavailable: '+e.message}
}
el('wsSave')&&el('wsSave').addEventListener('click',async()=>{try{const x=await api('/api/settings/workspace','POST',{root:el('wsRootInput').value.trim()});el('wsRootInput').value='';note('wsNotice','New workspaces will go to '+x.workspaces.root+'.','ok');await loadSettings()}catch(e){note('wsNotice',e.message,'error')}});
el('wsDefault')&&el('wsDefault').addEventListener('click',async()=>{try{const x=await api('/api/settings/workspace','POST',{root:''});note('wsNotice','Using the default folder (%LOCALAPPDATA%\\git when available): '+x.workspaces.root+'.','ok');await loadSettings()}catch(e){note('wsNotice',e.message,'error')}});
el('aiTest')&&el('aiTest').addEventListener('click',async()=>{const b=el('aiTest');b.disabled=true;note('aiNotice','Testing...','');try{const r=await runJob('/api/ai/test',{});note('aiNotice','Working: '+r.model+' answered in '+r.milliseconds+' ms.','ok')}catch(e){note('aiNotice','Test failed: '+e.message,'error')}finally{b.disabled=false}});
// Spoken status (opt-in). Results and errors are read aloud with the voices installed on this PC through
// the browser; nothing is sent anywhere, and progress messages are never spoken. With no voices the toggle is off and the text stays on screen.
function speakable(k,t,on){return !!(on&&t&&(k==='ok'||k==='error'||k==='warn'))}
function speechOn(){try{return localStorage.getItem('gp.speak')==='1'}catch{return false}}
function speechReady(){return !!(window.speechSynthesis&&window.SpeechSynthesisUtterance)}
function speak(t){if(!speechReady())return;try{window.speechSynthesis.cancel();const u=new SpeechSynthesisUtterance(String(t).slice(0,240));u.lang=document.documentElement.lang||'en';window.speechSynthesis.speak(u)}catch{}}
function initSpeech(){const t=el('speakToggle'),h=el('speakHint'),ok=speechReady();t.disabled=!ok;t.checked=ok&&speechOn();h.textContent=ok?'Uses the voices installed on this PC. Nothing is sent anywhere.':'This browser has no local voices, so messages stay on screen only.';t.addEventListener('change',()=>{try{localStorage.setItem('gp.speak',t.checked?'1':'0')}catch{}if(t.checked)speak('Spoken status is on.')})}
initSpeech();


/* ---- Tokens, writable projects, branch pick, sync (v5) ---- */
let renewProvider=null;
let selectedWritable=null;
let catalogProjects=[];
let selectedPaths=new Set();

let pendingSelection=null; // {provider,path,branch,url} chosen in the form, not yet connected

function setNextStep(msg){const n=el('nextStep');if(n)n.innerHTML=msg}
function paintSelection(){
  const eyebrow=el('projectEyebrow'),title=el('projectTitle'),hint=el('projectHint'),dl=el('downloadHint');
  if(connected){
    if(eyebrow)eyebrow.textContent='CONNECTED PROJECT';
    if(dl)dl.innerHTML='This project is connected. <strong>Start my safe workspace</strong> creates a new work branch and downloads it. <strong>Explore this branch</strong> downloads the branch in the field below (no new branch). Both use a new folder and never overwrite existing files.';
    return;
  }
  if(pendingSelection&&pendingSelection.path){
    if(eyebrow)eyebrow.textContent='SELECTED (NOT CONNECTED YET)';
    if(title)title.textContent=pendingSelection.path+(pendingSelection.branch?(' · '+pendingSelection.branch):'');
    if(hint)hint.textContent='Form only — the session is not open until you press Connect project'+(pendingSelection.provider?(' ('+pendingSelection.provider+')'):'')+'.';
    setNextStep('<strong>Next:</strong> Press <strong>Connect project</strong> to open this repository. After it connects, use section 2 to download.');
    const hp=el('headerProject'),ht=el('headerProjectText');
    if(hp&&ht){hp.hidden=false;ht.textContent='Selected: '+pendingSelection.path+(pendingSelection.branch?(' · '+pendingSelection.branch):'')+' (not connected)';}
    if(dl)dl.innerHTML='Download buttons stay off until Connect succeeds. After Connect: <strong>Start my safe workspace</strong> (new work branch) or <strong>Explore this branch</strong> (download the branch you chose).';
    return;
  }
  if(eyebrow)eyebrow.textContent='CURRENT PROJECT';
  if(title)title.textContent='Ready when you are';
  if(hint)hint.textContent='Add a token, then select a writable project or paste a URL. Nothing is connected until you press Connect.';
  setNextStep('<strong>Next:</strong> Refresh writable projects (or paste a URL), choose a branch, then Connect.');
  if(dl)dl.innerHTML='Connect a project first (section 1). Then either <strong>Start my safe workspace</strong> (new work branch + download) or <strong>Explore this branch</strong> (download the branch you chose, no new branch).';
}




let knownSites=[]; // from /api/integrations
let activeSite={id:'GitHub',kind:'GitHub',host:'github.com',label:'GitHub'};
const branchCache={}; // path -> {branches, defaultBranch, loaded}

async function loadTokenCards(){
  const box=el('tokenCards');
  if(!box)return;
  try{
    const info=await api('/api/integrations');
    knownSites=info.sites||info.credentials||[];
    // Ensure GitHub always present
    if(!knownSites.some(s=>(s.site||s.provider)==='GitHub')){
      knownSites=[{site:'GitHub',provider:'GitHub',kind:'GitHub',label:'GitHub',host:'github.com',configured:false,source:'none'},...knownSites];
    }
    box.replaceChildren();
    for(const s of knownSites){
      const id=s.site||s.provider;
      const label=s.label||id;
      const row=document.createElement('div');row.className='tokenRow';row.dataset.site=id;
      const prov=document.createElement('span');prov.className='tokenProv';prov.textContent=label;
      const st=document.createElement('span');st.className='tokenState';
      const meta=document.createElement('span');meta.className='tokenMeta';
      if(!s.configured){st.textContent='Not set';meta.textContent=s.host||'—'}
      else{
        st.textContent=s.login?('Ready · '+s.login):('Ready · '+s.source);
        const tc=Number(s.tokenCount||0);const bits=[];if(s.login)bits.push(s.login);if(tc>1)bits.push(tc+' tokens');else if(s.source)bits.push(s.source);if(s.expiresLabel&&s.expiresLabel!=='unknown')bits.push('exp '+s.expiresLabel);meta.textContent=bits.join(' · ')||'—';
      }
      const acts=document.createElement('span');acts.className='tokenActs';
      const add=document.createElement('button');add.type='button';add.className='btn fl-btn fl-btn--secondary';
      add.textContent=s.configured?'Replace':'Add';
      add.addEventListener('click',()=>openTokenAdd(id));
      const rm=document.createElement('button');rm.type='button';rm.className='btn fl-btn fl-btn--secondary';
      rm.textContent='Remove';rm.disabled=s.source!=='stored';
      rm.addEventListener('click',()=>removeToken(id));
      acts.append(add,rm);
      row.append(prov,st,meta,acts);
      box.append(row);
    }
    paintProviderButtons();
  }catch(e){
    box.textContent='Token status unavailable: '+e.message;
  }
}

function paintProviderButtons(){
  const box=el('providerBtns');
  if(!box)return;
  box.replaceChildren();
  const sites=knownSites.length?knownSites:[{site:'GitHub',kind:'GitHub',label:'GitHub',host:'github.com'}];
  for(const s of sites){
    const id=s.site||s.provider;
    const btn=document.createElement('button');
    btn.type='button';btn.className='btn fl-btn fl-btn--secondary providerBtn';
    btn.dataset.site=id;btn.dataset.kind=s.kind||(id==='GitHub'?'GitHub':'GitLab');
    btn.dataset.host=s.host||(id==='GitHub'?'github.com':id);
    btn.textContent=s.label||id;
    btn.title='List writable projects on '+(s.label||id);
    if(activeSite&&activeSite.id===id)btn.classList.add('active');
    btn.addEventListener('click',()=>{
      activeSite={id, kind:btn.dataset.kind, host:btn.dataset.host, label:btn.textContent};
      if(el('projectProvider'))el('projectProvider').value=activeSite.kind;
      if(el('projectHost'))el('projectHost').value=activeSite.kind==='GitHub'?'':(activeSite.host||id);
      paintProviderButtons();
      loadWritableProjects();
    });
    box.append(btn);
  }
}

let tokenAddProvider=null;
function openTokenAdd(siteId){
  tokenAddProvider=siteId||'GitHub';
  const box=el('tokenAddBox');if(!box)return;
  box.hidden=false;
  if(el('tokenAddSite'))el('tokenAddSite').value=tokenAddProvider==='GitHub'?'':tokenAddProvider;
  if(el('tokenAddValue')){el('tokenAddValue').value='';el('tokenAddValue').focus()}
}
if(el('tokenAddSiteBtn'))el('tokenAddSiteBtn').addEventListener('click',()=>openTokenAdd(''));
if(el('tokenAddCancel'))el('tokenAddCancel').addEventListener('click',()=>{el('tokenAddBox').hidden=true;tokenAddProvider=null;if(el('tokenAddValue'))el('tokenAddValue').value=''});
if(el('tokenAddSave'))el('tokenAddSave').addEventListener('click',async()=>{
  const v=el('tokenAddValue').value.trim();if(!v)return;
  let site=(el('tokenAddSite')?el('tokenAddSite').value.trim():'')||tokenAddProvider||'GitHub';
  if(!site||/^github(\.com)?$/i.test(site))site='GitHub';
  const b=el('tokenAddSave');b.disabled=true;
  try{
    await api('/api/credentials','POST',{provider:site,site,token:v});
    el('tokenAddValue').value='';el('tokenAddBox').hidden=true;tokenAddProvider=null;
    note('notice','Token saved for '+site+'. Additional tokens for the same site are kept and tried together.','ok');
    await loadTokenCards();await loadIntegrations();
  }catch(e){note('notice',e.message,'error')}
  finally{b.disabled=false}
});
async function removeToken(siteId){
  if(!confirm('Remove the saved token for '+siteId+' from this PC?'))return;
  try{
    await api('/api/credentials/remove','POST',{provider:siteId,site:siteId});
    note('notice','Token removed for '+siteId+'.','ok');
    await loadTokenCards();await loadIntegrations();
  }catch(e){note('notice',e.message,'error')}
}

function orgOf(path){
  const parts=String(path||'').split('/').filter(Boolean);
  return parts[0]||'(unknown)';
}

function parseRepoUrl(u){
  u=String(u||'').trim();
  if(!u)return null;
  try{
    const noHash=u.split('#')[0].split('?')[0].replace(/\.git$/i,'').replace(/\/$/,'');
    let host='';
    try{host=new URL(noHash).host}catch{host=''}
    let provider='GitLab';
    if(/github\.com$/i.test(host)||host==='github.com')provider='GitHub';
    const m=noHash.match(/^https?:\/\/[^/]+\/(.+)$/i);
    if(!m)return {provider, host, kind:'unknown', raw:u};
    let rest=m[1].replace(/\/$/,'');
    rest=rest.split('/-/')[0];
    for(const cut of ['/tree/','/blob/','/pull/','/merge_requests/','/issues/','/commit/']){
      const i=rest.indexOf(cut);if(i>0)rest=rest.slice(0,i);
    }
    const parts=rest.split('/').filter(Boolean);
    if(!parts.length)return {provider, host, kind:'unknown', raw:u};
    if(parts.length===1)return {provider, host, kind:'org', org:parts[0], path:parts[0], raw:u};
    return {provider, host, kind:'project', org:parts[0], path:parts.join('/'), raw:u};
  }catch{return null}
}

function updateSelectionSummary(){
  const s=el('selectionSummary');
  if(!s)return;
  const n=selectedPaths.size;
  if(!n){s.textContent='No projects selected.';return}
  s.textContent=n+' project'+(n===1?'':'s')+' selected.';
}

function setProviderUI(provider, host, {load}={load:false}){
  const kind=provider==='GitHub'?'GitHub':'GitLab';
  const id=kind==='GitHub'?'GitHub':(host||provider);
  activeSite={id, kind, host:kind==='GitHub'?'github.com':(host||id), label:id};
  if(el('projectProvider'))el('projectProvider').value=kind;
  if(el('projectHost'))el('projectHost').value=kind==='GitHub'?'':activeSite.host;
  paintProviderButtons();
  if(load)return loadWritableProjects();
}

function applyUrlHighlight(){
  const parsed=parseRepoUrl(el('repoUrl')?el('repoUrl').value:'');
  const hint=el('urlParseHint');
  document.querySelectorAll('.orgGroup').forEach(g=>g.classList.remove('highlightOrg'));
  document.querySelectorAll('.orgBody .file').forEach(f=>f.classList.remove('highlightProject'));
  if(!parsed){if(hint)hint.textContent='';return parsed}
  if(parsed.provider)setProviderUI(parsed.provider, parsed.host, {load:false});
  if(hint){
    if(parsed.kind==='org')hint.textContent='URL → '+(parsed.host||parsed.provider)+' organization “'+parsed.org+'”.';
    else if(parsed.kind==='project')hint.textContent='URL → '+(parsed.host||parsed.provider)+' project “'+parsed.path+'”.';
    else hint.textContent='URL noted for '+(parsed.host||parsed.provider)+'.';
  }
  if(parsed.org){
    const g=document.querySelector('.orgGroup[data-org="'+CSS.escape(parsed.org)+'"]');
    if(g){if(parsed.kind==='org')g.classList.add('highlightOrg');g.scrollIntoView({block:'nearest'})}
  }
  if(parsed.kind==='project'&&parsed.path){
    const row=document.querySelector('.orgBody .file[data-path="'+CSS.escape(parsed.path)+'"]');
    if(row){row.classList.add('highlightProject');row.scrollIntoView({block:'nearest'})}
  }
  return parsed;
}

let urlPollTimer=null;
let lastUrlSiteKey='';
function scheduleUrlPoll(){
  // Debounced highlight only. Full catalog fetch is expensive — only when the site
  // changes and the list is empty (user still uses site buttons to load projects).
  if(urlPollTimer)clearTimeout(urlPollTimer);
  urlPollTimer=setTimeout(async()=>{
    const parsed=applyUrlHighlight();
    if(!parsed||!parsed.provider)return;
    const siteKey=parsed.provider==='GitHub'?'GitHub':(parsed.host||parsed.provider);
    setProviderUI(parsed.provider, parsed.host, {load:false});
    const needList=(!catalogProjects.length)||(siteKey!==lastUrlSiteKey&&!catalogProjects.length);
    if(needList){
      lastUrlSiteKey=siteKey;
      try{await loadWritableProjects()}catch{}
    }else{
      lastUrlSiteKey=siteKey;
    }
    applyUrlHighlight();
    if(parsed.kind==='project'&&parsed.path){
      const hit=catalogProjects.find(p=>p.path===parsed.path||String(p.path).toLowerCase()===parsed.path.toLowerCase());
      if(hit){
        selectedPaths=new Set([hit.path]);
        pendingSelection={provider:hit.provider,path:hit.path,branch:hit.defaultBranch||'main',url:hit.url||parsed.raw,host:hit.site||parsed.host};
        // Update checks in place — avoid full re-render (and branch storms).
        document.querySelectorAll('.orgBody .file input[type=checkbox]').forEach(cb=>{
          const row=cb.closest('.file');const path=row&&row.dataset.path;
          cb.checked=path&&selectedPaths.has(path);
        });
        updateSelectionSummary();
      }
    }else if(parsed.kind==='org'&&parsed.org){
      const inOrg=catalogProjects.filter(p=>orgOf(p.path).toLowerCase()===parsed.org.toLowerCase());
      selectedPaths=new Set(inOrg.map(p=>p.path));
      document.querySelectorAll('.orgBody .file input[type=checkbox]').forEach(cb=>{
        const row=cb.closest('.file');const path=row&&row.dataset.path;
        cb.checked=path&&selectedPaths.has(path);
      });
      updateSelectionSummary();
    }
  },450);
}

function branchName(b){
  if(b==null)return '';
  if(typeof b==='string')return b;
  if(typeof b==='object'){
    if(typeof b.Name==='string')return b.Name;
    if(typeof b.name==='string')return b.name;
  }
  const s=String(b);
  return s==='[object Object]'?'':s;
}
function asBranchList(list){
  if(list==null||list==='')return [];
  if(typeof list==='string')return [list];
  if(Array.isArray(list))return list.map(branchName).filter(Boolean);
  // PowerShell single-element or dictionary-shaped payloads
  if(typeof list==='object'){
    if(typeof list.Name==='string'||typeof list.name==='string')return [branchName(list)];
    try{return Object.values(list).map(branchName).filter(Boolean)}catch{return []}
  }
  return [branchName(list)].filter(Boolean);
}
function seedBranchSelect(sel, defaultBranch){
  const def=branchName(defaultBranch)||'main';
  const names=[];
  for(const n of ['main','master',def]){const s=branchName(n);if(s&&!names.includes(s))names.push(s)}
  sel.innerHTML='';
  names.forEach(b=>{
    const o=document.createElement('option');o.value=b;o.textContent=b;
    if(b===def)o.selected=true;
    sel.append(o);
  });
  if(!sel.value)sel.selectedIndex=0;
}
function projectBranchSelect(path){
  if(!path)return null;
  const row=document.querySelector('.orgBody .file[data-path="'+CSS.escape(path)+'"], .orgBody .projRow[data-path="'+CSS.escape(path)+'"]');
  if(!row)return null;
  return row.querySelector('select.projBranch');
}
function applyBranchOptions(sel, project, branches, defaultBranch){
  if(!sel)return;
  const def=branchName(defaultBranch)||branchName(project&&project.defaultBranch)||'main';
  let list=asBranchList(branches);
  const preferred=['main','master'];
  const head=[];
  for(const name of preferred){
    const i=list.findIndex(b=>String(b).toLowerCase()===name);
    if(i>=0){head.push(list[i]);list.splice(i,1)}
  }
  if(def&&!head.includes(def)){
    const i=list.indexOf(def);if(i>=0){head.push(list[i]);list.splice(i,1)}
    else head.unshift(def);
  }
  list.sort((a,b)=>String(a).localeCompare(String(b)));
  const cur=branchName(sel.value);
  const frag=document.createDocumentFragment();
  [...head,...list].forEach(b=>{
    const o=document.createElement('option');o.value=b;o.textContent=b;
    if(b===(cur||def))o.selected=true;
    frag.append(o);
  });
  sel.innerHTML='';
  sel.append(frag);
  if(!sel.value)sel.selectedIndex=0;
  sel.classList.remove('isLoading');
  sel.dataset.loaded=list.length?'1':'0';
}

const branchInflight={};
async function fillBranchSelect(sel, project){
  if(!project||!project.path)return;
  const key=project.path;
  const live=()=>projectBranchSelect(key)||sel;
  if(branchCache[key]&&branchCache[key].loaded){
    applyBranchOptions(live(), project, branchCache[key].branches, branchCache[key].defaultBranch);
    return;
  }
  const target=live();
  if(target){seedBranchSelect(target, project.defaultBranch);target.classList.add('isLoading')}
  if(branchInflight[key]){
    try{await branchInflight[key]}catch{}
    if(branchCache[key]&&branchCache[key].loaded){
      applyBranchOptions(live(), project, branchCache[key].branches, branchCache[key].defaultBranch);
    }else{
      const s=live();if(s)s.classList.remove('isLoading');
    }
    return;
  }
  branchInflight[key]=(async()=>{
    const kind=project.provider||(activeSite&&activeSite.kind)||'GitLab';
    let host=project.site||'';
    if(!host&&kind!=='GitHub'){
      host=(activeSite&&activeSite.host)||(el('projectHost')&&el('projectHost').value)||'';
      if(host==='GitLab'||host==='GitHub')host='';
    }
    const q=new URLSearchParams({provider:kind,project:project.path});
    if(host)q.set('host',host);
    const x=await api('/api/project-branches?'+q.toString(),'GET',undefined,12000);
    const branches=asBranchList(x.branches!=null?x.branches:x.Branches);
    const def=branchName(x.defaultBranch||x.DefaultBranch)||branchName(project.defaultBranch)||'main';
    branchCache[key]={branches, defaultBranch:def, loaded:true};
    project.defaultBranch=def;
  })();
  try{
    await branchInflight[key];
    if(branchCache[key]&&branchCache[key].loaded){
      applyBranchOptions(live(), project, branchCache[key].branches, branchCache[key].defaultBranch);
    }
  }catch(e){
    const s=live();if(s)s.classList.remove('isLoading');
  }finally{
    delete branchInflight[key];
  }
}

async function loadAllProjectBranches(projects){
  // One batch job on the server (sequential HTTP cannot finish dozens of parallel branch GETs).
  const list=Array.isArray(projects)?projects.filter(p=>p&&p.path):[];
  if(!list.length)return;
  const sum=el('catalogSummary');
  const base=sum?sum.textContent:'';
  for(const proj of list){
    const sel=projectBranchSelect(proj.path);
    if(sel){sel.classList.add('isLoading');seedBranchSelect(sel, proj.defaultBranch)}
  }
  if(sum)sum.textContent=(base?base+' · ':'')+'Loading branches…';
  const kind=(activeSite&&activeSite.kind)||(list[0]&&list[0].provider)||'GitLab';
  let host='';
  if(kind!=='GitHub'){
    host=(activeSite&&activeSite.host)||(list[0]&&list[0].site)||(el('projectHost')&&el('projectHost').value)||'';
    if(host==='GitLab'||host==='GitHub')host='';
  }
  try{
    let started=await api('/api/project-branches-batch','POST',{
      provider:kind,
      host:host||'',
      projects:list.map(p=>p.path)
    });
    let result;
    if(started.job){
      activeJob=started.job;jobCancel(true,'Loading branches…');
      try{
        let after=0;
        for(;;){
          await sleep(400);
          const j=await api('/api/jobs/'+started.job+'?after='+after);
          after=j.next;
          if(el('jobCancelLabel'))el('jobCancelLabel').textContent=(j.progress||'Loading branches')+'…';
          if(sum&&j.progress)sum.textContent=(base?base+' · ':'')+j.progress;
          if(j.state==='succeeded'){result=j.result||{};break}
          if(j.state==='cancelled')throw Error('Stopped before branches finished.');
          if(j.state!=='running'&&j.state!=='cancelling'){const raw=j.error||'Branch listing failed.';throw Error(plain(raw))}
        }
      }finally{activeJob=null;jobCancel(false)}
    }else{result=started}

    const rows=Array.isArray(result.results)?result.results:[];
    let filled=0;
    for(const row of rows){
      const path=row.path||row.Path;
      if(!path)continue;
      const branches=asBranchList(row.branches!=null?row.branches:row.Branches);
      const def=branchName(row.defaultBranch||row.DefaultBranch)||'main';
      branchCache[path]={branches, defaultBranch:def, loaded:true};
      const proj=list.find(p=>p.path===path)||{path, defaultBranch:def};
      const sel=projectBranchSelect(path);
      if(sel){
        applyBranchOptions(sel, proj, branches, def);
        if(branches.length)filled++;
      }
    }
    // Any row still loading (missing from results) — clear spinner, keep seed.
    for(const proj of list){
      const sel=projectBranchSelect(proj.path);
      if(sel)sel.classList.remove('isLoading');
      if(!(branchCache[proj.path]&&branchCache[proj.path].loaded)){
        // leave seed options
      }
    }
    if(sum)sum.textContent=base+(filled?(' · '+filled+' with branches'):'');
  }catch(e){
    for(const proj of list){
      const sel=projectBranchSelect(proj.path);
      if(sel)sel.classList.remove('isLoading');
    }
    if(sum)sum.textContent=(base?base+' · ':'')+'Branches unavailable: '+(e.message||'error');
  }
}


function renderProjectCatalog(projects){
  const box=el('projectsList');
  if(!box)return;
  box.replaceChildren();
  catalogProjects=Array.isArray(projects)?projects:[];
  selectedPaths=new Set([...selectedPaths].filter(p=>catalogProjects.some(x=>x.path===p)));
  if(!catalogProjects.length){
    const empty=document.createElement('div');empty.className='emptyHint';
    empty.textContent='No writable projects found for this site token. Paste a URL above if you can access a specific repo.';
    box.append(empty);
    const sum0=el('catalogSummary');if(sum0)sum0.textContent='0 writable projects.';
    updateSelectionSummary();applyUrlHighlight();
    return;
  }
  const groups={};
  for(const p of catalogProjects){
    if(!p||!p.path)continue;
    const o=orgOf(p.path);
    if(!groups[o])groups[o]=[];
    groups[o].push(p);
  }
  const orgs=Object.keys(groups).sort((a,b)=>a.localeCompare(b));
  const sum=el('catalogSummary');
  if(sum)sum.textContent=catalogProjects.length+' writable project'+(catalogProjects.length===1?'':'s')+' in '+orgs.length+' organization'+(orgs.length===1?'':'s')+'.';

  for(const org of orgs){
    const items=groups[org];
    const group=document.createElement('div');
    group.className='orgGroup';
    group.dataset.org=org;

    const head=document.createElement('div');
    head.className='orgHead';
    const lab=document.createElement('label');
    lab.className='orgHeadLab';
    const orgCb=document.createElement('input');
    orgCb.type='checkbox';
    orgCb.dataset.org=org;
    const allOn=items.every(p=>selectedPaths.has(p.path));
    const someOn=items.some(p=>selectedPaths.has(p.path));
    orgCb.checked=allOn;
    orgCb.indeterminate=!allOn&&someOn;
    const name=document.createElement('span');
    name.textContent=org;
    const cnt=document.createElement('span');
    cnt.className='orgCount';
    cnt.textContent=items.length+' project'+(items.length===1?'':'s');
    lab.append(orgCb,name,cnt);
    head.append(lab);

    const body=document.createElement('div');
    body.className='orgBody';

    orgCb.addEventListener('change',()=>{
      for(const p of items){
        if(orgCb.checked)selectedPaths.add(p.path);
        else selectedPaths.delete(p.path);
      }
      body.querySelectorAll('input.projCheck').forEach(cb=>{cb.checked=orgCb.checked});
      orgCb.indeterminate=false;
      updateSelectionSummary();
    });

    for(const p of items){
      const row=document.createElement('div');
      row.className='file projRow';
      row.dataset.path=p.path;

      // Layout: [checkbox] [path + icons] [branch select] — select is its own cell, always present.
      const cb=document.createElement('input');
      cb.type='checkbox';
      cb.className='projCheck';
      cb.checked=selectedPaths.has(p.path);
      cb.title='Select this project';
      cb.setAttribute('aria-label','Select '+p.path);

      const mid=document.createElement('div');
      mid.className='projMid';
      const path=document.createElement('span');
      path.className='path';
      path.textContent=p.path;
      path.title=p.path;
      mid.append(path);

      const vis=String(p.visibility||(p.private?'private':'public')).toLowerCase();
      if(vis==='private'||vis==='internal'){
        const tag=document.createElement('span');
        tag.className='visIcon';
        tag.title=vis==='private'?'Private':'Internal';
        if(typeof window.gangplankIcon==='function'){
          tag.append(window.gangplankIcon(vis==='private'?'lock':'shield',14));
        }else{
          tag.textContent=vis==='private'?'🔒':'🛡';
        }
        mid.append(tag);
      }
      const descText=(p.description&&String(p.description).trim())?String(p.description).trim():'';
      if(descText){
        const desc=document.createElement('span');
        desc.className='fileDesc';
        desc.textContent=descText;
        desc.title=descText;
        mid.append(desc);
      }

      const branchSel=document.createElement('select');
      branchSel.className='field fl-input projBranch';
      branchSel.title='Branch for '+p.path;
      branchSel.setAttribute('aria-label','Branch for '+p.path);
      branchSel.dataset.path=p.path;
      seedBranchSelect(branchSel, p.defaultBranch||'main');
      if(branchCache[p.path]&&branchCache[p.path].loaded){
        applyBranchOptions(branchSel, p, branchCache[p.path].branches, branchCache[p.path].defaultBranch);
      }
      branchSel.addEventListener('click',e=>e.stopPropagation());
      branchSel.addEventListener('mousedown',e=>e.stopPropagation());
      branchSel.addEventListener('change',()=>{
        if(selectedPaths.has(p.path)){
          pendingSelection={provider:p.provider,path:p.path,branch:branchSel.value,url:p.url||'',host:p.site||''};
          if(el('branch'))el('branch').value=branchSel.value;
          paintSelection();controls();
        }
      });

      cb.addEventListener('change',()=>{
        if(cb.checked)selectedPaths.add(p.path);else selectedPaths.delete(p.path);
        updateSelectionSummary();
        const sibs=items.map(x=>selectedPaths.has(x.path));
        orgCb.checked=sibs.every(Boolean);
        orgCb.indeterminate=!orgCb.checked&&sibs.some(Boolean);
        if(cb.checked){
          if(el('repoUrl'))el('repoUrl').value=p.url||el('repoUrl').value;
          pendingSelection={provider:p.provider,path:p.path,branch:branchSel.value||p.defaultBranch||'main',url:p.url||'',host:p.site||''};
          if(el('branch'))el('branch').value=pendingSelection.branch;
          paintSelection();controls();
        }
        applyUrlHighlight();
      });

      row.append(cb, mid, branchSel);
      body.append(row);
    }

    group.append(head, body);
    box.append(group);
  }

  // Sanity: every catalog project must have a select in the DOM.
  let missing=0;
  for(const p of catalogProjects){
    if(!projectBranchSelect(p.path))missing++;
  }
  if(missing&&sum)sum.textContent=(sum.textContent||'')+' · warning: '+missing+' rows missing branch control';

  updateSelectionSummary();
  applyUrlHighlight();
  loadAllProjectBranches(catalogProjects);
}

async function loadWritableProjects(){
  const kind=(activeSite&&activeSite.kind)||(el('projectProvider')?el('projectProvider').value:'GitHub');
  const host=(activeSite&&activeSite.kind!=='GitHub')?(activeSite.host||el('projectHost').value||activeSite.id):'';
  const label=host||kind;
  const box=el('projectsList');
  box.replaceChildren();
  const loading=document.createElement('div');loading.className='emptyHint';loading.textContent='Loading writable projects from '+label+'…';
  box.append(loading);const sumL=el('catalogSummary');if(sumL)sumL.textContent='Loading…';
  selectedWritable=null;
  try{
    const q=new URLSearchParams({provider:kind});
    if(host)q.set('host',host);
    let started=await api('/api/projects?'+q.toString());
    let result;
    if(started.job){
      activeJob=started.job;jobCancel(true,'Listing projects…');
      try{
        let after=0;
        for(;;){
          await sleep(400);
          const j=await api('/api/jobs/'+started.job+'?after='+after);
          after=j.next;el('jobCancelLabel').textContent=(j.progress||'Working')+'…';
          if(j.state==='succeeded'){result=j.result||{};break}
          if(j.state==='cancelled')throw Error('Stopped before it finished.');
          if(j.state!=='running'&&j.state!=='cancelling'){const raw=j.error||'The operation failed.';throw Error(plain(raw))}
        }
      }finally{activeJob=null;jobCancel(false)}
    }else{result=started}
    Object.keys(branchCache).forEach(k=>delete branchCache[k]);
    renderProjectCatalog(Array.isArray(result.projects)?result.projects:[]);
  }catch(e){
    box.replaceChildren();
    const err=document.createElement('div');err.className='emptyHint';
    err.textContent='Could not list projects: '+e.message;
    box.append(err);
  }
}



if(el('pullSelectionBtn'))el('pullSelectionBtn').addEventListener('click',async()=>{
  if(selectedPaths.size<1){
    note('notice','Check one or more projects, then Pull.','warn');
    return;
  }
  const projects=[];
  for(const path of selectedPaths){
    const hit=catalogProjects.find(p=>p.path===path);
    if(!hit)continue;
    const row=document.querySelector('.orgBody .file[data-path="'+CSS.escape(path)+'"]');
    const branchSel=row?row.querySelector('select.projBranch'):null;
    const branch=branchSel&&branchSel.value?branchSel.value:(hit.defaultBranch||'main');
    const url=hit.url||'';
    if(!url)continue;
    projects.push({url,branch,path:hit.path});
  }
  if(!projects.length){
    note('notice','No selected projects have a URL to pull.','warn');
    return;
  }
  const b=el('pullSelectionBtn');
  b.disabled=true;
  note('notice','Pulling '+projects.length+' project'+(projects.length===1?'':'s')+'…','');
  try{
    let started=await api('/api/pull','POST',{projects});
    let result;
    if(started.job){
      activeJob=started.job;jobCancel(true,'Pulling projects…');
      try{
        let after=0;
        for(;;){
          await sleep(400);
          const j=await api('/api/jobs/'+started.job+'?after='+after);
          after=j.next;el('jobCancelLabel').textContent=(j.progress||'Working')+'…';
          if(j.state==='succeeded'){result=j.result||{};break}
          if(j.state==='cancelled')throw Error('Stopped before it finished.');
          if(j.state!=='running'&&j.state!=='cancelling'){const raw=j.error||'The operation failed.';throw Error(plain(raw))}
        }
      }finally{activeJob=null;jobCancel(false)}
    }else{result=started}
    const pulled=Number(result.pulled||0), failed=Number(result.failed||0);
    const folders=result.folders||[];
    if(result.workspace||result.folder){
      workspace=result.workspace||result.folder;
      if(el('workspacePath'))el('workspacePath').textContent=workspace;
      connected=!!result.project;
      if(result.project&&el('projectTitle'))el('projectTitle').textContent=result.project;
      if(result.provider&&el('statProvider'))el('statProvider').textContent=result.provider;
      if(result.branch&&el('statBranch'))el('statBranch').textContent=result.branch;
      if(result.branch&&el('branch'))el('branch').value=result.branch;
    }
    let msg='Pulled '+pulled+' project'+(pulled===1?'':'s')+'.';
    if(failed)msg+=' '+failed+' failed.';
    if(folders.length===1)msg+=' Folder: '+folders[0];
    else if(folders.length>1)msg+=' Folders: '+folders.slice(0,3).join('; ')+(folders.length>3?'…':'');
    note('notice',msg, failed&&!pulled?'error':(failed?'warn':'ok'));
    log(msg);
    if(pulled)await refresh();
    controls();paintSelection();
  }catch(e){note('notice',e.message,'error')}
  finally{b.disabled=false}
});

if(el('repoUrl')){
  el('repoUrl')&&el('repoUrl').addEventListener('input',()=>{applyUrlHighlight();scheduleUrlPoll()});
  el('repoUrl')&&el('repoUrl').addEventListener('change',()=>{applyUrlHighlight();scheduleUrlPoll()});
}
