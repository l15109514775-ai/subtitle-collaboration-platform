'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const root=path.join(__dirname,'../../../site'),source=fs.readFileSync(path.join(root,'cloud-launch.prod-20261022-1.js'),'utf8');
const job='810f48af-ddaa-4305-a9b3-353c697ddfcc';
function client({enabled=true,response={job_id:job,state:'submitted'},ok=true,check=()=>{}}={}){
 let calls=[];
 const c=vm.runInNewContext(source+'\nCloudLaunch;',{window:{SUBTITLE_LAUNCH_ENABLED:enabled},BASE:'https://example-env.api.tcloudbasegateway.com',token:'synthetic-session',crypto:{randomUUID:()=>job},fetch:async(...args)=>{calls.push(args);return {ok,json:async()=>response};}});
 return {c,calls,session:{signal:undefined,check}};
}
test('disconnected website never sends a launch request',async()=>{
 const {c,calls,session}=client({enabled:false});await assert.rejects(()=>c.start(job,session));assert.equal(calls.length,0);
});
test('manual Cloud instructions contain only the exact job and fixed workflow',()=>{
 const {c}=client();assert.ok(c.instructions(job).includes('--job-id '+job));assert.ok(c.instructions(job).includes('PRODUCTION_FLOW.md'));
 assert.throws(()=>c.instructions('$(malicious)'));
});
test('launch uses fixed destination and user session, never input source URLs',async()=>{
 const {c,calls,session}=client();assert.equal((await c.start(job,session)).state,'submitted');
 assert.equal(calls.length,1);assert.equal(calls[0][1].redirect,'error');assert.equal(calls[0][1].credentials,'omit');
 assert.equal(calls[0][0],'https://example-env.api.tcloudbasegateway.com/subtitle-dispatch');
 assert.deepEqual(Object.keys(JSON.parse(calls[0][1].body)).sort(),['job_id','request_id']);
});
test('failed launch has no automatic retry',async()=>{
 const {c,calls,session}=client({ok:false});await assert.rejects(()=>c.start(job,session));assert.equal(calls.length,1);
});
test('mismatched job response is rejected',async()=>{
 const {c,session}=client({response:{job_id:'different',state:'submitted'}});await assert.rejects(()=>c.start(job,session));
});
test('expired session cannot dispatch',async()=>{
 const {c,calls,session}=client({check:()=>{throw Error('session changed');}});await assert.rejects(()=>c.start(job,session));assert.equal(calls.length,0);
});
test('site bundle retains strict CSP, file modules and safe upload failure boundary',()=>{
 const html=fs.readFileSync(path.join(root,'index.html'),'utf8'),jobs=fs.readFileSync(path.join(root,'cloud-jobs.js'),'utf8');
 assert(html.includes("script-src 'self'"));assert(!/cloud-clips(?:-host)?\.(js|css)/.test(html));
 assert(html.indexOf('cloud-launch.prod-20261022-1.js')<html.indexOf('cloud-jobs.prod-20261022-1.js'));
 assert(jobs.includes('if(job&&!sourceReady&&!session.signal?.aborted)'));
 assert(jobs.includes("data-cloud-start"));
 for(const file of fs.readdirSync(root).filter(x=>x.endsWith('.js')))new vm.Script(fs.readFileSync(path.join(root,file),'utf8'),{filename:file});
});

