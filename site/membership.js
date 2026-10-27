'use strict';
// Registration creates an application only. Project access remains server controlled.
let membershipState=null,emailChallenge=null,emailSentAt=0,emailCaptcha=null;
const memberLoad=load,memberLogout=logout,memberSwitch=switchView;
async function authMail(path,body,headers={}){
 const session=SessionFence.capture();
 const r=await fetch(BASE+'/auth/v1/'+path,{method:'POST',signal:session.signal,credentials:'omit',cache:'no-store',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
 let v;try{v=await r.json()}catch{throw Error('认证服务返回异常，请稍后重试')}
 session.check();if(!r.ok||v.error){const e=Error(v.error_description||v.message||'验证未完成，请检查验证码或稍后重试');e.code=typeof v.error==='string'?v.error:v.error?.code;throw e}return v;
}
function waiting(status){
 membershipState=status.state;$('#login').hidden=true;$('#workspace').hidden=true;$('#guide-view').hidden=true;$('#membership-wait').hidden=false;$('#logout').hidden=false;
 $('#identity').textContent=(status.display_name||'新成员')+' · '+({suspended:'账号已停用',rejected:'申请未通过',unsubmitted:'尚未申请'}[status.state]||'等待分配');
 $('#membership-status').textContent=({suspended:'账号已停用，请联系组长。',rejected:'申请未通过，请联系组长核对。',unsubmitted:'邮箱已验证，请填写组内昵称并提交申请。'}[status.state]||'注册申请已提交，等待组长分配项目和身份。当前账号不能查看项目、文件、任务或积分。');
 $('#membership-apply').hidden=status.state!=='unsubmitted';notify('邮箱登录成功；项目权限由组长单独分配。');
}
async function finishMemberSession(s){
 if(!s?.access_token)throw Error('未取得登录会话');token=s.access_token;expires=Date.now()+(Number(s.expires_in)||7200)*1000;
 SessionFence.arm(expires-Date.now(),()=>{logout();notify('登录已过期，请重新登录。');});
 const status=await rpc('st_membership_status');membershipState=status.state;
 if(status.state!=='active'){waiting(status);return}
 $('#membership-wait').hidden=true;await load();$('#logout').hidden=false;switchView('board');notify('已登录协作台。');
}
switchView=function(next){if(token&&membershipState&&membershipState!=='active'){if(next==='guide'){$('#membership-wait').hidden=true;memberSwitch('guide')}else waiting({state:membershipState,display_name:$('#identity').textContent.split(' · ')[0]});return}memberSwitch(next)};
logout=function(){membershipState=null;emailChallenge=null;emailCaptcha=null;$('#membership-wait').hidden=true;$('#email-form').reset();$('#email-captcha').hidden=true;memberLogout()};$('#logout').onclick=logout;
$('#login-form').onsubmit=async e=>{e.preventDefault();const form=e.currentTarget,button=form.querySelector('button'),f=new FormData(form);button.disabled=true;try{const s=await request('/auth/v1/signin',{username:f.get('username'),password:f.get('password')},false);form.reset();await finishMemberSession(s)}catch(err){logout();notify(err.message,true)}finally{button.disabled=false}};
$('#email-open').onclick=()=>{$('#email-form').hidden=false;$('#login-form').hidden=true};
$('#password-open').onclick=()=>{$('#email-form').hidden=true;$('#login-form').hidden=false};
$('#email-captcha-refresh').onclick=()=>run(async()=>{emailCaptcha=await authMail('captcha/data',{});if(!/^data:image\/(gif|png|jpeg);base64,/i.test(emailCaptcha.data||''))throw Error('图片验证码格式异常');$('#email-captcha-image').src=emailCaptcha.data;$('#email-captcha').hidden=false;$('#email-captcha-code').value=''});
$('#email-send').onclick=async()=>{
 const b=$('#email-send'),email=$('#email-address').value.trim();if(!$('#email-address').reportValidity())return;
 if(Date.now()-emailSentAt<60000){notify('请等待一分钟后再发送验证码。',true);return}b.disabled=true;emailChallenge=null;
 try{let headers={};if(emailCaptcha){const c=await authMail('captcha/data/verify',{token:emailCaptcha.token,key:$('#email-captcha-code').value.trim()});headers['x-captcha-token']=c.captcha_token}
 const r=await authMail('verification',{email,target:'ANY'},headers);if(!r.verification_id)throw Error('未取得邮箱验证编号');emailChallenge={id:r.verification_id,email,isUser:!!r.is_user,until:Date.now()+(Number(r.expires_in)||600)*1000};emailSentAt=Date.now();emailCaptcha=null;$('#email-captcha').hidden=true;$('#email-new-fields').hidden=!!r.is_user;notify('验证码已发送，请检查收件箱和垃圾邮件。');
 }catch(err){if(err.code==='captcha_required'){$('#email-captcha-refresh').click();notify('请先完成图片验证，再点击发送邮箱验证码。',true)}else notify(err.message,true)}finally{b.disabled=false}
};
$('#email-address').oninput=()=>{emailChallenge=null;$('#email-code').value='';$('#email-new-fields').hidden=false};
$('#email-form').onsubmit=async e=>{
 e.preventDefault();const b=$('#email-submit');b.disabled=true;
 try{const c=emailChallenge;if(!c||c.email!==$('#email-address').value.trim()||Date.now()>c.until)throw Error('请先向当前邮箱发送验证码，过期后需重新发送');
 const name=$('#email-name').value.trim(),username=$('#email-username').value.trim(),password=$('#email-password').value;
 if(!c.isUser&&!name)throw Error('请填写组内昵称，昵称可以使用中文');
 if(!c.isUser&&!(/^[a-z][0-9a-z_-]{5,24}$/).test(username))throw Error('用户名须为 6–25 位，以小写英文字母开头，只能包含小写字母、数字、下划线和短横线；不能使用大写字母或英文句点');
 if(!c.isUser&&(password.length<8||password.length>32||!/[A-Z]/.test(password)||!/[a-z]/.test(password)||!/[0-9]/.test(password)||!(/[^A-Za-z0-9\s]/).test(password)))throw Error('请设置 8–32 位密码，包含大写字母、小写字母、数字和符号');
 if(!c.isUser&&password!==$('#email-password-confirm').value)throw Error('两次输入的密码不一致');
 const v=await authMail('verification/verify',{verification_id:c.id,verification_code:$('#email-code').value.trim()});
 let s;try{s=await authMail(c.isUser?'signin':'signup',c.isUser?{verification_token:v.verification_token}:{email:c.email,username,name,password,verification_token:v.verification_token})}finally{$('#email-password').value='';$('#email-password-confirm').value=''}
 emailChallenge=null;$('#email-code').value='';await finishMemberSession(s);
 if(membershipState==='unsubmitted'&&name){waiting(await rpc('st_apply_membership',{p_name:name}))}
 }catch(err){if(token&&membershipState===null){token=null;expires=0}notify(err.message,true)}finally{b.disabled=false}
};
$('#membership-apply').onsubmit=async e=>{e.preventDefault();submitForm(e.currentTarget,async f=>waiting(await rpc('st_apply_membership',{p_name:f.get('name').trim()})))};
$('#membership-refresh').onclick=()=>run(async()=>{const status=await rpc('st_membership_status');if(status.state==='active'){membershipState='active';$('#membership-wait').hidden=true;await load();switchView('board');notify('组长已分配权限，欢迎加入。')}else waiting(status)});
load=async function(){await memberLoad();$('#registration-panel').hidden=!data.me.owner;if(!data.me.owner)return;await loadApplications()};
async function loadApplications(){
 const apps=await rpc('st_pending_members');$('#registration-list').innerHTML=apps.map(a=>`<form class="card registration-item" data-application="${esc(a.id)}"><b>${esc(a.display_name)}</b><p>用户名：${esc(a.username)} · ${esc(new Date(a.created_at).toLocaleString('zh-CN'))}</p><label>分配项目<select name="project" required><option value="">请选择项目</option>${data.projects.map(p=>`<option value="${esc(p.id)}">${esc(p.title)}</option>`).join('')}</select></label><label>身份<select name="role"><option value="contributor">成员</option><option value="reviewer">审核</option><option value="lead">项目负责人</option></select></label><div class="toolbar"><button class="primary" type="submit">批准并分配权限</button><button type="button" data-reject="${esc(a.id)}">拒绝申请</button></div></form>`).join('')||empty('暂无待审批的注册申请。');
 document.querySelectorAll('[data-application]').forEach(form=>form.onsubmit=e=>{e.preventDefault();submitForm(form,async f=>{await rpc('st_decide_member',{p_application:form.dataset.application,p_approve:true,p_project:f.get('project'),p_role:f.get('role')});await load();notify('已批准申请并分配项目身份。')})});
 document.querySelectorAll('[data-reject]').forEach(b=>b.onclick=()=>run(async()=>{b.disabled=true;try{await rpc('st_decide_member',{p_application:b.dataset.reject,p_approve:false});await loadApplications();notify('已拒绝此申请。')}finally{b.disabled=false}}));
}
