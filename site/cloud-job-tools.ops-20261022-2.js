'use strict';
(function(root){
 const reasons={short_duration:'显示时间短于0.5秒',reading_speed:'阅读速度超过当前18字/秒警戒值',review_requested:'识别或模型提出人工复核；具体语义原因尚未核实',overlap:'与其他字幕重叠，可能是正常多人同时发言'};
 const count=v=>Number.isSafeInteger(v)&&v>=0&&v<=1e12?v:null;
 const show=v=>count(v)===null?'未上报':String(v);
 const requests=v=>count(v)===null?'未上报':String(v)+'次';
 const time=v=>Number.isFinite(v)&&v>=0&&v<=1200.2?`${Math.floor(v/60)}:${(v%60).toFixed(2).padStart(5,'0')}`:null;
 const uuid=v=>typeof v==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(v);
 function job(j,now=Date.now()){
  const p=j.progress||{},o=p.operations_v1?.version===1?p.operations_v1:null;
  const states={uploading:['上传未完成','提交人','核对上传情况；当前流程不支持断点续传。'],queued:['待人工启动','组长','审批已完成。复制执行指令，在已发布的Codex Cloud环境新建任务并发送一次。'],running:['处理中','云端执行；组长跟进','可以关闭本机。遇到长时间无更新，请回原云对话核对，勿重复启动。'],waiting_configuration:['等待配置处理','组长','回原云对话检查配置、租约或素材授权。不得通过重复登记、重置额度来绕过问题。'],waiting_reconciliation:['请求结果待核对','组长','核对原云对话和供应商记录；结果不明时禁止自动重发识别或翻译请求。'],failed:['交付或处理失败','组长','核对原云对话。已有检查点不代表可以从新任务恢复，不要直接重新识别翻译。'],cancelled:['已取消','组长','不再执行；历史文件和记录不因此永久删除。'],succeeded:['AI初稿已交付','项目成员与审核人','下载ASS/SRT和质量报告，在字幕软件中听校并提交人工版本；AI交付不等于人工审核通过。']};
  let [label,who,next]=states[j.state]||['状态未识别','组长','刷新并核对原云对话，勿重复执行。'];
  if(j.state==='queued'&&Number.isFinite(Date.parse(j.source_expires_at))&&Date.parse(j.source_expires_at)<=now)next='素材授权已过期。组长在原申请刷新素材授权，沿用同一任务；刷新不会重新识别或重置额度。';
  if(j.state==='running'&&j.stage==='publish_result_needs_reconciliation'){label='交付结果待核对';who='组长';next='字幕处理已进入交付阶段。先核对网站是否已有结果，再由组长回原云对话按原租约仅补传已保存的交付包。';}
  if(j.state==='waiting_reconciliation'&&count(o?.request_states?.rejected)>0){label='接口拒绝，等待核对';next='服务商已明确拒绝至少一次请求，仍占已预留额度。组长核对原云对话、配置与账单；不自动重发，不重置历史次数。';}
  if(j.stage==='delivery_validation_failed')next='交付文件的完整性或体积检查未通过。由组长检查原云对话中保留的产物；不能用重跑模型代替修复交付包。';
  if(j.stage==='source_authorization_expired')next='素材授权已过期。只有尚未开始的排队任务可直接刷新；已运行任务需组长核对原对话，不自动重新领取。';
  const stale=j.state==='running'&&Number.isFinite(Date.parse(j.updated_at))&&now-Date.parse(j.updated_at)>180000;
  const completed=o?.completed;
  const retained=completed?`主识别检查点：${completed.primary_checkpoint?'已观察到':'尚未观察到'}；千问检查点：${completed.secondary_checkpoint?'已观察到':'尚未观察到'}；翻译完成${show(completed.translate)}批，复核完成${show(completed.review)}批；交付文件${show(completed.delivery_files)}/9。`:'旧任务或当前阶段未上报检查点证据，无法确认已完成步骤和文件保留情况。';
  return {label,who,next,stale,retained,
   preservation:'检查点只属于原云任务工作区，不是永久备份；新建云任务不会自动继承。已交付的私有文件仍从网站下载。',
   reserved:`服务端已预留：文字：${requests(p.text_requests)}；千问：${requests(p.secondary_requests)}。预留包含失败或结果不明的请求，不等于成功次数或已结算费用。`,
   canPublishOnly:j.state==='running'&&o?.recovery?.mode==='same_lease_publish_only'&&o.recovery.publish_payload_saved===true,
   usage:o?.usage||null};
 }
 function recoveryCommand(id){
  if(!uuid(id))throw Error('无效云任务编号');
  return '仅在原Codex Cloud对话、原工作目录和原租约中，由组长核对后执行下面的固定命令。不得新建任务、重新领取、换身份、重置额度或调用模型。缺少session/publish-payload或租约失效即停止。\ncd /workspace/subtitle-cloud-worker\n.venv/bin/python platform_worker.py --job-id '+id+' --work-root /workspace/subtitle-platform-production --execute --publish-only';
 }
 function requestHint(r){
  if(r.state==='approved'&&r.job_state==='succeeded')return '项目成员与审核人：字幕初稿已交付，请在下方任务卡查看报告并下载，继续人工听校。';
  if(r.state==='approved'&&r.job_state!=='queued')return '组长：执行任务已启动或已停止；请看下方任务卡的状态与下一步，不重复发送启动指令。';
  return ({uploading:'提交人：上传未完成；核对后撤回重传，尚未创建执行任务。',pending:'组长：审核素材与批准额度；等待审批不会调用模型。',approved:'组长：核对下方云任务卡；尚未启动时只发送一次指令。',rejected:'提交人：查看审批意见；不会启动云任务。',withdrawn:'申请已撤回；素材不会立即永久删除。'})[r.state]||'请刷新并核对申请状态。';
 }
 function quality(report,cues=[]){
  if(!report||!Array.isArray(report.warnings))throw Error('质量报告格式无法识别');
  const byId=new Map(Array.isArray(cues)?cues.filter(c=>c&&Number.isSafeInteger(c.id)).map(c=>[c.id,c]):[]);
  const rows=report.warnings.slice(0,200).map(w=>{
   const cue=byId.get(w.id)||{},start=time(w.start??cue.start),end=time(w.end??cue.end);
   let reason=reasons[w.code]||(String(w.reason||'').includes('overlap')?reasons.overlap:'旧版综合警告或未分类警告，需人工核对原报告');
   if(w.code==='reading_speed'&&Number.isFinite(w.characters_per_second))reason+=`（${w.characters_per_second}字/秒）`;
   if(Number.isSafeInteger(w.overlaps_with))reason+=`；涉及字幕${w.overlaps_with}`;
   return {id:Number.isSafeInteger(w.id)?String(w.id):'未提供',interval:start&&end?start+'–'+end:'时间段未提供',reason};
  });
  const total=count(report.warning_count)??report.warnings.length;
  return {cueCount:show(report.cue_count),warningCount:total,affected:show(report.affected_cue_count),rows,
          truncated:report.warnings_truncated===true||total>rows.length,
          humanReviewed:report.human_listening_complete===true,
          note:'结构检查和警告不能证明听校完成或语义准确。原始字幕保留；请在字幕软件中按编号、时间段定位。'};
 }
 function usageLines(usage){
  return ['text','qwen'].map(provider=>{
   const u=usage?.[provider];const label=provider==='text'?'文字服务商':'千问服务商';
   if(!u||!count(u.reported_requests))return label+'：尚无可识别的token用量返回；不代表零用量或零费用。';
   const metric=key=>count(u[key])===null?'未返回该字段':`${show(u[key])}（${show(u[key+'_reports'])}次有此字段）`;
   return `${label}返回用量：输入token ${metric('input_tokens')}，输出token ${metric('output_tokens')}；仅覆盖已保存响应，不是最终账单。`;
  });
 }
 function usageFile(report){
  if(!report||!Array.isArray(report.requests))return null;
  const out={text:{reported_requests:0},qwen:{reported_requests:0}};
  for(const request of report.requests.slice(0,440)){
   const p=String(request.checkpoint||'').replaceAll('\\','/');const provider=p.startsWith('text/')?'text':p.startsWith('qwen/')?'qwen':null;
   if(!provider||!request.usage||typeof request.usage!=='object')continue;
   let found=false;const u=out[provider];
   for(const key of ['input_tokens','output_tokens','total_tokens']){const n=count(request.usage[key]);if(n!==null){u[key]=(u[key]??0)+n;u[key+'_reports']=(u[key+'_reports']??0)+1;found=true;}}
   if(found)u.reported_requests++;
  }return out;
 }
 async function jsonFile(file,cryptoObject=globalThis.crypto){
  if(!file||typeof file.base64!=='string'||!Number.isSafeInteger(file.bytes)||file.bytes<0||file.bytes>500000||!(/^[0-9a-f]{64}$/).test(file.sha256||''))throw Error('报告元数据无法校验');
  if(file.base64.length>666672)throw Error('报告编码体积超限');
  const raw=Uint8Array.from(atob(file.base64),c=>c.charCodeAt(0));
  if(raw.length!==file.bytes)throw Error('报告大小校验失败');
  const hash=Array.from(new Uint8Array(await cryptoObject.subtle.digest('SHA-256',raw)),x=>x.toString(16).padStart(2,'0')).join('');
  if(hash!==file.sha256)throw Error('报告SHA256校验失败');
  try{return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(raw).replace(/^\uFEFF/,''));}catch{throw Error('报告JSON格式无法识别');}
 }
 const api={job,recoveryCommand,requestHint,quality,usageLines,usageFile,jsonFile};
 if(typeof module==='object'&&module.exports)module.exports=api;else root.CloudJobTools=Object.freeze(api);
})(typeof window==='object'?window:globalThis);
