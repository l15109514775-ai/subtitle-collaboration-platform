-- Run AFTER 026 using the migration administrator, on a database with the
-- existing website schema and an active owner. Transaction rolls back EVERY
-- fixture. These are SQL metadata/RLS tests, NOT real storage HTTP/media tests.
begin;

create function pg_temp.clip_expect_failure(statement text) returns void
language plpgsql as $$
declare rejected boolean:=false;
begin
  begin execute statement; exception when others then rejected:=true; end;
  if not rejected then raise exception 'expected_rejection_missing'; end if;
end $$;

do $$
declare
  subject text; w jsonb; w2 jsonb; job jsonb; job2 jsonb; claim jsonb; selection_data jsonb;
  jid uuid; jid2 uuid; lid uuid; mid uuid; reservation jsonb; result jsonb;
  roles text[]:=array['clean','subtitled','cover']; role_name text; item jsonb;
  files jsonb:='[]'::jsonb; raw bytea; fname text; package jsonb; first_delivery uuid;
  before_points bigint; before_contributions bigint; old_rpc_hash text;
  missing boolean; requestid uuid:=gen_random_uuid(); headers jsonb; actual_count bigint;
begin
  select m.auth_subject into subject from public.st_members m join public.st_member_roles r on r.member_id=m.id
    where r.role_code='owner' and m.state='active' limit 1;
  if subject is null then raise exception 'active_owner_fixture_required'; end if;
  select count(*) into before_points from public.st_point_entries;
  select count(*) into before_contributions from public.st_contributions;
  select md5(string_agg(pg_get_functiondef(p.oid),'' order by p.oid)) into old_rpc_hash
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
    where ns.nspname='public' and p.proname='st_cloud_worker_call';
  perform set_config('request.jwt.claim.sub',subject,true);
  execute 'SET LOCAL ROLE authenticated';
  w:=public.st_cloud_worker_create('clip-sql-rollback-fixture');
  w2:=public.st_cloud_worker_create('clip-sql-other-worker');
  job:=public.st_cloud_clip_create('https://www.youtube.com/live/PTL-ZkyrSPA','浮気判定',4200,20,2,(w->>'id')::uuid);
  job2:=public.st_cloud_clip_create('https://www.youtube.com/watch?v=PTL-ZkyrSPA','隔离夹具',4200,20,2,(w2->>'id')::uuid);
  jid:=(job->>'job_id')::uuid;jid2:=(job2->>'job_id')::uuid;
  perform pg_temp.clip_expect_failure($q$select public.st_cloud_clip_create('https://127.0.0.1/','x')$q$);
  perform pg_temp.clip_expect_failure($q$select public.st_cloud_clip_create('https://www.youtube.com/watch?v=PTL-ZkyrSPA','x',4201)$q$);
  execute 'RESET ROLE';
  if exists(select 1 from public.st_tasks where project_id=(job->>'project_id')::uuid and state<>'archived') then
    raise exception 'generation_tasks_are_human_claimable'; end if;
  execute 'SET LOCAL ROLE anon';
  perform set_config('request.jwt.claim.sub','',true);
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L)',repeat('0',64),'claim',jid));
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L)',w->>'key','claim',jid2));
  claim:=public.st_cloud_clip_call(w->>'key','claim',jid);lid:=(claim->>'lease_id')::uuid;
  if claim->>'state'<>'running' or claim->>'max_clip_seconds'<>'4200' then raise exception 'clip_claim_failed'; end if;
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L)',w->>'key','claim',jid));
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','heartbeat',jid,jsonb_build_object('lease_id',gen_random_uuid())));
  selection_data:=jsonb_build_object('source_title','SQL离线夹具，不是实际直播成品','source_duration',14400,
    'source_sha256',repeat('a',64),'start',8673,'end',12521,'topic_confirmed',true,
    'complete_exchange_confirmed',true,'boundary_reason','Explicit synthetic SQL fixture',
    'evidence',jsonb_build_array(jsonb_build_object('fixture',true)));
  result:=public.st_cloud_clip_call(w->>'key','record_selection',jid,jsonb_build_object('lease_id',lid,'selection',selection_data));
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','record_selection',jid,jsonb_build_object('lease_id',lid,'selection',selection_data||'{"end":13000}')));
  result:=public.st_cloud_clip_call(w->>'key','reserve_request',jid,jsonb_build_object('lease_id',lid,'provider','qwen','request_id',requestid));
  if result->>'state'<>'reserved_once' then raise exception 'request_reservation_failed'; end if;
  result:=public.st_cloud_clip_call(w->>'key','reserve_request',jid,jsonb_build_object('lease_id',lid,'provider','qwen','request_id',requestid));
  if result->>'state'<>'already_reserved_do_not_resend' then raise exception 'reservation_replayed_permission'; end if;
  perform public.st_cloud_clip_call(w->>'key','reserve_request',jid,jsonb_build_object('lease_id',lid,'provider','qwen','request_id',gen_random_uuid()));
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','reserve_request',jid,jsonb_build_object('lease_id',lid,'provider','qwen','request_id',gen_random_uuid())));
  execute 'RESET ROLE';
  update public.st_cloud_workers set active=false where id=(w->>'id')::uuid;
  execute 'SET LOCAL ROLE anon';
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',w->>'key','heartbeat',jid,jsonb_build_object('lease_id',lid)));
  execute 'RESET ROLE';
  update public.st_cloud_workers set active=true where id=(w->>'id')::uuid;
  update public.st_cloud_clip_jobs set lease_expires_at=now()-interval '1 minute' where id=jid;
  execute 'SET LOCAL ROLE anon';
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',w->>'key','heartbeat',jid,jsonb_build_object('lease_id',lid)));
  execute 'RESET ROLE';
  update public.st_cloud_clip_jobs set lease_expires_at=now()+interval '45 minutes' where id=jid;
  execute 'SET LOCAL ROLE anon';
  foreach role_name in array roles loop
    reservation:=public.st_cloud_clip_call(w->>'key','reserve_media',jid,jsonb_build_object('lease_id',lid,
      'role',role_name,'filename',role_name||case when role_name='cover' then '.png' else '.mp4' end,
      'mime',case when role_name='cover' then 'image/png' else 'video/mp4' end,'bytes',10,'sha256',repeat('b',64)));
    mid:=(reservation->>'media_id')::uuid;
    perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
      w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid,'worker_verified_sha256',repeat('b',64))));
    item:=reservation->'parts'->0;
    -- Metadata fixture only: no actual media bytes exist in this transaction.
    execute 'RESET ROLE';
    insert into storage.objects(bucket_id,name,metadata,owner_id) values('subtitle-deliveries',item->>'object_name',
      jsonb_build_object('size',9,'mimetype',case when role_name='cover' then 'image/png' else 'video/mp4' end),'');
    execute 'SET LOCAL ROLE anon';
    perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
      w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid)));
    execute 'RESET ROLE';
    update storage.objects set metadata=jsonb_build_object('size',10,'mimetype','invalid/mime')
      where bucket_id='subtitle-deliveries' and name=item->>'object_name';
    execute 'SET LOCAL ROLE anon';
    perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
      w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid)));
    execute 'RESET ROLE';
    update storage.objects set metadata=jsonb_build_object('size',10,'mimetype',case when role_name='cover' then 'image/png' else 'video/mp4' end)
      where bucket_id='subtitle-deliveries' and name=item->>'object_name';
    execute 'SET LOCAL ROLE anon';
    perform set_config('request.headers','{}',true);
    select count(*) into actual_count from storage.objects where bucket_id='subtitle-deliveries' and name=item->>'object_name';
    if actual_count<>0 then raise exception 'anonymous_private_part_leaked'; end if;
    headers:=jsonb_build_object('x-cloud-clip-object',item->>'object_name',
      'x-cloud-clip-capability',reservation->>'capability','x-cloud-clip-worker',w->>'key');
    perform set_config('request.headers',headers::text,true);
    select count(*) into actual_count from storage.objects where bucket_id='subtitle-deliveries' and name=item->>'object_name';
    if actual_count<>1 then raise exception 'scoped_read_not_available'; end if;
    if public.st_clip_storage_insert_allowed('subtitle-deliveries','cloud-clips/'||repeat('0',64)||'/part-000001',
      jsonb_build_object('size',10,'mimetype','video/mp4')) then raise exception 'cross_path_insert_allowed'; end if;
    result:=public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid));
    if result->>'state'<>'metadata_verified' or result->>'server_sha_verified'<>'false' then raise exception 'server_claimed_byte_hash'; end if;
    result:=public.st_cloud_clip_call(w->>'key','finish_media',jid,jsonb_build_object('lease_id',lid,'media_id',mid,'worker_verified_sha256',repeat('b',64)));
    if result->>'state'<>'worker_sha_verified' then raise exception 'worker_attestation_missing'; end if;
  end loop;
  perform set_config('request.headers','{}',true);
  foreach fname in array array['Chinese.ass','Bilingual.ass','Chinese.srt','Bilingual.srt','cues.json','quality.json',
    'recognition-provenance.json','manifest.json','usage.json','selection.json'] loop
    raw:=convert_to(case when fname='selection.json' then selection_data::text
      when fname like '%.srt' then E'1\n00:00:00,000 --> 00:00:01,000\n明确的离线夹具'
      when fname like '%.ass' then E'[Script Info]\nScriptType: v4.00+\n[Events]\n; Offline fixture'
      else '{"offline_fixture":true}' end,'UTF8');
    files:=files||jsonb_build_array(jsonb_build_object('name',fname,'base64',encode(raw,'base64'),
      'bytes',octet_length(raw),'sha256',encode(sha256(raw),'hex')));
  end loop;
  package:=jsonb_build_object('lease_id',lid,'files',files);
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','publish',jid,jsonb_build_object('lease_id',lid,'files',files-9)));
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','publish',jid,jsonb_build_object('lease_id',lid,'files',jsonb_set(files,'{9}',files->0))));
  result:=public.st_cloud_clip_call(w->>'key','publish',jid,package);
  first_delivery:=(result->>'delivery_id')::uuid;
  if first_delivery is null or result->>'state'<>'succeeded' then raise exception 'clip_publish_failed'; end if;
  if public.st_cloud_clip_call(w->>'key','publish',jid,package)->>'delivery_id' is distinct from first_delivery::text then
    raise exception 'clip_publish_not_idempotent'; end if;
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L,%L::jsonb)',
    w->>'key','publish',jid,package||'{"unexpected":true}'));
  execute 'RESET ROLE';
  if (select count(*) from public.st_deliveries where project_id=(job->>'project_id')::uuid)<>4 then
    raise exception 'duplicate_or_missing_delivery_versions'; end if;
  if exists(select 1 from public.st_tasks where project_id=(job->>'project_id')::uuid and state<>'open') then
    raise exception 'human_review_not_opened'; end if;
  if exists(select 1 from public.st_claims where project_id=(job->>'project_id')::uuid and released_at is null) then
    raise exception 'worker_created_human_claim'; end if;
  if (select count(*) from public.st_contributions)<>before_contributions or (select count(*) from public.st_point_entries)<>before_points then
    raise exception 'human_credit_awarded_by_ai'; end if;
  if old_rpc_hash is distinct from (select md5(string_agg(pg_get_functiondef(p.oid),'' order by p.oid))
    from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='public' and p.proname='st_cloud_worker_call') then
    raise exception 'old_nine_file_rpc_changed'; end if;
  -- Cancellation and authorization expiry are independent from lease expiry.
  update public.st_cloud_clip_jobs set authorization_expires_at=now()-interval '1 minute' where id=jid2;
  execute 'SET LOCAL ROLE anon';
  perform pg_temp.clip_expect_failure(format('select public.st_cloud_clip_call(%L,%L,%L)',w2->>'key','claim',jid2));
  execute 'RESET ROLE';
end $$;

rollback;

