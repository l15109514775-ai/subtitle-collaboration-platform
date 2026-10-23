'use strict';
(function(root){
 const maximum=Object.freeze({seconds:1200,text:400,qwen:40});
 function validate(values){
  for(const name of Object.keys(maximum)){
   if(!Number.isInteger(values[name])||values[name]<1||values[name]>maximum[name])throw Error('云端字幕限额：最长20分钟、文字最多400次、千问最多40次');
  }
  return values;
 }
 const api=Object.freeze({maximum,validate});
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
 else root.CloudLimits=api;
})(typeof globalThis!=='undefined'?globalThis:this);
