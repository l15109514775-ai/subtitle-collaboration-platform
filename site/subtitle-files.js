(function(root){
 'use strict';
 function assText(text){
  const clean=String(text).replace(/^\uFEFF/,'');
  return /^\s*\[Script Info\]\s*$/im.test(clean)&&/^\s*ScriptType\s*:\s*v4\.00\+\s*$/im.test(clean)&&/^\s*\[V4\+ Styles\]\s*$/im.test(clean)&&/^\s*\[Events\]\s*$/im.test(clean);
 }
 function timestamp(value){
  const m=/^(\d+):(\d{2}):(\d{2})[,.](\d{3})$/.exec(value);
  if(!m||Number(m[2])>59||Number(m[3])>59)throw Error('无效的 SRT 时间轴');
  return ((Number(m[1])*60+Number(m[2]))*60+Number(m[3]))*1000+Number(m[4]);
 }
 function parseSrt(text){
  const normalized=String(text).replace(/^\uFEFF/,'').replace(/\r\n?/g,'\n').trim();
  if(!normalized)throw Error('空字幕');
  return normalized.split(/\n[ \t]*\n+/).map(block=>{
   const lines=block.split('\n');
   if(/^\d+$/.test(lines[0].trim()))lines.shift();
   const timing=/^\s*(\d+:\d{2}:\d{2}[,.]\d{3})\s+-->\s+(\d+:\d{2}:\d{2}[,.]\d{3})\s*$/.exec(lines.shift()||'');
   if(!timing||!lines.length)throw Error('SRT 包含不支持的时间轴或空字幕，请下载原 SRT');
   const start=timestamp(timing[1]),end=timestamp(timing[2]);
   if(end<=start)throw Error('字幕结束时间必须晚于开始时间');
   const content=lines.join('\n');
   if(/[{}\\]/.test(content)||/<(?!\/?(?:b|i|u)\s*>)[^>]*>/i.test(content))throw Error('SRT 含特殊格式，请下载原 SRT 以保留原文');
   return {start,end,text:content};
  });
 }
 function assTime(centiseconds){
  const cs=centiseconds%100,seconds=Math.floor(centiseconds/100)%60,minutes=Math.floor(centiseconds/6000)%60,hours=Math.floor(centiseconds/360000);
  return hours+':'+String(minutes).padStart(2,'0')+':'+String(seconds).padStart(2,'0')+'.'+String(cs).padStart(2,'0');
 }
 function toAss(text){
  const cues=parseSrt(text);
  const header='[Script Info]\r\n; Converted by subtitle workspace\r\nScriptType: v4.00+\r\nPlayResX: 1920\r\nPlayResY: 1080\r\nWrapStyle: 0\r\nScaledBorderAndShadow: yes\r\n\r\n[V4+ Styles]\r\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\r\nStyle: Default,Microsoft YaHei,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,40,40,40,1\r\n\r\n[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\n';
  return header+cues.map(c=>{
   const start=Math.floor(c.start/10),end=Math.max(start+1,Math.ceil(c.end/10));
   const content=c.text.replace(/<(\/?)(b|i|u)\s*>/gi,(_,close,tag)=>'{\\'+tag.toLowerCase()+(close?'0':'1')+'}').replace(/\n/g,'\\N');
   return 'Dialogue: 0,'+assTime(start)+','+assTime(end)+',Default,,0,0,0,,'+content;
  }).join('\r\n')+'\r\n';
 }
 function prepare(text){
  text=String(text??'');
  if(assText(text))return {format:'ASS',extension:'ass',content:text,label:'下载 ASS',notice:'ASS 原格式 · 保留样式、时间轴和特效'};
  if(/^\s*\[V4 Styles\]\s*$/im.test(text)&&/^\s*\[Events\]\s*$/im.test(text))return {format:'SSA',extension:'ssa',content:text,label:'下载 SSA',notice:'SSA 原格式'};
  if(/^\uFEFF?WEBVTT(?:\s|$)/.test(text)||/^WEBVTT(?:\s|$)/.test(text))return {format:'VTT',extension:'vtt',content:text,label:'下载 VTT',notice:'VTT 原格式'};
  if(/\d+:\d{2}:\d{2}[,.]\d{3}\s+-->/.test(text)){
   try{return {format:'SRT',extension:'ass',content:toAss(text),label:'下载 ASS',originalExtension:'srt',notice:'由 SRT 转为 ASS · 使用默认样式（1920×1080），原 SRT 也可下载'};}
   catch(e){return {format:'SRT',extension:'srt',content:text,label:'下载原 SRT',notice:e.message};}
  }
  return {format:'TXT',extension:'txt',content:text,label:'下载 TXT',notice:'未识别到完整字幕格式；请提交完整 ASS 文件，普通文本不能直接转成带时间轴的 ASS'};
 }
 function filename(title,version,extension){
  const safe=String(title||'subtitle').replace(/[<>:"/\\|?*\x00-\x1f]/g,'_').replace(/[. ]+$/,'').slice(0,80)||'subtitle';
  return safe+'-v'+String(version).replace(/\D/g,'')+'.'+extension;
 }
 const api={assText,parseSrt,toAss,prepare,filename};
 if(typeof module!=='undefined'&&module.exports)module.exports=api;
 else root.SubtitleFiles=api;
})(typeof globalThis!=='undefined'?globalThis:this);
