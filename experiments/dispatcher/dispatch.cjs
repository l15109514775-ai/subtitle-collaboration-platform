'use strict';
// Review candidate, disabled by default. Never import or export desktop auth files.
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const {probeEnvironment}=require('./preflight.cjs');
const execFileAsync=promisify(execFile);
const BASE='https://example-env.api.tcloudbasegateway.com';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const TASK_URL=/^https:\/\/chatgpt\.com\/(?:local\/[0-9a-f-]{36}|codex\/tasks\/[A-Za-z0-9_-]{1,120})$/;
class DispatchError extends Error {constructor(code){super(code);this.code=code;}}
function command(job,environment){
 if(!UUID.test(job)||!environment||environment.startsWith('-')||/[\s\x00-\x1f]/.test(environment))throw new DispatchError('invalid_dispatch_config');
 const prompt=`Process only website subtitle job ${job} using the published per-job-v1 workflow. Run platform_worker.py with --job-id ${job} --work-root /workspace/subtitle-platform-production --execute using the prepared Python runtime. Each video must be <=1200 seconds, text requests <=400, Qwen requests <=40, additionally bounded by the server claim. Do not edit code, permissions, config, deadlines, ledgers or quotas. Do not claim another job, reset state, automatically retry ambiguous model requests, or reveal credentials, source URLs or subtitle text. Report only job ID, state and delivery ID. Human review is mandatory.`;
 return ['cloud','exec','--env',environment,'--attempts','1','--branch','cloud/subtitle-20min',prompt];
}
function taskUrl(stdout){
 const urls=String(stdout).match(/https:\/\/chatgpt\.com\/[^\s<>"']+/g)||[];
 const valid=[...new Set(urls.filter(x=>TASK_URL.test(x)))];
 if(valid.length!==1)throw new DispatchError('launch_result_unknown');
 return valid[0];
}
function createDispatcher({config,fetchImpl=fetch,exec=execFileAsync}){
 async function rpc(name,payload,bearer){
  const response=await fetchImpl(BASE+'/v1/rdb/rest/rpc/'+name,{method:'POST',redirect:'error',signal:AbortSignal.timeout(15000),headers:{'Content-Type':'application/json',Authorization:'Bearer '+bearer},body:JSON.stringify(payload)});
  if(!response.ok)throw new DispatchError('platform_request_rejected');
  const text=await response.text();
  if(text.length>20000)throw new DispatchError('platform_response_rejected');
  const result=JSON.parse(text);
  if(!result||Array.isArray(result)||result.error||result.code)throw new DispatchError('platform_response_rejected');
  return result;
 }
 return async function dispatch(input,bearer){
  if(config.enabled!==true||config.environmentVerified!==true)throw new DispatchError('launcher_not_configured');
  if(!input||Object.keys(input).some(k=>!['job_id','request_id'].includes(k))||!UUID.test(input.job_id)||!UUID.test(input.request_id))throw new DispatchError('invalid_request');
  if(typeof bearer!=='string'||bearer.length>16000||/\s/.test(bearer)||!bearer)throw new DispatchError('login_required');
  if(!config.workerToken||!config.gatewayKey||!config.executable||!config.environment)throw new DispatchError('launcher_not_configured');
  // Verify CLI access before changing the outbox. A stale deployment flag must
  // not strand a real job in submitting when the published environment is absent.
  await probeEnvironment(config,exec);
  const authorized=await rpc('st_cloud_launch_request',{p_job:input.job_id,p_request:input.request_id},bearer);
  if(authorized.job_id!==input.job_id||!UUID.test(authorized.request_id))throw new DispatchError('authorization_response_invalid');
  const payload={p_key:config.workerToken,p_job:input.job_id,p_request:authorized.request_id};
  const begin=await rpc('st_cloud_dispatch_call',{...payload,p_action:'begin'},config.gatewayKey);
  if(begin.may_submit!==true)return {state:begin.state,job_id:input.job_id,task_url:begin.task_url||null};
  // Marked submitting BEFORE invoking the CLI. A timeout/crash stays ambiguous;
  // neither browser retries nor a new service instance may submit it again.
  let url;
  try{
   const result=await exec(config.executable,command(input.job_id,config.environment),{shell:false,timeout:90000,maxBuffer:65536,windowsHide:true,cwd:config.cwd,env:config.cliEnv});
   url=taskUrl(result.stdout);
  }catch{
   try{await rpc('st_cloud_dispatch_call',{...payload,p_action:'unknown'},config.gatewayKey);}catch{}
   throw new DispatchError('launch_result_unknown_do_not_resubmit');
  }
  try{
   await rpc('st_cloud_dispatch_call',{...payload,p_action:'submitted',p_task_url:url},config.gatewayKey);
  }catch{throw new DispatchError('launch_result_unknown_do_not_resubmit');}
  return {state:'submitted',job_id:input.job_id,task_url:url};
 };
}
module.exports={createDispatcher,command,taskUrl,DispatchError,BASE};
