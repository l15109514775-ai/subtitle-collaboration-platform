'use strict';
let creditReport=null,creditOffset=0,creditMember=null,creditProject=null,creditLoad=0,creditAdjustment=null,creditAdjustBusy=false;
$('#credits-view').innerHTML=`<div class="section-heading"><div><div class="eyebrow">VERIFIED CONTRIBUTIONS</div><h2>贡献与积分</h2></div><button id="credit-refresh" type="button">刷新积分</button></div><p class="muted">审核通过的人工贡献生成凭据与积分；AI初稿不计人工积分。成员仅查看本人记录，组长可查看全组。历史流水不覆盖，调整必须注明原因。</p><div class="toolbar"><label id="credit-member-label">成员<select id="credit-member"><option value="">全组成员</option></select></label><label>项目<select id="credit-project"><option value="">全部项目（含历史记录）</option></select></label></div><p id="credit-message" role="status"></p><div id="credit-summary" class="stats"></div><section id="credit-team"><h3>成员汇总</h3><div id="credit-members"></div></section><h3>积分流水</h3><div id="credit-ledger"></div><h3>可核验贡献记录</h3><div id="credit-records"></div><div class="toolbar"><button id="credit-prev" type="button">上一页</button><span id="credit-page"></span><button id="credit-next" type="button">下一页</button></div><div id="credits" hidden></div><div id="contributions" hidden></div>`;
const creditDialog=document.createElement('dialog');creditDialog.id='credit-adjust-dialog';
creditDialog.innerHTML=`<form id="credit-adjust-form"><h2>调整贡献积分</h2><p id="credit-adjust-target"></p><p class="muted">只新增调整流水，不改写原审核与积分记录。该份贡献调整后的积分须在0至10000之间。</p><label>积分变化（正数增加，负数扣减）<input name="delta" type="number" step="1" min="-10000" max="10000" required></label><label>调整原因（5至300字）<textarea name="reason" minlength="5" maxlength="300" required rows="3"></textarea></label><p id="credit-adjust-message" role="status"></p><div class="toolbar"><button id="credit-adjust-close" type="button">返回</button><button id="credit-adjust-submit" type="submit" class="primary">确认记录调整</button></div></form>`;
document.body.append(creditDialog);
const creditDate=value=>esc(new Date(value).toLocaleString('zh-CN'));
function renderCreditReport(r){
 $('#credit-member-label').hidden=!r.owner;$('#credit-team').hidden=!r.owner;
 $('#credit-member').innerHTML='<option value="">全组成员</option>'+r.members.map(m=>`<option value="${esc(m.id)}">${esc(m.name)}</option>`).join('');$('#credit-member').value=creditMember||'';
 $('#credit-project').innerHTML='<option value="">全部项目（含历史记录）</option>'+r.projects.map(p=>`<option value="${esc(p.id)}">${esc(p.title)}</option>`).join('');$('#credit-project').value=creditProject||'';
 $('#credit-summary').innerHTML=[['累计积分',r.summary.points],['已核验贡献',r.summary.verified],['已撤销贡献',r.summary.revoked],['积分调整',r.summary.adjustments]].map(([name,n])=>`<div class="stat"><span>${esc(name)}</span><b>${esc(n)}</b></div>`).join('');
 $('#credit-members').innerHTML=r.member_totals.map(m=>`<div class="row"><b>${esc(m.name)}</b><span>已核验 ${esc(m.verified)} 项 · ${esc(m.points)} 分</span></div>`).join('')||empty('尚无已审核贡献。');
 const labels={award:'审核发放',reversal:'原积分冲销',adjustment:'组长调整'};
 $('#credit-ledger').innerHTML=r.ledger.map(e=>`<article class="version"><header><b>${esc(e.member_name)} · ${esc(labels[e.entry_type]||e.entry_type)}</b><span class="badge">${Number(e.points)>0?'+':''}${esc(e.points)} 分</span></header><p>${esc(e.reason)}</p><p class="muted">${esc(e.project_title)} / ${esc(e.task_title)}</p><small>操作人：${esc(e.operator)} · ${creditDate(e.created_at)}<br>流水 ${esc(e.id)}<br>贡献 ${esc(e.contribution_id)}</small></article>`).join('')||empty('暂无积分流水；审核认可0分的贡献仍可记录。');
 $('#credit-records').innerHTML=r.contributions.map(c=>`<article class="version"><header><b>${esc(c.member_name)} · ${esc(kinds[c.contribution_kind]||c.contribution_kind)}</b><span class="badge">${c.revoked?'已撤销':'已核验'} · ${esc(c.points)} 分</span></header><p>${esc(c.project_title)} / ${esc(c.task_title)}</p><p>${esc(c.human_work_description)}</p><small>审核背书：${esc(c.reviewer_name)} · ${creditDate(c.created_at)}<br>贡献 ${esc(c.id)}<br>交付 V${esc(c.version_no)} · ${esc(c.delivery_id)}<br>审核 ${esc(c.review_id)}</small><details><summary>文件校验摘要</summary><p class="pre">SHA-256：${esc(c.content_sha256)}</p></details>${r.owner&&!c.revoked?'<button type="button" data-credit-adjust="'+esc(c.id)+'">调整积分</button>':''}</article>`).join('')||empty('尚无已审核贡献，先完成任务交付并由另一位审核员验收。');
 $('#credit-prev').disabled=creditOffset===0;$('#credit-next').disabled=creditOffset+50>=Math.max(Number(r.ledger_count),Number(r.contribution_count));$('#credit-page').textContent=`第 ${Math.floor(creditOffset/50)+1} 页 · ${r.ledger_count} 条积分流水 / ${r.contribution_count} 份贡献`;
 document.querySelectorAll('[data-credit-adjust]').forEach(b=>b.onclick=()=>{
  const c=creditReport?.contributions.find(c=>c.id===b.dataset.creditAdjust);if(!creditReport?.owner||!c||c.revoked)return;
  creditAdjustment={id:c.id,request:crypto.randomUUID()};$('#credit-adjust-form').reset();$('#credit-adjust-message').textContent='';$('#credit-adjust-target').textContent=c.member_name+' · '+c.task_title+' · 当前 '+c.points+' 分';creditDialog.showModal();
 });
}
async function loadCreditReport(){
 const session=SessionFence.capture(),sequence=++creditLoad;$('#credit-message').textContent='正在读取贡献与积分…';
 try{const r=await rpc('st_credit_report',{p_member:creditMember,p_project:creditProject,p_offset:creditOffset});session.check();if(sequence!==creditLoad)return;creditReport=r;renderCreditReport(r);$('#credit-message').textContent=r.owner?'统计包含所选范围的历史记录，不受当前工作台项目选择影响。':'当前显示本人跨项目的贡献与积分。';}
 catch(error){session.check();if(sequence===creditLoad){creditReport=null;for(const id of ['summary','members','ledger','records'])$('#credit-'+id).replaceChildren();$('#credit-message').textContent=error.message;}throw error;}
}
$('#credit-refresh').onclick=()=>run(loadCreditReport,'#credit-message');
$('#credit-member').onchange=()=>{creditMember=$('#credit-member').value||null;creditProject=null;creditOffset=0;run(loadCreditReport,'#credit-message');};
$('#credit-project').onchange=()=>{creditProject=$('#credit-project').value||null;creditOffset=0;run(loadCreditReport,'#credit-message');};
$('#credit-prev').onclick=()=>{creditOffset=Math.max(0,creditOffset-50);run(loadCreditReport,'#credit-message');};
$('#credit-next').onclick=()=>{creditOffset+=50;run(loadCreditReport,'#credit-message');};
$('#credit-adjust-close').onclick=()=>{if(!creditAdjustBusy)creditDialog.close();};
$('#credit-adjust-form').onsubmit=e=>{e.preventDefault();if(creditAdjustBusy||!creditAdjustment)return;run(async()=>{
 const session=SessionFence.capture(),form=e.currentTarget,fields=new FormData(form),delta=Number(fields.get('delta')),reason=String(fields.get('reason')).trim(),target={...creditAdjustment};
 if(!Number.isInteger(delta)||delta===0||Math.abs(delta)>10000||reason.length<5||reason.length>300)throw Error('请输入非零整数积分及5至300字调整原因');
 creditAdjustBusy=true;$('#credit-adjust-submit').disabled=true;$('#credit-adjust-close').disabled=true;
 try{await rpc('st_credit_adjust',{p_contribution:target.id,p_delta:delta,p_reason:reason,p_request:target.request});session.check();creditDialog.close();creditAdjustment=null;await loadCreditReport();$('#credit-message').textContent='积分调整已记录，原审核和积分流水保留。';}
 finally{creditAdjustBusy=false;$('#credit-adjust-submit').disabled=false;$('#credit-adjust-close').disabled=false;}
 },'#credit-adjust-message');};
const creditSwitchBefore=switchView;switchView=function(next){creditSwitchBefore(next);if(next==='credits'&&data?.me)run(loadCreditReport,'#credit-message');};
const creditLoadBefore=load;load=async function(){await creditLoadBefore();if(view==='credits'&&data?.me)await loadCreditReport();};
const creditLogoutBefore=logout;logout=function(){creditLoad++;creditReport=null;creditOffset=0;creditMember=creditProject=creditAdjustment=null;creditDialog.close();for(const id of ['summary','members','ledger','records'])$('#credit-'+id).replaceChildren();$('#credit-message').textContent='';creditLogoutBefore();};$('#logout').onclick=logout;
