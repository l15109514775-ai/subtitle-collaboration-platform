'use strict';
// This page uploads and enqueues only. Recognition and publication run in Cloud.
let cloudState={jobs:[],workers:[],deleted_workers:[]},cloudBusy=false,cloudLoadVersion=0;
const cloudReportViews=new Map();let cloudReportScope=null;
const cloudStates={uploading:'上传素材中',queued:'待人工启动',running:'云端处理中',waiting_configuration:'等待配置',waiting_reconciliation:'请求结果需核对',failed:'交付或处理失败',cancelled:'已取消',succeeded:'AI 初稿已交付'};
const cloudStages={preparing:'准备云端任务',checking_configuration:'检查识别环境',downloading:'正在读取原视频',recognition_and_text:'正在识别、翻译与复核',text_request:'正在翻译或复核字幕',secondary_request:'正在进行辅助识别',publishing:'正在保存字幕与报告',platform_or_configuration_unavailable:'需要处理环境或连接配置',model_request_needs_reconciliation:'接口结果需要核对，已暂停',input_or_processing_failed:'素材或处理遇到问题，已停止',publish_result_needs_reconciliation:'交付响应待核对，禁止重跑模型',delivery_validation_failed:'交付文件校验未通过',source_authorization_expired:'素材授权已过期'};
const cloudLaunchBusy=new Set();
const cloudPanel=document.createElement('section');cloudPanel.id='cloud-panel';cloudPanel.className='card';
cloudPanel.innerHTML=`<div class="section-heading"><div><div class="eyebrow">CODEX CLOUD</div><h2>云端字幕交付</h2></div><button id="cloud-refresh" type="button">刷新状态</button></div><p class="muted">这里显示已批准的执行任务与字幕交付。请在上方“字幕申请与审批”登记和审批；组长手动在 Codex Cloud 启动后，可以关闭电脑，字幕自动回传。QQ机器人每天按北京时间07:00、12:00、16:00、00:00集中检查申请与审批结果，执行指令仅私聊组长；审批和云端启动仍由组长人工操作。原视频保留7天，到期后自动清理；字幕与报告继续保留。</p><div id="cloud-owner" hidden><details hidden><summary>提交原视频到云端</summary><p class="muted">单次素材最长20分钟，每个作业独立限额：最多400次文字请求、40次千问识别请求；不同视频不共用试跑额度。限额是上限，不会为用完额度而追加调用；失败和结果不明的请求也计入预算。</p><form id="cloud-form"><label>直播标题<input id="cloud-title" required maxlength="125"></label><label>时间戳<input id="cloud-stamp" required maxlength="40" placeholder="例如 01:00–02:00"></label><label>原视频<input id="cloud-video" type="file" accept=".mp4,.mkv,.mov,.webm" required></label><label>执行身份<select id="cloud-worker" required></select></label><div class="toolbar"><label>时长上限（秒）<input id="cloud-seconds" type="number" value="1200" min="1" max="1200" required></label><label>文字请求上限<input id="cloud-text-limit" type="number" value="400" min="1" max="400" required></label><label>千问识别请求上限<input id="cloud-asr-limit" type="number" value="40" min="1" max="40" required></label></div><label><input id="cloud-approved" type="checkbox" required>我批准本次任务在上述限额内调用识别、翻译接口；货币费用以供应商账单为准。</label><button type="submit" class="primary">上传原视频并登记云任务</button><p id="cloud-upload-status" role="status"></p></form></details><details id="cloud-worker-settings"><summary>云执行身份设置</summary><div class="cloud-worker-guide"><p><b>身份备注 ≠ Codex Cloud 环境名</b></p><p>执行身份是网站授予字幕程序的授权；备注只帮助你辨认，可自行修改。备注里的 Cloud、60s 或 20min 不会选择环境，也不会决定视频时长；时长以每次审批的额度为准。</p><p>Codex Cloud 环境是运行程序的位置。当前工作流使用 <code>subtitle-delivery-20min-active</code>。审批时选中的身份，须与该环境内 <code>SUBTITLE_PLATFORM_TOKEN</code> 保存的身份密钥一致；名称相同不代表已经关联。</p><p class="muted">修改备注不更换密钥、环境或额度。身份只可领取分配给它的任务、更新状态和提交 AI 初稿。新密钥仅创建时显示一次，请直接保存到云环境安全表单，不要发到聊天或放入仓库。</p></div><label>新身份备注<input id="cloud-worker-label" maxlength="80" placeholder="例如：字幕交付 · 20分钟环境" autocomplete="off"></label><button id="cloud-worker-create" type="button">创建云执行身份</button><label id="cloud-key-wrap" hidden>新身份密钥（仅此页显示一次）<input id="cloud-new-key" type="password" readonly autocomplete="off"></label><button id="cloud-copy-key" type="button" hidden>复制身份密钥</button><button id="cloud-clear-key" type="button" hidden>清除此页密钥</button><div id="cloud-workers"></div><details id="cloud-worker-trash"><summary id="cloud-worker-trash-title">已删除身份（0）</summary><p class="muted">恢复后仍为已撤销，不能执行任务；历史任务、交付和审计记录继续保留。</p><div id="cloud-deleted-workers"></div></details></details></div><div id="cloud-job-list"></div><p id="cloud-message" role="status"></p>`;
$('#board-view').prepend(cloudPanel);
const cloudWorkerDialog=document.createElement('dialog');cloudWorkerDialog.id='cloud-worker-dialog';
cloudWorkerDialog.innerHTML=`<form id="cloud-worker-action-form"><h2 id="cloud-worker-action-title"></h2><p id="cloud-worker-action-name"></p><p id="cloud-worker-action-description"></p><label id="cloud-worker-rename-label">身份备注<input id="cloud-worker-rename-value" maxlength="80" required autocomplete="off"></label><div class="toolbar"><button type="button" id="cloud-worker-action-cancel">取消</button><button type="submit" id="cloud-worker-action-submit" class="primary">确认</button></div><p id="cloud-worker-action-message" role="status"></p></form>`;
document.body.append(cloudWorkerDialog);let cloudWorkerAction=null,cloudWorkerActionBusy=false;
function closeCloudWorkerAction(){cloudWorkerAction=null;$('#cloud-worker-rename-value').value='';$('#cloud-worker-action-message').textContent='';if(cloudWorkerDialog.open)cloudWorkerDialog.close();}
$('#cloud-worker-action-cancel').onclick=closeCloudWorkerAction;
cloudWorkerDialog.addEventListener('close',()=>{cloudWorkerAction=null;$('#cloud-worker-rename-value').value='';});
function openCloudWorkerAction(id,action){
 if(!data?.me.owner)return;
 const worker=[...cloudState.workers,...(cloudState.deleted_workers||[])].find(w=>w.id===id);if(!worker)return;
 if(action==='delete'&&worker.active)return;
 const labels={delete:'删除已撤销身份',restore:'恢复已删除身份',rename:'修改身份备注'};
 cloudWorkerAction={id,action};$('#cloud-worker-action-title').textContent=labels[action];
 $('#cloud-worker-action-name').textContent=worker.label+' · '+worker.id.slice(0,8);
 $('#cloud-worker-action-description').textContent=action==='delete'?'该身份将移入“已删除身份”，不再出现在日常列表。历史任务、字幕交付和审计记录继续保留，可随时恢复列表记录。':action==='restore'?'只恢复列表记录，身份仍为已撤销，不会重新取得执行权限。':'备注只用于辨认身份；修改后，原密钥、执行权限、Codex Cloud 环境与任务额度均保持原样。';
 $('#cloud-worker-rename-label').hidden=action!=='rename';$('#cloud-worker-rename-value').required=action==='rename';$('#cloud-worker-rename-value').value=action==='rename'?worker.label:'';
 $('#cloud-worker-action-submit').textContent=action==='delete'?'确认删除':action==='restore'?'恢复记录':'保存备注';$('#cloud-worker-action-submit').className=action==='delete'?'danger':'primary';$('#cloud-worker-action-submit').disabled=false;$('#cloud-worker-action-message').textContent='';cloudWorkerDialog.showModal();
}
$('#cloud-worker-action-form').onsubmit=e=>{
 e.preventDefault();if(!cloudWorkerAction||cloudWorkerActionBusy)return;
 const action={...cloudWorkerAction},label=$('#cloud-worker-rename-value').value.trim(),session=SessionFence.capture();
 if(action.action==='rename'&&(!label||Array.from(label).length>80)){$('#cloud-worker-action-message').textContent='请填写1至80字的身份备注。';return;}
 cloudWorkerActionBusy=true;$('#cloud-worker-action-submit').disabled=true;
 return run(async()=>{try{
  if(action.action==='rename')await rpc('st_cloud_worker_rename',{p_worker:action.id,p_label:label});
  else await rpc('st_cloud_worker_set_deleted',{p_worker:action.id,p_deleted:action.action==='delete'});
  session.check();closeCloudWorkerAction();clearCloudKey();await loadCloud();session.check();
  $('#cloud-message').textContent=action.action==='delete'?'身份已移入“已删除身份”，历史记录继续保留。':action.action==='restore'?'身份记录已恢复，仍为已撤销。':'身份备注已更新；密钥和云环境关联保持原样。';
 }finally{cloudWorkerActionBusy=false;$('#cloud-worker-action-submit').disabled=false;}},'#cloud-worker-action-message');
};

function clearCloudKey(){$('#cloud-new-key').value='';for(const id of ['cloud-key-wrap','cloud-copy-key','cloud-clear-key'])$('#'+id).hidden=true;}
$('#cloud-copy-key').onclick=()=>run(async()=>{await navigator.clipboard.writeText($('#cloud-new-key').value);$('#cloud-message').textContent='已复制，请直接粘贴到云环境变量，保存后清除此页密钥。'},'#cloud-message');
$('#cloud-clear-key').onclick=clearCloudKey;
async function loadCloud(){const version=++cloudLoadVersion,session=SessionFence.capture(),result=await rpc('st_cloud_jobs_view');session.check();if(version!==cloudLoadVersion)return;cloudState={...result,deleted_workers:result.deleted_workers||[]};renderCloud();}

function renderCloudJob(j){
 const info=CloudJobTools.job(j);
 return `<article class="version"><header><b>${esc(j.project_title)}</b><span class="badge">${esc(info.label)}</span></header>
 <p>${esc(j.state==='succeeded'?'字幕与报告已回传，等待人工听校':cloudStages[j.stage]||'当前阶段未提供')}</p><div class="cloud-next"><b>下一步 · ${esc(info.who)}</b><p>${esc(info.next)}</p>${info.stale?'<p class="cloud-stale">超过3分钟没有状态更新，当前信息可能已过期，不能据此确认云端仍在运行；请组长核对原对话，勿重复启动。</p>':''}</div>
 <p class="muted">${esc(j.file_name)} · ${esc(MediaFiles.bytes(j.byte_size))} · 批准上限：${esc(j.max_video_seconds)}秒 / 文字${esc(j.max_text_requests)}次 / 千问${esc(j.max_secondary_requests)}次</p>
 <p>${esc(info.reserved)}</p><details class="cloud-evidence"><summary>已完成步骤、文件保留与用量依据</summary><p>${esc(info.retained)}</p><p>${esc(info.preservation)}</p>${CloudJobTools.usageLines(info.usage).map(line=>'<p>'+esc(line)+'</p>').join('')}<p class="muted">未接入最终账单核验，不计算或展示“实际费用”；请以供应商账单为准。预留次数不会因刷新或新建对话自动归零。</p></details>
 <small>任务 ${esc(j.id)} · 更新于 ${esc(new Date(j.updated_at).toLocaleString('zh-CN'))}</small><div class="toolbar">${data?.me.owner&&j.state==='queued'?'<button type="button" data-cloud-instructions="'+esc(j.id)+'">复制云端执行指令</button>':''}${info.canPublishOnly&&data?.me.owner?'<button type="button" data-cloud-publish-only="'+esc(j.id)+'">复制仅补传指令</button>':''}${j.state==='succeeded'?'<button type="button" data-cloud-report="'+esc(j.id)+'">查看质量与用量报告</button><button type="button" data-cloud-files="'+esc(j.id)+'">下载字幕与报告</button>':''}${data?.me.owner&&!['succeeded','cancelled'].includes(j.state)?'<button type="button" data-cloud-cancel="'+esc(j.id)+'">取消此云任务</button>':''}</div><div id="cloud-report-${esc(j.id)}" class="cloud-report">${cloudReportViews.get(j.id)||''}</div><div id="cloud-files-${esc(j.id)}"></div></article>`;
}
function bindCloudReports(){
 document.querySelectorAll('[data-cloud-publish-only]').forEach(button=>button.onclick=()=>run(async()=>{
  if(!confirm('仅适用于原Codex Cloud对话、原工作目录与原租约。此按钮只复制指令，不启动任务；缺少已保存交付包或租约失效时必须停止。继续复制？'))return;
  await navigator.clipboard.writeText(CloudJobTools.recoveryCommand(button.dataset.cloudPublishOnly));$('#cloud-message').textContent='仅补传指令已复制。由组长回原云对话核对后执行；不要新建云任务，也不要重新识别翻译。';
 },'#cloud-message'));
 document.querySelectorAll('[data-cloud-report]').forEach(button=>button.onclick=()=>run(async()=>{
  const session=SessionFence.capture();button.disabled=true;
  try{
   const files=await rpc('st_cloud_files',{p_job:button.dataset.cloudReport});session.check();
   const quality=await CloudJobTools.jsonFile(files.find(f=>f.name==='quality.json'));
   const cues=await CloudJobTools.jsonFile(files.find(f=>f.name==='cues.json'));
   const usage=await CloudJobTools.jsonFile(files.find(f=>f.name==='usage.json'));session.check();
   const report=CloudJobTools.quality(quality,cues),box=document.getElementById('cloud-report-'+button.dataset.cloudReport);if(!box)return;
   box.innerHTML='<h4>简明质量报告</h4><p>字幕数量：'+esc(report.cueCount)+' · 警告数量：'+esc(report.warningCount)+' · 受影响字幕：'+esc(report.affected)+'</p><p>'+esc(report.note)+'</p>'+ (report.humanReviewed?'<p>文件标记听校已完成；仍以平台人工审核记录为准。</p>':'<p>尚未完成人工听校，等待成员和审核人处理。</p>') + (report.truncated?'<p>此处仅列出前'+report.rows.length+'项；完整交付报告请下载quality.json。若文件标记截断，全量诊断仅在原云工作区quality-full.json中保留，不是永久备份。</p>':'') + '<div class="cloud-report-scroll"><table><thead><tr><th>字幕编号</th><th>时间段</th><th>具体原因</th></tr></thead><tbody>'+report.rows.map(row=>'<tr><td>'+esc(row.id)+'</td><td>'+esc(row.interval)+'</td><td>'+esc(row.reason)+'</td></tr>').join('')+'</tbody></table></div><h4>服务商返回用量</h4>'+CloudJobTools.usageLines(CloudJobTools.usageFile(usage)).map(line=>'<p>'+esc(line)+'</p>').join('')+'<p>用量返回不等于结算费用；没有账单依据时不估算金额。</p>';
   cloudReportViews.set(button.dataset.cloudReport,box.innerHTML);
  }finally{if(button.isConnected)button.disabled=false;}
 },'#cloud-message'));
}

function renderCloud(){
 const scope=data?.me?.id??null;if(scope===null||scope!==cloudReportScope){cloudReportViews.clear();cloudReportScope=scope;}
 const visible=new Set(cloudState.jobs.map(j=>j.id));for(const id of cloudReportViews.keys())if(!visible.has(id))cloudReportViews.delete(id);

 $('#cloud-owner').hidden=!data?.me.owner;
 const previous=$('#cloud-worker').value;
 $('#cloud-worker').innerHTML=cloudState.workers.filter(w=>w.active&&w.available!==false).map(w=>`<option value="${esc(w.id)}">${esc(w.label)} · ${esc(w.id.slice(0,8))}</option>`).join('');
 if(cloudState.workers.some(w=>w.id===previous&&w.active))$('#cloud-worker').value=previous;
 $('#cloud-workers').innerHTML=cloudState.workers.map(w=>`<article class="cloud-worker-item"><p><b>${esc(w.label)}</b> <span class="badge">${!w.active?'已撤销':w.available===false?'已到期或任务额度已用完':'可用'}</span></p><p class="muted">身份编号 ${esc(w.id.slice(0,8))}${w.expires_at?' · 到期 '+esc(new Date(w.expires_at).toLocaleString('zh-CN'))+' · 已领取 '+esc(w.claimed_jobs)+' / '+esc(w.max_jobs):''}</p><div class="toolbar"><button type="button" data-rename-worker="${esc(w.id)}">修改备注</button>${w.active?'<button type="button" data-revoke-worker="'+esc(w.id)+'">撤销身份</button>':'<button type="button" class="danger" data-delete-worker="'+esc(w.id)+'">删除身份</button>'}</div></article>`).join('')||empty('暂无执行身份。');
 $('#cloud-worker-trash-title').textContent='已删除身份（'+(cloudState.deleted_workers||[]).length+'）';
 $('#cloud-deleted-workers').innerHTML=(cloudState.deleted_workers||[]).map(w=>`<article class="cloud-worker-item"><p><b>${esc(w.label)}</b> · ${esc(w.id.slice(0,8))} · 已撤销</p><button type="button" data-restore-worker="${esc(w.id)}">恢复记录</button></article>`).join('')||empty('暂无已删除身份。');
 for(const action of ['rename','delete','restore'])document.querySelectorAll('[data-'+action+'-worker]').forEach(b=>b.onclick=()=>openCloudWorkerAction(b.dataset[action+'Worker'],action));
 $('#cloud-job-list').innerHTML=cloudState.jobs.map(renderCloudJob).join('')||empty('尚无云端字幕任务。');
 bindCloudReports();
 document.querySelectorAll('[data-cloud-instructions]').forEach(b=>b.onclick=()=>run(async()=>{await navigator.clipboard.writeText(CloudLaunch.instructions(b.dataset.cloudInstructions));$('#cloud-message').textContent='执行指令已复制，请在已发布的 Codex Cloud 字幕环境新任务中发送。';},'#cloud-message'));
 document.querySelectorAll('[data-cloud-start]').forEach(b=>b.onclick=()=>run(async()=>{
  const id=b.dataset.cloudStart;if(cloudLaunchBusy.has(id))return;
  const session=SessionFence.capture();cloudLaunchBusy.add(id);b.disabled=true;
  try{const result=await CloudLaunch.start(id,session);$('#cloud-message').textContent=result.state==='submitted'?'云端任务已提交。可以关闭电脑，结果会自动回传。':'云端启动结果正在核对，请保留当前任务，不要重复上传。';await loadCloud();}
  finally{cloudLaunchBusy.delete(id);if(b.isConnected)b.disabled=false;}
 },'#cloud-message'));
 document.querySelectorAll('[data-revoke-worker]').forEach(b=>b.onclick=()=>run(async()=>{await rpc('st_cloud_worker_revoke',{p_worker:b.dataset.revokeWorker});clearCloudKey();await loadCloud();},'#cloud-message'));
 document.querySelectorAll('[data-cloud-cancel]').forEach(b=>b.onclick=()=>run(async()=>{await rpc('st_cloud_cancel',{p_job:b.dataset.cloudCancel});await loadCloud();},'#cloud-message'));
 document.querySelectorAll('[data-cloud-files]').forEach(b=>b.onclick=()=>run(async()=>{
  const files=await rpc('st_cloud_files',{p_job:b.dataset.cloudFiles}),box=document.getElementById('cloud-files-'+b.dataset.cloudFiles);box.replaceChildren();
  for(const f of files){const button=document.createElement('button');button.type='button';button.textContent='下载 '+f.name;button.onclick=()=>run(async()=>{const bytes=Uint8Array.from(atob(f.base64),c=>c.charCodeAt(0));const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');if(hash!==f.sha256||bytes.length!==f.bytes)throw Error('文件校验失败，未下载');const url=URL.createObjectURL(new Blob([bytes],{type:f.name.endsWith('.json')?'application/json':'text/plain;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=f.name;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);},'#cloud-message');box.append(button);}
 },'#cloud-message'));
}
$('#cloud-worker-create').onclick=()=>run(async()=>{const session=SessionFence.capture(),label=$('#cloud-worker-label').value.trim();if(Array.from(label).length>80)throw Error('身份备注最多80字');const w=await rpc('st_cloud_worker_create',{p_label:label||'subtitle-cloud-worker'});session.check();$('#cloud-new-key').value=w.key;for(const id of ['cloud-key-wrap','cloud-copy-key','cloud-clear-key'])$('#'+id).hidden=false;await loadCloud();$('#cloud-worker').value=w.id;},'#cloud-message');
$('#cloud-refresh').onclick=()=>run(loadCloud,'#cloud-message');
$('#cloud-form').onsubmit=async e=>{
 e.preventDefault();if(cloudBusy)return;const session=SessionFence.capture();cloudBusy=true;const button=e.currentTarget.querySelector('button[type="submit"]');button.disabled=true;let job=null,sourceReady=false;
 const status=message=>{$('#cloud-upload-status').textContent=message;};
 try{
  CloudLimits.validate({seconds:Number($('#cloud-seconds').value),text:Number($('#cloud-text-limit').value),qwen:Number($('#cloud-asr-limit').value)});
  const file=$('#cloud-video').files[0];if(!file||file.size>1073741824||file.size<=0)throw Error('请选择1GB以内的原视频');
  const mime=MediaFiles.mime('clip',file.name,file.size,new Uint8Array(await file.slice(0,32).arrayBuffer()));
  status('正在校验原视频…');const hash=await MediaFiles.hash(file,p=>status('校验原视频 '+Math.round(p*100)+'%'),session.signal);session.check();
  job=await rpc('st_cloud_prepare',{p_worker:$('#cloud-worker').value,p_stream_title:$('#cloud-title').value.trim(),p_timestamp:$('#cloud-stamp').value.trim(),p_filename:file.name,p_mime:mime,p_size:file.size,p_sha256:hash,p_max_seconds:Number($('#cloud-seconds').value),p_max_text:Number($('#cloud-text-limit').value),p_max_secondary:Number($('#cloud-asr-limit').value)});
  const sources=[];
  for(let i=0;i<job.part_count;i++){
   session.check();const part=file.slice(i*job.chunk_size,Math.min(file.size,(i+1)*job.chunk_size)),path=job.object_prefix+'/part-'+String(i).padStart(4,'0');status('正在上传原视频 '+(i+1)+' / '+job.part_count+' 片…');
   const response=await fetch(BASE+'/v1/storages/object/subtitle-inputs/'+MediaFiles.objectPath(path),{method:'POST',signal:session.signal,credentials:'omit',headers:{Authorization:'Bearer '+token,'Content-Type':mime},body:part});session.check();if(!response.ok)throw Error('素材上传未完成（'+response.status+'）');
   const s=await request('/v1/storages/object/sign/subtitle-inputs/'+MediaFiles.objectPath(path),{expiresIn:86400});const signed=new URL(s.fullSignedURL||s.signedURL,BASE);if(signed.origin!==BASE)throw Error('素材地址不匹配');sources.push({path,byte_size:part.size,url:signed.href});
  }
  session.check();await rpc('st_cloud_source_ready',{p_job:job.job_id,p_sources:sources});sourceReady=true;status('原视频已完整上传。云任务 '+job.job_id+' 已排队；请在 Codex 云端启动一次领取任务。素材访问授权有效期约23小时。');await load();
 }catch(error){status(error.message+(job&&!sourceReady?'；上传尚未完成，任务已停止。':sourceReady?'；视频已排队保留，请核对启动状态，勿重复上传。':''));if(job&&!sourceReady&&!session.signal?.aborted){try{await rpc('st_cloud_cancel',{p_job:job.job_id});}catch{}}}
 finally{cloudBusy=false;button.disabled=false;}
};
const beforeCloudLoad=load;load=async function(){await beforeCloudLoad();try{await loadCloud();}catch(error){$('#cloud-message').textContent='云任务状态暂不可用：'+error.message;}};
const beforeCloudLogout=logout;logout=function(){cloudLoadVersion++;closeCloudWorkerAction();$('#cloud-worker-label').value='';$('#cloud-deleted-workers').replaceChildren();$('#cloud-worker-trash-title').textContent='已删除身份（0）';$('#cloud-worker-trash').open=false;clearCloudKey();cloudReportViews.clear();cloudReportScope=null;cloudState={jobs:[],workers:[],deleted_workers:[]};$('#cloud-job-list').replaceChildren();$('#cloud-workers').replaceChildren();$('#cloud-form').reset();$('#cloud-upload-status').textContent='';beforeCloudLogout();};$('#logout').onclick=logout;


// Only poll visible, authenticated pending work. Never auto-submit or retry model requests.
setInterval(()=>{if(document.visibilityState==='visible'&&data?.me&&cloudState.jobs.some(j=>['queued','running'].includes(j.state)))loadCloud().catch(()=>{});},20000);

