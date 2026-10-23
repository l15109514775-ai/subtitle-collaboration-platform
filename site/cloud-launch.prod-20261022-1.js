'use strict';
// Activation requires a verified server dispatcher. No account or provider key belongs here.
const CloudLaunch=Object.freeze({
 configured:()=>window.SUBTITLE_LAUNCH_ENABLED===true,
 instructions(job){
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(job))throw Error('任务编号无效');
  return `请在已发布的字幕交付 Cloud 环境中仅处理网站作业 ${job}。先按 PRODUCTION_FLOW.md 核对固定环境，再运行 .venv/bin/python platform_worker.py --job-id ${job} --work-root /workspace/subtitle-platform-production --execute。单视频上限20分钟、文字400次、千问40次，并服从服务端更低限额。遇到未知请求结果立即停止核对，不重复发送，不修改代码、权限、有效期或账本。按正常流程自动回传九个私有字幕/报告文件后停止；保持人工听校和审核，不发放人工积分。`;
 },
 async start(job,session){
  if(!this.configured())throw Error('云端启动服务尚未接通；素材仍保留在队列中。');
  if(!/^[0-9a-f-]{36}$/.test(job))throw Error('任务编号无效');
  session.check();
  const response=await fetch(BASE+'/subtitle-dispatch',{method:'POST',credentials:'omit',redirect:'error',signal:session.signal,
   headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({job_id:job,request_id:crypto.randomUUID()})});
  session.check();
  if(!response.ok)throw Error('云端启动未确认，请刷新状态核对；不要重复上传视频。');
  const result=await response.json();session.check();
  if(result.job_id!==job||!['submitted','submitting','unknown'].includes(result.state))throw Error('云端启动结果需核对；请保留当前任务。');
  return result;
 }
});
