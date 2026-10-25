// Fleet shell preferences (docs/UNIFIED-UI.md sections 3.1 and 5). Loaded in <head> without
// defer so the remembered theme and sidebar width apply before the first paint.
//   gangplank-theme:   absent = follow Windows, 'dark' = Night watch, 'light' = Chart room
//   gangplank-sidebar: 'collapsed' or 'expanded' (default); under 1024 px it collapses by itself
// Storage can be unavailable (private windows, blocked site data); the choices then last for this page only.
'use strict';
(()=>{
const THEME_KEY='gangplank-theme',SIDEBAR_KEY='gangplank-sidebar',root=document.documentElement;
const load=k=>{try{return window.localStorage.getItem(k)}catch{return null}};
const save=(k,v)=>{try{if(v===null)window.localStorage.removeItem(k);else window.localStorage.setItem(k,v)}catch{}};
const NAMES={system:'Follow Windows',dark:'Night watch',light:'Chart room'},ICON={system:'themeSystem',dark:'themeDark',light:'themeLight'};
const next=t=>t==='system'?'dark':t==='dark'?'light':'system';
let theme=(v=>v==='dark'||v==='light'?v:'system')(load(THEME_KEY));
let collapsedPref=load(SIDEBAR_KEY)==='collapsed';
const narrow=window.matchMedia('(max-width: 1023px)');
function applyTheme(){if(theme==='system')root.removeAttribute('data-theme');else root.setAttribute('data-theme',theme)}
function applySidebar(){root.classList.toggle('sidebar-collapsed',collapsedPref||narrow.matches);root.classList.toggle('sidebar-narrow',narrow.matches)}
applyTheme();applySidebar();
const icon=(name,size)=>typeof window.gangplankIcon==='function'?window.gangplankIcon(name,size):document.createTextNode('');
function paintButtons(){
 const t=document.getElementById('themeBtn');
 if(t){t.title='Theme: '+NAMES[theme]+'. Select for '+NAMES[next(theme)]+'.';t.querySelector('.navIcon').replaceChildren(icon(ICON[theme],20));t.querySelector('.navLabel').textContent=NAMES[theme]}
 const c=document.getElementById('collapseBtn');
 if(c){const collapsed=root.classList.contains('sidebar-collapsed');c.hidden=narrow.matches;c.title=collapsed?'Expand the sidebar':'Collapse the sidebar';c.setAttribute('aria-expanded',String(!collapsed));c.querySelector('.navIcon').replaceChildren(icon(collapsed?'expand':'collapse',20));c.querySelector('.navLabel').textContent=collapsed?'Expand':'Collapse'}
}
narrow.addEventListener('change',()=>{applySidebar();paintButtons()});
document.addEventListener('DOMContentLoaded',()=>{
 const t=document.getElementById('themeBtn'),c=document.getElementById('collapseBtn');
 if(t)t.addEventListener('click',()=>{theme=next(theme);save(THEME_KEY,theme==='system'?null:theme);applyTheme();paintButtons()});
 if(c)c.addEventListener('click',()=>{collapsedPref=!root.classList.contains('sidebar-collapsed');save(SIDEBAR_KEY,collapsedPref?'collapsed':'expanded');applySidebar();paintButtons()});
 paintButtons();
});
})();
