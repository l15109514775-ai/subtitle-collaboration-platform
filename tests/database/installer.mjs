import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {bootstrap} from './bootstrap.mjs';
const root=fileURLToPath(new URL('../../',import.meta.url));
const tempBase=path.resolve(root,'build','test-temp');await fs.mkdir(tempBase,{recursive:true});
const folder=await fs.mkdtemp(path.join(tempBase,'subtitle-install-'));
try{
 const config=path.join(folder,'fixture.json'),dest=path.join(folder,'deployment');
 await fs.writeFile(config,JSON.stringify({environment_id:'fixture-community',website_url:'https://fixture.tcloudbaseapp.com/',cloud_environment_name:'fixture-cloud',text_api_url:'https://fixture-provider.test/v1',text_model:'fixture-model',owner_auth_subject:'fixture-owner'}));
 execFileSync(process.env.PYTHON||'python',[path.join(root,'tools/configure.py'),'--config',config,'--out',dest],{stdio:'pipe'});
 const sql=await fs.readFile(path.join(dest,'database/INSTALL_ALL.sql'),'utf8');
 for(const modern of [false,true]){
  const db=await bootstrap({modern,installSql:sql});
  try{
   const field=modern?'id':'sub';
   await db.exec(`INSERT INTO auth.users(${field},username) VALUES('fixture-joiner','joiner');SELECT set_config('request.jwt.claim.sub','fixture-owner',false);SET ROLE authenticated;`);
   const id=(await db.query("SELECT public.st_enroll_member('fixture-joiner','Synthetic joiner') id")).rows[0].id;
   assert(id);
   await db.exec('RESET ROLE');
   await assert.rejects(()=>db.exec(sql),/Only install into an empty environment/);
   await db.exec('ROLLBACK');
   assert.equal((await db.query('SELECT count(*)::int n FROM public.st_members')).rows[0].n,2);
   console.log('PASS generated one-transaction installer and owner/member auth compatibility: '+field);
  }finally{await db.close();}
 }
}finally{
 const relative=path.relative(tempBase,path.resolve(folder));
 if(!relative || relative.startsWith('..') || path.isAbsolute(relative))throw Error('Refusing cleanup outside test temp base');
 await fs.rm(folder,{recursive:true,force:true});
}
