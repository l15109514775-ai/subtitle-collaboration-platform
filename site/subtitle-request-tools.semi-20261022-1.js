(function(root){
 'use strict';
 const uuid=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
 const tools=Object.freeze({
  sourceParts(r){
   if(!uuid.test(r.id)||!Number.isSafeInteger(r.byte_size)||r.byte_size<1||r.byte_size>1073741824)throw Error('申请素材记录无效');
   return Array.from({length:Math.ceil(r.byte_size/4194304)},(_,i)=>({path:'requests/'+r.id+'/part-'+String(i).padStart(4,'0'),byte_size:Math.min(4194304,r.byte_size-i*4194304)}));
  },
  duration(seconds){if(!Number.isFinite(seconds)||seconds<=0||seconds>1200)throw Error('请选择时长不超过20分钟的视频');return Math.ceil(seconds);},
  notification(packet){
   if(!uuid.test(packet.request_id))throw Error('申请编号无效');
   const line=x=>String(x??'').replace(/[\r\n\x00-\x1f\x7f]/g,' ').slice(0,200);
   const lines=['【字幕申请 · '+line({pending:'待组长审批',approved:'已批准',rejected:'已驳回',withdrawn:'已撤回',uploading:'上传中'}[packet.state]||packet.state)+'】',
    '申请：'+packet.request_id,'提交人：'+line(packet.submitter),'标题：'+line(packet.title),'时间段：'+line(packet.timestamp),'视频时长：'+line(packet.seconds)+'秒',
    '网站：https://example-site.tcloudbaseapp.com/?request='+packet.request_id];
   if(packet.instruction&&packet.state==='approved'&&uuid.test(packet.job_id)){
    lines.push('额度：文字≤'+line(packet.max_text_requests)+'次；千问≤'+line(packet.max_secondary_requests)+'次',
     '素材授权到期：'+line(packet.source_expires_at),'请核对网站最新状态后，在现有 Codex Cloud 字幕环境中新建任务并粘贴以下指令：',packet.instruction);
   }else lines.push('当前没有可执行指令。请到网站审批或核对任务状态；不要重复上传或重复启动。');
   return lines.join('\n');
  }
 });
 root.SubtitleRequestTools=tools;if(typeof module!=='undefined'&&module.exports)module.exports=tools;
})(globalThis);
