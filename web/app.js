'use strict';const CLIENT='keystone-ui/1',el=id=>document.getElementById(id);let connected=false,workspace='',changes=[],stale=false,lastSaved=false;
function tab(name){document.querySelectorAll('.section').forEach(x=>x.classList.toggle('active',x.id===name));document.querySelectorAll('.nav button').forEach(x=>x.classList.toggle('active',x.dataset.tab===name));el('crumb').textContent=name;if(connected){if(name==='branches')loadBranches();if(name==='compare')loadBranchSelectors();if(name==='activity')loadHistory();if(name==='reviews')loadReviews();}if(name==='integrations'){loadIntegrations();loadAudit()}}
document.querySelectorAll('.nav button').forEach(x=>x.addEventListener('click',()=>tab(x.dataset.tab)));
function note(id,t,k=''){let x=el(id);x.hidden=!t;x.className='notice '+k;x.textContent=t;}
function log(t){let d=document.createElement('div'),x=document.createElement('time');d.className='activityItem';d.textContent=t;x.textContent=new Date().toLocaleTimeString();d.append(x);el('activityList').prepend(d);}
async function api(path,method='GET',body){let r=await fetch(path,{method,headers:{'X-Keystone-Client':CLIENT,...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,cache:'no-store',credentials:'same-origin'}),t=await r.text(),x;try{x=JSON.parse(t)}catch{throw Error('Invalid service response')}if(r.status===401&&x.error==='SESSION'){ended(x.message);throw Error(x.message)}if(!r.ok){const e=Error(x.message||x.error||'Request failed');e.code=x.error||'';throw e}return x;}
function ended(t){el('ended').hidden=false;if(t)el('endedText').textContent=t}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
// Long operations run as background jobs on the host: start, then poll.
async function runJob(path,body,onProgress,onChunk){let x=await api(path,'POST',body||{});if(!x.job)return x;let after=0;for(;;){await sleep(400);const j=await api('/api/jobs/'+x.job+'?after='+after);if(onChunk&&j.chunks)for(const c of j.chunks)onChunk(c);after=j.next;if(onProgress)onProgress(j.progress);if(j.state==='succeeded')return j.result||{};if(j.state!=='running'&&j.state!=='cancelling'){const e=Error(j.error||'The operation failed.');e.code=(j.error||'').split('|')[0];throw e}}}
async function bootstrap(){const m=/[#&]k=([A-Za-z0-9_-]{20,})/.exec(location.hash);if(m){history.replaceState(null,'',location.pathname);try{await fetch('/api/session',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({nonce:m[1]}),credentials:'same-origin'}).then(async r=>{if(!r.ok){const x=await r.json().catch(()=>({}));throw Error(x.message||'Launch link expired')}})}catch(e){ended(e.message);return false}}const h=await fetch('/api/health',{cache:'no-store'}).then(r=>r.json()).catch(()=>({}));if(!h.session){ended();return false}return true}

let arcDiagnosticText='';
el('copyArcDiagnostics').addEventListener('click',async()=>{if(!arcDiagnosticText){await loadIntegrations()}try{await navigator.clipboard.writeText(arcDiagnosticText);note('arcNotice','Safe diagnostics copied. They contain no tokens or passwords.','ok')}catch(e){note('arcNotice','Clipboard access denied. Select and copy the details shown above.','warn')}});
const SOURCE={environment:'environment variable',stored:'saved on this PC',arc:'ARC vault',none:'not set'};
function credRow(c,storeOk){const row=document.createElement('div');row.className='credRow';const name=document.createElement('strong');name.textContent=c.provider==='GenAi'?'GenAI':c.provider;const body=document.createElement('div');const state=document.createElement('div');state.className='small';state.textContent=c.configured?('Ready: '+SOURCE[c.source]+(c.source==='environment'?' ('+c.environmentVariable+')':'')+(c.source==='stored'&&c.storedAt?' since '+new Date(c.storedAt).toLocaleDateString():'')):'Not set. Paste a personal access token below, or set '+c.environmentVariable+'.';body.append(state);
 if(storeOk){const input=document.createElement('input');input.type='password';input.className='field';input.autocomplete='off';input.spellcheck=false;input.placeholder=c.source==='stored'?'Paste a new token to replace the saved one':'Paste token';input.setAttribute('aria-label',name.textContent+' token');const acts=document.createElement('div');acts.className='actions';const save=document.createElement('button');save.className='btn';save.type='button';save.textContent='Save token';save.addEventListener('click',async()=>{const v=input.value.trim();if(!v)return;save.disabled=true;try{await api('/api/credentials','POST',{provider:c.provider,token:v});input.value='';note('credNotice',name.textContent+' token saved and sealed on this PC.','ok');await loadIntegrations()}catch(e){note('credNotice',e.message,'error')}finally{save.disabled=false}});acts.append(save);
  if(c.source==='stored'||c.storedAt){const rm=document.createElement('button');rm.className='btn';rm.type='button';rm.textContent='Remove saved token';rm.addEventListener('click',async()=>{if(!confirm('Remove the saved '+name.textContent+' token from this PC?'))return;try{await api('/api/credentials/remove','POST',{provider:c.provider});note('credNotice','Saved token removed.','ok');await loadIntegrations()}catch(e){note('credNotice',e.message,'error')}});acts.append(rm)}
  body.append(input,acts)}
 row.append(name,body);return row}
async function loadIntegrations(){
 try{const info=await api('/api/integrations');
  el('credStore').textContent=info.storeAvailable?('Saved tokens are protected with '+info.storeProtection+'.'):'Saving tokens needs Windows DPAPI, which is not available here. Use environment variables instead.';
  const list=el('credList');list.replaceChildren();for(const c of info.credentials||[])list.append(credRow(c,info.storeAvailable));
  const arc=info.arc||{},st=arc.status||{};el('arcEnabled').checked=!!arc.enabled;el('arcEnabled').disabled=!!arc.fromEnvironment;el('arcPath').value=arc.configuredPath||'';el('arcPath').disabled=!!arc.fromEnvironment;
  const status=el('arcStatus');
  if(!arc.enabled){status.className='notice';status.textContent='ARC is off. Keystone uses environment variables and tokens saved above.';el('arcDetails').textContent='';arcDiagnosticText='ARC: not configured';el('arcMappings').replaceChildren();return}
  const ready=st.arcLoaded&&st.arcUnlocked;status.className='notice '+(ready?'ok':'warn');status.textContent=(arc.fromEnvironment?'Configured by KEYSTONE_ARC_PATH. ':'')+(st.message||'ARC status unavailable.');
  const helper=st.helpers||{},missing=Array.isArray(st.missingModules)?st.missingModules:[];
  arcDiagnosticText=['Status code: '+(st.code||'OK'),'ARC version: '+(st.arcVersion||'unknown'),'ARC located: '+!!st.arcFound,'ARC loaded: '+!!st.arcLoaded,'Vault unlocked: '+!!st.arcUnlocked,'Helpers: '+Object.entries(helper).filter(([k,v])=>v).map(([k])=>k).join(', '),...(missing.length?['Missing ARC files:',...missing.map(x=>'  '+x)]:[])].join('\n');
  el('arcDetails').textContent=ready?'':arcDiagnosticText;
  const box=el('arcMappings');box.replaceChildren();if(!ready)return;const names=Array.isArray(st.itemNames)?st.itemNames:[];
  for(const c of info.credentials||[]){const row=document.createElement('div');row.className='credRow';const n=document.createElement('strong');n.textContent=c.provider==='GenAi'?'GenAI':c.provider;const wrap=document.createElement('div');const sel=document.createElement('select');sel.className='field';for(const name of [...new Set([c.arcItem,...names])].filter(Boolean)){const o=document.createElement('option');o.value=name;o.textContent=name;o.selected=name===c.arcItem;sel.append(o)}const b=document.createElement('button');b.className='btn';b.type='button';b.textContent='Use this ARC item';b.addEventListener('click',async()=>{try{await api('/api/integrations/map','POST',{provider:c.provider,item:sel.value});note('arcNotice','Saved. Only the item name was stored.','ok');await loadIntegrations()}catch(e){note('arcNotice',e.message,'error')}});wrap.append(sel,b);row.append(n,wrap);box.append(row)}
 }catch(e){el('arcStatus').className='notice error';el('arcStatus').textContent='Unable to read credential status: '+e.message}
}
el('credRefresh').addEventListener('click',loadIntegrations);
el('arcSave').addEventListener('click',async()=>{try{await api('/api/integrations/arc','POST',{enabled:el('arcEnabled').checked,path:el('arcPath').value.trim()});note('arcNotice',el('arcEnabled').checked?'Saved. Restart Keystone and unlock ARC in its PowerShell window to use it.':'ARC turned off.','ok');await loadIntegrations()}catch(e){note('arcNotice',e.message,'error')}});
async function loadAudit(){try{const x=await api('/api/audit?last=30');const box=el('auditList');box.replaceChildren();if(!x.entries.length){box.textContent='Nothing recorded yet.';return}for(const a of x.entries){const d=document.createElement('div');d.className='activityItem';d.textContent=a.action+(a.project?' · '+a.project:'')+(a.branch?' · '+a.branch:'')+(a.commit?' · '+String(a.commit).slice(0,10):'')+(a.provider&&!a.project?' · '+a.provider:'');const t=document.createElement('time');t.textContent=new Date(a.time).toLocaleString();d.append(t);box.append(d)}}catch(e){el('auditList').textContent='Unavailable: '+e.message}}
el('auditRefresh').addEventListener('click',loadAudit);
function selected(){return [...document.querySelectorAll('#files input:checked')].map(x=>x.value);}
function suggest(){let a=changes.filter(x=>selected().includes(x.Path)),roots=[...new Set(a.map(x=>x.Path.replace(/\\/g,'/').split('/')[0]))],scope=roots.length===1&&!roots[0].includes('.')?roots[0].toLowerCase():'project',type=a.every(x=>x.Kind==='New')?'feat':'chore';return a.length?(type+'('+scope+'): update '+(a.length===1?a[0].Path.split('/').pop():a.length+' files')):'No changes';}
function controls(){el('startBtn').disabled=!connected;el('reviewBtn').disabled=!lastSaved;el('downloadBtn').disabled=!connected;el('refreshBtn').disabled=!workspace;el('selectBtn').disabled=!changes.length;el('localBtn').disabled=!selected().length;el('aiBtn').disabled=!selected().length||stale;el('saveBtn').disabled=!selected().length||stale;}
function changed(){el('selectedCount').textContent=selected().length+' selected';el('message').value=suggest();controls();}
function render(){el('files').replaceChildren();for(let f of changes){let row=document.createElement('label'),input=document.createElement('input'),path=document.createElement('span'),tag=document.createElement('span');row.className='file';input.type='checkbox';input.value=f.Path;input.checked=f.Selected&&!f.Blocked;input.disabled=f.Blocked;input.addEventListener('change',changed);path.className='path';path.textContent=f.Path;tag.className='tag';tag.textContent=f.Blocked?'Excluded':f.Kind;row.append(input,path,tag);el('files').append(row);}el('diffSummary').textContent=changes.length?changes.length+' pending files; deletions are never selected automatically.':'No local changes yet.';el('statChanges').textContent=changes.length;el('stale').hidden=!stale;changed();}
async function refresh(){if(!workspace)return;try{let x=await api('/api/preview');changes=x.changes||[];stale=!!x.remoteChanged;render();}catch(e){note('saveNotice',e.message,'error')}}
async function init(){try{let x=await api('/api/status');connected=!!x.connected;workspace=x.workspace||'';lastSaved=!!x.canReview;el('online').textContent='● Local service connected';el('projectTitle').textContent=x.project||'Ready when you are';el('testBanner').hidden=!x.localDev;if(x.localDev&&x.devProvider&&!el('repoUrl').value)el('repoUrl').value=x.devProvider+'/keystone-demo/sample';el('projectHint').textContent=x.restoredWaiting?'Your previous session is saved. Add a token in Credentials to continue it.':connected?(workspace?'Workspace ready. Edit files there, then Smart Save.':'Connected; download a workspace to begin.'):'Paste a GitHub or GitLab project URL to get started.';if(x.branch)el('branch').value=x.branch;el('statProvider').textContent=x.provider||'—';el('statBranch').textContent=x.branch||'—';el('workspacePath').textContent=workspace||'No workspace downloaded.';if(workspace)await refresh();if(connected)await loadInsights();await loadIntegrations();}catch(e){el('online').textContent='Open this page through Start-KeystoneWeb.ps1';note('notice','Start Keystone using Start-KeystoneWeb.ps1, then open the localhost URL.','warn')}controls()}
el('connectBtn').addEventListener('click',async()=>{let b=el('connectBtn');b.disabled=true;try{let x=await runJob('/api/connect',{url:el('repoUrl').value.trim()},p=>note('notice',p+'...'));connected=true;workspace='';changes=[];lastSaved=false;el('workspacePath').textContent='No workspace downloaded.';el('projectTitle').textContent=x.project;el('projectHint').textContent='Connected. Download a clean workspace to start.';el('statProvider').textContent=x.provider;el('statBranch').textContent=x.branch;el('statChanges').textContent='—';el('branch').value=x.branch;note('notice','Connected! Credentials remain in the PowerShell process.','ok');log('Connected to '+x.project);await loadInsights()}catch(e){const message=e.message.replace(/^[A-Z_]+\|/,'');note('notice',message,'error');if(/^(ARC_|CREDENTIAL_)/.test(e.code||'')){tab('integrations');await loadIntegrations();note('arcNotice',message,'error')}}finally{b.disabled=false;controls()}});
el('startBtn').addEventListener('click',async()=>{let b=el('startBtn');b.disabled=true;try{let x=await runJob('/api/start',{},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;el('branch').value=x.branch;note('notice','Safe work branch '+x.branch+' created and downloaded. Edit your files, then Smart Save.','ok');log('Started safe branch '+x.branch);await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('downloadBtn').addEventListener('click',async()=>{let b=el('downloadBtn');b.disabled=true;try{let x=await runJob('/api/download',{branch:el('branch').value.trim()},p=>note('notice',p+'...'));workspace=x.folder;el('workspacePath').textContent=workspace;el('statBranch').textContent=x.branch;note('notice','Fresh workspace downloaded. Edit files there and use Smart Save.','ok');log('Downloaded '+x.branch+' at '+x.sha.slice(0,8));await refresh()}catch(e){note('notice',e.message,'error')}finally{controls()}});
el('refreshBtn').addEventListener('click',refresh);el('selectBtn').addEventListener('click',()=>{document.querySelectorAll('#files input:not(:disabled)').forEach(x=>{x.checked=changes.find(c=>c.Path===x.value).Kind!=='Deleted'});changed()});el('localBtn').addEventListener('click',()=>{el('message').value=suggest()});
el('aiBtn').addEventListener('click',async()=>{if(!confirm('Send selected filenames and change types to your approved AI gateway?'))return;try{let x=await runJob('/api/commit-message',{paths:selected()});el('message').value=x.title;note('saveNotice','AI provided a proposed title. You can accept or edit it.','ok')}catch(e){note('saveNotice',e.message,'error')}});
el('reviewBtn').addEventListener('click',async()=>{if(!confirm('Create a GitHub pull request or GitLab merge request for your saved work?'))return;try{let x=await runJob('/api/review',{},p=>note('saveNotice',p+'...'));note('saveNotice','Review created: '+x.title,'ok');let a=document.createElement('a');a.href=x.url;a.rel='noopener noreferrer';a.target='_blank';a.textContent='Open review request ↗';el('saveNotice').append(document.createElement('br'),a);log('Created review request: '+x.url);lastSaved=false;controls()}catch(e){note('saveNotice',e.message,'error')}});
el('saveBtn').addEventListener('click',async()=>{let paths=selected();if(!paths.length)return;const b=el('saveBtn');b.disabled=true;try{
 const check=await api('/api/sentinel');let publicConfirmed=false;
 if(check.destination.Public){
  if(!check.publicPublishingEnabled)throw Error('This repository is PUBLIC. Publishing is disabled by your Keystone policy.');
  publicConfirmed=confirm('PUBLIC GITHUB/GITLAB REPOSITORY: Anyone may see the selected files and committed history. Confirm you have authorization to release this information. Continue publishing '+paths.length+' change(s)?');
  if(!publicConfirmed)return;
 }else if(!confirm('Publish '+paths.length+' file change(s) to your online branch? This creates a remote commit.'))return;
 const r=await runJob('/api/save',{paths,message:el('message').value.trim(),publicConfirmed},p=>note('saveNotice',p+'...')),x=r.saved;
 note('saveNotice','Published '+x.FileCount+' file(s) as '+x.Commit.slice(0,10)+'. '+x.Message,'ok');log('Published '+x.FileCount+' files: '+x.Message);lastSaved=true;await refresh();
 }catch(e){note('saveNotice',e.message,'error')}finally{controls()}});
function chat(who,txt){let wrap=document.createElement('div'),head=document.createElement('span'),body=document.createElement('span');wrap.className='bubble '+(who==='You'?'user':'');head.className='who';head.textContent=who;body.textContent=txt;wrap.append(head,body);el('messages').append(wrap);el('messages').scrollTop=el('messages').scrollHeight;return body}
el('chatForm').addEventListener('submit',async event=>{event.preventDefault();let input=el('chatText'),q=input.value.trim();if(!q)return;input.value='';chat('You',q);let output=chat('Keystone Assist',''),btn=el('chatBtn');btn.disabled=true;btn.textContent='Thinking...';try{await runJob('/api/chat',{message:q},null,t=>{output.textContent+=t;el('messages').scrollTop=el('messages').scrollHeight});if(!output.textContent)output.textContent='(No answer returned.)'}catch(e){output.textContent='Assistant unavailable: '+e.message.replace(/^[A-Z_]+\|/,'')}finally{btn.disabled=false;btn.textContent='\u2726 Ask assistant'}});

// All provider responses are untrusted. Render user-visible fields with textContent.
function clear(id){const x=el(id);x.replaceChildren();return x}
function itemRow(parent,title,detail,url){
 const row=document.createElement('div');row.className='repoRow';
 const heading=document.createElement('strong');heading.textContent=title;row.append(heading);
 const sub=document.createElement('small');sub.textContent=detail||'';row.append(sub);
 if(url){try{const u=new URL(url);if(u.protocol==='https:'){const a=document.createElement('a');a.href=u.href;a.target='_blank';a.rel='noopener noreferrer';a.className='file-link';a.textContent='View on provider ↗';row.append(a)}}catch{}}
 parent.append(row);return row;
}
async function loadBranches(){
 const box=el('branchesList');box.textContent='Reading branches…';
 try{const x=await api('/api/branches');const list=clear('branchesList');
 if(!x.branches.length){list.textContent='No branches found.';return}
 x.branches.forEach(b=>{const row=itemRow(list,b.Name,(b.IsDefault?'Default branch · ':'')+(b.IsCurrent?'Current selection':'Select to download a fresh copy'));const go=document.createElement('button');go.className='btn';go.textContent='Use this branch →';go.title='Select this branch in the Overview download field. This does not overwrite files.';go.addEventListener('click',()=>{el('branch').value=b.Name;tab('overview');note('notice','Branch '+b.Name+' selected. Choose Explore a branch to download it to a new folder.','ok')});row.append(go)});
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
connectBtn:'Connect Keystone to a GitHub repository or GitLab project using your configured credentials.',
startBtn:'Make a new branch and download a separate working folder. The shared main branch is not changed.',
downloadBtn:'Get a fresh local copy of the selected branch. Existing local files are not overwritten.',
refreshBtn:'Check your local folder for changes since the downloaded version.',
selectBtn:'Choose safe changed files for publication. You can uncheck any individual file.',
localBtn:'Suggest a brief name describing the changes you made. This does not publish anything.',
aiBtn:'Ask the approved AI provider for a suggested commit title using filenames only.',
saveBtn:'Publish selected changes to the online branch. Keystone creates a remote commit and updates that branch.',
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
(async()=>{if(await bootstrap())init()})();
