'use strict';
let workCatalog={projects:[],tasks:[]},catalogKind='all';
const projectWorkflowLoad=load,projectWorkflowLogout=logout;
const projectControlsSwitch=switchView;
switchView=function(next){projectControlsSwitch(next);const target=$(view==='board'?'#current-project-controls':'#shared-project-controls');target.append($('#project-toolbar'))};
load=async function(){await projectWorkflowLoad();workCatalog=await rpc('st_work_catalog');$('#new-project').hidden=false;renderWorkCatalog()};
logout=function(){workCatalog={projects:[],tasks:[]};catalogKind='all';$('#unclaimed-projects').replaceChildren();$('#open-kind-counts').replaceChildren();$('#catalog-tasks').replaceChildren();projectWorkflowLogout()};$('#logout').onclick=logout;
function renderWorkCatalog(){
 const free=workCatalog.projects.filter(p=>!p.lead_member_id);
 $('#unclaimed-project-count').textContent=free.length;
 $('#unclaimed-projects').innerHTML=free.map(p=>`<article class="card project-claim-card"><span class="tag">${p.origin==='codex'?'Codex 发起 · 等待负责人':'等待负责人'}</span><h3>${esc(p.title)}</h3><p class="muted">${esc(p.description||'认领后成为该项目负责人。')}</p><p>${workCatalog.tasks.filter(t=>t.project_id===p.id).length} 项任务待认领</p><button class="primary" data-claim-project="${esc(p.id)}">认领项目并担任负责人</button></article>`).join('')||empty('目前没有等待负责人认领的项目。');
 const entries=[['all','全部',workCatalog.tasks.length],...Object.entries(kinds).map(([key,label])=>[key,label,workCatalog.tasks.filter(t=>t.kind===key).length])];
 $('#open-kind-counts').innerHTML=entries.map(([key,label,n])=>`<button class="kind-count${catalogKind===key?' selected':''}" data-catalog-kind="${esc(key)}" aria-pressed="${catalogKind===key}"><span>${esc(label)}</span><b>${n}</b><small>未认领</small></button>`).join('');
 $('#catalog-list-title').textContent=(catalogKind==='all'?'全部':kinds[catalogKind])+'未认领任务';
 const tasks=workCatalog.tasks.filter(t=>catalogKind==='all'||t.kind===catalogKind);
 $('#catalog-tasks').innerHTML=tasks.map(t=>{const p=workCatalog.projects.find(p=>p.id===t.project_id);return `<tr><td><strong>${esc(t.title)}</strong><p class="task-description">${esc(t.description)}</p></td><td>${esc(p?.title||'项目')}</td><td>${esc(kinds[t.kind]||'其他')}</td><td><button data-catalog-claim="${esc(t.id)}">认领任务${p&&!p.lead_member_id?' · 担任负责人':''}</button></td></tr>`}).join('')||`<tr><td colspan="4">${empty('此类暂无未认领任务。')}</td></tr>`;
 document.querySelectorAll('[data-catalog-kind]').forEach(b=>b.onclick=()=>{catalogKind=b.dataset.catalogKind;renderWorkCatalog();$('#catalog-list').scrollIntoView({behavior:'smooth',block:'start'});$('#catalog-list-title').focus({preventScroll:true})});
 document.querySelectorAll('[data-claim-project]').forEach(b=>b.onclick=()=>run(async()=>{b.disabled=true;try{await rpc('st_claim_project',{p_project:b.dataset.claimProject});project=b.dataset.claimProject;await load();notify('项目已认领，你现在是该项目负责人。')}finally{b.disabled=false}}));
 document.querySelectorAll('[data-catalog-claim]').forEach(b=>b.onclick=()=>run(async()=>{const task=workCatalog.tasks.find(t=>t.id===b.dataset.catalogClaim);if(!task)return;b.disabled=true;try{await rpc('st_claim_task',{p_task:task.id});project=task.project_id;await load();notify('已认领任务并加入项目。');if(data.tasks.some(t=>t.id===task.id))await openTask(task.id)}finally{b.disabled=false}}));
}
const projectWorkflowCreate=create;
create=function(mode){projectWorkflowCreate(mode);$('#project-origin-label').hidden=mode!=='project'||!data.me.owner;updateCodexProjectName()};
function updateCodexProjectName(){
 const codex=createMode==='project'&&$('#project-origin').value==='codex';$('#codex-timestamp-label').hidden=!codex;$('#codex-timestamp').required=codex;$('#codex-name-preview').hidden=!codex;$('#create-name-label').textContent=codex?'直播标题':'名称';
 if(codex){const title=$('#create-form input[name="title"]').value.trim(),stamp=$('#codex-timestamp').value.trim();$('#codex-name-preview').textContent=`项目名称：${title||'直播标题'}｜${stamp||'时间戳'}｜AI字幕初稿`}
}
$('#project-origin').onchange=updateCodexProjectName;$('#codex-timestamp').oninput=updateCodexProjectName;$('#create-form input[name="title"]').addEventListener('input',updateCodexProjectName);
const projectWorkflowSubmit=$('#create-form').onsubmit;
$('#create-form').onsubmit=e=>{
 if(createMode!=='project'||$('#project-origin').value!=='codex'){projectWorkflowSubmit(e);return}
 e.preventDefault();submitForm(e.currentTarget,async f=>{const created=await rpc('st_create_named_codex_project',{p_stream_title:f.get('title').trim(),p_timestamp:f.get('timestamp').trim(),p_description:f.get('description')});project=created.project_id;await load();$('#create-dialog').close();notify('Codex 项目已按直播标题和时间戳命名，并创建校对任务。')},'#create-message');
};
