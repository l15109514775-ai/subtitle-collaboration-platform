'use strict';
// Same-environment authentication only; no database/admin privileges or persistent credentials.
const resetOpen=document.createElement('button');resetOpen.id='password-reset-open';resetOpen.type='button';resetOpen.textContent='忘记密码？';$('#email-open').before(resetOpen);
const resetDialog=document.createElement('dialog');resetDialog.id='password-reset-dialog';
resetDialog.innerHTML=`<form id="password-reset-form"><h2>找回登录密码</h2><p class="muted">使用账号已绑定的邮箱验证身份。仅用户名开户、尚未绑定邮箱的账号，请联系组长核实；不能通过此页面替他人重置。</p><label>注册邮箱<input id="reset-email" name="email" type="email" autocomplete="email" maxlength="254" required></label><div id="reset-captcha" hidden><img id="reset-captcha-image" alt="找回密码图片验证码"><button id="reset-captcha-refresh" type="button">换一张验证码</button><label>图片验证码<input id="reset-captcha-code" autocomplete="off" maxlength="8"></label></div><button id="reset-send" type="button">发送邮箱验证码</button><label>邮箱验证码<input id="reset-code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}" minlength="6" maxlength="6" required></label><label>新密码<input id="reset-password" name="password" type="password" autocomplete="new-password" minlength="8" maxlength="32" required></label><label>确认新密码<input id="reset-confirm" name="confirm" type="password" autocomplete="new-password" minlength="8" maxlength="32" required></label><p class="muted">密码为8至32位，包含大写字母、小写字母、数字和符号。密码及验证码仅提交到当前网站的 CloudBase 认证服务。</p><p id="reset-message" role="status"></p><div class="toolbar"><button id="reset-close" type="button">返回登录</button><button id="reset-submit" type="submit" class="primary">验证并重设密码</button></div></form>`;
document.body.append(resetDialog);
let resetChallenge=null,resetCaptcha=null,resetController=null,resetGeneration=0,resetBusy=false,resetTimer=null;
const resetSent=new Map();
function resetMessage(text){$('#reset-message').textContent=text;}
function clearResetSecrets(){for(const id of ['reset-code','reset-password','reset-confirm','reset-captcha-code'])$('#'+id).value='';}
function resetClose(){resetGeneration++;resetController?.abort();resetController=null;resetChallenge=resetCaptcha=null;resetBusy=false;clearInterval(resetTimer);resetTimer=null;clearResetSecrets();$('#password-reset-form').reset();$('#reset-captcha').hidden=true;$('#reset-captcha-image').removeAttribute('src');$('#reset-email').disabled=false;$('#reset-submit').disabled=false;resetDialog.close();}
function resetTick(){const remaining=Math.max(0,Math.ceil(((resetSent.get($('#reset-email').value.trim())||0)+60000-Date.now())/1000));$('#reset-send').disabled=resetBusy||remaining>0;$('#reset-send').textContent=remaining?'重新发送（'+remaining+'秒）':'发送邮箱验证码';}
function resetStill(generation){if(generation!==resetGeneration||!resetDialog.open)throw new DOMException('Reset flow closed','AbortError');}
async function resetAuth(path,body,headers={},generation=resetGeneration){
 if(!['verification','verification/verify','reset','captcha/data','captcha/data/verify'].includes(path))throw Error('Unsupported authentication route');
 const response=await fetch(BASE+'/auth/v1/'+path,{method:'POST',signal:AbortSignal.any([resetController.signal,AbortSignal.timeout(30000)]),credentials:'omit',cache:'no-store',redirect:'error',headers:{'Content-Type':'application/json',...headers},body:JSON.stringify(body)});
 resetStill(generation);let value;try{const text=await response.text();value=text?JSON.parse(text):{};}catch{throw Error('Unexpected authentication response');}resetStill(generation);
 if(!response.ok||value?.error){const error=Error('Authentication request rejected');error.code=typeof value.error==='string'?value.error:value.error?.code;throw error;}return value;
}
async function loadResetCaptcha(generation){const c=await resetAuth('captcha/data',{}, {},generation);resetStill(generation);if(!/^data:image\/(gif|png|jpeg);base64,/i.test(c.data||'')||!c.token)throw Error('Invalid captcha response');resetCaptcha={token:c.token};$('#reset-captcha-image').src=c.data;$('#reset-captcha').hidden=false;$('#reset-captcha-code').value='';}
resetOpen.onclick=()=>{resetClose();resetController=new AbortController();resetDialog.showModal();resetMessage('先发送邮箱验证码，再填写验证码与新密码。请勿把验证码发给他人。');resetTimer=setInterval(resetTick,1000);resetTick();};
$('#reset-close').onclick=resetClose;resetDialog.addEventListener('cancel',e=>{e.preventDefault();resetClose();});
$('#reset-email').oninput=()=>{resetChallenge=null;clearResetSecrets();resetTick();};
$('#reset-captcha-refresh').onclick=async()=>{if(resetBusy)return;const generation=resetGeneration;try{await loadResetCaptcha(generation);}catch{if(generation===resetGeneration)resetMessage('图片验证码暂时无法加载，请稍后再试。');}};
$('#reset-send').onclick=async()=>{
 if(resetBusy||!$('#reset-email').reportValidity())return;const email=$('#reset-email').value.trim(),generation=resetGeneration;
 if(Date.now()-(resetSent.get(email)||0)<60000){resetTick();return;}
 resetBusy=true;resetChallenge=null;$('#reset-email').disabled=true;$('#reset-submit').disabled=true;resetTick();
 try{
  let headers={};if(resetCaptcha){if(!$('#reset-captcha-code').value.trim()){resetMessage('请先在页面填写图片验证码。');return;}const v=await resetAuth('captcha/data/verify',{token:resetCaptcha.token,key:$('#reset-captcha-code').value.trim()},{},generation);if(!v.captcha_token)throw Error('Missing captcha verification');headers['x-captcha-token']=v.captcha_token;resetCaptcha=null;}
  resetSent.set(email,Date.now());const r=await resetAuth('verification',{email,target:'USER',usage:'recovery'},headers,generation);
  if(!r.verification_id)throw Error('Missing verification challenge');resetChallenge={id:r.verification_id,email,until:Date.now()+Math.min(Number(r.expires_in)||600,600)*1000};$('#reset-captcha').hidden=true;
  resetMessage('若此邮箱可用于找回，验证码将发送到收件箱，请同时检查垃圾邮件。验证码仅在有效期内使用。');
 }catch(error){if(generation!==resetGeneration)return;
  if(error.code==='captcha_required'||error.code==='captcha_invalid'){resetSent.delete(email);try{await loadResetCaptcha(generation);resetMessage('请在页面完成图片验证，再发送邮箱验证码。');}catch{resetMessage('图片验证暂不可用，请稍后重试。');}}
  else if(['not_found','user_not_found'].includes(error.code))resetMessage('若此邮箱可用于找回，验证码将发送到收件箱。未绑定邮箱的账号请联系组长核实。');
  else resetMessage('验证码暂未发送成功，请稍后重试。若已有邮件，请以最新验证码为准。');
 }finally{if(generation===resetGeneration){resetBusy=false;$('#reset-email').disabled=false;$('#reset-submit').disabled=false;resetTick();}}
};
$('#password-reset-form').onsubmit=async e=>{
 e.preventDefault();if(resetBusy)return;const generation=resetGeneration,c=resetChallenge,email=$('#reset-email').value.trim(),password=$('#reset-password').value,confirmation=$('#reset-confirm').value,code=$('#reset-code').value.trim();
 if(!c||c.email!==email||Date.now()>=c.until){resetMessage('请先为当前邮箱发送有效验证码。');return;}
 if(!/^[0-9]{6}$/.test(code)){resetMessage('请输入6位邮箱验证码。');return;}
 if(password.length<8||password.length>32||!/[A-Z]/.test(password)||!/[a-z]/.test(password)||!/[0-9]/.test(password)||!/[^A-Za-z0-9\s]/.test(password)){resetMessage('密码须为8至32位，包含大写字母、小写字母、数字和符号。');return;}
 if(password!==confirmation){resetMessage('两次输入的密码不一致。');return;}
 resetBusy=true;$('#reset-email').disabled=true;$('#reset-submit').disabled=true;resetTick();let resetting=false;
 try{
  const v=await resetAuth('verification/verify',{verification_id:c.id,verification_code:code},{},generation);if(!v.verification_token)throw Error('Missing verification token');
  // One use only, no automatic retry and no automatic sign-in/admin session.
  resetChallenge=null;resetting=true;await resetAuth('reset',{email:c.email,new_password:password,verification_token:v.verification_token},{},generation);
  resetStill(generation);resetClose();$('#login-form').hidden=false;$('#email-form').hidden=true;$('#login-form').reset();notify('密码已重设，请使用原用户名和新密码登录；也可使用邮箱验证码登录。');
 }catch(error){if(generation!==resetGeneration)return;
  resetMessage(resetting?'重设结果尚未确认。请先返回登录尝试新密码；若不能登录，再重新获取验证码。':'邮箱验证码不正确、已过期或验证暂不可用，请核对后重试。');
 }finally{if(generation===resetGeneration){clearResetSecrets();resetBusy=false;$('#reset-email').disabled=false;$('#reset-submit').disabled=false;resetTick();}}
};
const beforeResetLogout=logout;logout=function(){resetClose();beforeResetLogout();};$('#logout').onclick=logout;
