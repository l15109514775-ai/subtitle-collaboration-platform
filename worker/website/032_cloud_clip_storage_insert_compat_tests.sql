-- Run AFTER 031, as migration administrator. Everything rolls back. Tests the
-- measured native initial INSERT metadata=NULL phase without broadening scope.
begin;
create function pg_temp.clip_assert(value boolean,label text) returns void language plpgsql as $$
begin if not coalesce(value,false) then raise exception '%',label; end if; end $$;
do $$
declare own text; w jsonb; job jsonb; claim jsonb; plan jsonb; selection_data jsonb;
        jid uuid; lid uuid; mid uuid; object_name text; cap text; headers jsonb; rejected boolean; result jsonb;
begin
  select m.auth_subject into own from public.st_members m join public.st_member_roles r on r.member_id=m.id
    where r.role_code='owner' and m.state='active' limit 1;
  if own is null then raise exception 'active_owner_required'; end if;
  perform set_config('request.jwt.claim.sub',own,true);
  execute 'SET LOCAL ROLE authenticated';
  w:=public.st_cloud_worker_create('insert-null-metadata-rollback-only');
  job:=public.st_cloud_clip_create('https://www.youtube.com/watch?v=PTL-ZkyrSPA','SQL离线存储夹具',4200,0,0,(w->>'id')::uuid);
  jid:=(job->>'job_id')::uuid;
  execute 'RESET ROLE';execute 'SET LOCAL ROLE anon';
  claim:=public.st_cloud_clip_call(w->>'key','claim',jid);lid:=(claim->>'lease_id')::uuid;
  selection_data:=jsonb_build_object('source_title','明确SQL离线夹具','source_duration',1,'source_sha256',repeat('a',64),
    'start',0,'end',1,'topic_confirmed',true,'complete_exchange_confirmed',true,'boundary_reason','SQL rollback fixture',
    'evidence',jsonb_build_array(jsonb_build_object('fixture',true)));
  perform public.st_cloud_clip_call(w->>'key','record_selection',jid,jsonb_build_object('lease_id',lid,'selection',selection_data));
  plan:=public.st_cloud_clip_call(w->>'key','reserve_media',jid,jsonb_build_object('lease_id',lid,
    'role','cover','filename','fixture.png','mime','image/png','bytes',68,'sha256',repeat('b',64)));
  mid:=(plan->>'media_id')::uuid;object_name:=plan->'parts'->0->>'object_name';cap:=plan->>'capability';
  headers:=jsonb_build_object('x-cloud-clip-object',object_name,'x-cloud-clip-capability',cap,'x-cloud-clip-worker',w->>'key');
  perform set_config('request.headers',headers::text,true);
  perform pg_temp.clip_assert(public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'exact_scoped_null_metadata_insert_denied');
  -- Actual initial row insertion, not just helper evaluation.
  insert into storage.objects(bucket_id,name,metadata,owner_id) values('subtitle-deliveries',object_name,null,'');
  rejected:=false;
  begin perform public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid));
  exception when others then rejected:=true; end;
  perform pg_temp.clip_assert(rejected,'finish_accepted_missing_actual_metadata');
  perform set_config('request.headers','{}',true);
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'missing_headers_insert_allowed');
  perform set_config('request.headers',(headers||jsonb_build_object('x-cloud-clip-worker','invalid'))::text,true);
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'invalid_worker_insert_allowed');
  perform set_config('request.headers',(headers||jsonb_build_object('x-cloud-clip-capability','invalid'))::text,true);
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'wrong_capability_insert_allowed');
  perform set_config('request.headers',headers::text,true);
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',cap||'/part-000002',null),'unreserved_path_insert_allowed');
  execute 'RESET ROLE';
  -- Avoid PL/pgSQL variable/column ambiguity in subsequent updates.
  update storage.objects o set metadata=jsonb_build_object('size',69,'mimetype','image/png')
    where o.bucket_id='subtitle-deliveries' and o.name=plan->'parts'->0->>'object_name';
  execute 'SET LOCAL ROLE anon';
  rejected:=false;
  begin perform public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid));
  exception when others then rejected:=true; end;
  perform pg_temp.clip_assert(rejected,'finish_accepted_wrong_actual_size');
  execute 'RESET ROLE';
  update storage.objects o set metadata=jsonb_build_object('size',68,'mimetype','video/mp4')
    where o.bucket_id='subtitle-deliveries' and o.name=plan->'parts'->0->>'object_name';
  execute 'SET LOCAL ROLE anon';rejected:=false;
  begin perform public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid));
  exception when others then rejected:=true; end;
  perform pg_temp.clip_assert(rejected,'finish_accepted_wrong_actual_mime');
  execute 'RESET ROLE';
  update storage.objects o set metadata=jsonb_build_object('size',68,'mimetype','image/png')
    where o.bucket_id='subtitle-deliveries' and o.name=plan->'parts'->0->>'object_name';
  execute 'SET LOCAL ROLE anon';
  result:=public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid));
  perform pg_temp.clip_assert(result->>'state'='metadata_verified' and result->>'server_sha_verified'='false','metadata_verification_misreported');
  execute 'RESET ROLE';
  update public.st_cloud_clip_media set state='reserved' where id=mid;
  update public.st_cloud_workers set active=false where id=(w->>'id')::uuid;
  execute 'SET LOCAL ROLE anon';
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'revoked_worker_insert_allowed');
  execute 'RESET ROLE';
  update public.st_cloud_workers set active=true where id=(w->>'id')::uuid;
  update public.st_cloud_clip_jobs set lease_expires_at=now()-interval '1 minute' where id=jid;
  execute 'SET LOCAL ROLE anon';
  perform pg_temp.clip_assert(not public.st_clip_storage_insert_allowed('subtitle-deliveries',object_name,null),'expired_lease_insert_allowed');
  execute 'RESET ROLE';
end $$;
rollback;

