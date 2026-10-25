// Gangplank presence heartbeat, run in a dedicated worker.
// Browsers throttle timers on a hidden page's main thread (Chrome: to once a minute
// after 5 minutes hidden), which would make the host think the tab had closed and
// stop. The page starts this worker and falls back to its own timer if it cannot.
'use strict';
// The host serves one request at a time; while a save runs, a heartbeat waits for it.
// Keep at most one in flight so they do not pile up behind a long request.
let timer=0,cfg=null,inflight=false;
function beat(){
 if(!cfg||inflight)return;
 inflight=true;
 fetch('/api/heartbeat',{method:'POST',headers:{'Content-Type':'application/json','X-Gangplank-Client':cfg.token},body:JSON.stringify({tab:cfg.tab,leaving:false}),cache:'no-store',credentials:'same-origin'})
  .then(r=>{inflight=false;postMessage({ok:r.ok,status:r.status})},()=>{inflight=false;postMessage({ok:false,status:0})});
}
onmessage=e=>{
 const m=e.data||{};
 if(m.type==='start'){cfg={token:String(m.token),tab:String(m.tab)};clearInterval(timer);beat();timer=setInterval(beat,m.interval||5000);}
 else if(m.type==='beat'){beat();}
 else if(m.type==='stop'){clearInterval(timer);cfg=null;}
};
