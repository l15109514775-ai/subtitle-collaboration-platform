-- Add a private upload source without modifying the original 60-second queue.
-- 026/027 are frozen for main-task review; this is an additive migration.
begin;
alter table public.st_cloud_clip_jobs drop constraint st_cloud_clip_jobs_state_check;
alter table public.st_cloud_clip_jobs add constraint st_cloud_clip_jobs_state_check
  check(state in ('waiting_source','queued','running','waiting_configuration','waiting_reconciliation','failed','cancelled','succeeded'));
alter table public.st_cloud_clip_jobs add column source_kind text not null default 'youtube' check(source_kind in ('youtube','upload'));

create table public.st_cloud_clip_sources(
  job_id uuid primary key references public.st_cloud_clip_jobs(id),
  filename text not null check(length(filename) between 1 and 160 and filename !~ '[/\\]'),
  mime text not null check(mime in ('video/mp4','video/webm','audio/mp4','audio/mpeg','audio/wav')),
  byte_size bigint not null check(byte_size between 1 and 4294967296),
  sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
  duration numeric not null check(duration>0 and duration<=21600),
  is_topic_only boolean not null,
  original_offset numeric not null check(original_offset>=0 and original_offset<=21600),
  object_prefix text not null unique,
  parts jsonb not null,
  created_by uuid not null references public.st_members(id),
  created_at timestamptz not null default now(),
  upload_expires_at timestamptz not null,
  state text not null default 'uploading' check(state in ('uploading','ready')),
  signed_sources jsonb,
  source_expires_at timestamptz,
  check((is_topic_only and duration<=4200 and original_offset+duration<=21600) or (not is_topic_only and original_offset=0))
);
alter table public.st_cloud_clip_sources enable row level security;
revoke all on public.st_cloud_clip_sources from public,anon,authenticated;

create function public.st_cloud_clip_create_upload(p_source_url text,p_topic text,
  p_max_clip_seconds integer default 4200,p_max_text_requests integer default 20,p_max_qwen_requests integer default 2,p_worker uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare result jsonb;
begin
  result:=public.st_cloud_clip_create(p_source_url,p_topic,p_max_clip_seconds,p_max_text_requests,p_max_qwen_requests,p_worker);
  update public.st_cloud_clip_jobs set state='waiting_source',source_kind='upload' where id=(result->>'job_id')::uuid;
  return result||jsonb_build_object('state','waiting_source','source_kind','upload');
end $$;

create function public.st_cloud_clip_prepare_upload(p_job uuid,p_filename text,p_mime text,p_bytes bigint,
  p_sha256 text,p_duration numeric,p_is_topic_only boolean,p_original_offset numeric default 0)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; s public.st_cloud_clip_sources; member uuid;
        prefix text; parts jsonb:='[]'::jsonb; n integer; count_parts integer;
begin
  if not public.st_owner() then raise exception 'owner_required' using errcode='42501'; end if;
  select * into j from public.st_cloud_clip_jobs where id=p_job for update;
  if not found or j.source_kind<>'upload' or j.state<>'waiting_source' then raise exception 'upload_job_not_waiting'; end if;
  select id into member from public.st_members where state='active' and auth_subject=current_setting('request.jwt.claim.sub',true);
  if member is null then raise exception 'active_owner_required'; end if;
  if p_filename is null or length(p_filename) not between 1 and 160 or p_filename ~ '[/\\]' or
     p_mime is null or p_mime not in ('video/mp4','video/webm','audio/mp4','audio/mpeg','audio/wav') or
     p_bytes is null or p_bytes not between 1 and 4294967296 or
     p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or
     p_duration is null or p_duration<=0 or p_duration>21600 or p_is_topic_only is null or
     p_original_offset is null or p_original_offset<0 or
     (p_is_topic_only and (p_duration>j.max_clip_seconds or p_original_offset+p_duration>21600)) or
     (not p_is_topic_only and p_original_offset<>0) then raise exception 'invalid_private_source'; end if;
  select * into s from public.st_cloud_clip_sources where job_id=p_job for update;
  if found then
    if s.filename<>p_filename or s.mime<>p_mime or s.byte_size<>p_bytes or s.sha256<>p_sha256 or
       s.duration<>p_duration or s.is_topic_only<>p_is_topic_only or s.original_offset<>p_original_offset then
      raise exception 'source_specification_changed'; end if;
    if s.upload_expires_at<=now() then raise exception 'source_upload_expired_requires_review'; end if;
  else
    prefix:='cloud-clips/'||encode(sha256(convert_to(gen_random_uuid()::text||gen_random_uuid()::text||gen_random_uuid()::text,'UTF8')),'hex')||'/source';
    count_parts:=ceil(p_bytes::numeric/4194304)::integer;
    for n in 1..count_parts loop
      parts:=parts||jsonb_build_array(jsonb_build_object('index',n,'path',prefix||'/part-'||lpad(n::text,6,'0'),
        'byte_size',least(4194304,p_bytes-(n-1)::bigint*4194304)));
    end loop;
    insert into public.st_cloud_clip_sources(job_id,filename,mime,byte_size,sha256,duration,is_topic_only,
      original_offset,object_prefix,parts,created_by,upload_expires_at)
      values(p_job,p_filename,p_mime,p_bytes,p_sha256,p_duration,p_is_topic_only,p_original_offset,prefix,
        parts,member,least(now()+interval '4 hours',j.authorization_expires_at)) returning * into s;
  end if;
  return jsonb_build_object('state','uploading','job_id',p_job,'bucket','subtitle-inputs',
    'part_bytes',4194304,'parts',s.parts,'expires_at',s.upload_expires_at,'overwrite',false);
end $$;

create function public.st_clip_input_owner_allowed(p_bucket text,p_name text,p_metadata jsonb,p_insert boolean)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select p_bucket='subtitle-inputs' and public.st_owner() and exists(
    select 1 from public.st_cloud_clip_sources s join public.st_cloud_clip_jobs j on j.id=s.job_id
      cross join lateral jsonb_array_elements(s.parts) part
    where s.state='uploading' and j.state='waiting_source' and s.upload_expires_at>now()
      and part->>'path'=p_name
      and (not p_insert or (p_metadata->>'size' ~ '^[0-9]+$' and
        (p_metadata->>'size')::bigint=(part->>'byte_size')::bigint and p_metadata->>'mimetype'=s.mime))
  );
$$;
-- No anonymous read/insert policy, no UPDATE/DELETE policy, no bucket publicity.
create policy st_clip_owner_insert_source on storage.objects for insert to authenticated
  with check(public.st_clip_input_owner_allowed(bucket_id,name,metadata,true));
create policy st_clip_owner_sign_source on storage.objects for select to authenticated
  using(public.st_clip_input_owner_allowed(bucket_id,name,metadata,false));

create function public.st_cloud_clip_source_ready(p_job uuid,p_sources jsonb,p_expires_at timestamptz)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; s public.st_cloud_clip_sources; part jsonb; supplied jsonb; n integer:=0; cnt integer;
begin
  if not public.st_owner() then raise exception 'owner_required' using errcode='42501'; end if;
  select * into j from public.st_cloud_clip_jobs where id=p_job for update;
  select * into s from public.st_cloud_clip_sources where job_id=p_job for update;
  if j.id is null or s.job_id is null or j.state<>'waiting_source' or s.state<>'uploading' or s.upload_expires_at<=now() then
    raise exception 'source_not_waiting_upload'; end if;
  if p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '23 hours' or
     jsonb_typeof(p_sources) is distinct from 'array' or jsonb_array_length(p_sources)<>jsonb_array_length(s.parts) then
    raise exception 'signed_source_parts_required'; end if;
  select count(*) into cnt from storage.objects o where o.bucket_id='subtitle-inputs' and
    left(o.name,length(s.object_prefix)+1)=s.object_prefix||'/';
  if cnt<>jsonb_array_length(s.parts) then raise exception 'source_parts_incomplete'; end if;
  for part in select value from jsonb_array_elements(s.parts) loop
    supplied:=p_sources->n;n:=n+1;
    if (supplied->>'index')::integer is distinct from (part->>'index')::integer or
       (supplied->>'byte_size')::bigint is distinct from (part->>'byte_size')::bigint or
       supplied->>'url' is null or supplied->>'url' !~ '^https://example-env\.api\.tcloudbasegateway\.com/' or
       strpos(supplied->>'url',part->>'path')=0 then raise exception 'source_url_or_order_invalid'; end if;
    if not exists(select 1 from storage.objects o where o.bucket_id='subtitle-inputs' and o.name=part->>'path' and
       o.metadata->>'size' ~ '^[0-9]+$' and (o.metadata->>'size')::bigint=(part->>'byte_size')::bigint and
       o.metadata->>'mimetype'=s.mime and o.created_at>=s.created_at and o.created_at<=s.upload_expires_at) then
      raise exception 'source_part_metadata_mismatch'; end if;
  end loop;
  update public.st_cloud_clip_sources set state='ready',signed_sources=p_sources,source_expires_at=p_expires_at where job_id=p_job;
  update public.st_cloud_clip_jobs set state='queued',updated_at=now() where id=p_job;
  return jsonb_build_object('state','queued','source_metadata_verified',true,'server_sha_verified',false);
end $$;

-- Extend, do not replace the original 60-second RPC. Wrapper can be removed
-- independently; inner 026 remains available only to the definer, never anon.
alter function public.st_cloud_clip_call(text,text,uuid,jsonb) rename to st_cloud_clip_call_v026;
revoke all on function public.st_cloud_clip_call_v026(text,text,uuid,jsonb) from public,anon,authenticated;
create function public.st_cloud_clip_call(p_key text,p_action text,p_job uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; s public.st_cloud_clip_sources; result jsonb;
begin
  if p_action='claim' then
    select * into j from public.st_cloud_clip_jobs where id=p_job for update;
    if j.source_kind='upload' then
      select * into s from public.st_cloud_clip_sources where job_id=p_job;
      if s.state is distinct from 'ready' or s.source_expires_at<=now() then raise exception 'private_source_not_ready_or_expired'; end if;
    end if;
  end if;
  result:=public.st_cloud_clip_call_v026(p_key,p_action,p_job,p_payload);
  if p_action='claim' and j.source_kind='upload' then
    result:=result||jsonb_build_object('source_kind','upload','source_file_name',s.filename,'source_mime',s.mime,
      'source_bytes',s.byte_size,'source_sha256',s.sha256,'source_duration',s.duration,
      'source_is_topic_only',s.is_topic_only,'original_offset',s.original_offset,
      'sources',s.signed_sources,'source_expires_at',s.source_expires_at);
  end if;
  return result;
end $$;

revoke all on function public.st_cloud_clip_create_upload(text,text,integer,integer,integer,uuid),
  public.st_cloud_clip_prepare_upload(uuid,text,text,bigint,text,numeric,boolean,numeric),
  public.st_cloud_clip_source_ready(uuid,jsonb,timestamptz) from public,anon;
grant execute on function public.st_cloud_clip_create_upload(text,text,integer,integer,integer,uuid),
  public.st_cloud_clip_prepare_upload(uuid,text,text,bigint,text,numeric,boolean,numeric),
  public.st_cloud_clip_source_ready(uuid,jsonb,timestamptz) to authenticated;
revoke all on function public.st_clip_input_owner_allowed(text,text,jsonb,boolean) from public,anon;
grant execute on function public.st_clip_input_owner_allowed(text,text,jsonb,boolean) to authenticated;
revoke all on function public.st_cloud_clip_call(text,text,uuid,jsonb) from public,authenticated;
grant execute on function public.st_cloud_clip_call(text,text,uuid,jsonb) to anon;
insert into public.st_schema_migrations(version) values('028_cloud_clip_upload_sources');
commit;

