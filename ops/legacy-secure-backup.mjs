import crypto from 'node:crypto'; import fs from 'node:fs/promises'; import path from 'node:path'; import cp from 'node:child_process'; import {fileURLToPath} from 'node:url'; const __dirname=path.dirname(fileURLToPath(import.meta.url));

const magic=Buffer.from('STBACKUP1\n');
function dpapi(bytes,mode){const r=cp.spawnSync('python',[path.join(__dirname,'legacy-dpapi.py'),mode],{input:bytes,windowsHide:true,maxBuffer:1048576});if(r.status!==0)throw Error('DPAPI operation failed');return r.stdout;}
async function sealBuffer(bytes,destination){
 const key=crypto.randomBytes(32),nonce=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',key,nonce);
 const encrypted=Buffer.concat([cipher.update(bytes),cipher.final()]);
 const header=Buffer.from(JSON.stringify({algorithm:'AES-256-GCM',keyProtection:'Windows CurrentUser DPAPI',wrappedKey:dpapi(key,'protect').toString('base64'),nonce:nonce.toString('base64'),tag:cipher.getAuthTag().toString('base64'),bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}));
 key.fill(0);const size=Buffer.alloc(4);size.writeUInt32BE(header.length);
 await fs.mkdir(path.dirname(destination),{recursive:true});await fs.writeFile(destination,Buffer.concat([magic,size,header,encrypted]),{flag:'wx'});
 const restored=await unsealBuffer(destination);if(!restored.equals(bytes))throw Error('Backup round trip mismatch');restored.fill(0);
 return {bytes:bytes.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex'),roundTripVerified:true};
}
async function unsealBuffer(source){
 const raw=await fs.readFile(source);if(!raw.subarray(0,magic.length).equals(magic))throw Error('Invalid backup');
 const n=raw.readUInt32BE(magic.length);if(n>65536)throw Error('Invalid header');const at=magic.length+4;
 const h=JSON.parse(raw.subarray(at,at+n));const key=dpapi(Buffer.from(h.wrappedKey,'base64'),'unprotect');
 try{const decipher=crypto.createDecipheriv('aes-256-gcm',key,Buffer.from(h.nonce,'base64'));decipher.setAuthTag(Buffer.from(h.tag,'base64'));
  const data=Buffer.concat([decipher.update(raw.subarray(at+n)),decipher.final()]);
  if(data.length!==h.bytes||crypto.createHash('sha256').update(data).digest('hex')!==h.sha256)throw Error('Backup integrity failed');return data;
 }finally{key.fill(0);}
}

export {sealBuffer,unsealBuffer};
