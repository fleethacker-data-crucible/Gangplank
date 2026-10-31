'use strict';const el=id=>document.getElementById(id);let connected=false,workspace='',changes=[],stale=false,lastSaved=false;
function tab(name){document.querySelectorAll('.section').forEach(x=>x.classList.toggle('active',x.id===name));document.querySelectorAll('.nav button[data-tab]').forEach(x=>{const on=x.dataset.tab===name;x.classList.toggle('active',on);if(on){x.setAttribute('aria-current','page');el('crumb').textContent=x.querySelector('.navLabel')?.textContent||name}else x.removeAttribute('aria-current')});el('main').scrollTop=0;if(connected){if(name==='branches')loadBranches();if(name==='compare')loadBranchSelectors();if(name==='activity')loadHistory();if(name==='reviews')loadReviews();}if(name==='integrations'){loadIntegrations();loadAudit();loadSettings()}}
document.querySelectorAll('.nav button[data-tab]').forEach(x=>x.addEventListener('click',()=>tab(x.dataset.tab)));
function note(id,t,k=''){let x=el(id);x.hidden=!t;x.className='notice '+k;x.textContent=t;}
function log(t){let d=document.createElement('div'),x=document.createElement('time');d.className='activityItem';d.textContent=t;x.textContent=new Date().toLocaleTimeString();d.append(x);el('activityList').prepend(d);}
async function api(path,method='GET',body){let r=await fetch(path,{method,headers:{'X-Gangplank-Client':clientSecret(),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,cache:'no-store',credentials:'same-origin'}),t=await r.text(),x;try{x=JSON.parse(t)}catch{throw Error('Invalid service response')}if(r.status===401&&x.error==='SESSION'){ended(x.message);throw Error(x.message)}if(!r.ok){const e=Error(plain(x.message||x.error||'Request failed'));e.code=x.error||'';throw e}return x;}
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
async function runJob(path,body,onProgress,onChunk){let x=await api(path,'POST',body||{});if(!x.job)return x;let after=0;for(;;){await sleep(400);const j=await api('/api/jobs/'+x.job+'?after='+after);if(onChunk&&j.chunks)for(const c of j.chunks)onChunk(c);after=j.next;if(onProgress)onProgress(j.progress);if(j.state==='succeeded')return j.result||{};if(j.state!=='running'&&j.state!=='cancelling'){const raw=j.error||'The operation failed.',e=Error(plain(raw));e.code=/^[A-Z][A-Z0-9_]{2,40}\|/.test(raw)?raw.split('|')[0]:'';throw e}}}
async function bootstrap(){const m=/[#&]k=([A-Za-z0-9_-]{20,})/.exec(location.hash);if(m){history.replaceState(null,'',location.pathname);try{const r=await fetch('/api/session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:m[1]}),credentials:'same-origin'});const x=await r.json().catch(()=>({}));if(r.ok&&x.client)setClientSecret(x.client)}catch{}}
 // A reused or expired link is fine if this tab already has a live session.
 const h=await fetch('/api/health',{cache:'no-store',headers:{'X-Gangplank-Client':clientSecret()}}).then(r=>r.json()).catch(()=>({}));if(!h.session){ended();return false}return true}

let lazaretteDiagnosticText='';
el('copyLazaretteDiagnostics').addEventListener('click',async()=>{if(!lazaretteDiagnosticText){await loadIntegrations()}try{await navigator.clipboard.writeText(lazaretteDiagnosticText);note('lazaretteNotice','Safe diagnostics copied. They contain no tokens or passwords.','ok')}catch(e){note('lazaretteNotice','Clipboard access denied. Select and copy the details shown above.','warn')}});
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
  const helper=st.helpers||{},missing=Array.isArray(st.missingModules)?st.missingModules:[];
  lazaretteDiagnosticText=['Status code: '+(st.code||'OK'),'Lazarette version: '+(st.lazaretteVersion||'unknown'),'Lazarette located: '+!!st.lazaretteFound,'Lazarette loaded: '+!!st.lazaretteLoaded,'Vault unlocked: '+!!st.lazaretteUnlocked,'Helpers: '+Object.entries(helper).filter(([k,v])=>v).map(([k])=>k).join(', '),...(missing.length?['Missing Lazarette files:',...missing.map(x=>'  '+x)]:[])].join('\n');
  el('lazaretteDetails').textContent=ready?'':lazaretteDiagnosticText;
  const box=el('lazaretteMappings');box.replaceChildren();if(!ready)return;const names=Array.isArray(st.itemNames)?st.itemNames:[];
  for(const c of info.credentials||[]){const row=document.createElement('div');row.className='credRow';const n=document.createElement('strong');n.textContent=c.provider;const wrap=document.createElement('div');const sel=document.createElement('select');sel.className='field';for(const name of [...new Set([c.lazaretteItem,...names])].filter(Boolean)){const o=document.createElement('option');o.value=name;o.textContent=name;o.selected=name===c.lazaretteItem;sel.append(o)}const b=document.createElement('button');b.className='btn';b.type='button';b.textContent='Use this Lazarette item';b.addEventListener('click',async()=>{try{await api('/api/integrations/map','POST',{provider:c.provider,item:sel.value});note('lazaretteNotice','Saved. Only the item name was stored.','ok');await loadIntegrations()}catch(e){note('lazaretteNotice',e.message,'error')}});wrap.append(sel,b);row.append(n,wrap);box.append(row)}
 }catch(e){el('lazaretteStatus').className='notice error';el('lazaretteStatus').textContent='Unable to read credential status: '+e.message}
}
el('credRefresh').addEventListener('click',loadIntegrations);
el('lazaretteSave').addEventListener('click',async()=>{try{await api('/api/integrations/lazarette','POST',{enabled:el('lazaretteEnabled').checked,path:el('lazarettePath').value.trim()});note('lazaretteNotice',el('lazaretteEnabled').checked?'Saved. Restart Gangplank and unlock Lazarette in its PowerShell window to use it.':'Lazarette turned off.','ok');await loadIntegrations()}catch(e){note('lazaretteNotice',e.message,'error')}});
async function loadAudit(){try{const x=await api('/api/audit?last=30');const box=el('auditList');box.replaceChildren();if(!x.entries.length){box.textContent='Nothing recorded yet.';return}for(const a of x.entries){const d=document.createElement('div');d.className='activityItem';d.textContent=a.action+(a.project?' · '+a.project:'')+(a.branch?' · '+a.branch:'')+(a.commit?' · '+String(a.commit).slice(0,10):'')+(a.provider&&!a.project?' · '+a.provider:'');const t=document.createElement('time');t.textContent=new Date(a.time).toLocaleString();d.append(t);box.append(d)}}catch(e){el('auditList').textContent='Unavailable: '+e.message}}
el('auditRefresh').addEventListener('click',loadAudit);
function selected(){return [...document.querySelectorAll('#files input:checked')].map(x=>x.value);}
function suggest(){let a=changes.filter(x=>selected().includes(x.Path)),roots=[...new Set(a.map(x=>x.Path.replace(/\\/g,'/').split('/')[0]))],scope=roots.length===1&&!roots[0].includes('.')?roots[0].toLowerCase():'project',type=a.every(x=>x.Kind==='New')?'feat':'chore';return a.length?(type+'('+scope+'): update '+(a.length===1?a[0].Path.split('/').pop():a.length+' files')):'No changes';}
function controls(){const project=connected?el('projectTitle').textContent:'',branch=el('statBranch').textContent;el('headerProject').hidden=!project;el('headerProjectText').textContent=project+(branch&&branch!=='\u2014'?' \u00b7 '+branch:'');el('statusProject').textContent=project?'Project: '+project:'No project connected';el('startBtn').disabled=!connected;el('reviewBtn').disabled=!lastSaved;el('downloadBtn').disabled=!connected;el('refreshBtn').disabled=!workspace;el('selectBtn').disabled=!changes.length;el('localBtn').disabled=!selected().length;el('aiBtn').disabled=!selected().length||stale;el('saveBtn').disabled=!selected().length||stale;}
function changed(){el('selectedCount').textContent=selected().length+' selected';el('message').value=suggest();controls();}
function render(){el('files').replaceChildren();for(let f of changes){let row=document.createElement('label'),input=document.createElement('input'),path=document.createElement('span'),tag=document.createElement('span');row.className='file';input.type='checkbox';input.value=f.Path;input.checked=f.Selected&&!f.Blocked;input.disabled=f.Blocked;input.addEventListener('change',changed);path.className='path';path.textContent=f.Path;tag.className='tag';tag.textContent=f.Blocked?'Excluded':f.Kind;row.append(input,path,tag);if(!f.Blocked&&f.Kind!=='New'){let rv=document.createElement('button');rv.type='button';rv.className='btn fl-btn fl-btn--secondary rowBtn';rv.textContent='Revert';rv.title='Go back to the downloaded version of this file. Your edited copy is saved aside first.';rv.setAttribute('aria-label','Revert '+f.Path);rv.addEventListener('click',ev=>{ev.preventDefault();revertFile(f.Path)});row.append(rv)}el('files').append(row);}el('diffSummary').textContent=changes.length?changes.length+' pending files; deletions are never selected automatically.':'No local changes yet.';el('statChanges').textContent=changes.length;el('stale').hidden=!stale;changed();}
async function revertFile(p){if(!confirm('Go back to the downloaded version of '+p+'? Your edited copy is saved in a backup folder next to the workspace first.'))return;try{const r=await runJob('/api/revert',{path:p},x=>note('saveNotice',x+'...'));note('saveNotice','Reverted '+p+(r.BackupPath?'. Your edited copy is in '+r.BackupPath:'.'),'ok');await refresh()}catch(e){note('saveNotice',e.message,'error')}}
async function refresh(){if(!workspace)return;try{let x=await api('/api/preview');changes=x.changes||[];stale=!!x.remoteChanged;render();}catch(e){note('saveNotice',e.message,'error')}}
async function init(){try{let x=await api('/api/status');connected=!!x.connected;workspace=x.workspace||'';lastSaved=!!x.canReview;el('online').textContent='Local service connected';engine('running');el('projectTitle').textContent=x.project||'Ready when you are';el('testBanner').hidden=!x.localDev;if(x.localDev&&x.devProvider&&!el('repoUrl').value)el('repoUrl').value=x.devProvider+'/gangplank-demo/sample';el('projectHint').textContent=x.restoredWaiting?'Your previous session is saved. Add a token in Credentials to continue it.':connected?(workspace?'Workspace ready. Edit files there, then Smart Save.':'Connected; download a workspace to begin.'):'Paste a GitHub or GitLab project URL to get started.';if(x.branch)el('branch').value=x.branch;el('statProvider').textContent=x.provider||'—';el('statBranch').textContent=x.branch||'—';el('workspacePath').textContent=workspace||'No workspace downloaded.';if(workspace)await refresh();if(connected)await loadInsights();await loadIntegrations();}catch(e){el('online').textContent='Open this page through Start-Gangplank.ps1';engine('disconnected');note('notice','Start Gangplank using Start-Gangplank.ps1, then open the localhost URL.','warn')}controls()}
el('connectBtn').addEventListener('click',async()=>{let b=el('connectBtn');b.disabled=true;try{let x=await runJob('/api/connect',{url:el('repoUrl').value.trim()},p=>note('notice',p+'...'));connected=true;workspace='';changes=[];lastSaved=false;el('workspacePath').textContent='No workspace downloaded.';el('projectTitle').textContent=x.project;el('projectHint').textContent='Connected. Download a clean workspace to start.';el('statProvider').textContent=x.provider;el('statBranch').textContent=x.branch;el('statChanges').textContent='—';el('branch').value=x.branch;note('notice','Connected! Credentials remain in the PowerShell process.','ok');log('Connected to '+x.project);await loadInsights()}catch(e){const message=e.message;note('notice',message,'error');if(/^(ARC_|CREDENTIAL_)/.test(e.code||'')){tab('integrations');await loadIntegrations();note('lazaretteNotice',message,'error')}}finally{b.disabled=false;controls()}});
el('startBtn').addEventListener('click',async()=>{let b=el('startBtn');b.disabled=true;try{let x=await runJob('/api/start',{name:el('workName').value.trim()},p=>note('notice',p+'...'));el('workName').value='';workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;el('branch').value=x.branch;note('notice','Safe work branch '+x.branch+' created and downloaded. Edit your files, then Smart Save.','ok');log('Started safe branch '+x.branch);await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('downloadBtn').addEventListener('click',async()=>{let b=el('downloadBtn');b.disabled=true;try{let x=await runJob('/api/download',{branch:el('branch').value.trim()},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;note('notice','Fresh workspace downloaded. Edit files there and use Smart Save.','ok');log('Downloaded '+x.branch+' at '+x.sha.slice(0,8));await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('refreshBtn').addEventListener('click',refresh);el('selectBtn').addEventListener('click',()=>{document.querySelectorAll('#files input:not(:disabled)').forEach(x=>{x.checked=changes.find(c=>c.Path===x.value).Kind!=='Deleted'});changed()});el('localBtn').addEventListener('click',()=>{el('message').value=suggest()});
el('aiBtn').addEventListener('click',async()=>{if(!confirm('Send selected filenames and change types to your approved AI gateway?'))return;try{let x=await runJob('/api/commit-message',{paths:selected()});el('message').value=x.title;note('saveNotice','AI provided a proposed title. You can accept or edit it.','ok')}catch(e){note('saveNotice',e.message,'error')}});
el('reviewBtn').addEventListener('click',async()=>{if(!confirm('Create a GitHub pull request or GitLab merge request for your saved work?'))return;try{let x=await runJob('/api/review',{},p=>note('saveNotice',p+'...'));note('saveNotice','Review created: '+x.title,'ok');let a=document.createElement('a');a.href=x.url;a.rel='noopener noreferrer';a.target='_blank';withIcon(a,'Open review request ','external');el('saveNotice').append(document.createElement('br'),a);log('Created review request: '+x.url);lastSaved=false;controls()}catch(e){note('saveNotice',e.message,'error')}});
el('saveBtn').addEventListener('click',async()=>{let paths=selected();if(!paths.length)return;const b=el('saveBtn');b.disabled=true;try{
 const check=await api('/api/sentinel');let publicConfirmed=false;
 if(check.destination.Public){
  if(!check.publicPublishingEnabled)throw Error('This repository is PUBLIC. Publishing is disabled by your Gangplank policy.');
  publicConfirmed=confirm('PUBLIC GITHUB/GITLAB REPOSITORY: Anyone may see the selected files and committed history. Confirm you have authorization to release this information. Continue publishing '+paths.length+' change(s)?');
  if(!publicConfirmed)return;
 }else if(!confirm('Publish '+paths.length+' file change(s) to your online branch? This creates a remote commit.'))return;
 const r=await runJob('/api/save',{paths,message:el('message').value.trim(),publicConfirmed},p=>note('saveNotice',p+'...')),x=r.saved;
 note('saveNotice','Published '+x.FileCount+' file(s) as '+x.Commit.slice(0,10)+'. '+x.Message,'ok');log('Published '+x.FileCount+' files: '+x.Message);lastSaved=true;await refresh();
 }catch(e){note('saveNotice',e.message,'error')}finally{controls()}});
function chat(who,txt){let wrap=document.createElement('div'),head=document.createElement('span'),body=document.createElement('span');wrap.className='bubble '+(who==='You'?'user':'');head.className='who';head.textContent=who;body.textContent=txt;wrap.append(head,body);el('messages').append(wrap);el('messages').scrollTop=el('messages').scrollHeight;return body}
el('chatForm').addEventListener('submit',async event=>{event.preventDefault();let input=el('chatText'),q=input.value.trim();if(!q)return;input.value='';chat('You',q);let output=chat('Gangplank Assist',''),btn=el('chatBtn');btn.disabled=true;el('chatBtnLabel').textContent='Thinking...';try{await runJob('/api/chat',{message:q},null,t=>{output.textContent+=t;el('messages').scrollTop=el('messages').scrollHeight});if(!output.textContent)output.textContent='(No answer returned.)'}catch(e){output.textContent='Assistant unavailable: '+e.message}finally{btn.disabled=false;el('chatBtnLabel').textContent='Ask assistant'}});

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
 const box=el('insightsSummary');box.textContent='Checking repository information…';
 try{const x=await api('/api/insights');box.textContent=x.BranchCount+' branches · '+x.OpenReviewCount+' open reviews · '+x.Branch;
 const list=clear('insightsList');x.Suggestions.forEach(s=>itemRow(list,'Suggested next step',s));
 }catch(e){box.textContent='Insights unavailable: '+e.message}
}
el('branchesRefresh').addEventListener('click',loadBranches);
el('compareRefresh').addEventListener('click',loadBranchSelectors);
el('compareRun').addEventListener('click',loadCompare);
el('historyRefresh').addEventListener('click',loadHistory);
el('historyBranch').addEventListener('change',loadHistory);
el('reviewsRefresh').addEventListener('click',loadReviews);
el('insightsRefresh').addEventListener('click',loadInsights);
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
el('sentinelRefresh').addEventListener('click',async()=>{
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
el('endSession').addEventListener('click',async()=>{
 if(!confirm('End this Gangplank session? The local service stops (after any save or download in progress). Unsaved selections in this page are lost; published work is not affected.'))return;
 const b=el('endSession');b.disabled=true;
 try{const r=await fetch('/api/session/stop',{method:'POST',headers:{'Content-Type':'application/json','X-Gangplank-Client':clientSecret(),'X-Gangplank-Intent':'end-session'},body:'{}',cache:'no-store',credentials:'same-origin'});let x={};try{x=await r.json()}catch{}if(!r.ok)throw Error(plain(x.message||x.error||'Request failed'));ended(x.waitingForJobs?'Gangplank stops as soon as the running task finishes. You can close this tab.':'Gangplank has stopped. You can close this tab. To keep working, start Gangplank again with Launch-Gangplank.bat.',x.waitingForJobs?'stopping':'stopped')}
 catch(e){b.disabled=false;alert('Could not end the session: '+e.message)}
});
(async()=>{if(await bootstrap()){startHeartbeat();init()}})();

// ---- Settings: workspace folder and AI model --------------------------------
const AI_KIND={openai:'OpenAI-compatible gateway',azure:'Azure OpenAI',databricks:'Databricks model serving',ollama:'Ollama on this PC'};
let aiDetected=null;
async function loadSettings(){
 try{const x=await api('/api/settings');const w=x.workspaces||{};el('wsRoot').textContent=w.root||'';el('wsRootInput').disabled=!!w.fixed;el('wsSave').disabled=!!w.fixed;el('wsDefault').disabled=!!w.fixed;if(w.fixed)note('wsNotice','This folder is set when Gangplank starts (-WorkRoot or GANGPLANK_WORK_ROOT).','');
  const a=x.intelligence||{};if(!el('aiEndpoint').value)el('aiEndpoint').value=a.endpoint||'';if(!el('aiModel').value)el('aiModel').value=a.model||'';
  el('aiCurrent').textContent='In use: '+(a.model||'?')+' at '+(a.endpoint||'?')+' ('+(AI_KIND[a.profile]||a.profile||'unknown')+(a.source==='environment'?', set by environment variables':a.source==='default'?', the default':'')+'). AI token: '+(a.tokenReady?'ready':(a.tokenRequired===false?'not needed on this PC':'not set'))+'.'+(a.allowedHosts&&a.allowedHosts.length?' Allowed by your administrator: '+a.allowedHosts.join(', ')+'.':'')+(a.problem?' Problem: '+a.problem:'');
 }catch(e){el('aiCurrent').textContent='Settings unavailable: '+e.message}
}
el('wsSave').addEventListener('click',async()=>{try{const x=await api('/api/settings/workspace','POST',{root:el('wsRootInput').value.trim()});el('wsRootInput').value='';note('wsNotice','New workspaces will go to '+x.workspaces.root+'.','ok');await loadSettings()}catch(e){note('wsNotice',e.message,'error')}});
el('wsDefault').addEventListener('click',async()=>{try{const x=await api('/api/settings/workspace','POST',{root:''});note('wsNotice','Using the default folder: '+x.workspaces.root+'.','ok');await loadSettings()}catch(e){note('wsNotice',e.message,'error')}});
el('aiDetect').addEventListener('click',async()=>{const b=el('aiDetect');b.disabled=true;el('aiKind').textContent='Detecting...';try{const r=await runJob('/api/ai/detect',{endpoint:el('aiEndpoint').value.trim(),model:el('aiModel').value.trim()});aiDetected=r;const dl=el('aiModels');dl.replaceChildren();for(const m of r.models||[]){const o=document.createElement('option');o.value=m;dl.append(o)}if(r.recommended)el('aiModel').value=r.recommended;el('aiKind').textContent=(AI_KIND[r.profile]||r.profile)+': '+(r.models&&r.models.length?r.models.length+' chat model(s) found; best match selected. Click the Model box to see them all.':'no model list available.')+(r.note?' '+r.note:'');note('aiNotice','Detected. Check the model, then Save.','ok')}catch(e){el('aiKind').textContent='';note('aiNotice',e.message,'error')}finally{b.disabled=false}});
el('aiSave').addEventListener('click',async()=>{try{const d=aiDetected||{};await api('/api/settings/intelligence','POST',{endpoint:el('aiEndpoint').value.trim(),model:el('aiModel').value.trim(),profile:d.profile||'',base:d.base||'',auth:d.auth||''});note('aiNotice','AI setting saved.','ok');await loadSettings()}catch(e){note('aiNotice',e.message,'error')}});
el('aiReset').addEventListener('click',async()=>{try{await api('/api/settings/intelligence','POST',{endpoint:''});el('aiEndpoint').value='';el('aiModel').value='';aiDetected=null;note('aiNotice','Back to the default AI endpoint.','ok');await loadSettings()}catch(e){note('aiNotice',e.message,'error')}});
el('aiTest').addEventListener('click',async()=>{const b=el('aiTest');b.disabled=true;note('aiNotice','Testing...','');try{const r=await runJob('/api/ai/test',{});note('aiNotice','Working: '+r.model+' answered in '+r.milliseconds+' ms.','ok')}catch(e){note('aiNotice','Test failed: '+e.message,'error')}finally{b.disabled=false}});
