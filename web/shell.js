// Fleet shell preferences (docs/UNIFIED-UI.md sections 3.1 and 5). Loaded in <head> without
// defer so the remembered theme and sidebar width apply before the first paint.
//   gangplank-theme:    absent = follow Windows, 'dark' = Night watch, 'light' = Chart room
//   gangplank-sidebar:  'collapsed' or 'expanded' (default); under 1024 px it collapses by itself
//   gangplank-assistant:'collapsed' or 'expanded' (default)
// Left/right edge rails toggle the side panels (no bottom Collapse control).
'use strict';
(()=>{
const THEME_KEY='gangplank-theme',SIDEBAR_KEY='gangplank-sidebar',ASSIST_KEY='gangplank-assistant',root=document.documentElement;
const load=k=>{try{return window.localStorage.getItem(k)}catch{return null}};
const save=(k,v)=>{try{if(v===null)window.localStorage.removeItem(k);else window.localStorage.setItem(k,v)}catch{}};
const NAMES={system:'Follow Windows',dark:'Night watch',light:'Chart room'},ICON={system:'themeSystem',dark:'themeDark',light:'themeLight'};
const next=t=>t==='system'?'dark':t==='dark'?'light':'system';
let theme=(v=>v==='dark'||v==='light'?v:'system')(load(THEME_KEY));
let collapsedPref=load(SIDEBAR_KEY)==='collapsed';
let assistCollapsed=load(ASSIST_KEY)==='collapsed';
const narrow=window.matchMedia('(max-width: 1023px)');
function applyTheme(){if(theme==='system')root.removeAttribute('data-theme');else root.setAttribute('data-theme',theme)}
function applySidebar(){root.classList.toggle('sidebar-collapsed',collapsedPref||narrow.matches);root.classList.toggle('sidebar-narrow',narrow.matches)}
function applyAssistant(){root.classList.toggle('assistant-collapsed',assistCollapsed&&!narrow.matches)}
applyTheme();applySidebar();applyAssistant();
const icon=(name,size)=>typeof window.gangplankIcon==='function'?window.gangplankIcon(name,size):document.createTextNode('');
function paintButtons(){
 const t=document.getElementById('themeBtn');
 if(t){t.title='Theme: '+NAMES[theme]+'. Select for '+NAMES[next(theme)]+'.';const ni=t.querySelector('.navIcon');if(ni)ni.replaceChildren(icon(ICON[theme],20));const nl=t.querySelector('.navLabel');if(nl)nl.textContent=NAMES[theme]}
 const sideCollapsed=root.classList.contains('sidebar-collapsed');
 const rl=document.getElementById('railLeft');
 if(rl){rl.title=sideCollapsed?'Expand the left navigation':'Collapse the left navigation';rl.setAttribute('aria-expanded',String(!sideCollapsed));const s=rl.querySelector('span');if(s)s.textContent='Nav'}
 const rr=document.getElementById('railRight');
 const aCollapsed=root.classList.contains('assistant-collapsed');
 if(rr){rr.hidden=narrow.matches;rr.title=aCollapsed?'Expand the assistant panel':'Collapse the assistant panel';rr.setAttribute('aria-expanded',String(!aCollapsed));const s=rr.querySelector('span');if(s)s.textContent='Assist'}
}
function toggleSidebar(){
 if(narrow.matches)return;
 collapsedPref=!root.classList.contains('sidebar-collapsed');
 save(SIDEBAR_KEY,collapsedPref?'collapsed':'expanded');
 applySidebar();paintButtons();
}
function toggleAssistant(){
 if(narrow.matches)return;
 assistCollapsed=!root.classList.contains('assistant-collapsed');
 save(ASSIST_KEY,assistCollapsed?'collapsed':'expanded');
 applyAssistant();paintButtons();
}
narrow.addEventListener('change',()=>{applySidebar();applyAssistant();paintButtons()});
document.addEventListener('DOMContentLoaded',()=>{
 const t=document.getElementById('themeBtn');
 if(t)t.addEventListener('click',()=>{theme=next(theme);save(THEME_KEY,theme==='system'?null:theme);applyTheme();paintButtons()});
 const rl=document.getElementById('railLeft'),rr=document.getElementById('railRight');
 if(rl)rl.addEventListener('click',toggleSidebar);
 if(rr)rr.addEventListener('click',toggleAssistant);
 paintButtons();
});
})();
