const assert=require('node:assert/strict'),crypto=require('node:crypto'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const root=path.resolve(__dirname,'../../../site');
global.crypto=crypto.webcrypto;global.sha256=require(path.join(root,'sha256.min.js'));
const {SessionFence,SecurityFiles}=require(path.join(root,'security.js'));
const results=[];
async function test(name,fn){await fn();results.push({name,result:'pass'});console.log('PASS',name);}
const bytes=Buffer.from('synthetic private bytes, never user media');
const asset={byte_size:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),mime_type:'video/mp4'};
(async()=>{
 await test('correct file bytes and SHA',async()=>{const b=await SecurityFiles.verifiedDownload(new Response(bytes),asset);assert.deepEqual(Buffer.from(await b.arrayBuffer()),bytes);});
 await test('same-size corrupt content rejected',async()=>{await assert.rejects(SecurityFiles.verifiedDownload(new Response(Buffer.alloc(bytes.length)),asset),/SHA/);});
 await test('oversize stream rejected',async()=>{await assert.rejects(SecurityFiles.verifiedDownload(new Response(Buffer.concat([bytes,bytes])),asset),/大小/);});
 await test('partial response rejected',async()=>{await assert.rejects(SecurityFiles.verifiedDownload(new Response(bytes.subarray(0,4)),asset),/SHA/);});
 await test('verified stream commits after hash',async()=>{let closed=false,aborted=false;const chunks=[];const handle={createWritable:async()=>({write:async v=>chunks.push(v),close:async()=>{closed=true;},abort:async()=>{aborted=true;}})};await SecurityFiles.verifiedDownload(new Response(bytes),asset,{handle});assert(closed);assert(!aborted);assert.deepEqual(Buffer.concat(chunks),bytes);});
 await test('bad stream aborts without commit',async()=>{let closed=false,aborted=false;const handle={createWritable:async()=>({write:async()=>{},close:async()=>{closed=true;},abort:async()=>{aborted=true;}})};await assert.rejects(SecurityFiles.verifiedDownload(new Response(Buffer.alloc(bytes.length)),asset,{handle}),/SHA/);assert(aborted);assert(!closed);});
 await test('logout invalidates in-flight session',async()=>{const s=SessionFence.capture();s.check();SessionFence.clear();assert(s.signal.aborted);assert.throws(()=>s.check(),/会话/);SessionFence.capture().check();});
 await test('logout aborts downloads',async()=>{const abort=new AbortController();abort.abort();await assert.rejects(SecurityFiles.verifiedDownload(new Response(bytes),asset,{signal:abort.signal}),/取消/);});
 await test('expiry callback clears private state',async()=>{let expired=false;SessionFence.arm(1,()=>{expired=true;SessionFence.clear();});await new Promise(r=>setTimeout(r,10));assert(expired);});
 await test('late authenticated RPC response cannot repopulate page',async()=>{
  let release;const response=new Promise(r=>release=r);
  const elements=new Map();function el(id){if(!elements.has(id))elements.set(id,{hidden:false,value:'',textContent:'',classList:{toggle(){}},replaceChildren(){},close(){},reset(){}});return elements.get(id);}
  const context=vm.createContext({SessionFence,AbortController,fetch:()=>response,document:{querySelector:el,querySelectorAll:()=>[]},window:{addEventListener(){}},Date,Error,Number,JSON,FormData:class{},URL,Blob,setTimeout,clearTimeout});
  vm.runInContext(fs.readFileSync(path.join(root,'app.js'),'utf8'),context);
  vm.runInContext("token='fake-session';expires=Date.now()+10000",context);
  const pending=vm.runInContext("request('/fixture',{})",context);vm.runInContext('logout()',context);
  release({ok:true,text:async()=>'{"private":"synthetic"}'});await assert.rejects(pending,/会话/);assert.equal(vm.runInContext('data',context),null);
 });
 await test('business admin controls remain owner-only and use scoped RPC',async()=>{
  const calls=[],prompts=['Member A','Synthetic access revocation'];
  function node(){return {children:[],textContent:'',hidden:false,append(...x){this.children.push(...x);},replaceChildren(){this.children=[];},setAttribute(){}};}
  const members=node(),logout=node();
  const context=vm.createContext({SessionFence,document:{createElement:node,getElementById:()=>members},window:{prompt:()=>prompts.shift()},rpc:async(name,args)=>{calls.push({name,args});return name==='st_security_members'?[{id:'owner',display_name:'Owner',state:'active',owner:true},{id:'a',display_name:'Member A',state:'active',owner:false,blocked:false}]:undefined;},notify(){}});
  context.logoutButton=logout;
  vm.runInContext("const $=()=>logoutButton;let data={me:{id:'owner',owner:true}},project='project-a';function load(){}function logout(){data=null}",context);
  vm.runInContext(fs.readFileSync(path.join(root,'security-admin.js'),'utf8'),context);
  await vm.runInContext('load()',context);
  const panel=members.children[0],list=panel.children[2];assert.equal(list.children[0].children.length,1);assert.equal(list.children[1].children.length,3);
  await list.children[1].children[2].onclick();
  const change=calls.find(c=>c.name==='st_set_project_block');assert.equal(change.args.p_project,'project-a');assert.equal(change.args.p_member,'a');assert.equal(change.args.p_block,true);
  const count=calls.filter(c=>c.name==='st_security_members').length;
  vm.runInContext('data.me.owner=false',context);await vm.runInContext('load()',context);assert(panel.hidden);assert.equal(calls.filter(c=>c.name==='st_security_members').length,count);
  vm.runInContext('logout()',context);assert.equal(list.children.length,0);
 });
 for(const file of (await fs.promises.readdir(root)).filter(n=>n.endsWith('.js')))new vm.Script(await fs.promises.readFile(path.join(root,file),'utf8'),{filename:file});
 results.push({name:'all deployed-source JavaScript syntax',result:'pass'});
 await fs.promises.writeFile(path.join(__dirname,'../frontend-results.json'),JSON.stringify({live:false,tests:results,limitations:['DOM and streams simulated; no real browser UI or filesystem picker tested']},null,2));
 SessionFence.clear();
})().catch(e=>{SessionFence.clear();console.error(e);process.exitCode=1;});
