-- Independent clip core, aligned with the host schema supplied by the main task.
-- Real CloudBase HTTP header propagation/RLS still requires deployment testing.
begin;

do $$
begin
  if to_regclass('public.st_cloud_workers') is null or
     to_regclass('public.st_deliveries') is null or
     to_regclass('public.st_artifacts') is null or
     to_regclass('storage.objects') is null then
    raise exception 'cloud_clip_existing_schema_required';
  end if;
end $$;

create table public.st_cloud_clip_jobs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null,
  source_url text not null check (source_url ~ '^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$'),
  topic text not null check (length(topic) between 1 and 100),
  authorization_scope text not null unique,
  state text not null default 'queued' check (state in ('queued','running','waiting_configuration','waiting_reconciliation','failed','cancelled','succeeded')),
  worker_id uuid,
  lease_id uuid,
  lease_expires_at timestamptz,
  authorization_expires_at timestamptz not null default (now()+interval '24 hours'),
  max_clip_seconds integer not null check (max_clip_seconds between 1 and 4200),
  max_text_requests integer not null check (max_text_requests between 0 and 20),
  max_qwen_requests integer not null check (max_qwen_requests between 0 and 2),
  text_requests integer not null default 0 check (text_requests between 0 and 20),
  qwen_requests integer not null default 0 check (qwen_requests between 0 and 2),
  source_title text,
  source_duration numeric,
  source_sha256 text,
  clip_start numeric,
  clip_end numeric,
  selection jsonb,
  delivery_id uuid,
  publish_sha256 text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((selection is null) or (source_sha256 ~ '^[0-9a-f]{64}$' and
    source_duration > 0 and clip_start >= 0 and clip_end > clip_start and
    clip_end <= source_duration and clip_end-clip_start <= max_clip_seconds))
);

create table public.st_cloud_clip_attempts (
  job_id uuid not null references public.st_cloud_clip_jobs(id),
  request_id uuid not null,
  provider text not null check (provider in ('text','qwen')),
  lease_id uuid not null,
  created_at timestamptz not null default now(),
  primary key(job_id,request_id)
);

create table public.st_cloud_clip_media (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.st_cloud_clip_jobs(id),
  lease_id uuid not null,
  role text not null check (role in ('clean','subtitled','cover')),
  filename text not null check (filename ~ '^[A-Za-z0-9_-]{1,80}\.(mp4|png|jpg)$'),
  mime text not null check (mime in ('video/mp4','image/png','image/jpeg')),
  total_bytes bigint not null check (total_bytes between 1 and 1073741824),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  object_prefix text not null unique,
  expires_at timestamptz not null,
  part_count integer not null check (part_count between 1 and 256),
  parts jsonb not null,
  state text not null default 'reserved' check (state in ('reserved','metadata_verified','worker_sha_verified')),
  created_at timestamptz not null default now(),
  worker_verified_at timestamptz,
  artifact_id uuid,
  task_id uuid,
  unique(job_id,role),
  check ((role='cover' and mime in ('image/png','image/jpeg') and total_bytes <= 10000000) or
         (role in ('clean','subtitled') and mime='video/mp4'))
);

alter table public.st_cloud_clip_jobs enable row level security;
alter table public.st_cloud_clip_attempts enable row level security;
alter table public.st_cloud_clip_media enable row level security;
revoke all on public.st_cloud_clip_jobs, public.st_cloud_clip_attempts, public.st_cloud_clip_media from public,anon,authenticated;

create function public.st_clip_worker_identity(p_key text) returns uuid
language sql stable security definer set search_path=pg_catalog,public as $$
  select id from public.st_cloud_workers where active and key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
$$;
create function public.st_clip_worker_is_active(p_worker uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select exists(select 1 from public.st_cloud_workers where id=p_worker and active);
$$;
create function public.st_clip_is_owner() returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$ select public.st_owner(); $$;
create function public.st_clip_project_access(p_project uuid) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select public.st_owner() or exists(select 1 from public.st_project_members pm join public.st_members m on m.id=pm.member_id
    where pm.project_id=p_project and m.state='active' and m.auth_subject=current_setting('request.jwt.claim.sub',true));
$$;
create function public.st_clip_create_project(p_job uuid,p_title text) returns uuid
language plpgsql security definer set search_path=pg_catalog,public as $$
declare pid uuid; member uuid;
begin
  if not public.st_owner() then raise exception 'owner_required'; end if;
  select id into member from public.st_members where state='active' and auth_subject=current_setting('request.jwt.claim.sub',true);
  if member is null then raise exception 'active_owner_required'; end if;
  insert into public.st_projects(title,description,created_by,origin)
    values('待获取直播标题｜待确认时间码｜AI字幕初稿','云端独立剪辑；生成后开放人工听校。',member,'codex') returning id into pid;
  insert into public.st_tasks(project_id,title,description,kind,origin,state,created_by)
    values(pid,'原片剪辑','云端生成中；暂不开放人工认领。','clip','codex','archived',member),
          (pid,'中文字幕成片','云端生成中；暂不开放人工认领。','encode','codex','archived',member),
          (pid,'实际帧封面','云端生成中；暂不开放人工认领。','cover','codex','archived',member),
          (pid,'AI字幕初稿听校','生成完成后请人工听校、修订和复核。','proofread','codex','archived',member);
  return pid;
end $$;
create function public.st_clip_record_selection(p_project uuid,p_selection jsonb) returns void
language plpgsql security definer set search_path=pg_catalog,public as $$
declare a integer:=(p_selection->>'start')::numeric::integer; b integer:=(p_selection->>'end')::numeric::integer; stamp text;
begin
  stamp:=lpad((a/3600)::text,2,'0')||':'||lpad((a/60%60)::text,2,'0')||':'||lpad((a%60)::text,2,'0')||'–'||
    lpad((b/3600)::text,2,'0')||':'||lpad((b/60%60)::text,2,'0')||':'||lpad((b%60)::text,2,'0');
  update public.st_projects set title=left(replace(p_selection->>'source_title','｜',' '),120)||'｜'||stamp||'｜AI字幕初稿'
    where id=p_project and origin='codex';
end $$;

create function public.st_clip_register_delivery(p_job uuid,p_package jsonb) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; member uuid; runid uuid; taskid uuid; aid uuid; did uuid;
        proofid uuid; item jsonb; part jsonb; artifact_parts jsonb; role_name text; primary_delivery uuid; body text;
begin
  select * into strict j from public.st_cloud_clip_jobs where id=p_job for update;
  select created_by into member from public.st_cloud_workers where id=j.worker_id;
  if member is null then raise exception 'worker_creator_missing'; end if;
  if exists(select 1 from public.st_claims where project_id=j.project_id and released_at is null) then
    raise exception 'generation_task_claim_race'; end if;
  insert into public.st_agent_runs(project_id,provider,external_run_id,initiated_by,model_label,summary)
    values(j.project_id,'codex','cloud-clip:'||j.id::text,member,'gpt-6-luna / qwen3-asr-flash',
      'AI初稿；待人工听校；不计人工贡献或积分。') returning id into runid;
  for item in select value from jsonb_array_elements(p_package->'media') loop
    role_name:=item->>'role';
    select id into strict taskid from public.st_tasks where project_id=j.project_id and origin='codex' and
      title=case role_name when 'clean' then '原片剪辑' when 'subtitled' then '中文字幕成片' else '实际帧封面' end;
    select jsonb_agg(jsonb_build_object('index',(v->>'index')::integer,'path',v->>'object_name',
      'byte_size',(v->>'bytes')::bigint) order by (v->>'index')::integer) into artifact_parts
      from jsonb_array_elements(item->'parts') v;
    insert into public.st_artifacts(project_id,object_path,file_name,sha256,byte_size,mime_type,uploaded_by,parts)
      values(j.project_id,item->'parts'->0->>'object_name',item->>'filename',item->>'sha256',
        (item->>'bytes')::bigint,item->>'mime',member,artifact_parts) returning id into aid;
    update public.st_cloud_clip_media set artifact_id=aid,task_id=taskid where id=(item->>'media_id')::uuid and job_id=j.id;
    insert into public.st_deliveries(task_id,project_id,version_no,source,submitted_by,agent_run_id,artifact_id,
      content_sha256,notes) values(taskid,j.project_id,1,'codex',member,runid,aid,item->>'sha256',
      '云端AI初稿；来源和时间码已记录。SHA由云端上传后回读核验，服务端仅核验存储元数据；费用未对账。') returning id into did;
    if role_name='subtitled' then primary_delivery:=did; end if;
  end loop;
  select id into strict proofid from public.st_tasks where project_id=j.project_id and origin='codex' and kind='proofread';
  select convert_from(decode(f->>'base64','base64'),'UTF8') into body
    from jsonb_array_elements(p_package->'files') f where f->>'name'='Bilingual.srt';
  insert into public.st_deliveries(task_id,project_id,version_no,source,submitted_by,agent_run_id,content_text,content_sha256,notes)
    values(proofid,j.project_id,1,'codex',member,runid,body,encode(sha256(convert_to(body,'UTF8')),'hex'),
      '中日双语AI字幕初稿，需人工听校。完整ASS/SRT及质量/选段/usage可从云端剪辑报告下载。');
  -- Separate package table below retains all original small-file bytes. Human
  -- credit/points tables are never written by this workflow.
  insert into public.st_cloud_clip_packages(job_id,files) values(j.id,p_package->'files');
  update public.st_tasks set state='open' where project_id=j.project_id and origin='codex' and state='archived';
  return jsonb_build_object('state','succeeded','delivery_id',primary_delivery);
end $$;

create table public.st_cloud_clip_packages(job_id uuid primary key references public.st_cloud_clip_jobs(id),files jsonb not null);
alter table public.st_cloud_clip_packages enable row level security;
revoke all on public.st_cloud_clip_packages from public,anon,authenticated;

-- Helper is not executable by anon/authenticated. Locks the exact job, validates
-- current capability against the REAL st_cloud_workers adapter on every call.
create function public.st_clip_locked_job(p_key text,p_job uuid,p_lease uuid)
returns public.st_cloud_clip_jobs language plpgsql security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; w uuid;
begin
  w:=public.st_clip_worker_identity(p_key);
  if w is null then raise exception 'inactive_worker' using errcode='42501'; end if;
  select * into j from public.st_cloud_clip_jobs where id=p_job for update;
  if not found or j.worker_id is distinct from w or j.lease_id is distinct from p_lease or
     j.state <> 'running' or j.lease_expires_at <= now() or j.authorization_expires_at <= now() then
    raise exception 'inactive_job_or_lease' using errcode='42501';
  end if;
  return j;
end $$;

create function public.st_cloud_clip_create(p_source_url text,p_topic text,
  p_max_clip_seconds integer default 4200,p_max_text_requests integer default 20,p_max_qwen_requests integer default 2,p_worker uuid default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare jid uuid:=gen_random_uuid(); pid uuid; u text; vid text; assigned uuid;
begin
  if not public.st_clip_is_owner() then raise exception 'owner_required' using errcode='42501'; end if;
  if p_source_url ~ '^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$' then u:=p_source_url;
  elsif p_source_url ~ '^https://www\.youtube\.com/live/[A-Za-z0-9_-]{11}$' then
    vid:=substring(p_source_url from '/live/([A-Za-z0-9_-]{11})$');
    u:='https://www.youtube.com/watch?v='||vid;
  else raise exception 'canonical_public_youtube_url_required'; end if;
  if p_topic is null or length(btrim(p_topic)) not between 1 and 100 or
     p_max_clip_seconds is null or p_max_clip_seconds not between 1 and 4200 or
     p_max_text_requests is null or p_max_text_requests not between 0 and 20 or
     p_max_qwen_requests is null or p_max_qwen_requests not between 0 and 2 then
    raise exception 'invalid_clip_authorization';
  end if;
  -- Adapter creates a Codex project/generation tasks; prevents human task claim
  -- while preserving the project's normal owner/leader claim behavior.
  select id into assigned from public.st_cloud_workers where active and (p_worker is null or id=p_worker)
    order by created_at desc limit 1;
  if assigned is null then raise exception 'active_assigned_worker_required'; end if;
  pid:=public.st_clip_create_project(jid,'云端剪辑 · 等待识别');
  if pid is null then raise exception 'project_creation_not_confirmed'; end if;
  insert into public.st_cloud_clip_jobs(id,project_id,source_url,topic,authorization_scope,
    max_clip_seconds,max_text_requests,max_qwen_requests,worker_id)
  values(jid,pid,u,btrim(p_topic),'clip-'||jid::text,p_max_clip_seconds,p_max_text_requests,p_max_qwen_requests,assigned);
  return jsonb_build_object('state','queued','job_id',jid,'project_id',pid);
end $$;

-- Only exact reserved paths are writable. A random 256-bit path is a short-lived
-- capability; no prefix listing, wildcard reads or owner-id assumptions.
-- Host must confirm no earlier permissive anon storage policy applies. This
-- migration refuses to silently weaken/replace existing storage policies.
create function public.st_clip_storage_scope(p_job uuid,p_prefix text,p_name text) returns boolean
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare headers jsonb; w uuid;
begin
  begin headers:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  exception when others then return false; end;
  if headers->>'x-cloud-clip-object' is distinct from p_name or
     headers->>'x-cloud-clip-capability' is distinct from p_prefix then return false; end if;
  w:=public.st_clip_worker_identity(headers->>'x-cloud-clip-worker');
  return w is not null and exists(select 1 from public.st_cloud_clip_jobs where id=p_job and worker_id=w
    and state='running' and lease_expires_at>now() and authorization_expires_at>now());
end $$;


create function public.st_clip_storage_insert_allowed(p_bucket text,p_name text,p_metadata jsonb)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select p_bucket='subtitle-deliveries' and exists (
    select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id
    cross join lateral jsonb_array_elements(m.parts) part
    where m.state='reserved' and m.expires_at>now() and j.state='running'
      and j.lease_id=m.lease_id and j.lease_expires_at>now() and j.authorization_expires_at>now()
      and public.st_clip_storage_scope(m.job_id,m.object_prefix,p_name)
      and part->>'object_name'=p_name
      and (p_metadata->>'size') ~ '^[0-9]+$'
      and (p_metadata->>'size')::bigint=(part->>'bytes')::bigint
      and p_metadata->>'mimetype'=m.mime
  );
$$;

-- Storage requests must carry exactly one object name, its opaque capability,
-- and the dedicated worker identity. If CloudBase does not expose these headers
-- to RLS, access fails closed: validate actual HTTP before running real jobs.
-- Never add a fallback broad anonymous policy to make an upload succeed.
create function public.st_clip_storage_read_allowed(p_bucket text,p_name text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_bucket='subtitle-deliveries' and exists(select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id cross join lateral jsonb_array_elements(m.parts) part
    where part->>'object_name'=p_name and m.expires_at>now() and j.lease_id=m.lease_id
      and public.st_clip_storage_scope(m.job_id,m.object_prefix,p_name));
$$;

create policy st_clip_insert_reserved_part on storage.objects for insert to anon
  with check (public.st_clip_storage_insert_allowed(bucket_id,name,metadata));
create policy st_clip_worker_read_exact_part on storage.objects for select to anon
  using (public.st_clip_storage_read_allowed(bucket_id,name));
create function public.st_clip_member_storage_read_allowed(p_bucket text,p_name text) returns boolean
language sql stable security definer set search_path=pg_catalog,public as $$
  select p_bucket='subtitle-deliveries' and exists(select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id cross join lateral jsonb_array_elements(m.parts) part
    where j.state='succeeded' and part->>'object_name'=p_name and public.st_clip_project_access(j.project_id));
$$;
create policy st_clip_member_read_published_part on storage.objects for select to authenticated
  using (public.st_clip_member_storage_read_allowed(bucket_id,name));

create function public.st_cloud_clip_call(p_key text,p_action text,p_job uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public as $$
declare
  j public.st_cloud_clip_jobs; m public.st_cloud_clip_media; w uuid; lid uuid;
  result jsonb; part jsonb; specs jsonb:='[]'::jsonb; objects_seen integer;
  size_bytes bigint; count_parts integer; part_bytes bigint; prefix text;
  role_name text; mime_type text; fname text; full_sha text; n integer;
  selection_data jsonb; request_uuid uuid; provider_name text; requested integer;
  encoded text; file_data bytea; total_small bigint:=0; names text[]:='{}';
  payload_sha text; media_result jsonb; delivery_uuid uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'invalid_payload'; end if;
  if p_action not in ('claim','heartbeat','reserve_request','record_selection','reserve_media','read_part','finish_media','publish','stop') then
    raise exception 'invalid_clip_action';
  end if;
  w:=public.st_clip_worker_identity(p_key);
  if w is null then raise exception 'inactive_worker' using errcode='42501'; end if;
  if p_job is null then raise exception 'exact_clip_job_required'; end if;
  select * into j from public.st_cloud_clip_jobs where id=p_job for update;
  if not found then raise exception 'unknown_clip_job' using errcode='42501'; end if;
  lid:=nullif(p_payload->>'lease_id','')::uuid;
  if p_action='claim' then
    if j.worker_id is distinct from w then raise exception 'worker_not_assigned_to_job' using errcode='42501'; end if;
    if j.state<>'queued' or j.authorization_expires_at<=now() then raise exception 'clip_not_queued'; end if;
    lid:=gen_random_uuid();
    update public.st_cloud_clip_jobs set state='running',worker_id=w,lease_id=lid,
      lease_expires_at=now()+interval '45 minutes',updated_at=now() where id=p_job returning * into j;
    return jsonb_build_object('state','running','job_id',j.id,'lease_id',lid,'lease_seconds',2700,
      'authorization_scope',j.authorization_scope,'source_url',j.source_url,'topic',j.topic,
      'max_clip_seconds',j.max_clip_seconds,'max_text_requests',j.max_text_requests,'max_qwen_requests',j.max_qwen_requests,
      'authorization_expires_at',j.authorization_expires_at,'text_requests',j.text_requests,'qwen_requests',j.qwen_requests);
  end if;
  -- Same-lease repeated publish is readable after completion, even if its lease
  -- has naturally expired. Worker must still be active; no second version.
  if p_action='publish' and j.state='succeeded' and j.worker_id=w and j.lease_id=lid then
    payload_sha:=encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
    if payload_sha is distinct from j.publish_sha256 then raise exception 'publish_payload_changed'; end if;
    return jsonb_build_object('state','succeeded','delivery_id',j.delivery_id);
  end if;
  j:=public.st_clip_locked_job(p_key,p_job,lid);
  if p_action='heartbeat' then
    update public.st_cloud_clip_jobs set lease_expires_at=now()+interval '45 minutes',updated_at=now() where id=p_job;
    return jsonb_build_object('state','running','lease_seconds',2700,'text_requests',j.text_requests,'qwen_requests',j.qwen_requests);
  elsif p_action='record_selection' then
    selection_data:=p_payload->'selection';
    if jsonb_typeof(selection_data) is distinct from 'object' or length(selection_data::text)>50000 or
       not(selection_data ?& array['source_sha256','source_title','source_duration','start','end','topic_confirmed','complete_exchange_confirmed','boundary_reason','evidence']) or
       jsonb_typeof(selection_data->'source_sha256') is distinct from 'string' or
       jsonb_typeof(selection_data->'source_duration') is distinct from 'number' or
       jsonb_typeof(selection_data->'start') is distinct from 'number' or
       jsonb_typeof(selection_data->'end') is distinct from 'number' or
       (selection_data->>'source_duration')::numeric>21600 or
       selection_data->>'source_sha256' !~ '^[0-9a-f]{64}$' or
       length(coalesce(selection_data->>'source_title','')) not between 1 and 500 or
       selection_data->>'topic_confirmed' is distinct from 'true' or
       selection_data->>'complete_exchange_confirmed' is distinct from 'true' or
       length(coalesce(selection_data->>'boundary_reason',''))<3 or
       jsonb_typeof(selection_data->'evidence') is distinct from 'array' or jsonb_array_length(selection_data->'evidence')=0 then
      raise exception 'reviewed_source_selection_required';
    end if;
    if j.selection is not null then
      if j.selection<>selection_data then raise exception 'selection_is_immutable'; end if;
    else
      update public.st_cloud_clip_jobs set selection=selection_data,source_title=selection_data->>'source_title',
        source_duration=(selection_data->>'source_duration')::numeric,source_sha256=selection_data->>'source_sha256',
        clip_start=(selection_data->>'start')::numeric,clip_end=(selection_data->>'end')::numeric,
        updated_at=now() where id=p_job;
      -- Host adapter uses title + timecodes + AI字幕初稿, no human contribution.
      perform public.st_clip_record_selection(j.project_id,selection_data);
    end if;
    return jsonb_build_object('state','selection_recorded');
  elsif p_action='reserve_request' then
    if j.selection is null then raise exception 'selection_required_before_paid_request'; end if;
    request_uuid:=(p_payload->>'request_id')::uuid; provider_name:=p_payload->>'provider';
    if request_uuid is null or provider_name not in ('text','qwen') or provider_name is null then raise exception 'invalid_request_reservation'; end if;
    if exists(select 1 from public.st_cloud_clip_attempts where job_id=p_job and request_id=request_uuid) then
      -- Reconciliation does not grant permission to send again.
      return jsonb_build_object('state','already_reserved_do_not_resend');
    end if;
    requested:=case when provider_name='text' then j.text_requests else j.qwen_requests end;
    if requested >= (case when provider_name='text' then j.max_text_requests else j.max_qwen_requests end) then
      raise exception 'clip_request_budget_exhausted';
    end if;
    insert into public.st_cloud_clip_attempts(job_id,request_id,provider,lease_id) values(p_job,request_uuid,provider_name,lid);
    update public.st_cloud_clip_jobs set text_requests=text_requests+case when provider_name='text' then 1 else 0 end,
      qwen_requests=qwen_requests+case when provider_name='qwen' then 1 else 0 end,updated_at=now() where id=p_job;
    return jsonb_build_object('state','reserved_once','request_id',request_uuid);
  elsif p_action='reserve_media' then
    if j.selection is null then raise exception 'selection_required_before_media'; end if;
    role_name:=p_payload->>'role';mime_type:=p_payload->>'mime';fname:=p_payload->>'filename';
    size_bytes:=(p_payload->>'bytes')::bigint;full_sha:=p_payload->>'sha256';
    if role_name is null or role_name not in ('clean','subtitled','cover') or
       size_bytes is null or size_bytes not between 1 and 1073741824 or
       full_sha is null or full_sha !~ '^[0-9a-f]{64}$' or
       fname is null or fname !~ '^[A-Za-z0-9_-]{1,80}\.(mp4|png|jpg)$' or
       mime_type is null or
       (role_name='cover' and (mime_type not in ('image/png','image/jpeg') or size_bytes>10000000)) or
       (role_name<>'cover' and mime_type<>'video/mp4') then raise exception 'invalid_media_specification'; end if;
    select * into m from public.st_cloud_clip_media where job_id=p_job and role=role_name for update;
    if found then
      if m.lease_id<>lid or m.filename<>fname or m.mime<>mime_type or m.total_bytes<>size_bytes or m.sha256<>full_sha then
        raise exception 'media_specification_changed'; end if;
      if m.expires_at<=now() then raise exception 'media_capability_expired_reconciliation_required'; end if;
    else
      count_parts:=ceil(size_bytes::numeric/4194304)::integer;
      prefix:='cloud-clips/'||encode(sha256(convert_to(gen_random_uuid()::text||gen_random_uuid()::text||gen_random_uuid()::text,'UTF8')),'hex');
      for n in 1..count_parts loop
        part_bytes:=least(4194304,size_bytes-(n-1)::bigint*4194304);
        specs:=specs||jsonb_build_array(jsonb_build_object('index',n,'bytes',part_bytes,
          'object_name',prefix||'/part-'||lpad(n::text,6,'0')));
      end loop;
      insert into public.st_cloud_clip_media(job_id,lease_id,role,filename,mime,total_bytes,sha256,object_prefix,expires_at,part_count,parts)
      values(p_job,lid,role_name,fname,mime_type,size_bytes,full_sha,prefix,
        least(now()+interval '30 minutes',j.lease_expires_at,j.authorization_expires_at),count_parts,specs) returning * into m;
    end if;
    return jsonb_build_object('state','media_reserved','media_id',m.id,'bucket','subtitle-deliveries','capability',m.object_prefix,
      'part_bytes',4194304,'parts',m.parts,'expires_at',m.expires_at,'overwrite',false);
  elsif p_action in ('read_part','finish_media') then
    select * into m from public.st_cloud_clip_media where id=(p_payload->>'media_id')::uuid and job_id=p_job for update;
    if not found or m.lease_id<>lid or m.expires_at<=now() then raise exception 'inactive_media_capability'; end if;
    -- Verify every actual object, never just the caller's part declarations.
    select count(*) into objects_seen from storage.objects o
      where o.bucket_id='subtitle-deliveries' and left(o.name,length(m.object_prefix)+1)=m.object_prefix||'/';
    if objects_seen<>m.part_count then raise exception 'missing_or_extra_media_parts'; end if;
    for part in select value from jsonb_array_elements(m.parts) loop
      if not exists(select 1 from storage.objects o where o.bucket_id='subtitle-deliveries'
          and o.name=part->>'object_name' and o.metadata->>'mimetype'=m.mime
          and o.metadata->>'size' ~ '^[0-9]+$' and (o.metadata->>'size')::bigint=(part->>'bytes')::bigint
          and o.created_at>=m.created_at and o.created_at<=m.expires_at) then
        raise exception 'media_part_metadata_mismatch';
      end if;
    end loop;
    if p_action='read_part' then
      n:=(p_payload->>'index')::integer;
      if n is null or n<1 or n>m.part_count then raise exception 'invalid_part_index'; end if;
      -- Host implementation supplies one short-lived signed read URL, exact path
      -- only, never adds broad anonymous SELECT to the private bucket.
      return jsonb_build_object('state','read_part_ready','bucket','subtitle-deliveries',
        'object_name',m.parts->(n-1)->>'object_name','bytes',(m.parts->(n-1)->>'bytes')::bigint,
        'capability',m.object_prefix,'expires_at',m.expires_at);
    end if;
    if p_payload->>'worker_verified_sha256' is distinct from m.sha256 then
      update public.st_cloud_clip_media set state='metadata_verified' where id=m.id;
      return jsonb_build_object('state','metadata_verified','server_sha_verified',false,'worker_sha_verified',false);
    end if;
    update public.st_cloud_clip_media set state='worker_sha_verified',worker_verified_at=now() where id=m.id;
    return jsonb_build_object('state','worker_sha_verified','server_sha_verified',false,'worker_sha_verified',true);
  elsif p_action='stop' then
    if p_payload->>'state' is null or p_payload->>'state' not in ('failed','waiting_configuration','waiting_reconciliation') then
      raise exception 'invalid_stop_state'; end if;
    update public.st_cloud_clip_jobs set state=p_payload->>'state',updated_at=now() where id=p_job;
    return jsonb_build_object('state',p_payload->>'state','text_requests',j.text_requests,'qwen_requests',j.qwen_requests);
  elsif p_action='publish' then
    if j.selection is null then raise exception 'selection_missing'; end if;
    select jsonb_agg(jsonb_build_object('media_id',id,'role',role,'filename',filename,'mime',mime,
      'bytes',total_bytes,'sha256',sha256,'parts',parts)) into media_result
      from public.st_cloud_clip_media where job_id=p_job and lease_id=lid and state='worker_sha_verified';
    if coalesce(jsonb_array_length(media_result),0)<>3 then raise exception 'three_verified_media_required'; end if;
    if jsonb_typeof(p_payload->'files') is distinct from 'array' or jsonb_array_length(p_payload->'files')<>10 then
      raise exception 'ten_small_delivery_files_required'; end if;
    for part in select value from jsonb_array_elements(p_payload->'files') loop
      fname:=part->>'name';encoded:=part->>'base64';
      if fname is null or fname not in ('Chinese.ass','Bilingual.ass','Chinese.srt','Bilingual.srt','cues.json',
          'quality.json','recognition-provenance.json','manifest.json','usage.json','selection.json') or fname=any(names) then
        raise exception 'invalid_or_duplicate_delivery_filename'; end if;
      names:=array_append(names,fname);
      if encoded is null or length(encoded)>666668 then raise exception 'small_file_limit'; end if;
      file_data:=decode(encoded,'base64');total_small:=total_small+octet_length(file_data);
      if octet_length(file_data)>500000 or octet_length(file_data) is distinct from (part->>'bytes')::integer or
         encode(sha256(file_data),'hex') is distinct from part->>'sha256' or total_small>2000000 then
        raise exception 'delivery_bytes_or_hash_mismatch'; end if;
      if fname='selection.json' and convert_from(file_data,'UTF8')::jsonb is distinct from j.selection then
        raise exception 'selection_report_changed'; end if;
    end loop;
    payload_sha:=encode(sha256(convert_to(p_payload::text,'UTF8')),'hex');
    -- Adapter must atomically create ONE source=codex delivery/version, register
    -- st_artifacts including parts, open human proofread tasks and award no human
    -- points/contributions. It must not accept arbitrary project/media paths.
    result:=public.st_clip_register_delivery(p_job,jsonb_build_object('project_id',j.project_id,
      'source','codex','human_review_required',true,'human_contribution',0,'human_points',0,
      'media',media_result,'files',p_payload->'files','selection',j.selection));
    delivery_uuid:=(result->>'delivery_id')::uuid;
    if result->>'state' is distinct from 'succeeded' or delivery_uuid is null then raise exception 'delivery_registration_not_confirmed'; end if;
    update public.st_cloud_clip_jobs set state='succeeded',delivery_id=delivery_uuid,publish_sha256=payload_sha,updated_at=now() where id=p_job;
    return jsonb_build_object('state','succeeded','delivery_id',delivery_uuid,'human_review_required',true);
  end if;
  raise exception 'unsupported_clip_action';
end $$;

create function public.st_cloud_clip_cancel(p_job uuid) returns jsonb
language plpgsql security definer set search_path=pg_catalog,public as $$
begin
  if not public.st_clip_is_owner() then raise exception 'owner_required' using errcode='42501'; end if;
  update public.st_cloud_clip_jobs set state='cancelled',updated_at=now() where id=p_job and state<>'succeeded';
  return jsonb_build_object('state','cancelled');
end $$;

create function public.st_cloud_clip_board() returns jsonb
language sql stable security definer set search_path=pg_catalog,public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',j.id,'project_id',j.project_id,
    'project_name',coalesce(j.source_title,'云端剪辑')||' · AI字幕初稿','source_title',j.source_title,
    'state',j.state,'text_requests',j.text_requests,'qwen_requests',j.qwen_requests,'delivery_id',j.delivery_id,
    'media',case when j.state='succeeded' then (select jsonb_agg(jsonb_build_object('id',m.id,'role',m.role,
      'filename',m.filename,'mime',m.mime,'bytes',m.total_bytes,'sha256',m.sha256,'artifact_id',m.artifact_id,'task_id',m.task_id))
      from public.st_cloud_clip_media m where m.job_id=j.id) else '[]'::jsonb end)
    order by j.created_at desc),'[]'::jsonb)
  from public.st_cloud_clip_jobs j join public.st_projects p on p.id=j.project_id
  where p.deleted_at is null and public.st_clip_project_access(j.project_id);
$$;

create function public.st_cloud_clip_files(p_job uuid) returns jsonb
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare j public.st_cloud_clip_jobs; result jsonb;
begin
  select * into j from public.st_cloud_clip_jobs where id=p_job;
  if not found or j.state<>'succeeded' or not public.st_clip_project_access(j.project_id) then
    raise exception 'project_access_required' using errcode='42501'; end if;
  select files into result from public.st_cloud_clip_packages where job_id=p_job;
  return jsonb_build_object('job_id',p_job,'files',result);
end $$;

revoke all on function public.st_clip_locked_job(text,uuid,uuid) from public,anon,authenticated;
revoke all on function public.st_clip_worker_identity(text),public.st_clip_worker_is_active(uuid),
  public.st_clip_is_owner(),public.st_clip_project_access(uuid),public.st_clip_create_project(uuid,text),
  public.st_clip_record_selection(uuid,jsonb),public.st_clip_register_delivery(uuid,jsonb),
  public.st_clip_storage_scope(uuid,text,text) from public,anon,authenticated;
revoke all on function public.st_clip_storage_insert_allowed(text,text,jsonb) from public,authenticated;
grant execute on function public.st_clip_storage_insert_allowed(text,text,jsonb) to anon;
revoke all on function public.st_clip_storage_read_allowed(text,text) from public,authenticated;
grant execute on function public.st_clip_storage_read_allowed(text,text) to anon;
revoke all on function public.st_cloud_clip_call(text,text,uuid,jsonb) from public,authenticated;
grant execute on function public.st_cloud_clip_call(text,text,uuid,jsonb) to anon;
revoke all on function public.st_cloud_clip_create(text,text,integer,integer,integer,uuid) from public,anon;
revoke all on function public.st_cloud_clip_cancel(uuid) from public,anon;
revoke all on function public.st_cloud_clip_board() from public,anon;
revoke all on function public.st_cloud_clip_files(uuid) from public,anon;
grant execute on function public.st_cloud_clip_files(uuid) to authenticated;
revoke all on function public.st_clip_member_storage_read_allowed(text,text) from public,anon;
grant execute on function public.st_clip_member_storage_read_allowed(text,text) to authenticated;
insert into public.st_schema_migrations(version) values('026_cloud_clips');
grant execute on function public.st_cloud_clip_create(text,text,integer,integer,integer,uuid),
  public.st_cloud_clip_cancel(uuid),public.st_cloud_clip_board() to authenticated;

commit;

