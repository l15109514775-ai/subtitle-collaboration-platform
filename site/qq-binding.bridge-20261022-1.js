'use strict';
// Loaded after existing membership/project modules; no browser session is shared
// with QQ, and no gateway credential is shipped in website assets.
(()=>{
 const baseLoad=load,baseLogout=logout;
 const panel=document.createElement('section');panel.className='card';panel.id='qq-binding';
 panel.innerHTML='<h2>QQ 账号绑定</h2><p>先私聊「字幕助手」，发送「字幕绑定」。把它回复的五分钟有效绑定码粘贴到这里。</p><p>绑定后，此 QQ 可私聊查询你有权访问的项目与任务；不会获得认领、审核或积分操作权限。</p><form id="qq-bind-form"><label>机器人私聊中的绑定码<input name="code" required pattern="[0-9a-f]{64}" minlength="64" maxlength="64" autocomplete="off" spellcheck="false"></label><label><input name="consent" type="checkbox" required>我确认该绑定码来自我本人的 QQ，并允许此 QQ 查询我有权访问的项目和任务。</label><button class="primary">确认绑定本人 QQ</button></form><p id="qq-bind-status" role="status"></p><div id="qq-links"></div>';
 $('#members-view').prepend(panel);
 const status=message=>{$('#qq-bind-status').textContent=message;};
 async function refresh(){
  const session=SessionFence.capture(),v=await rpc('st_qq_link_status');session.check();
  $('#qq-links').replaceChildren();
  for(const link of v.links){
   const row=document.createElement('div'),p=document.createElement('p'),b=document.createElement('button');
   p.textContent='已绑定 QQ 机器人 '+link.app_id+(link.active?'':'（连接已停用）');
   b.type='button';b.textContent='解除此 QQ 绑定';
   b.onclick=async()=>{b.disabled=true;try{await rpc('st_qq_link_remove',{p_gateway:link.gateway});await refresh();status('已解除绑定。');}catch(e){status(e.message);}finally{b.disabled=false;}};
   row.append(p,b);$('#qq-links').append(row);
  }
 }
 load=async function(...args){await baseLoad(...args);if(data?.me)try{await refresh();}catch(e){status('QQ 绑定状态暂时无法读取，请稍后刷新。');}};
 logout=function(...args){$('#qq-bind-form').reset();$('#qq-links').replaceChildren();status('');return baseLogout(...args);};
 if($('#logout'))$('#logout').onclick=logout;
 $('#qq-bind-form').onsubmit=async e=>{
  e.preventDefault();const form=e.currentTarget,button=form.querySelector('button'),code=form.elements.code.value.trim();
  if(!form.reportValidity())return;button.disabled=true;status('正在确认绑定…');
  try{const session=SessionFence.capture();await rpc('st_qq_link_confirm',{p_code:code});session.check();form.reset();await refresh();status('绑定成功。现在可私聊机器人发送「我的任务」或「待领任务」。');}
  catch(error){status(error.message);}finally{button.disabled=false;}
 };
})();
