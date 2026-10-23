'use strict';
(()=>{
 const sections=new Set(['guide-cloud-identity','guide-pc','guide-android','guide-cloud-flow','guide-collaboration']);
 function openGuide(target){
  if(!sections.has(target))return;
  const section=document.getElementById(target);if(!section)return;
  switchView('guide');
  if(section.tagName==='DETAILS')section.open=true;
  section.scrollIntoView({block:'start'});section.focus({preventScroll:true});
 }
 document.querySelectorAll('[data-guide-target]').forEach(button=>button.onclick=()=>openGuide(button.dataset.guideTarget));
 const helpAnchor=document.querySelector('#cloud-worker-settings .cloud-worker-guide');
 if(helpAnchor){
  const button=document.createElement('button');button.type='button';button.id='cloud-worker-help';
  button.textContent='密钥怎么用（PC / 安卓）';button.onclick=()=>openGuide('guide-cloud-identity');helpAnchor.after(button);
 }
 const target=location.hash.slice(1);
 if(target==='guide')switchView('guide');else if(sections.has(target))openGuide(target);
})();
