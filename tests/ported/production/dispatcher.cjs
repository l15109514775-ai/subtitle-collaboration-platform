'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createDispatcher,command,taskUrl}=require('../../../experiments/dispatcher/dispatch.cjs');
const {createHandler}=require('../../../experiments/dispatcher/http.cjs');
const {probeEnvironment}=require('../../../experiments/dispatcher/preflight.cjs');
const job='810f48af-ddaa-4305-a9b3-353c697ddfcc',request='0185c222-33f3-4a17-9bf4-53ddc9718c80';
const url='https://chatgpt.com/local/00000000-0000-4000-8000-000000000000';
function fixture(overrides={}){
 const calls=[];let executions=0,launchState='requested';
 const config={enabled:true,environmentVerified:true,environment:'verified-test-env',executable:'/review-only/codex',workerToken:'synthetic-worker',gatewayKey:'synthetic-publishable',cliEnv:{},...overrides};
 const dispatch=createDispatcher({config,exec:async(...args)=>{if(args[1][1]==='list')return {stdout:'{"tasks":[],"cursor":null}'};executions++;calls.push({exec:args});return {stdout:url};},fetchImpl:async(target,options)=>{
  const payload=JSON.parse(options.body);calls.push({target,options,payload});
  let data;
  if(target.endsWith('st_cloud_launch_request'))data={job_id:job,request_id:request,state:launchState};
  else if(payload.p_action==='begin'){const allowed=launchState==='requested';if(allowed)launchState='submitting';data={state:launchState,may_submit:allowed};}
  else {launchState=payload.p_action;data={state:launchState};}
  return {ok:true,text:async()=>JSON.stringify(data)};
 }});
 return {dispatch,calls,get executions(){return executions;}};
}
test('disabled launcher cannot send even a platform request',async()=>{
 const f=fixture({enabled:false});await assert.rejects(()=>f.dispatch({job_id:job,request_id:request},'synthetic-user'));assert.equal(f.calls.length,0);
});
test('unverified native environment blocks launch',async()=>{
 const f=fixture({environmentVerified:false});await assert.rejects(()=>f.dispatch({job_id:job,request_id:request},'synthetic-user'));assert.equal(f.executions,0);
});
test('server command accepts UUID only; shell is disabled and one attempt fixed',async()=>{
 assert.throws(()=>command('$(malicious)', 'env'));const f=fixture();await f.dispatch({job_id:job,request_id:request},'synthetic-user');
 const call=f.calls.find(x=>x.exec).exec;assert.equal(call[2].shell,false);assert.equal(call[1][call[1].indexOf('--attempts')+1],'1');
 assert.ok(!JSON.stringify(call).includes('synthetic-worker'));assert.ok(!JSON.stringify(call).includes('synthetic-user'));
});
test('browser credentials are used only for the owner RPC; capability only for dispatch RPC',async()=>{
 const f=fixture();await f.dispatch({job_id:job,request_id:request},'synthetic-user');
 const requests=f.calls.filter(x=>x.target);assert.equal(requests[0].options.headers.Authorization,'Bearer synthetic-user');
 assert.ok(requests.slice(1).every(x=>x.options.headers.Authorization==='Bearer synthetic-publishable'));
 assert.ok(requests.every(x=>x.target.startsWith('https://example-env.api.tcloudbasegateway.com/')));
 assert.ok(requests.every(x=>x.options.redirect==='error'));
});
test('concurrent or repeated clicks produce a single CLI invocation',async()=>{
 const f=fixture();await Promise.all([f.dispatch({job_id:job,request_id:request},'synthetic-user'),f.dispatch({job_id:job,request_id:request},'synthetic-user')]);
 assert.equal(f.executions,1);
});
test('failed CLI stays ambiguous; no automatic submission retry',async()=>{
 let executions=0,calls=[];
 const dispatch=createDispatcher({config:{enabled:true,environmentVerified:true,environment:'test-env',executable:'/codex',workerToken:'fixture',gatewayKey:'fixture'},exec:async(file,args)=>{if(args[1]==='list')return {stdout:'{"tasks":[]}'};executions++;throw Error('private command output must never escape');},fetchImpl:async(target,opt)=>{
  const p=JSON.parse(opt.body);calls.push(p);return {ok:true,text:async()=>JSON.stringify(target.endsWith('st_cloud_launch_request')?{job_id:job,request_id:request}:p.p_action==='begin'?{may_submit:true,state:'submitting'}:{state:'unknown'})};
 }});
 await assert.rejects(()=>dispatch({job_id:job,request_id:request},'fixture'),{message:'launch_result_unknown_do_not_resubmit'});
 assert.equal(executions,1);assert.equal(calls.at(-1).p_action,'unknown');
});
test('reject untrusted task URLs or multiple results',()=>{
 assert.throws(()=>taskUrl('https://evil.example/x'));assert.throws(()=>taskUrl(url+' https://chatgpt.com/local/00000000-0000-4000-8000-000000000000'));
 assert.equal(taskUrl(url),url);
});
test('HTTP boundary rejects foreign origins, oversized bodies and missing login',async()=>{
 let calls=0;const handler=createHandler(async()=>{calls++;return {state:'submitted'};});
 const event={httpMethod:'POST',headers:{origin:'https://example-site.tcloudbaseapp.com','content-type':'application/json',authorization:'Bearer fixture'},body:'{}'};
 assert.equal((await handler({...event,headers:{...event.headers,origin:'https://evil.example'}})).statusCode,403);
 assert.equal((await handler({...event,body:'x'.repeat(1025)})).statusCode,400);
 assert.equal((await handler({...event,headers:{...event.headers,authorization:''}})).statusCode,401);
 assert.equal(calls,0);
});
test('missing CLI environment cannot mutate outbox or submit a job even with stale verified flag',async()=>{
 let writes=0;const commands=[];
 const dispatch=createDispatcher({config:{enabled:true,environmentVerified:true,environment:'test-env',executable:'/codex',workerToken:'fixture',gatewayKey:'fixture'},exec:async(file,args)=>{commands.push(args);throw Error('private CLI failure');},fetchImpl:async()=>{writes++;throw Error('must not reach platform');}});
 await assert.rejects(()=>dispatch({job_id:job,request_id:request},'fixture'),{code:'cloud_environment_unavailable'});
 assert.equal(writes,0);assert.equal(commands.length,1);assert.equal(commands[0][1],'list');
});
test('read-only probe rejects malformed output and conceals private CLI failure text',async()=>{
 const cfg={executable:'/codex',environment:'test-env'};
 await assert.rejects(()=>probeEnvironment(cfg,async()=>({stdout:'not JSON; private details'})),{message:'cloud_environment_unavailable'});
 await assert.rejects(()=>probeEnvironment(cfg,async()=>({stdout:'{"tasks":null}'})),{code:'cloud_environment_unavailable'});
});
test('probe uses a bounded read-only command without credentials in arguments',async()=>{
 let observed;const result=await probeEnvironment({executable:'/codex',environment:'test-env'},async(...args)=>{observed=args;return {stdout:'{"tasks":[],"cursor":null}'};});
 assert.equal(result.available,true);assert.deepEqual(observed[1],['cloud','list','--env','test-env','--limit','1','--json']);assert.equal(observed[2].shell,false);
});
