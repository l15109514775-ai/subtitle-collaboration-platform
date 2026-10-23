import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs/promises';
const root=new URL('../../',import.meta.url);
// Synthetic platform adapter only. NEVER apply auth/storage mocks to CloudBase.
export async function bootstrap({modern=false,installSql=null}={}){
 const db=new PGlite();
 await db.exec(`CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role BYPASSRLS;
 CREATE SCHEMA auth; CREATE SCHEMA storage;
 CREATE TABLE auth.users(id bigint GENERATED ALWAYS AS IDENTITY,sub text UNIQUE,username text,project text DEFAULT 'fixture',email_verified boolean);
 INSERT INTO auth.users(sub,username) VALUES('fixture-owner','administrator');
 CREATE FUNCTION auth.uid() RETURNS text LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('request.jwt.claim.sub',true),'') $$;
 GRANT USAGE ON SCHEMA auth,storage,public TO anon,authenticated,service_role;
 GRANT EXECUTE ON FUNCTION auth.uid() TO anon,authenticated,service_role;
 CREATE TABLE storage.buckets(id text PRIMARY KEY,name text,public boolean DEFAULT false,file_size_limit bigint,allowed_mime_types text[]);
 CREATE TABLE storage.objects(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),bucket_id text REFERENCES storage.buckets(id),name text,owner_id text,metadata jsonb,created_at timestamptz DEFAULT now(),UNIQUE(bucket_id,name));
 GRANT ALL ON storage.buckets,storage.objects TO anon,authenticated,service_role;`);
 if(modern)await db.exec("ALTER TABLE auth.users RENAME COLUMN id TO internal_id; ALTER TABLE auth.users RENAME COLUMN sub TO id;");
 const migrations=installSql ? [] : JSON.parse(await fs.readFile(new URL('database/migrations.json',root),'utf8'));
 for(const file of migrations){
  try{await db.exec(await fs.readFile(new URL('database/migrations/'+file,root),'utf8'));}
  catch(e){await db.close();throw new Error('Migration failed: '+file+': '+e.message);}
 }
 if(installSql)await db.exec(installSql);
 await db.exec(`INSERT INTO public.st_members(auth_subject,display_name) VALUES('fixture-owner','Synthetic owner');
 INSERT INTO public.st_member_roles(member_id,role_code) SELECT id,'owner' FROM public.st_members WHERE auth_subject='fixture-owner';`);
 return db;
}
