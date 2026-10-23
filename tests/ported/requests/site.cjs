const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),test=require('node:test');
const source=fs.readFileSync(require('node:path').join(__dirname,'../../../site/subtitle-requests.delete-20261023-3.js'),'utf8');
function boot(){
 const nodes=new Map();const node=()=>({innerHTML:'',textContent:'',hidden:false,disabled:false,addEventListener(){},before(){},append(){},replaceChildren(){},reset(){},close(){},showModal(){},querySelectorAll(){return []}});
 const $=s=>{if(!nodes.has(s))nodes.set(s,node());return nodes.get(s)};
 const c={URLSearchParams,location:{search:''},document:{createElement:node,body:node(),querySelectorAll(){return []}},$,
  data:{me:{owner:true}},SessionFence:{capture:()=>({check(){}})},CloudJobTools:{requestHint:()=>''},cloudStates:{},MediaFiles:{bytes:()=>''},
  esc:s=>String(s).replace(/[&<>"']/g,x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[x])),empty:s=>s,
  load:async()=>{},logout(){},run:fn=>fn(),rpc:async()=>({requests:[]}),setInterval(){}};
 vm.createContext(c);vm.runInContext(source,c);return {c,nodes,run:s=>vm.runInContext(s,c)};
}
test('delete control appears only on eligible withdrawn request; text is escaped',()=>{
 const b=boot();b.run(`subtitleRequests=[{id:'fixture',state:'withdrawn',can_delete:true,stream_title:'<script>',created_at:'2026-10-23'}];renderSubtitleRequests()`);
 assert(b.nodes.get('#subtitle-request-list').innerHTML.includes('data-request-delete="fixture"'));assert(!b.nodes.get('#subtitle-request-list').innerHTML.includes('<script>'));
 for(const state of ['pending','approved','rejected','uploading']){b.run(`subtitleRequests[0].state='${state}';renderSubtitleRequests()`);assert(!b.nodes.get('#subtitle-request-list').innerHTML.includes('data-request-delete='));}
 b.run(`subtitleRequests[0].state='withdrawn';subtitleRequests[0].can_delete=false;renderSubtitleRequests()`);assert(!b.nodes.get('#subtitle-request-list').innerHTML.includes('data-request-delete='));
});
test('deleted request offers restore rather than another delete',()=>{
 const b=boot();b.run(`subtitleRequests=[{id:'fixture',state:'withdrawn',can_delete:true,deleted_at:'2026-10-23',created_at:'2026-10-23'}];renderSubtitleRequests()`);
 const html=b.nodes.get('#subtitle-request-list').innerHTML;assert(html.includes('data-request-restore="fixture"'));assert(!html.includes('data-request-delete='));
});
test('deleted-list toggle uses server trash RPC; return uses ordinary list RPC',async()=>{
 const b=boot(),calls=[];b.c.rpc=async(name)=>{calls.push(name);return {requests:[]}};
 await b.nodes.get('#subtitle-request-deleted').onclick();assert.equal(calls[0],'st_subtitle_requests_trash');assert.equal(b.nodes.get('#subtitle-request-deleted').textContent,'返回申请列表');assert.equal(b.nodes.get('#subtitle-request-list').innerHTML,'暂无已删除申请。');
 await b.nodes.get('#subtitle-request-deleted').onclick();assert.equal(calls[1],'st_subtitle_requests_view');assert.equal(b.nodes.get('#subtitle-request-deleted').textContent,'已删除申请');
});
test('logout clears deleted-list mode to prevent leaking the prior session view',()=>{const b=boot();b.run('showDeletedSubtitleRequests=true;logout()');assert.equal(b.run('showDeletedSubtitleRequests'),false);});
test('inline confirmation can cancel, confirm, or be cancelled by logout',async()=>{const b=boot();let p=b.run("confirmRequestDelete('fixture')");b.nodes.get('#request-delete-cancel').onclick();assert.equal(await p,false);p=b.run("confirmRequestDelete('fixture')");b.nodes.get('#request-delete-confirm').onclick();assert.equal(await p,true);p=b.run("confirmRequestDelete('fixture')");b.run('logout()');assert.equal(await p,false);});

test('owner can delete approved cancelled application but not queued or running work',()=>{const b=boot();b.run(`subtitleRequests=[{id:'fixture',state:'approved',job_state:'cancelled',can_delete:true,created_at:'2026-10-23'}];renderSubtitleRequests()`);assert(b.nodes.get('#subtitle-request-list').innerHTML.includes('data-request-delete="fixture"'));for(const state of ['queued','running','waiting_reconciliation']){b.run(`subtitleRequests[0].job_state='${state}';renderSubtitleRequests()`);assert(!b.nodes.get('#subtitle-request-list').innerHTML.includes('data-request-delete='));}});
