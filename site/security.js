(function(root){
 'use strict';
 let epoch=0,controller=new AbortController(),expiryTimer=null;
 const fence=Object.freeze({
  capture(){const at=epoch;return {signal:controller.signal,check(){if(at!==epoch)throw Error('会话已结束，请重新登录');}};},
  clear(){epoch++;controller.abort();controller=new AbortController();clearTimeout(expiryTimer);expiryTimer=null;},
  arm(ms,expire){clearTimeout(expiryTimer);expiryTimer=setTimeout(expire,Math.max(0,Math.min(ms,2147483647)));}
 });
 async function verifiedDownload(response,asset,{handle=null,signal}={}){
  if(!response.ok||!Number.isSafeInteger(asset.byte_size)||asset.byte_size<1||asset.byte_size>1073741824||!/^[0-9a-f]{64}$/.test(asset.sha256||''))throw Error('文件记录或响应无效');
  const check=()=>{if(signal?.aborted)throw Error('会话已结束，下载已取消');};
  check();
  if(handle){
   if(!root.sha256?.create)throw Error('文件校验组件未加载，请刷新重试');
   const digest=root.sha256.create(),writer=await handle.createWritable(),reader=response.body.getReader();let count=0;
   const abort=()=>{void reader.cancel().catch(()=>{});};
   signal?.addEventListener('abort',abort,{once:true});
   try{
    for(;;){check();const {done,value}=await reader.read();check();if(done)break;count+=value.byteLength;if(count>asset.byte_size)throw Error('文件超过登记大小');digest.update(value);await writer.write(value);}
    if(count!==asset.byte_size||digest.hex()!==asset.sha256)throw Error('文件 SHA-256 或大小不符，未保存');
    check();await writer.close();return null;
   }catch(error){try{await reader.cancel();}catch{}try{await writer.abort();}catch{}throw error;}
   finally{signal?.removeEventListener('abort',abort);reader.releaseLock();}
  }
  // Refuse unexpected large in-memory downloads even if caller omitted a picker.
  if(asset.byte_size>134217728)throw Error('大文件需要选择保存位置后下载');
  const reader=response.body.getReader(),chunks=[];let count=0;
  const abort=()=>{void reader.cancel().catch(()=>{});};
  signal?.addEventListener('abort',abort,{once:true});
  try{
   for(;;){check();const {done,value}=await reader.read();check();if(done)break;count+=value.byteLength;if(count>asset.byte_size)throw Error('文件超过登记大小');chunks.push(value);}
   const blob=new Blob(chunks,{type:asset.mime_type||'application/octet-stream'});
   const hex=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await blob.arrayBuffer())),b=>b.toString(16).padStart(2,'0')).join('');
   check();if(count!==asset.byte_size||hex!==asset.sha256)throw Error('文件 SHA-256 或大小不符，未下载');return blob;
  }finally{signal?.removeEventListener('abort',abort);await reader.cancel().catch(()=>{});reader.releaseLock();}
 }
 root.SessionFence=fence;root.SecurityFiles=Object.freeze({verifiedDownload});
 if(typeof module!=='undefined'&&module.exports)module.exports={SessionFence:fence,SecurityFiles:root.SecurityFiles};
})(globalThis);
