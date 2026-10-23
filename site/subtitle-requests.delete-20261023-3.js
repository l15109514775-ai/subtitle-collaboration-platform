'use strict';
let subtitleRequests=[],subtitleUploading=false,showDeletedSubtitleRequests=false;
const requestedIntake=new URLSearchParams(location.search).get('request');
let focusedIntake=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(requestedIntake||'')?requestedIntake:null;
const requestStates={uploading:'上传未完成',pending:'待组长审批',approved:'已批准',rejected:'已驳回',withdrawn:'已撤回'};
const requestPanel=document.createElement('section');requestPanel.id='subtitle-request-panel';requestPanel.className='card';
requestPanel.innerHTML=`<div class="section-heading"><div><div class="eyebrow">SUBTITLE REQUESTS</div><h2>字幕申请与审批</h2></div><button id="subtitle-request-refresh" type="button">刷新申请</button></div>
<p class="muted">组员上传登记 → 组长批准额度 → 组长复制指令到 Codex Cloud → 字幕自动回传。登记和批准本身不会调用识别或翻译接口。</p>
<p class="muted">QQ机器人按北京时间每天07:00、12:00、16:00、00:00集中检查。新申请在已绑定群@组长并私聊提醒；审批通过后的执行指令仅私聊发送，仍需组长检查后手动启动Codex Cloud。登记草稿不会通知。原视频上传完成后保留7天，到期后在下一检查时段自动清理，字幕与报告继续保留；执行中或结果待核对的任务暂缓清理。</p>
<details><summary>登记字幕申请</summary><p class="muted">单视频不超过20分钟、1GB。每人最多3项待处理申请；上传中断不支持续传，可撤回后重传。等待审批时不生成云端执行任务。</p>
<form id="subtitle-request-form"><label>直播标题<input id="subtitle-request-title" required maxlength="125"></label><label>时间段<input id="subtitle-request-timestamp" required maxlength="40" placeholder="例如 01:00–21:00"></label><label>原视频<input id="subtitle-request-file" type="file" accept=".mp4,.mkv,.mov,.webm" required></label><label>申请说明<textarea id="subtitle-request-notes" maxlength="1000" rows="2" placeholder="字幕需求、注意事项"></textarea></label><button class="primary" type="submit">上传并提交审批</button><button id="subtitle-request-abort" type="button" hidden>停止上传</button><p id="subtitle-request-upload-status" role="status"></p></form></details>
<button id="subtitle-request-deleted" type="button">已删除申请</button><button id="subtitle-request-all" type="button" hidden>查看全部申请</button><div id="subtitle-request-list"></div><p id="subtitle-request-message" role="status"></p>`;
$('#cloud-panel').before(requestPanel);
const requestDialog=document.createElement('dialog');requestDialog.id='subtitle-approval-dialog';
requestDialog.innerHTML=`<form id="subtitle-approval-form"><h2>审批字幕申请</h2><p id="subtitle-approval-summary"></p><label>审批结论<select id="subtitle-approval-decision"><option value="approved">批准并生成执行任务</option><option value="rejected">驳回申请</option></select></label><div id="subtitle-approval-budget"><label>云执行身份<select id="subtitle-approval-worker"></select></label><label>视频时长上限（秒）<input id="subtitle-approval-seconds" type="number" min="1" max="1200" value="1200"></label><label>文字请求上限<input id="subtitle-approval-text" type="number" min="1" max="400" value="400"></label><label>千问识别请求上限<input id="subtitle-approval-qwen" type="number" min="1" max="40" value="40"></label><label><input id="subtitle-approval-consent" type="checkbox">我批准此申请在上述额度内调用接口；实际费用以供应商账单为准。</label><p class="muted">批准后仍需人工粘贴指令启动。素材访问授权约23小时；未启动且授权过期时，可刷新素材授权，无需重传视频。</p></div><label>审批意见<textarea id="subtitle-approval-note" rows="2" maxlength="300"></textarea></label><div class="toolbar"><button id="subtitle-approval-close" type="button">返回</button><button class="primary" type="submit">确认审批</button></div><p id="subtitle-approval-message" role="status"></p></form>`;
document.body.append(requestDialog);
const requestDeleteDialog=document.createElement('dialog');requestDeleteDialog.id='request-delete-dialog';
requestDeleteDialog.innerHTML='<h2>删除字幕申请</h2><p id="request-delete-title"></p><p>删除申请记录后从列表隐藏，可在“已删除申请”中恢复。原视频仍按7天保留规则清理，字幕与报告不受影响。</p><div class="toolbar"><button id="request-delete-cancel" type="button">返回</button><button id="request-delete-confirm" type="button" class="danger">确认删除申请</button></div>';
document.body.append(requestDeleteDialog);let requestDeleteChoice=null;
function closeRequestDelete(confirmed=false){requestDeleteDialog.close();requestDeleteChoice?.(confirmed);requestDeleteChoice=null;}
function confirmRequestDelete(id){$('#request-delete-title').textContent=subtitleRequests.find(r=>r.id===id)?.stream_title||'已撤回申请';requestDeleteDialog.showModal();return new Promise(resolve=>{requestDeleteChoice=resolve;});}
$('#request-delete-cancel').onclick=()=>closeRequestDelete(false);$('#request-delete-confirm').onclick=()=>closeRequestDelete(true);
requestDeleteDialog.addEventListener('cancel',e=>{e.preventDefault();closeRequestDelete(false);});
let approvalRequest=null,requestUploadAbort=null;
function requestStatus(text){$('#subtitle-request-upload-status').textContent=text;}
async function loadSubtitleRequests(){const session=SessionFence.capture();const response=showDeletedSubtitleRequests?await rpc('st_subtitle_requests_trash'):await rpc('st_subtitle_requests_view',{p_request:focusedIntake});session.check();const rows=response.requests;const retention=rows.length?await rpc('st_source_retention_status',{p_requests:rows.map(r=>r.id)}):[];session.check();subtitleRequests=rows.map(r=>{const s=retention.find(s=>s.id===r.id);return {...r,source_delete_after:s?.delete_after,source_cleaned_at:s?.cleaned_at};});$('#subtitle-request-all').hidden=!focusedIntake||showDeletedSubtitleRequests;$('#subtitle-request-deleted').textContent=showDeletedSubtitleRequests?'返回申请列表':'已删除申请';renderSubtitleRequests();}
function subtitleSourceExpired(r){return !!r.source_cleaned_at||!!(r.source_delete_after&&new Date(r.source_delete_after)<=new Date());}
$('#subtitle-request-deleted').onclick=()=>run(async()=>{showDeletedSubtitleRequests=!showDeletedSubtitleRequests;await loadSubtitleRequests();},'#subtitle-request-message');
$('#subtitle-request-all').onclick=()=>run(async()=>{focusedIntake=null;await loadSubtitleRequests();},'#subtitle-request-message');
function renderSubtitleRequests(){
 const owner=!!data?.me.owner;
 $('#subtitle-request-list').innerHTML=subtitleRequests.map(r=>`<article class="version" id="subtitle-request-${esc(r.id)}"><header><b>${esc(r.stream_title)}｜${esc(r.timestamp_label)}</b><span class="badge">${esc(requestStates[r.state])}</span></header><p class="muted">${esc(subtitleSourceExpired(r)&&r.state==='pending'?'原视频保留期已满，请撤回后重新上传申请。':CloudJobTools.requestHint(r))}</p><p>${esc(r.submitter)} · ${esc(r.declared_seconds)}秒 · ${esc(MediaFiles.bytes(r.byte_size))}</p><p class="muted">${esc(r.file_name)}${r.notes?' · '+esc(r.notes):''}</p>${r.review_note?'<p>审批意见：'+esc(r.review_note)+'</p>':''}${r.job_id?'<p>云任务：'+esc(cloudStates[r.job_state]||r.job_state)+'<br><small>'+esc(r.job_id)+'</small></p>':''}${r.source_delete_after?'<p class="muted">原视频：'+(r.source_cleaned_at?'已清理，字幕与报告继续保留。':subtitleSourceExpired(r)?'保留期已满，待检查时段清理；执行中或待核对任务暂缓。':'保留至 '+esc(new Date(r.source_delete_after).toLocaleString('zh-CN'))+'，之后在检查时段自动清理。')+'</p>':''}<small>申请 ${esc(r.id)} · ${esc(new Date(r.created_at).toLocaleString('zh-CN'))}</small><div class="toolbar">${r.can_delete&&(r.state==='withdrawn'||(owner&&r.state==='approved'&&r.job_state==='cancelled'))?'<button type="button" '+(r.deleted_at?'data-request-restore':'data-request-delete')+'="'+esc(r.id)+'">'+(r.deleted_at?'恢复申请':'删除申请')+'</button>':''}${owner&&r.state==='pending'&&!subtitleSourceExpired(r)?'<button type="button" data-request-review="'+esc(r.id)+'">审批申请</button>':''}${['uploading','pending'].includes(r.state)?'<button type="button" data-request-withdraw="'+esc(r.id)+'">撤回申请</button>':''}${owner?'<button type="button" data-request-packet="'+esc(r.id)+'">复制通知摘要</button>':''}${owner&&r.state==='approved'&&r.job_state==='queued'&&!subtitleSourceExpired(r)?'<button type="button" data-request-copy="'+esc(r.id)+'">复制云端执行指令</button><button type="button" data-request-refresh="'+esc(r.id)+'">刷新素材授权</button>':''}</div>${r.state==='approved'&&r.job_state==='queued'?'<p class="muted">素材授权到期：'+esc(new Date(r.source_expires_at).toLocaleString('zh-CN'))+'；由组长手动在 Codex Cloud 发送一次执行指令。</p>':''}</article>`).join('')||empty(showDeletedSubtitleRequests?'暂无已删除申请。':'暂无字幕申请。');
 document.querySelectorAll('[data-request-delete],[data-request-restore]').forEach(b=>b.onclick=()=>run(async()=>{
  const deleting=!!b.dataset.requestDelete,id=b.dataset.requestDelete||b.dataset.requestRestore;
  const session=SessionFence.capture();if(deleting&&!await confirmRequestDelete(id))return;session.check();b.disabled=true;
  try{await rpc('st_subtitle_request_set_deleted',{p_request:id,p_deleted:deleting});session.check();await loadSubtitleRequests();$('#subtitle-request-message').textContent=deleting?'申请已删除，可在“已删除申请”中恢复。':'申请已恢复到列表，原审批与云任务状态保持不变。';}
  finally{if(b.isConnected)b.disabled=false;}
 },'#subtitle-request-message'));
 document.querySelectorAll('[data-request-review]').forEach(b=>b.onclick=()=>openSubtitleApproval(b.dataset.requestReview));
 document.querySelectorAll('[data-request-withdraw]').forEach(b=>b.onclick=()=>run(async()=>{
  if(!confirm('撤回此申请？已上传素材不会立即永久删除；撤回后不能继续审批。'))return;
  await rpc('st_subtitle_request_withdraw',{p_request:b.dataset.requestWithdraw});await loadSubtitleRequests();
 },'#subtitle-request-message'));
 document.querySelectorAll('[data-request-copy]').forEach(b=>b.onclick=()=>run(async()=>{
  const packet=await rpc('st_subtitle_request_packet',{p_request:b.dataset.requestCopy});if(!packet.instruction)throw Error('任务尚未批准、已启动、素材授权过期或执行身份不可用；请核对状态。');
  await navigator.clipboard.writeText(packet.instruction);$('#subtitle-request-message').textContent='已复制。请在现有 Codex Cloud 字幕环境新建任务，粘贴并发送一次；结果自动回传。';
 },'#subtitle-request-message'));
 document.querySelectorAll('[data-request-packet]').forEach(b=>b.onclick=()=>run(async()=>{
  const packet=await rpc('st_subtitle_request_packet',{p_request:b.dataset.requestPacket});await navigator.clipboard.writeText(SubtitleRequestTools.notification(packet));$('#subtitle-request-message').textContent='通知摘要已复制，可人工转发。自动提醒以绑定群的机器人回执为准；必要时也可人工转发。';
 },'#subtitle-request-message'));
 document.querySelectorAll('[data-request-refresh]').forEach(b=>b.onclick=()=>run(async()=>{
  b.disabled=true;try{const r=subtitleRequests.find(x=>x.id===b.dataset.requestRefresh),sources=await signSubtitleSources(r);await rpc('st_subtitle_request_refresh',{p_request:r.id,p_sources:sources});await load();$('#subtitle-request-message').textContent='已刷新素材授权；沿用同一个云任务和原批准额度，没有重置请求账本。';}finally{if(b.isConnected)b.disabled=false;}
 },'#subtitle-request-message'));
}
async function signSubtitleSources(r){
 const session=SessionFence.capture(),sources=[];
 for(const part of SubtitleRequestTools.sourceParts(r)){
  session.check();const signed=await request('/v1/storages/object/sign/subtitle-inputs/'+MediaFiles.objectPath(part.path),{expiresIn:86400});
  const url=new URL(signed.fullSignedURL||signed.signedURL,BASE);if(url.origin!==BASE)throw Error('素材授权地址不匹配');sources.push({...part,url:url.href});
 }session.check();return sources;
}
function openSubtitleApproval(id){
 const r=subtitleRequests.find(x=>x.id===id);if(!data?.me.owner||!r||r.state!=='pending')return;
 approvalRequest=r;$('#subtitle-approval-form').reset();$('#subtitle-approval-message').textContent='';$('#subtitle-approval-summary').textContent=r.submitter+' · '+r.stream_title+'｜'+r.timestamp_label+' · '+r.declared_seconds+'秒';
 $('#subtitle-approval-worker').innerHTML=cloudState.workers.filter(w=>w.active&&w.available!==false).map(w=>'<option value="'+esc(w.id)+'">'+esc(w.label)+'</option>').join('');
 $('#subtitle-approval-seconds').min=r.declared_seconds;syncSubtitleDecision();requestDialog.showModal();
}
function syncSubtitleDecision(){const approved=$('#subtitle-approval-decision').value==='approved';$('#subtitle-approval-budget').hidden=!approved;$('#subtitle-approval-budget').querySelectorAll('input,select').forEach(x=>{x.disabled=!approved;x.required=approved;});$('#subtitle-approval-note').required=!approved;}
$('#subtitle-approval-decision').onchange=syncSubtitleDecision;
$('#subtitle-approval-close').onclick=()=>requestDialog.close();
$('#subtitle-approval-form').onsubmit=e=>{e.preventDefault();const form=e.currentTarget;submitForm(form,async()=>{
 if(!approvalRequest)throw Error('请重新选择申请');const decision=$('#subtitle-approval-decision').value;
 const payload={p_request:approvalRequest.id,p_decision:decision,p_note:$('#subtitle-approval-note').value.trim()};
 if(decision==='approved'){
  if(!$('#subtitle-approval-consent').checked)throw Error('请先确认本次调用额度');
  Object.assign(payload,{p_worker:$('#subtitle-approval-worker').value,p_max_seconds:Number($('#subtitle-approval-seconds').value),p_max_text:Number($('#subtitle-approval-text').value),p_max_secondary:Number($('#subtitle-approval-qwen').value),p_sources:await signSubtitleSources(approvalRequest)});
  CloudLimits.validate({seconds:payload.p_max_seconds,text:payload.p_max_text,qwen:payload.p_max_secondary});
 }
 await rpc('st_subtitle_request_decide',payload);requestDialog.close();await load();$('#subtitle-request-message').textContent=decision==='approved'?'已批准，云端尚未启动。请复制执行指令并在 Codex Cloud 中发送。':'申请已驳回。';
 },'#subtitle-approval-message');};
async function subtitleVideoDuration(file,signal){
 return new Promise((resolve,reject)=>{
  const video=document.createElement('video'),url=URL.createObjectURL(file);let timer;
  const cleanup=()=>{clearTimeout(timer);signal?.removeEventListener('abort',abort);video.removeAttribute('src');video.load();URL.revokeObjectURL(url);};
  const finish=(error,value)=>{video.onloadedmetadata=video.onerror=null;cleanup();error?reject(error):resolve(value);};
  const abort=()=>finish(Error('上传已停止'));
  video.preload='metadata';video.onloadedmetadata=()=>{try{const seconds=SubtitleRequestTools.duration(video.duration);finish(null,seconds);}catch(error){finish(error);}};
  video.onerror=()=>finish(Error('浏览器无法读取视频时长，请使用可播放的 MP4/WebM 文件'));
  if(signal?.aborted){abort();return;}signal?.addEventListener('abort',abort,{once:true});timer=setTimeout(()=>finish(Error('读取视频时长超时，请检查文件格式')),15000);video.src=url;
 });
}
$('#subtitle-request-abort').onclick=()=>requestUploadAbort?.abort();
$('#subtitle-request-form').onsubmit=async e=>{
 e.preventDefault();if(subtitleUploading)return;const form=e.currentTarget,button=form.querySelector('button[type="submit"]'),session=SessionFence.capture();
 subtitleUploading=true;requestUploadAbort=new AbortController();const signal=AbortSignal.any([session.signal,requestUploadAbort.signal]);button.disabled=true;$('#subtitle-request-abort').hidden=false;let prepared=null,submitted=false;
 try{
  const file=$('#subtitle-request-file').files[0];if(!file||file.size<1||file.size>1073741824)throw Error('请选择1GB以内的原视频');
  requestStatus('正在读取视频时长和格式…');const seconds=await subtitleVideoDuration(file,signal),mime=MediaFiles.mime('clip',file.name,file.size,new Uint8Array(await file.slice(0,32).arrayBuffer()));
  const hash=await MediaFiles.hash(file,p=>requestStatus('校验视频 '+Math.round(p*100)+'%'),signal);session.check();if(signal.aborted)throw Error('上传已停止');
  prepared=await rpc('st_subtitle_request_prepare',{p_title:$('#subtitle-request-title').value.trim(),p_timestamp:$('#subtitle-request-timestamp').value.trim(),p_notes:$('#subtitle-request-notes').value.trim(),p_filename:file.name,p_mime:mime,p_size:file.size,p_sha256:hash,p_seconds:seconds});
  for(let i=0;i<prepared.part_count;i++){
   session.check();if(signal.aborted)throw Error('上传已停止');const part=file.slice(i*prepared.chunk_size,Math.min(file.size,(i+1)*prepared.chunk_size)),path=prepared.object_prefix+'/part-'+String(i).padStart(4,'0');
   requestStatus('上传视频 '+(i+1)+' / '+prepared.part_count+' 片…');
   const response=await fetch(BASE+'/v1/storages/object/subtitle-inputs/'+MediaFiles.objectPath(path),{method:'POST',signal,credentials:'omit',redirect:'error',headers:{Authorization:'Bearer '+token,'Content-Type':mime},body:part});session.check();if(!response.ok)throw Error('视频上传未完成（'+response.status+'）');
  }
  session.check();if(signal.aborted)throw Error('上传已停止');await rpc('st_subtitle_request_submit',{p_request:prepared.request_id});submitted=true;showDeletedSubtitleRequests=false;
  requestStatus('视频已登记，等待组长审批。尚未调用识别、翻译，也没有启动 Codex。');focusedIntake=null;form.reset();await loadSubtitleRequests();
 }catch(error){requestStatus((signal.aborted?'上传已停止。':error.message)+' 请刷新申请核对状态；不要立即重复上传。未完成申请可撤回后重传。');if(prepared&&!submitted&&!session.signal.aborted){try{await loadSubtitleRequests();}catch{}}}
 finally{subtitleUploading=false;requestUploadAbort=null;button.disabled=false;$('#subtitle-request-abort').hidden=true;}
};
$('#subtitle-request-refresh').onclick=()=>run(loadSubtitleRequests,'#subtitle-request-message');
const beforeRequestLoad=load;load=async function(){await beforeRequestLoad();try{await loadSubtitleRequests();}catch(error){$('#subtitle-request-message').textContent=error.message;}};
const beforeRequestLogout=logout;logout=function(){requestUploadAbort?.abort();requestDialog.close();closeRequestDelete(false);approvalRequest=null;subtitleRequests=[];showDeletedSubtitleRequests=false;$('#subtitle-request-list').replaceChildren();$('#subtitle-request-form').reset();requestStatus('');$('#subtitle-request-message').textContent='';beforeRequestLogout();};$('#logout').onclick=logout;
setInterval(()=>{if(document.visibilityState==='visible'&&data?.me&&!requestDialog.open&&subtitleRequests.some(r=>['uploading','pending'].includes(r.state)))loadSubtitleRequests().catch(()=>{});},30000);
