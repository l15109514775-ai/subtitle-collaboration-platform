'use strict';
const mediaChannels=new Set();
async function chunkedMediaURL(artifact){
 if(!('serviceWorker' in navigator))throw Error('此浏览器不支持大文件流式下载，请使用新版 Chrome 或 Edge');
 await navigator.serviceWorker.register('media-stream-worker.js');const registration=await navigator.serviceWorker.ready;
 if(!navigator.serviceWorker.controller)await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('文件服务正在初始化，请重新点击')),10000);navigator.serviceWorker.addEventListener('controllerchange',()=>{clearTimeout(timer);resolve();},{once:true});});
 const channel=new MessageChannel();mediaChannels.add(channel.port1);
 const url=await new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>reject(Error('文件服务未就绪，请重试')),10000);
  channel.port1.onmessage=async event=>{
   const m=event.data;if(m?.type==='ready'){clearTimeout(timer);resolve(new URL(m.path,location.origin));return;}
   if(m?.type==='sign-part'){
    try{const part=artifact.parts[m.index];if(!part)throw Error('分片不存在');const s=await request('/v1/storages/object/sign/subtitle-deliveries/'+MediaFiles.objectPath(part.path),{expiresIn:600});const signed=new URL(s.fullSignedURL||s.signedURL,BASE);if(signed.origin!==BASE)throw Error('文件服务域名不匹配');channel.port1.postMessage({requestId:m.requestId,url:signed.href});}
    catch(e){channel.port1.postMessage({requestId:m.requestId,error:e.message});$('#dialog-message').textContent=e.message;}
   }
  };
  (navigator.serviceWorker.controller||registration.active).postMessage({type:'media-file',name:artifact.file_name,mime:artifact.mime_type,size:artifact.byte_size,parts:artifact.parts,origin:BASE},[channel.port2]);
 });return url;
}
const singleSignedMedia=signedMedia;
signedMedia=async function(id){const artifact=detail.artifacts.find(a=>a.id===id);if(artifact?.parts?.length)return {artifact,url:await chunkedMediaURL(artifact)};return singleSignedMedia(id);};
downloadMedia=async function(id){
 const session=SessionFence.capture();
 const selected=detail.artifacts.find(a=>a.id===id);if(!selected)throw Error('文件不存在');
 let handle=null;
 if(selected.byte_size>134217728){if(!window.showSaveFilePicker)throw Error('超过128MB的文件请使用新版 Chrome 或 Edge 下载');handle=await window.showSaveFilePicker({suggestedName:selected.file_name});}
 session.check();$('#dialog-message').textContent='正在下载并核验完整文件，请保持登录…';
 const {artifact,url}=await signedMedia(id);session.check();
 const response=await fetch(url.href,{cache:'no-store',credentials:'omit',signal:session.signal});
 const blob=await SecurityFiles.verifiedDownload(response,artifact,{handle,signal:session.signal});session.check();
 if(blob){const href=URL.createObjectURL(blob),a=document.createElement('a');a.href=href;a.download=artifact.file_name;a.click();setTimeout(()=>URL.revokeObjectURL(href),60000);}
 $('#dialog-message').textContent='完整文件 SHA-256 与大小核验通过。';
};
const plainLogout=logout;
logout=function(){for(const p of mediaChannels)p.close();mediaChannels.clear();navigator.serviceWorker?.controller?.postMessage({type:'clear-media'});plainLogout();};$('#logout').onclick=logout;
