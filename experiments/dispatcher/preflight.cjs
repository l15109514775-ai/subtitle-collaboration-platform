'use strict';
const {execFile}=require('node:child_process');
const {promisify}=require('node:util');
const run=promisify(execFile);
class PreflightError extends Error {constructor(){super('cloud_environment_unavailable');this.code='cloud_environment_unavailable';}}
// Read-only probe. Never read/export login files or create a task to test access.
async function probeEnvironment(config,exec=run){
 if(!config.executable||!config.environment||config.environment.startsWith('-')||/[\s\x00-\x1f]/.test(config.environment))throw new PreflightError();
 try{
  const result=await exec(config.executable,['cloud','list','--env',config.environment,'--limit','1','--json'],{
   shell:false,windowsHide:true,timeout:20000,maxBuffer:65536,cwd:config.cwd,env:config.cliEnv
  });
  const data=JSON.parse(result.stdout);
  if(!data||!Array.isArray(data.tasks)||data.tasks.length>1)throw new Error();
  return {available:true,scope:'CLI environment visibility only; published runtime/version still requires independent acceptance'};
 }catch{throw new PreflightError();}
}
if(require.main===module){
 probeEnvironment({executable:process.env.SUBTITLE_CODEX_BIN||'codex',environment:process.argv[2]})
  .then(result=>process.stdout.write(JSON.stringify(result)+'\n'))
  .catch(()=>{process.stdout.write(JSON.stringify({available:false,code:'cloud_environment_unavailable',business_writes:false,task_submitted:false})+'\n');process.exitCode=1;});
}
module.exports={probeEnvironment,PreflightError};
