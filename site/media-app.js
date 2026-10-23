'use strict';
kinds.clip='剪辑';kinds.timing='时间轴';kinds.cover='封面';
const baseRender=render,textDeliverySubmit=$('#delivery-form').onsubmit;
let pendingDelete=null,mediaAbort=null,mediaBusy=false;
render=function(){baseRender();$('#delete-project').hidden=!project||!data.can_manage;$('#project-danger').hidden=!project;};
function uploadProgress(label,ratio){$('#upload-progress-wrap').hidden=false;$('#upload-status').textContent=label;$('#upload-progress').value=Math.max(0,Math.min(100,ratio*100));}
function configureDelivery(kind){
 const c=MediaFiles.config(kind);
 $('#media-file-label').hidden=!c;$('#subtitle-file-label').hidden=!!c;$('#content-label').hidden=!!c;$('#source-label').hidden=!!c;$('#model-label').hidden=!!c;
 $('#delivery-content').required=!c;$('#delivery-content').disabled=!!c;$('#delivery-file').required=!!c;
 $('#delivery-file').accept=c?.accept||'';$('#media-help').textContent=c?(kind==='cover'?'封面上传 JPG/PNG/WebP，单文件不超过 20MB。':'剪辑/压制上传 MP4/MKV/MOV/WebM，上限 1GB（1024MB）。大文件分片传输，全部上传成功后才生成交付版本；当前不支持断点续传。'):'';
 $('#upload-progress-wrap').hidden=true;$('#cancel-upload').hidden=true;
}
function renderDelivery(d){
 const artifact=(detail.artifacts||[]).find(a=>a.id===d.artifact_id);
 let controls='',body='';
 if(artifact){
  const isVideo=artifact.mime_type.startsWith('video/');
  controls=`<button data-file="${esc(artifact.id)}">下载原文件</button><button data-preview="${esc(artifact.id)}">${isVideo?'预览视频':'预览图片'}</button>`;
  body=`<p>${esc(artifact.file_name)} · ${esc(MediaFiles.bytes(artifact.byte_size))}</p><div id="preview-${esc(artifact.id)}" class="media-preview"></div>`;
 }else if(d.artifact_id){body='<p>文件记录暂不可用，请刷新后重试。</p>';
 }else{
  const f=SubtitleFiles.prepare(d.content_text);
  controls=`<button data-download="${esc(d.id)}">${esc(f.label)}</button>${f.originalExtension?`<button data-original="${esc(d.id)}">下载原 ${esc(f.format)}</button>`:''}`;
  body=`<p class="muted">${esc(f.notice)}</p><pre>${esc(d.content_text||'')}</pre>`;
 }
 return `<section class="version"><header><b>V${d.version_no} · ${d.source==='manual'?'成员交付':'Codex 初稿'}</b><div class="version-actions">${controls}</div></header><p>${esc(who(d.submitted_by))} · ${esc(new Date(d.created_at).toLocaleString('zh-CN'))}</p><p class="pre">${esc(d.notes)}</p>${body}<div class="hash">SHA-256（${artifact?'提交端文件校验':'保存正文'}） ${esc(d.content_sha256)}</div></section>`;
}
async function openTask(id){
 if(mediaBusy)throw Error('请等待上传完成，或先取消上传');
 currentTask=data.tasks.find(t=>t.id===id);if(!currentTask)throw Error('任务已被删除或不在当前列表');
 detail=await rpc('st_task_detail',{p_task:id});
 $('#task-title').textContent=currentTask.title;$('#task-description').textContent=currentTask.description;$('#dialog-message').textContent='';$('#delivery-form').reset();$('#review-form').reset();
 const claim=data.claims.find(c=>c.task_id===id),mine=claim?.member_id===data.me.id,isMedia=!!MediaFiles.config(currentTask.kind);
 $('#task-actions').replaceChildren();if(currentTask.state==='open')action('认领任务',()=>rpc('st_claim_task',{p_task:id}));if(currentTask.state==='claimed'&&(mine||data.can_manage))action('释放认领',()=>rpc('st_release_task',{p_task:id}));
 $('#delivery-form').hidden=!(mine&&['claimed','submitted'].includes(currentTask.state))&&!(data.can_manage&&currentTask.state==='open'&&!isMedia);
 $('#delivery-source').querySelector('[value="codex"]').hidden=!data.can_manage||currentTask.state!=='open';$('#delivery-source').value=currentTask.state==='open'&&!isMedia?'codex':'manual';
 configureDelivery(currentTask.kind);
 $('#review-form').hidden=!(data.can_review&&currentTask.state==='submitted'&&detail.deliveries[0]?.submitted_by!==data.me.id);
 $('#versions').innerHTML=detail.deliveries.map(renderDelivery).join('')||empty('还没有交付版本。');
 $('#reviews').innerHTML=detail.reviews.map(r=>`<div class="version"><b>${esc(who(r.reviewer_id))} · ${r.decision==='approved'?'审核通过':'退回修改'}</b><p>${esc(r.feedback)}</p></div>`).join('')||empty('尚无审核记录。');
 document.querySelectorAll('[data-download]').forEach(b=>b.onclick=()=>downloadDelivery(b.dataset.download));document.querySelectorAll('[data-original]').forEach(b=>b.onclick=()=>downloadDelivery(b.dataset.original,true));
 document.querySelectorAll('[data-file]').forEach(b=>b.onclick=()=>run(()=>downloadMedia(b.dataset.file),'#dialog-message'));
 document.querySelectorAll('[data-preview]').forEach(b=>b.onclick=()=>run(()=>previewMedia(b.dataset.preview),'#dialog-message'));
 $('#delete-task').hidden=!data.can_manage;
 if(!$('#task-dialog').open)$('#task-dialog').showModal();
}
async function signedMedia(id){
 const artifact=detail.artifacts.find(a=>a.id===id);if(!artifact)throw Error('文件记录不存在');
 const s=await request('/v1/storages/object/sign/subtitle-deliveries/'+MediaFiles.objectPath(artifact.object_path),{expiresIn:600});
 const value=s.fullSignedURL||s.signedURL;if(!value)throw Error('未取得文件访问链接');
 const url=new URL(value,BASE);if(url.origin!==BASE)throw Error('文件服务返回了非预期域名');
 return {artifact,url};
}
async function downloadMedia(id){const {artifact,url}=await signedMedia(id);url.searchParams.set('download',artifact.file_name);const a=document.createElement('a');a.href=url.href;a.download=artifact.file_name;a.target='_blank';a.rel='noopener noreferrer';a.click();}
async function previewMedia(id){
 const {artifact,url}=await signedMedia(id),box=document.getElementById('preview-'+id);box.replaceChildren();
 const media=document.createElement(artifact.mime_type.startsWith('video/')?'video':'img');media.src=url.href;
 if(media.tagName==='VIDEO'){media.controls=true;media.preload='metadata';}else media.alt=artifact.file_name;
 const hint=document.createElement('p');hint.className='muted';hint.textContent='访问链接有效期 10 分钟。若浏览器无法播放此视频格式，请下载原文件。';
 box.append(media,hint);media.onerror=()=>{hint.textContent='浏览器无法预览此文件，请下载原文件或重新获取预览。';};
}
function sendMediaFile(session,file,mime,signal,partOffset=0,totalSize=file.size){return new Promise((resolve,reject)=>{
 const xhr=new XMLHttpRequest(),abort=()=>xhr.abort();
 xhr.open('POST',BASE+'/v1/storages/object/subtitle-deliveries/'+MediaFiles.objectPath(session.path));xhr.setRequestHeader('Authorization','Bearer '+token);xhr.setRequestHeader('Content-Type',mime);xhr.timeout=3600000;
 signal.addEventListener('abort',abort,{once:true});
 xhr.upload.onprogress=e=>{if(e.lengthComputable)uploadProgress('正在上传：'+MediaFiles.bytes(partOffset+e.loaded)+' / '+MediaFiles.bytes(totalSize),(partOffset+e.loaded)/totalSize);};
 const done=()=>signal.removeEventListener('abort',abort);
 xhr.onload=()=>{done();let result;try{result=JSON.parse(xhr.responseText);}catch{}if(xhr.status>=200&&xhr.status<300)resolve(result);else reject(Error(xhr.status===413?'平台拒绝了此文件大小，本次未生成交付版本。':result?.message||'文件上传未完成，请重试（'+xhr.status+'）'));};
 xhr.onerror=()=>{done();reject(Error('上传连接中断，尚未生成交付版本，请重试'));};xhr.ontimeout=()=>{done();reject(Error('上传超时，尚未生成交付版本，请重试'));};xhr.onabort=()=>{done();reject(Error('已取消上传，尚未生成交付版本'));};
 if(signal.aborted){done();reject(Error('已取消上传'));return;}xhr.send(file);
 });}
$('#delivery-form').onsubmit=e=>{
 if(!MediaFiles.config(currentTask.kind)){textDeliverySubmit(e);return;}
 e.preventDefault();const form=e.currentTarget;
 submitForm(form,async f=>{
  const file=$('#delivery-file').files[0];if(!file)throw Error('请选择交付文件');
  if(mediaBusy)throw Error('文件正在上传');
  const mime=MediaFiles.mime(currentTask.kind,file.name,file.size,new Uint8Array(await file.slice(0,16).arrayBuffer()));
  mediaBusy=true;mediaAbort=new AbortController();$('#dialog-message').textContent='';$('#cancel-upload').hidden=false;$('#cancel-upload').disabled=false;$('#delete-task').disabled=true;
  try{
   uploadProgress('正在计算文件校验…',0);
   const hash=await MediaFiles.hash(file,p=>uploadProgress('正在计算文件校验：'+Math.round(p*100)+'%',p),mediaAbort.signal);
   const session=await rpc(file.size>4194304?'st_upload_begin_chunked':'st_upload_begin',{p_task:currentTask.id,p_filename:file.name,p_mime:mime,p_size:file.size,p_sha256:hash});
   uploadProgress('开始上传…',0);
   if(session.chunk_size){for(let index=0,offset=0;offset<file.size;index++,offset+=session.chunk_size){await sendMediaFile({...session,path:session.path+'/part-'+String(index).padStart(4,'0')},file.slice(offset,offset+session.chunk_size),mime,mediaAbort.signal,offset,file.size);}}
   else await sendMediaFile(session,file,mime,mediaAbort.signal);
   uploadProgress('上传完成，正在保存交付版本…',1);await rpc('st_upload_finish',{p_upload:session.id,p_notes:f.get('notes')});
   mediaBusy=false;await load();await openTask(currentTask.id);$('#dialog-message').textContent='文件交付已保存，原文件可下载。';
  }finally{mediaBusy=false;mediaAbort=null;$('#cancel-upload').hidden=true;$('#delete-task').disabled=false;}
 },'#dialog-message');
};
$('#cancel-upload').onclick=()=>mediaAbort?.abort();
$('#close-task').onclick=()=>{if(mediaBusy){$('#dialog-message').textContent='上传中，请先点击“取消上传”或等待完成。';return;}$('#task-dialog').close();};
$('#task-dialog').addEventListener('cancel',e=>{if(mediaBusy){e.preventDefault();$('#dialog-message').textContent='上传中，请先取消上传。';}});
function askDelete(kind){
 if(mediaBusy){$('#dialog-message').textContent='请先完成或取消上传';return;}
 const item=kind==='project'?data.projects.find(p=>p.id===project):currentTask;if(!item)return;
 pendingDelete={kind,id:item.id,title:item.title};$('#delete-title').textContent=kind==='project'?'删除项目':'删除任务';$('#delete-name').textContent=item.title;
 $('#delete-description').textContent=kind==='project'?'项目及其中任务、交付文件将从工作台隐藏，可在回收站恢复。不会抹除历史贡献和审计。':'任务及其交付版本将从工作台隐藏，可在回收站恢复。当前认领会释放；历史记录保留。';
 $('#delete-confirmation').value='';$('#confirm-delete').disabled=true;$('#delete-message').textContent='';$('#delete-dialog').showModal();
}
$('#delete-project').onclick=()=>askDelete('project');$('#delete-task').onclick=()=>askDelete('task');$('#cancel-delete').onclick=()=>$('#delete-dialog').close();
$('#delete-confirmation').oninput=()=>$('#confirm-delete').disabled=$('#delete-confirmation').value!==pendingDelete?.title;
$('#delete-form').onsubmit=e=>{e.preventDefault();submitForm(e.currentTarget,async()=>{
 const item=pendingDelete,args=item.kind==='project'?{p_project:item.id,p_confirmation:$('#delete-confirmation').value}:{p_task:item.id,p_confirmation:$('#delete-confirmation').value};
 await rpc(item.kind==='project'?'st_delete_project':'st_delete_task',args);$('#delete-dialog').close();$('#task-dialog').close();currentTask=null;detail=null;if(item.kind==='project')project=null;await load();notify('已移入回收站，可从“回收站”恢复。');
},'#delete-message');};
async function showTrash(){
 const items=await rpc('st_deleted_items',{p_project:project});
 $('#trash-items').innerHTML=[...items.projects.map(p=>({kind:'project',...p})),...items.tasks.map(t=>({kind:'task',...t}))].map(item=>`<div class="row"><div><b>${esc(item.title)}</b><p class="muted">${item.kind==='project'?'项目':'当前项目中的任务'} · ${esc(new Date(item.deleted_at).toLocaleString('zh-CN'))}</p></div><button data-restore="${esc(item.id)}" data-restore-kind="${item.kind}">恢复</button></div>`).join('')||empty('没有你有权恢复的已删除内容。');
 document.querySelectorAll('[data-restore]').forEach(b=>b.onclick=()=>run(async()=>{b.disabled=true;try{const p=b.dataset.restoreKind==='project';await rpc(p?'st_restore_project':'st_restore_task',p?{p_project:b.dataset.restore}:{p_task:b.dataset.restore});if(p)project=b.dataset.restore;await load();await showTrash();notify('已恢复。任务的历史版本保留；曾被释放的认领需重新认领。');}finally{b.disabled=false;}},'#trash-message'));
 if(!$('#trash-dialog').open){$('#trash-message').textContent='';$('#trash-dialog').showModal();}
}
$('#open-trash').onclick=()=>run(showTrash);$('#close-trash').onclick=()=>$('#trash-dialog').close();
const originalLogout=logout;
logout=function(){mediaAbort?.abort();mediaBusy=false;pendingDelete=null;$('#delete-dialog').close();$('#trash-dialog').close();$('#trash-items').replaceChildren();originalLogout();};
$('#logout').onclick=logout;
