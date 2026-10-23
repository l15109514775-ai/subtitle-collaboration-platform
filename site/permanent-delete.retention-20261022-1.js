'use strict';
// Only the pinned account receives controls. Every operation is checked again by PostgreSQL.
const purgeDialog=document.createElement('dialog');purgeDialog.id='permanent-delete-dialog';
purgeDialog.innerHTML=`<form id="permanent-delete-form"><h2>永久删除</h2><p id="permanent-delete-target"></p><p id="permanent-delete-summary"></p><p>这会永久清除目标文件和交付正文，无法从回收站恢复。必要的审计、贡献和积分凭据继续保留。原视频至少保留7天，执行中的任务不可删除。</p><label>输入“永久删除 完整名称”<input id="permanent-delete-confirmation" autocomplete="off" required></label><label><input id="permanent-delete-consent" type="checkbox" required>我确认永久删除，并理解完成后不可恢复。</label><p>确认后进入删除队列，在北京时间07:00、12:00、16:00、00:00的检查中执行。关闭网页不会取消已提交的删除。</p><p id="permanent-delete-message" role="status"></p><div class="toolbar"><button id="permanent-delete-close" type="button">返回</button><button id="permanent-delete-submit" type="submit" class="danger" disabled>确认永久删除</button></div></form>`;
document.body.append(purgeDialog);
let purgeTarget=null,purgeBusy=false;
function purgeValidation(){const expected=purgeTarget?'永久删除 '+purgeTarget.title:'';$('#permanent-delete-submit').disabled=purgeBusy||!purgeTarget?.eligible||$('#permanent-delete-confirmation').value!==expected||!$('#permanent-delete-consent').checked;}
$('#permanent-delete-confirmation').addEventListener('input',purgeValidation);$('#permanent-delete-consent').addEventListener('change',purgeValidation);
$('#permanent-delete-close').onclick=()=>{if(!purgeBusy)purgeDialog.close();};
async function openPermanentDelete(kind,id){
 const session=SessionFence.capture();const v=await rpc('st_purge_preview',{p_kind:kind,p_target:id});session.check();
 const eligible=!v.busy&&(!v.not_before||new Date(v.not_before)<=new Date())&&!['queued','deleting','completed'].includes(v.state);
 purgeTarget={...v,eligible};$('#permanent-delete-form').reset();
 $('#permanent-delete-target').textContent=v.title;
 $('#permanent-delete-summary').textContent=`将处理 ${v.files} 个存储对象，合计 ${MediaFiles.bytes(Number(v.bytes))}。`+(v.not_before?' 最早可删除：'+new Date(v.not_before).toLocaleString('zh-CN')+'。':'')+(v.busy?'云任务仍在处理或等待结果核对，请先处理任务状态。':'')+(v.state?'当前删除状态：'+v.state:'');
 $('#permanent-delete-message').textContent=eligible?'请核对范围后输入完整名称。':'当前不能永久删除：仍在保留期、任务未停止，或已进入删除流程。';
 purgeValidation();purgeDialog.showModal();
}
$('#permanent-delete-form').onsubmit=e=>{e.preventDefault();if(purgeBusy||$('#permanent-delete-submit').disabled)return;run(async()=>{
 const session=SessionFence.capture(),target=purgeTarget;purgeBusy=true;purgeValidation();$('#permanent-delete-close').disabled=true;
 try{await rpc('st_purge_begin',{p_kind:target.kind,p_target:target.id,p_confirmation:$('#permanent-delete-confirmation').value});session.check();purgeDialog.close();await showTrash();$('#trash-message').textContent='永久删除已登记，将在下一个检查时段执行；已锁定恢复。';}
 finally{purgeBusy=false;$('#permanent-delete-close').disabled=false;purgeValidation();}
},'#permanent-delete-message');};
const baseTrashForPurge=showTrash;
showTrash=async function(){
 await baseTrashForPurge();const session=SessionFence.capture();const info=await rpc('st_purge_console');session.check();
 if(!info.allowed)return;
 document.querySelectorAll('[data-restore]').forEach(restore=>{
  const kind=restore.dataset.restoreKind,id=restore.dataset.restore;
  const state=(info.jobs||[]).find(j=>j.kind===kind&&j.target_id===id)?.state;
  if(['queued','deleting','completed'].includes(state)){restore.hidden=true;const text=document.createElement('span');text.textContent=state==='queued'?'等待永久删除':state==='deleting'?'正在永久删除':'已永久删除';restore.parentElement.append(text);return;}
  if(state==='blocked'){restore.hidden=true;const text=document.createElement('span');text.textContent='删除范围变化，需重新核对并确认';restore.parentElement.append(text);}
  const button=document.createElement('button');button.type='button';button.className='danger';button.textContent='永久删除';button.dataset.permanentDelete=id;
  button.onclick=()=>run(()=>openPermanentDelete(kind,id),'#trash-message');restore.parentElement.append(button);
 });
};
const logoutBeforePurge=logout;
logout=function(){purgeTarget=null;purgeDialog.close();logoutBeforePurge();};$('#logout').onclick=logout;
