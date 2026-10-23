/* Business access controls only. This page never manages cloud IAM or secrets. */
(() => {
 'use strict';
 const panel=document.createElement('section');panel.className='card';panel.hidden=true;
 const title=document.createElement('h3');title.textContent='成员停用与项目访问撤销';
 const help=document.createElement('p');help.className='muted';help.textContent='仅组长可操作。项目撤销会阻止该成员通过认领重新加入；解除后仍需重新分配或认领。已发出的文件签名链接在到期前可能仍可访问。';
 const list=document.createElement('div'),status=document.createElement('p');status.setAttribute('role','status');
 panel.append(title,help,list,status);document.getElementById('members-view').append(panel);
 let generation=0;
 async function refresh(){
  const at=++generation;list.replaceChildren();panel.hidden=!data?.me.owner;
  if(panel.hidden)return;
  try{
   const members=await rpc('st_security_members',{p_project:project});
   if(at!==generation||!data?.me.owner)return;
   status.textContent='';
   for(const member of members){
    const row=document.createElement('div');row.className='row';
    const name=document.createElement('span');name.textContent=member.display_name+' · '+(member.state==='active'?'有效':'已停用')+(member.blocked?' · 当前项目已撤销':'');row.append(name);
    if(!member.owner&&member.id!==data.me.id){
     const add=(label,action,args)=>{const button=document.createElement('button');button.type='button';button.textContent=label;
      button.onclick=async()=>{const session=SessionFence.capture(),selected=project;
       if(window.prompt('请输入成员完整显示名确认：'+member.display_name)!==member.display_name)return;
       const reason=window.prompt('请填写操作原因（不要包含密码、密钥或稿件正文）：');if(!reason?.trim())return;
       button.disabled=true;
       try{session.check();await rpc(action,{...args,p_reason:reason.trim()});session.check();if(selected!==project)return;await load();notify('成员访问设置已更新，已记录审计。');}
       catch{status.textContent='设置未完成，请刷新核对权限或联系管理员。';}finally{button.disabled=false;}
      };row.append(button);};
     add(member.state==='active'?'停用成员':'恢复成员','st_set_member_state',{p_member:member.id,p_state:member.state==='active'?'suspended':'active'});
     if(project)add(member.blocked?'解除本项目限制':'撤销本项目访问','st_set_project_block',{p_project:project,p_member:member.id,p_block:!member.blocked});
    }
    list.append(row);
   }
  }catch{if(at===generation)status.textContent='成员安全管理接口尚未发布或暂不可用。';}
 }
 const previousLoad=load;load=async function(...args){const value=await previousLoad.apply(this,args);await refresh();return value;};
 const previousLogout=logout;logout=function(...args){++generation;panel.hidden=true;list.replaceChildren();status.textContent='';return previousLogout.apply(this,args);};
 $('#logout').onclick=logout;
})();
