import assert from 'node:assert/strict';
import {bootstrap} from './bootstrap.mjs';
const db=await bootstrap();
try{
 const row=async(sql,args=[]) => (await db.query(sql,args)).rows[0];
 const rls=await row("SELECT count(*)::int n FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND c.relname LIKE 'st_%' AND NOT c.relrowsecurity");
 assert.equal(rls.n,0);console.log('PASS all business tables have RLS');
 assert.equal((await row('SELECT count(*)::int n FROM storage.buckets WHERE public')).n,0);console.log('PASS all project buckets private');
 await db.exec("SELECT set_config('request.jwt.claim.sub','fixture-owner',false);SET ROLE authenticated");
 const w=(await row("SELECT public.st_cloud_worker_create('Synthetic community worker') result")).result;
 assert.match(w.key,/^[0-9a-f]{64}$/);assert(w.id);console.log('PASS fresh installation creates scoped identity');
 await db.exec('RESET ROLE');
 await db.exec("INSERT INTO st_members(auth_subject,display_name) VALUES('fixture-member','Synthetic member');INSERT INTO st_member_roles SELECT id,'contributor',now() FROM st_members WHERE auth_subject='fixture-member'");
 await db.exec("SELECT set_config('request.jwt.claim.sub','fixture-member',false);SET ROLE authenticated");
 await assert.rejects(()=>db.query("SELECT public.st_cloud_worker_create('Forbidden')"));
 await assert.rejects(()=>db.query('SELECT key_hash FROM public.st_cloud_workers'));
 console.log('PASS ordinary member cannot create identity or read credential hashes');
 await db.exec('RESET ROLE;SET ROLE anon');
 await assert.rejects(()=>db.query('SELECT * FROM public.st_members'));
 await assert.rejects(()=>db.query('SELECT * FROM public.st_point_entries'));
 console.log('PASS anonymous cannot read members or point history');
 console.log('PASS clean install (synthetic platform adapter; real CloudBase not contacted)');
}finally{await db.close();}
