'use strict';
(() => {
const BUILD='priority-20261023-2';
let scope='mine',offset=0,report=null,serial=0,deadlineTask=null,diagnostic=null;
const nav=document.querySelector('nav'),todoButton=document.createElement('button');
todoButton.dataset.view='todo';todoButton.innerHTML='<span class="nav-icon">☑</span><span>我的待办</span>';
nav.prepend(todoButton);
const panel=document.createElement('section');panel.id='todo-view';panel.className='card priority-panel';panel.hidden=true;
panel.innerHTML=`<div class="section-title"><div><div class="eyebrow">MY WORK</div><h2>我的待办</h2></div><button id="todo-refresh" type="button">刷新待办</button></div><p class="muted">汇总各项目中本人认领的任务、退回修改和可审核稿件。截止时间按北京时间显示，组长及本项目负责人可在任务详情设置。</p><div class="toolbar"><label id="todo-scope-label" hidden>范围<select id="todo-scope"><option value="mine">我的待办</option><option value="team">全组待办</option></select></label></div><p id="todo-message" role="status"></p><div id="todo-summary" class="stats"></div><div id="todo-list"></div><div class="toolbar"><button id="todo-prev" type="button">上一页</button><span id="todo-page"></span><button id="todo-next" type="button">下一页</button></div>`;
$('#workspace').after(panel);
const dateText=v=>v?new Date(v).toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',hour12:false}):'未设置';
function paint(r){
 $('#todo-scope-label').hidden=!r.owner;$('#todo-scope').value=scope;
 $('#todo-summary').innerHTML=[['当前范围待办',r.summary.total],['本人任务',r.summary.mine],['可审核',r.summary.review],['退回修改',r.summary.returned],['已逾期',r.summary.overdue]].map(([label,n])=>`<div class="stat"><span>${esc(label)}</span><b>${esc(n)}</b></div>`).join('');
 $('#todo-list').innerHTML=r.items.map(t=>`<article class="todo-item"><div><p class="muted small">${esc(t.project_title)} · ${esc(kinds[t.kind]||'其他')}</p><h3>${esc(t.title)}</h3><div class="todo-tags"><span class="badge ${esc(t.state)}">${esc(states[t.state]||t.state)}</span>${t.returned?'<span class="todo-alert">退回修改</span>':''}${t.needs_review?'<span class="todo-tag">等待你审核</span>':''}${t.overdue?'<span class="todo-alert">已逾期</span>':''}</div><p class="muted">负责人：${esc(t.assignee_name||'待认领')}<br>截止：${esc(dateText(t.due_at))}${t.due_at?'（北京时间）':''}</p></div><button type="button" data-todo-task="${esc(t.id)}">打开任务 →</button></article>`).join('')||empty(scope==='team'?'全组暂无待办任务。':'暂无本人任务或待审核稿件。可在任务工作台认领任务。');
 $('#todo-page').textContent=`第 ${Math.floor(offset/50)+1} 页 · 共 ${r.summary.total} 项`;$('#todo-prev').disabled=offset===0;$('#todo-next').disabled=offset+50>=r.summary.total;
 panel.querySelectorAll('[data-todo-task]').forEach(b=>b.onclick=()=>run(async()=>{b.disabled=true;try{const item=report?.items.find(t=>t.id===b.dataset.todoTask);if(!item)throw Error('请刷新待办后重试');project=item.project_id;switchView('board');await load();await openTask(item.id);}finally{b.disabled=false}},'#notice'));
}
async function refreshTodo(){
 if(!token||!data?.me)return;
 const sequence=++serial,session=SessionFence.capture();$('#todo-message').textContent='正在汇总待办…';
 const value=await rpc('st_my_work',{p_scope:scope,p_offset:offset});session.check();
 if(sequence!==serial||view!=='todo')return;
 report=value;paint(value);$('#todo-message').textContent='已更新。此页不持续轮询，操作后可点击刷新。';
}
$('#todo-refresh').onclick=()=>run(refreshTodo,'#todo-message');
$('#todo-scope').onchange=()=>{scope=$('#todo-scope').value;offset=0;run(refreshTodo,'#todo-message');};
$('#todo-prev').onclick=()=>{offset=Math.max(0,offset-50);run(refreshTodo,'#todo-message');};
$('#todo-next').onclick=()=>{offset+=50;run(refreshTodo,'#todo-message');};
const beforeSwitch=switchView;
switchView=function(next){
 panel.hidden=true;
 beforeSwitch(next==='todo'?'board':next);
 if(next!=='todo'||!token||!data?.me||membershipState!=='active')return;
 view='todo';$('#heading').textContent='我的待办';$('#workspace').hidden=true;panel.hidden=false;
 document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active',b.dataset.view==='todo'));
 run(refreshTodo,'#todo-message');
};
todoButton.onclick=()=>switchView('todo');
const beforeLoad=load;load=async function(){await beforeLoad();if(view==='todo'&&token&&data?.me)await refreshTodo();};

const dueDialog=document.createElement('dialog');dueDialog.id='deadline-dialog';
dueDialog.innerHTML='<form id="deadline-form"><h2>设置任务截止时间</h2><p id="deadline-name"></p><label>截止时间（北京时间）<input id="deadline-value" type="datetime-local"></label><p class="muted">留空并保存可取消截止时间。修改会留下审计记录。</p><p id="deadline-message" role="status"></p><div class="toolbar"><button id="deadline-close" type="button">返回</button><button id="deadline-save" type="submit" class="primary">保存截止时间</button></div></form>';
document.body.append(dueDialog);$('#deadline-close').onclick=()=>dueDialog.close();
const beforeOpen=openTask;
openTask=async function(id){
 const session=SessionFence.capture(),context=await rpc('st_task_work_context',{p_task:id});session.check();
 if(!data||context.task.project_id!==project)throw Error('项目已切换，请重新打开任务');
 data.tasks=data.tasks.filter(t=>t.id!==id);data.tasks.push(context.task);data.claims=data.claims.filter(c=>c.task_id!==id);if(context.claim)data.claims.push(context.claim);
 await beforeOpen(id);session.check();
 const due=document.createElement('p');due.className='muted';due.textContent='截止：'+dateText(context.task.due_at)+(context.task.due_at?'（北京时间）':'');$('#task-actions').append(due);
 if(data.can_manage&&['open','claimed','submitted'].includes(context.task.state)){
  const b=document.createElement('button');b.type='button';b.textContent='设置截止时间';b.onclick=()=>{deadlineTask=id;$('#deadline-name').textContent=context.task.title;$('#deadline-message').textContent='';$('#deadline-value').value=context.task.due_at?new Date(Date.parse(context.task.due_at)+8*3600000).toISOString().slice(0,16):'';dueDialog.showModal();};$('#task-actions').append(b);
 }
};
$('#deadline-form').onsubmit=e=>{e.preventDefault();run(async()=>{const session=SessionFence.capture(),id=deadlineTask,raw=$('#deadline-value').value;$('#deadline-save').disabled=true;try{const due=raw?new Date(raw+':00+08:00').toISOString():null;await rpc('st_task_deadline',{p_task:id,p_due:due});session.check();dueDialog.close();await load();await openTask(id);$('#dialog-message').textContent='截止时间已保存。';}finally{$('#deadline-save').disabled=false;}},'#deadline-message');};

// Diagnostics contain fixed categories and random references only, never exception
// messages, request bodies, headers, query strings, form fields or local storage.
const beforeRequest=request;request=async function(path,...args){try{return await beforeRequest(path,...args);}catch(error){if(error?.name!=='AbortError')diagnostic={reference:crypto.randomUUID(),time:new Date().toISOString(),category:path.startsWith('/auth/')?'认证请求':'业务请求'};throw error;}};
window.addEventListener('error',()=>{diagnostic={reference:crypto.randomUUID(),time:new Date().toISOString(),category:'页面脚本'};});
const feedbackButton=document.createElement('button');feedbackButton.type='button';feedbackButton.id='feedback-open';feedbackButton.innerHTML='<span class="nav-icon">✎</span><span>反馈问题</span>';nav.append(feedbackButton);
const feedback=document.createElement('dialog');feedback.id='feedback-dialog';feedback.className='feedback-dialog';
feedback.innerHTML='<form id="feedback-form"><h2>内测问题反馈</h2><p class="muted">说明刚才做了什么、预期结果和实际现象。不要填写密码、验证码、密钥或未公开稿件。生成后先核对，再自行发给组长；本页不会自动上传或发送。</p><label>问题类型<select id="feedback-kind"><option>任务与审核</option><option>视频上传</option><option>云端字幕</option><option>账号登录</option><option>贡献与积分</option><option>其他</option></select></label><label>问题说明<textarea id="feedback-description" rows="4" maxlength="2000" placeholder="操作步骤、预期结果、实际出现的问题"></textarea></label><button id="feedback-preview" type="button">生成 / 更新反馈摘要</button><label>核对后复制<textarea id="feedback-packet" rows="10" readonly></textarea></label><p id="feedback-message" role="status"></p><div class="toolbar"><button id="feedback-close" type="button">返回</button><button id="feedback-copy" class="primary" type="button">复制反馈摘要</button></div></form>';
document.body.append(feedback);
function packet(){return ['灯塔字幕札记 · 内测反馈','页面版本：'+BUILD,'生成时间：'+new Date().toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',hour12:false})+'（北京时间）','当前页面：'+(!token&&view!=='guide'?'登录页':token&&membershipState!=='active'?'成员申请':{todo:'我的待办',board:'任务工作台',credits:'贡献与积分',members:'成员管理',guide:'使用说明'}[view]||'登录页'),'问题类型：'+$('#feedback-kind').value,'问题说明：'+($('#feedback-description').value.trim()||'（待补充）'),diagnostic?'错误参考：'+diagnostic.reference+'\n发生时间：'+diagnostic.time+'\n请求类别：'+diagnostic.category:'错误参考：暂无已记录的请求或脚本错误','诊断摘要不包含账号口令、视频链接、字幕正文或原始错误信息。'].join('\n');}
function updatePacket(){$('#feedback-packet').value=packet();$('#feedback-message').textContent='请核对问题说明。可复制后通过 QQ 私聊发给组长。';}
feedbackButton.onclick=()=>{$('#feedback-message').textContent='';$('#feedback-packet').value='';feedback.showModal();};
$('#feedback-preview').onclick=updatePacket;$('#feedback-form').onsubmit=e=>e.preventDefault();
$('#feedback-copy').onclick=async()=>{if(!$('#feedback-packet').value){updatePacket();$('#feedback-message').textContent='摘要已生成，请先核对，再次点击复制。';return;}try{await navigator.clipboard.writeText($('#feedback-packet').value);$('#feedback-message').textContent='已复制，请自行发给组长。';}catch{$('#feedback-packet').focus();$('#feedback-packet').select();$('#feedback-message').textContent='浏览器未允许自动复制，请长按或手动复制上方摘要。';}};
function clearFeedback(){$('#feedback-form').reset();$('#feedback-packet').value='';$('#feedback-message').textContent='';}
$('#feedback-close').onclick=()=>feedback.close();feedback.addEventListener('close',clearFeedback);
$('#feedback-description').addEventListener('input',()=>{$('#feedback-packet').value='';});$('#feedback-kind').addEventListener('change',()=>{$('#feedback-packet').value='';});
const beforeLogout=logout;logout=function(){serial++;report=null;scope='mine';offset=0;diagnostic=null;deadlineTask=null;panel.hidden=true;dueDialog.close();feedback.close();clearFeedback();for(const id of ['todo-summary','todo-list'])$('#'+id).replaceChildren();$('#todo-message').textContent='';beforeLogout();};$('#logout').onclick=logout;
const guide=document.createElement('p');guide.textContent='我的待办：集中查看本人任务、退回修改及可审核稿件，组长可切换全组待办。云端结果通知已启用，机器人会在每天北京时间00:00、07:00、12:00、16:00检查完成、失败或需核对的任务，并私聊组长，不会自动重试模型。遇到内测问题可点击“反馈问题”，核对并复制摘要后自行发送。';$('#guide-view').append(guide);
const resultHint=document.querySelector('#cloud-panel > p.muted');if(resultHint)resultHint.textContent+=' 云端任务完成、失败或需要核对时，也会在下一检查时段私聊组长；结果不明时先核对再决定是否重新执行。';
})();
