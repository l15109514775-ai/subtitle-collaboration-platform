const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const source=fs.readFileSync(require('node:path').join(__dirname,'../site/membership.js'),'utf8');
function boot(){
 const nodes=new Map(),calls=[],messages=[];
 const $=id=>{if(!nodes.has(id))nodes.set(id,{value:'',textContent:id==='#email-submit'?'验证邮箱并继续':'',disabled:false,hidden:false,events:{},reset(){},classList:{toggle(){}},scrollIntoView(){},addEventListener(name,handler){this.events[name]=handler}});return nodes.get(id)};
 const c=vm.createContext({console,Date,Error,TypeError,FormData:class{},AbortSignal,BASE:'https://fixture.invalid',SessionFence:{capture:()=>({signal:new AbortController().signal,check(){}})},$,load:async()=>{},logout(){},switchView(){},token:null,expires:0,notify:m=>messages.push(m),document:{querySelectorAll:()=>[]}});
 vm.runInContext(source,c);vm.runInContext('originalAuthMail=authMail',c);
 for(const [id,value] of Object.entries({'email-address':'fixture@example.invalid','email-name':'测试成员','email-username':'abcdef','email-password':'NotARealPassword1!','email-password-confirm':'NotARealPassword1!','email-code':'123456'}))$('#'+id).value=value;
 c.reply=async(path,body)=>{calls.push({path,body});return path==='verification/verify'?{verification_token:'fixture-only'}:{access_token:'fixture-only'}};
 vm.runInContext("emailChallenge={id:'fixture',email:'fixture@example.invalid',isUser:false,until:Date.now()+60000};authMail=(p,b)=>reply(p,b);finishMemberSession=async()=>{membershipState='pending'}",c);
 return {c,$,calls,messages,run:s=>vm.runInContext(s,c),submit:()=>$('#email-form').onsubmit({preventDefault(){}})};
}
(async()=>{
 let count=0;
 for(const username of ['abcde','Abcdef','abcDef','1abcde','abc.de','中文名字测试','a'.repeat(26),'']){const b=boot();b.$('#email-username').value=username;await b.submit();assert.equal(b.calls.length,0);assert.match(b.$('#email-message').textContent,/用户名须为/);assert.equal(b.$('#email-submit').disabled,false);count++}
 for(const username of ['abcdef','a'.repeat(25),'a_1-23']){const b=boot();b.$('#email-username').value=username;await b.submit();assert.equal(b.calls[1].path,'signup');assert.equal(b.calls[1].body.username,username);count++}
 {const b=boot();b.run('emailChallenge.isUser=true');b.$('#email-username').value='';await b.submit();assert.equal(b.calls[1].path,'signin');count++}
 {const b=boot();b.$('#email-form').events.invalid({target:{id:'email-code'}});assert.match(b.$('#email-message').textContent,/6 位数字/);assert.equal(b.calls.length,0);count++}
 for(const change of ['emailChallenge=null','emailChallenge.until=0']){const b=boot();b.run(change);await b.submit();assert.equal(b.calls.length,0);assert.match(b.$('#email-message').textContent,/发送验证码/);assert.equal(b.$('#email-submit').textContent,'验证邮箱并继续');count++}
 {const b=boot();b.c.reply=async p=>{b.calls.push(p);throw Error('验证码不正确')};await b.submit();assert.equal(b.calls.length,1);assert.match(b.$('#email-message').textContent,/验证码不正确/);assert.equal(b.$('#email-submit').disabled,false);count++}
 {const b=boot();b.c.reply=async p=>{b.calls.push(p);if(p==='verification/verify')return{verification_token:'fixture-only'};throw Error('注册结果待确认')};await b.submit();assert.match(b.$('#email-message').textContent,/重新发送验证码/);assert.equal(b.run('emailChallenge'),null);assert.equal(b.$('#email-code').value,'');assert.equal(b.$('#email-password').value,'');const prior=b.calls.length;await b.submit();assert.equal(b.calls.length,prior);count++}
 {const b=boot();let resolve;b.c.reply=async p=>{b.calls.push(p);return new Promise(r=>resolve=r)};const first=b.submit();assert.equal(b.$('#email-submit').textContent,'正在核验邮箱…');await b.submit();assert.equal(b.calls.length,1);resolve({verification_token:'fixture-only'});await Promise.resolve();await Promise.resolve();b.c.reply=async()=>({access_token:'fixture-only'});resolve({access_token:'fixture-only'});await first;assert.equal(b.$('#email-submit').disabled,false);count++}
 {const b=boot();b.c.AbortSignal={any:()=>AbortSignal.abort(),timeout:()=>AbortSignal.abort()};b.c.fetch=async()=>{throw Error('synthetic abort')};await assert.rejects(()=>b.run("originalAuthMail('signup',{})"),/超过 30 秒/);count++}
 console.log(`${count} registration feedback cases passed; no real authentication requests.`);
})().catch(e=>{console.error(e);process.exitCode=1});
