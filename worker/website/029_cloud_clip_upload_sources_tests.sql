-- Metadata/RLS transaction fixtures only; real source HTTP download is separate.
begin;
do $$
declare own text; w jsonb; j jsonb; jid uuid; prepared jsonb; sources jsonb; part jsonb;
        result jsonb; failed boolean; total bigint; lease uuid;
begin
  select m.auth_subject into own from public.st_members m join public.st_member_roles r on r.member_id=m.id
    where r.role_code='owner' and m.state='active' limit 1;
  if own is null then raise exception 'active_owner_required'; end if;
  perform set_config('request.jwt.claim.sub',own,true);
  execute 'SET LOCAL ROLE authenticated';
  w:=public.st_cloud_worker_create('clip-upload-rollback-fixture');
  j:=public.st_cloud_clip_create_upload('https://www.youtube.com/watch?v=PTL-ZkyrSPA','浮気判定',4200,20,2,(w->>'id')::uuid);
  jid:=(j->>'job_id')::uuid;
  if j->>'state'<>'waiting_source' then raise exception 'source_not_waiting'; end if;
  prepared:=public.st_cloud_clip_prepare_upload(jid,'source.mp4','video/mp4',10,repeat('c',64),3848,true,8673);
  failed:=false;
  begin perform public.st_cloud_clip_prepare_upload(jid,'changed.mp4','video/mp4',10,repeat('c',64),3848,true,8673);
  exception when others then failed:=true; end;
  if not failed then raise exception 'changed_source_accepted'; end if;
  part:=prepared->'parts'->0;
  sources:=jsonb_build_array(jsonb_build_object('index',1,'byte_size',10,
    'url','https://example-env.api.tcloudbasegateway.com/v1/storages/object/subtitle-inputs/'||(part->>'path')));
  failed:=false;
  begin perform public.st_cloud_clip_source_ready(jid,sources,now()+interval '1 hour');
  exception when others then failed:=true; end;
  if not failed then raise exception 'missing_source_parts_accepted'; end if;
  execute 'RESET ROLE';
  execute 'SET LOCAL ROLE anon';
  failed:=false;
  begin perform public.st_cloud_clip_call(w->>'key','claim',jid);
  exception when others then failed:=true; end;
  if not failed then raise exception 'claimed_incomplete_source'; end if;
  execute 'RESET ROLE';
  insert into storage.objects(bucket_id,name,metadata,owner_id) values('subtitle-inputs',part->>'path',
    jsonb_build_object('size',10,'mimetype','video/mp4'),'');
  execute 'SET LOCAL ROLE anon';
  select count(*) into total from storage.objects where bucket_id='subtitle-inputs' and name=part->>'path';
  if total<>0 then raise exception 'anonymous_input_read'; end if;
  execute 'RESET ROLE';
  execute 'SET LOCAL ROLE authenticated';
  result:=public.st_cloud_clip_source_ready(jid,sources,now()+interval '1 hour');
  if result->>'state'<>'queued' or result->>'server_sha_verified'<>'false' then raise exception 'source_ready_misreported'; end if;
  execute 'RESET ROLE';
  execute 'SET LOCAL ROLE anon';
  result:=public.st_cloud_clip_call(w->>'key','claim',jid);
  if result->>'state'<>'running' or result->>'source_kind'<>'upload' or result->>'source_sha256'<>repeat('c',64) or
    result->>'original_offset'<>'8673' or result->>'source_is_topic_only'<>'true' then
    raise exception 'upload_source_claim_metadata_lost'; end if;
  execute 'RESET ROLE';
end $$;
rollback;

