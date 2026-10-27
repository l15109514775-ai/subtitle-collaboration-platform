const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const source=readFileSync(require('node:path').join(__dirname,'../site/membership.js'),'utf8');
async function run(username,isUser=false){
 const elements=new Map(),calls=[],messages=[];
 const element=id=>{if(!elements.has(id))elements.set(id,{value:'',hidden:false,disabled:false,reset(){}});return elements.get(id)};
 const ctx=vm.createContext({console,Date,Error,FormData:class{},$:element,load:async()=>{},logout(){},switchView(){},token:null,expires:0,notify:m=>messages.push(m),document:{querySelectorAll(){return[]}}});
 vm.runInContext(source,ctx);
 element('#email-address').value='fixture@example.invalid';
 element('#email-name').value='测试成员';element('#email-username').value=username;
 element('#email-password').value='NotARealPassword1!';element('#email-password-confirm').value='NotARealPassword1!';element('#email-code').value='123456';
 ctx.recordCall=(path,body)=>{calls.push({path,body});return path==='verification/verify'?{verification_token:'fixture-only'}:{access_token:'fixture-only'}};
 vm.runInContext(`emailChallenge={id:'fixture',email:'fixture@example.invalid',isUser:${isUser},until:Date.now()+60000};authMail=async(path,body)=>recordCall(path,body);finishMemberSession=async()=>{membershipState='pending'};`,ctx);
 await element('#email-form').onsubmit({preventDefault(){}});
 return {calls,messages,button:element('#email-submit')};
}
(async()=>{
 let count=0;
 for(const username of ['abcde','Abcdef','abcDef','1abcde','abc.de','中文名字测试','a'.repeat(26),'']){
  const result=await run(username);assert.equal(result.calls.length,0,username+' must fail before consuming OTP');assert.match(result.messages.at(-1),/用户名须为 6–25 位/);assert.equal(result.button.disabled,false);count++;
 }
 for(const username of ['abcdef','a'.repeat(25),'a_1-23']){
  const result=await run(username);assert.equal(result.calls[0].path,'verification/verify');assert.equal(result.calls[1].path,'signup');assert.equal(result.calls[1].body.username,username);assert.equal(result.button.disabled,false);count++;
 }
 const existing=await run('',true);assert.equal(existing.calls[1].path,'signin');count++;
 console.log(`${count} registration flow cases passed; all authentication calls mocked.`);
})().catch(error=>{console.error(error);process.exitCode=1});
