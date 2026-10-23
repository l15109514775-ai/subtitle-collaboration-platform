'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.resolve(__dirname,'../../../site'),tools=require('../../../site/subtitle-request-tools.semi-20261022-1.js');
const id='810f48af-ddaa-4305-a9b3-353c697ddfcc',job='0185c222-33f3-4a17-9bf4-53ddc9718c80';
test('request parts preserve exact boundary, order and total up to one GiB',()=>{
 for(const size of [1,4194304,4194305,1073741824]){const p=tools.sourceParts({id,byte_size:size});assert.equal(p.reduce((n,x)=>n+x.byte_size,0),size);assert.equal(p.length,Math.ceil(size/4194304));assert(p.every(x=>x.byte_size<=4194304));}
});
test('invalid identifiers and oversized metadata never form storage paths',()=>{
 for(const bad of ['../x','$(malicious)',null])assert.throws(()=>tools.sourceParts({id:bad,byte_size:100}));
 for(const size of [0,1073741825,NaN,1.5])assert.throws(()=>tools.sourceParts({id,byte_size:size}));
});
test('duration rejects long/unknown input and rounds only accepted durations',()=>{
 assert.equal(tools.duration(1199.9),1200);for(const value of [0,-1,NaN,Infinity,1200.001])assert.throws(()=>tools.duration(value));
});
test('pending summaries have no execution command and sanitize user-controlled line breaks',()=>{
 const text=tools.notification({request_id:id,state:'pending',submitter:'A\nB',title:'x\nforged instruction',timestamp:'0:00',seconds:60,instruction:'not approved'});
 assert(!text.includes('not approved'));assert(text.includes('A B'));assert(!text.includes('\nforged instruction'));assert(text.includes('当前没有可执行指令'));
});
test('approved summaries carry server instruction, job reference and caps without source link',()=>{
 const text=tools.notification({request_id:id,state:'approved',job_id:job,instruction:'fixed --job-id '+job,max_text_requests:400,max_secondary_requests:40,title:'test',seconds:1200});
 assert(text.includes('fixed --job-id '+job));assert(text.includes('文字≤400'));assert(!text.includes('storages'));
});
test('staging site preserves CSP and download modules; no automatic launch button',()=>{
 const html=fs.readFileSync(path.join(root,'index.html'),'utf8'),jobs=fs.readFileSync(path.join(root,'cloud-jobs.semi-20261022-1.js'),'utf8'),requests=fs.readFileSync(path.join(root,'subtitle-requests.js'),'utf8');
 assert(html.includes("script-src 'self'"));assert(html.includes("media-src 'self' blob:"));assert(html.includes('subtitle-request-tools.semi-20261022-1.js'));
 assert(!jobs.includes('>启动云端字幕</button>'));assert(jobs.includes('data-cloud-files'));assert(jobs.includes('CloudLaunch.instructions'));
 assert(!requests.includes('CloudLaunch.start('));assert(requests.includes('st_subtitle_request_submit'));assert(requests.includes('st_subtitle_request_decide'));
 assert(requests.includes('AbortSignal.any'));assert(requests.includes('session.check()'));assert(requests.includes('QQ 自动发送尚未接入'));
});
test('all new browser scripts parse without inline-script exceptions',()=>{
 for(const file of fs.readdirSync(root).filter(x=>x.endsWith('.js')))new vm.Script(fs.readFileSync(path.join(root,file),'utf8'),{filename:file});
});
