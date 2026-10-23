(function(root){
 'use strict';
 const types={clip:{label:'剪辑视频',accept:'.mp4,.mkv,.mov,.webm',limit:1073741824},encode:{label:'压制视频',accept:'.mp4,.mkv,.mov,.webm',limit:1073741824},cover:{label:'封面图片',accept:'.jpg,.jpeg,.png,.webp',limit:20971520}};
 function config(kind){return types[kind]||null;}
 function mime(kind,name,size,head){
  const c=config(kind);if(!c)throw Error('该任务应提交字幕或文本');
  if(!size||size>c.limit)throw Error(kind==='cover'?'图片须为 20MB 以内':'视频须为 1GB（1024MB）以内');
  const ext=String(name).split('.').pop().toLowerCase(),b=Array.from(head||[]),ascii=(a,n)=>String.fromCharCode(...b.slice(a,a+n));
  const video={mp4:'video/mp4',mov:'video/quicktime',mkv:'video/x-matroska',webm:'video/webm'},image={jpg:'image/jpeg',jpeg:'image/jpeg',png:'image/png',webp:'image/webp'};
  const type=(kind==='cover'?image:video)[ext];if(!type)throw Error('文件类型不符合当前任务，请按提示选择');
  let valid;
  if(ext==='png')valid=b.slice(0,8).join(',')==='137,80,78,71,13,10,26,10';
  else if(ext==='jpg'||ext==='jpeg')valid=b[0]===255&&b[1]===216&&b[2]===255;
  else if(ext==='webp')valid=ascii(0,4)==='RIFF'&&ascii(8,4)==='WEBP';
  else if(ext==='mp4'||ext==='mov')valid=ascii(4,4)==='ftyp'||ascii(4,4)==='moov'||ascii(4,4)==='wide';
  else valid=b.slice(0,4).join(',')==='26,69,223,163';
  if(!valid)throw Error('文件内容与扩展名不符，请从编辑软件导出有效文件');
  return type;
 }
 function bytes(n){return n>=1073741824?(n/1073741824).toFixed(2)+' GB':n>=1048576?(n/1048576).toFixed(1)+' MB':(n/1024).toFixed(1)+' KB';}
 function objectPath(path){return path.split('/').map(encodeURIComponent).join('/');}
 function hash(file,onProgress,signal){return new Promise((resolve,reject)=>{
  const worker=new Worker('hash-worker.js');
  const abort=()=>{worker.terminate();reject(Error('已取消上传'));};
  if(signal?.aborted){abort();return;}
  signal?.addEventListener('abort',abort,{once:true});
  const done=()=>{signal?.removeEventListener('abort',abort);worker.terminate();};
  worker.onmessage=({data})=>{if(data.hash){done();resolve(data.hash);}else if(data.error){done();reject(Error(data.error));}else onProgress(data.progress);};
  worker.onerror=()=>{done();reject(Error('文件校验失败，请刷新页面后重试'));};
  worker.postMessage(file);
 });}
 const api={config,mime,bytes,objectPath,hash};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.MediaFiles=api;
})(typeof globalThis!=='undefined'?globalThis:this);
