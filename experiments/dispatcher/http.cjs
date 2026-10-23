'use strict';
const {createDispatcher}=require('./dispatch.cjs');
const ORIGIN='https://example-site.tcloudbaseapp.com';
function createHandler(dispatch){return async function(event){
 const headers=Object.fromEntries(Object.entries(event.headers||{}).map(([k,v])=>[k.toLowerCase(),v]));
 const response=(statusCode,value)=>({statusCode,headers:{'Content-Type':'application/json','Cache-Control':'no-store','Access-Control-Allow-Origin':ORIGIN,'Vary':'Origin'},body:JSON.stringify(value)});
 if(headers.origin!==ORIGIN)return response(403,{error:'origin_rejected'});
 if(event.httpMethod==='OPTIONS')return {...response(204,{}),headers:{...response(204,{}).headers,'Access-Control-Allow-Methods':'POST','Access-Control-Allow-Headers':'Authorization,Content-Type'}};
 if(event.httpMethod!=='POST'||String(headers['content-type']).split(';')[0]!=='application/json')return response(405,{error:'post_json_required'});
 if(event.isBase64Encoded||typeof event.body!=='string'||Buffer.byteLength(event.body)>1024)return response(400,{error:'invalid_request'});
 let input;try{input=JSON.parse(event.body);}catch{return response(400,{error:'invalid_request'});}
 const auth=/^Bearer ([^\s]+)$/.exec(headers.authorization||'');
 if(!auth)return response(401,{error:'login_required'});
 try{return response(200,await dispatch(input,auth[1]));}
  catch(error){return response(503,{error:['launcher_not_configured','cloud_environment_unavailable','launch_result_unknown_do_not_resubmit','invalid_request','login_required'].includes(error.code)?error.code:'dispatch_not_confirmed'});}
};}
// Disabled until platform migration, CLI/native-environment compatibility and
// separate authorization to host an account credential have all been verified.
exports.main=async(event)=>createHandler(createDispatcher({config:{
 enabled:process.env.SUBTITLE_DISPATCH_ENABLED==='true',
 environmentVerified:process.env.SUBTITLE_NATIVE_ENV_VERIFIED==='true',
 environment:process.env.SUBTITLE_CODEX_ENV_ID,executable:process.env.SUBTITLE_CODEX_BIN,
 workerToken:process.env.SUBTITLE_PLATFORM_TOKEN,gatewayKey:process.env.SUBTITLE_PLATFORM_GATEWAY_KEY,
 cwd:process.env.SUBTITLE_DISPATCH_CWD,
 cliEnv:Object.fromEntries(['PATH','HOME','CODEX_HOME','HTTPS_PROXY','HTTP_PROXY','NO_PROXY','SSL_CERT_FILE','NODE_EXTRA_CA_CERTS'].filter(k=>process.env[k]).map(k=>[k,process.env[k]]))
}}))(event);
exports.createHandler=createHandler;
