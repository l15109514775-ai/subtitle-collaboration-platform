'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'../../site'),tools=require(path.join(root,'cloud-job-tools.ops-20261022-2.js'));
const id='810f48af-ddaa-4305-a9b3-353c697ddfcc';
test('incremental index preserves concurrently published QQ binding and group menu',()=>{
 const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
 assert(html.includes('qq-binding.bridge-20261022-1.js'));
 assert(html.includes('字幕助手'));assert(html.includes('QQ 账号绑定'));
});
test('queued is manual launch, not an automatic dispatch promise',()=>{
 const j=tools.job({state:'queued',progress:{text_requests:0,secondary_requests:0}});
 assert.equal(j.label,'待人工启动');assert(j.next.includes('发送一次'));assert(j.reserved.includes('已预留'));assert(!j.canPublishOnly);
});
test('expired source only suggests same-job authorization refresh',()=>{
 const j=tools.job({state:'queued',source_expires_at:'2020-01-01T00:00:00Z'});
 assert(j.next.includes('刷新素材授权'));assert(j.next.includes('不会重新识别或重置额度'));
});
test('unknown model request never offers retry or upload recovery without proof',()=>{
 const j=tools.job({state:'waiting_reconciliation',progress:{}});
 assert(j.next.includes('禁止自动重发'));assert(!j.canPublishOnly);assert(j.retained.includes('无法确认'));
});
test('upload recovery requires running job and saved payload evidence',()=>{
 const progress={operations_v1:{version:1,recovery:{mode:'same_lease_publish_only',publish_payload_saved:true}}};
 assert(tools.job({state:'running',stage:'publish_result_needs_reconciliation',progress}).canPublishOnly);
 for(const state of ['queued','failed','waiting_reconciliation','cancelled','succeeded'])assert(!tools.job({state,progress}).canPublishOnly);
});
test('recovery command has exact UUID and publish-only guard; rejects injected shell',()=>{
 const command=tools.recoveryCommand(id);assert(command.includes('--job-id '+id));assert(command.includes('--execute --publish-only'));
 assert(command.includes('原Codex Cloud对话'));assert(!command.includes('SUBTITLE_'));
 for(const value of ['../x','$(whoami)',id+'; rm -rf /',null])assert.throws(()=>tools.recoveryCommand(value));
});
test('missing counters and usage are unknown rather than zero cost',()=>{
 const j=tools.job({state:'running',progress:{}});assert(j.reserved.includes('未上报'));
 const text=tools.usageLines(null).join('');assert(text.includes('不代表零用量或零费用'));
});
test('provider partial coverage and returned zero are displayed distinctly',()=>{
 const lines=tools.usageLines({text:{reported_requests:2,input_tokens:0,input_tokens_reports:1,output_tokens:12,output_tokens_reports:2}});
 assert(lines[0].includes('输入token 0（1次'));assert(lines[0].includes('不是最终账单'));
});
test('outdated running status is not claimed to be live progress',()=>{
 assert(tools.job({state:'running',updated_at:'2020-01-01T00:00:00Z'}).stale);
 assert(!tools.job({state:'succeeded',updated_at:'2020-01-01T00:00:00Z'}).stale);
});
test('quality warnings retain IDs, times, reasons and human review boundary',()=>{
 const r=tools.quality({cue_count:2,warning_count:1,affected_cue_count:1,warnings:[{id:7,start:60,end:62,code:'overlap',overlaps_with:2}]});
 assert.equal(r.rows[0].interval,'1:00.00–1:02.00');assert.equal(r.rows[0].id,'7');assert(r.rows[0].reason.includes('字幕2'));assert(!r.humanReviewed);
});
test('legacy report uses cue timestamps without inventing a precise cause',()=>{
 const r=tools.quality({cue_count:1,warnings:[{id:3,reason:'timing, reading speed, or recognition uncertainty'}]},[{id:3,start:.5,end:1.5}]);
 assert.equal(r.rows[0].interval,'0:00.50–0:01.50');assert(r.rows[0].reason.includes('旧版综合警告'));assert.equal(r.affected,'未上报');
});
test('quality rendering is bounded and totals survive truncation',()=>{
 const r=tools.quality({cue_count:3000,warning_count:5000,affected_cue_count:3000,warnings:Array.from({length:800},(_,id)=>({id,code:'review_requested'})),warnings_truncated:true});
 assert.equal(r.rows.length,200);assert.equal(r.warningCount,5000);assert(r.truncated);
});
test('provider file summary ignores private text and preserves missing usage',()=>{
 const result=tools.usageFile({requests:[{checkpoint:'text/000/request-state.json',usage:{input_tokens:4,private:'private-sentinel'}},{checkpoint:'qwen/000/request-state.json',usage:null}]});
 assert.equal(result.text.input_tokens,4);assert.equal(result.qwen.reported_requests,0);assert(!JSON.stringify(result).includes('private-sentinel'));
});
test('report JSON is accepted only after byte-size and SHA256 verification',async()=>{
 const raw=Buffer.from(JSON.stringify({warnings:[]})),f={base64:raw.toString('base64'),bytes:raw.length,sha256:crypto.createHash('sha256').update(raw).digest('hex')};
 assert.deepEqual(await tools.jsonFile(f,crypto.webcrypto),{warnings:[]});
 await assert.rejects(()=>tools.jsonFile({...f,sha256:'0'.repeat(64)},crypto.webcrypto));
 await assert.rejects(()=>tools.jsonFile({...f,bytes:f.bytes+1},crypto.webcrypto));
 await assert.rejects(()=>tools.jsonFile({...f,base64:'a'.repeat(666673)},crypto.webcrypto));
});
test('scripts parse, CSP stays strict, manual launch and same authorized file RPC remain',()=>{
 for(const name of ['cloud-job-tools.ops-20261022-2.js','cloud-jobs.workers-20261023-1.js','subtitle-requests.delete-20261023-3.js'])new vm.Script(fs.readFileSync(path.join(root,name),'utf8'));
 const html=fs.readFileSync(path.join(root,'index.html'),'utf8'),jobs=fs.readFileSync(path.join(root,'cloud-jobs.workers-20261023-1.js'),'utf8');
 assert(html.includes("script-src 'self'"));assert(!html.includes("'unsafe-inline'"));
 assert(html.indexOf('cloud-job-tools.ops')<html.indexOf('cloud-jobs.workers'));
 assert(jobs.includes("rpc('st_cloud_files'"));assert(jobs.includes('session.check()'));
 assert(jobs.includes('esc(row.reason)'));assert(!jobs.includes('>启动云端字幕</button>'));
});
