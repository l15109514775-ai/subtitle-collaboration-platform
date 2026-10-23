-- REVIEW CANDIDATE ONLY. No live execution authorized by this file.
-- Requires live metadata comparison and pre-change backup before approval.
BEGIN;
CREATE TABLE public.st_project_blocks(
 project_id uuid NOT NULL REFERENCES public.st_projects(id),member_id uuid NOT NULL REFERENCES public.st_members(id),
 reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 1 AND 300),created_by uuid NOT NULL REFERENCES public.st_members(id),
 created_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(project_id,member_id));
ALTER TABLE public.st_project_blocks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_project_blocks FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER st_audit AFTER INSERT OR UPDATE OR DELETE ON public.st_project_blocks FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
ALTER TABLE public.st_cloud_workers
 ADD COLUMN expires_at timestamptz NOT NULL DEFAULT (now()+interval '7 days'),
 ADD COLUMN max_jobs integer NOT NULL DEFAULT 20 CHECK(max_jobs BETWEEN 1 AND 1000),
 ADD COLUMN claimed_jobs integer NOT NULL DEFAULT 0 CHECK(claimed_jobs>=0);
ALTER TABLE public.st_cloud_jobs ADD COLUMN execution_deadline timestamptz;
ALTER TABLE public.st_cloud_clip_jobs ADD COLUMN execution_deadline timestamptz;

CREATE FUNCTION public.st_worker_valid(p_worker uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_workers w
 JOIN public.st_members m ON m.id=w.created_by AND m.state='active'
 JOIN public.st_member_roles r ON r.member_id=m.id AND r.role_code='owner'
 WHERE w.id=p_worker AND w.active AND w.expires_at>now());
$$;
CREATE OR REPLACE FUNCTION public.st_clip_worker_identity(p_key text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT id FROM public.st_cloud_workers WHERE p_key ~ '^[0-9a-f]{64}$'
 AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex') AND public.st_worker_valid(id);
$$;
CREATE OR REPLACE FUNCTION public.st_clip_worker_is_active(p_worker uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT public.st_worker_valid(p_worker); $$;
CREATE OR REPLACE FUNCTION public.st_clip_project_access(p_project uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT public.st_project_access(p_project); $$;

CREATE OR REPLACE FUNCTION public.st_project_access(p_project uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND deleted_at IS NULL AND state='active')
 AND (public.st_owner() OR (EXISTS(SELECT 1 FROM public.st_project_members WHERE project_id=p_project AND member_id=public.st_actor())
 AND NOT EXISTS(SELECT 1 FROM public.st_project_blocks WHERE project_id=p_project AND member_id=public.st_actor())));
$$;
CREATE FUNCTION public.st_blocked_membership_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.st_project_blocks WHERE project_id=NEW.project_id AND member_id=NEW.member_id)
 THEN RAISE EXCEPTION 'Project membership revoked' USING ERRCODE='42501'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_blocked_membership_guard BEFORE INSERT OR UPDATE ON public.st_project_members
 FOR EACH ROW EXECUTE FUNCTION public.st_blocked_membership_guard();
CREATE TRIGGER st_blocked_claim_guard BEFORE INSERT ON public.st_claims
 FOR EACH ROW EXECUTE FUNCTION public.st_blocked_membership_guard();

CREATE FUNCTION public.st_security_members(p_project uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION 'Owner required' USING ERRCODE='42501'; END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'display_name',m.display_name,'state',m.state,
 'owner',EXISTS(SELECT 1 FROM public.st_member_roles r WHERE r.member_id=m.id AND r.role_code='owner'),
 'blocked',EXISTS(SELECT 1 FROM public.st_project_blocks b WHERE b.member_id=m.id AND b.project_id=p_project)) ORDER BY m.created_at) FROM public.st_members m),'[]'::jsonb);
END; $$;
CREATE FUNCTION public.st_set_member_state(p_member uuid,p_state text,p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() OR p_member IS NOT DISTINCT FROM public.st_actor()
 OR EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=p_member AND role_code='owner')
 THEN RAISE EXCEPTION 'Cannot change this member state' USING ERRCODE='42501'; END IF;
 IF p_state IS NULL OR p_state NOT IN ('active','suspended') OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 300
 THEN RAISE EXCEPTION 'State and reason required'; END IF;
 UPDATE public.st_members SET state=p_state WHERE id=p_member;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown member'; END IF;
 -- Audit contains state transition and reason, not contact details.
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,'st_members',p_member::text,'UPDATE',jsonb_build_object('state',p_state,'reason',btrim(p_reason),'action','member_state'));
END; $$;
CREATE FUNCTION public.st_set_project_block(p_project uuid,p_member uuid,p_block boolean,p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() OR p_member IS NOT DISTINCT FROM public.st_actor()
 OR EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=p_member AND role_code='owner')
 THEN RAISE EXCEPTION 'Cannot revoke this member' USING ERRCODE='42501'; END IF;
 IF p_block IS NULL OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 1 AND 300 THEN RAISE EXCEPTION 'Reason required'; END IF;
 PERFORM 1 FROM public.st_projects WHERE id=p_project AND deleted_at IS NULL AND state='active' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Project unavailable'; END IF;
 PERFORM 1 FROM public.st_members WHERE id=p_member;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown member'; END IF;
 IF p_block THEN
  INSERT INTO public.st_project_blocks(project_id,member_id,reason,created_by) VALUES(p_project,p_member,btrim(p_reason),public.st_actor())
   ON CONFLICT(project_id,member_id) DO UPDATE SET reason=EXCLUDED.reason,created_by=EXCLUDED.created_by,created_at=now();
  DELETE FROM public.st_project_members WHERE project_id=p_project AND member_id=p_member;
  UPDATE public.st_tasks SET state='open' WHERE project_id=p_project AND state='claimed'
   AND id IN (SELECT task_id FROM public.st_claims WHERE project_id=p_project AND member_id=p_member AND released_at IS NULL);
  UPDATE public.st_claims SET released_at=now(),release_reason='project access revoked' WHERE project_id=p_project AND member_id=p_member AND released_at IS NULL;
  UPDATE public.st_projects SET lead_member_id=NULL WHERE id=p_project AND lead_member_id=p_member;
 ELSE
  DELETE FROM public.st_project_blocks WHERE project_id=p_project AND member_id=p_member;
 END IF;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,'st_project_blocks',p_member::text,'UPDATE',jsonb_build_object('project_id',p_project,'member_id',p_member,'blocked',p_block,'reason',btrim(p_reason),'action','project_access'));
END; $$;

-- Quota increment and claim are in the SAME transaction; locks serialize both queues.
CREATE FUNCTION public.st_cloud_job_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE w public.st_cloud_workers; lease_end timestamptz;
BEGIN
 IF NEW.state IN ('queued','running') THEN
  IF NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=NEW.project_id AND deleted_at IS NULL AND state='active')
  THEN RAISE EXCEPTION 'Project unavailable' USING ERRCODE='42501'; END IF;
  IF TG_TABLE_NAME='st_cloud_jobs' THEN
   IF NOT EXISTS(SELECT 1 FROM public.st_tasks WHERE id=NEW.task_id AND project_id=NEW.project_id AND deleted_at IS NULL AND state='open')
   THEN RAISE EXCEPTION 'Task unavailable' USING ERRCODE='42501'; END IF;
  END IF;
  IF NOT public.st_worker_valid(NEW.worker_id) THEN RAISE EXCEPTION 'Worker expired or revoked' USING ERRCODE='42501'; END IF;
 END IF;
 IF NEW.state='running' THEN
  IF TG_OP='INSERT' OR OLD.state IS DISTINCT FROM 'running' THEN
   UPDATE public.st_cloud_workers SET claimed_jobs=claimed_jobs+1 WHERE id=NEW.worker_id
    AND claimed_jobs<max_jobs AND public.st_worker_valid(id) RETURNING * INTO w;
   IF w.id IS NULL THEN RAISE EXCEPTION 'Worker job quota exhausted' USING ERRCODE='42501'; END IF;
   NEW.execution_deadline:=least(now()+interval '6 hours',w.expires_at);
  ELSE
   NEW.execution_deadline:=OLD.execution_deadline;
  END IF;
  IF NEW.execution_deadline IS NULL THEN
   NEW.execution_deadline:=least(OLD.created_at+interval '24 hours',now()+interval '6 hours');
  END IF;
  IF NEW.execution_deadline<=now() THEN RAISE EXCEPTION 'Execution deadline reached' USING ERRCODE='42501'; END IF;
  SELECT expires_at INTO lease_end FROM public.st_cloud_workers WHERE id=NEW.worker_id;
  IF TG_TABLE_NAME='st_cloud_jobs' THEN
   NEW.lease_until:=least(NEW.lease_until,NEW.execution_deadline,lease_end);
  ELSE
   NEW.lease_expires_at:=least(NEW.lease_expires_at,NEW.execution_deadline,lease_end,NEW.authorization_expires_at);
  END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_security_job_guard BEFORE INSERT OR UPDATE ON public.st_cloud_jobs
 FOR EACH ROW EXECUTE FUNCTION public.st_cloud_job_guard();
CREATE TRIGGER st_security_job_guard BEFORE INSERT OR UPDATE ON public.st_cloud_clip_jobs
 FOR EACH ROW EXECUTE FUNCTION public.st_cloud_job_guard();

CREATE FUNCTION public.st_review_resource_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.st_tasks t JOIN public.st_projects p ON p.id=t.project_id
  WHERE t.id=NEW.task_id AND p.id=NEW.project_id AND t.deleted_at IS NULL
  AND p.deleted_at IS NULL AND p.state='active' AND t.state='submitted')
 THEN RAISE EXCEPTION 'Cannot review deleted or inactive work' USING ERRCODE='42501'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_review_resource_guard BEFORE INSERT ON public.st_reviews
 FOR EACH ROW EXECUTE FUNCTION public.st_review_resource_guard();


CREATE OR REPLACE FUNCTION public.st_work_catalog() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可浏览待认领目录'; END IF;
 RETURN jsonb_build_object(
 'projects',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'description',CASE WHEN public.st_project_access(p.id) THEN p.description ELSE '' END,'origin',p.origin,'lead_member_id',p.lead_member_id,'lead_name',m.display_name,'can_access',public.st_project_access(p.id)) ORDER BY p.created_at DESC) FROM public.st_projects p LEFT JOIN public.st_members m ON m.id=p.lead_member_id WHERE p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(jsonb_build_object('id',t.id,'project_id',t.project_id,'title',t.title,'description',CASE WHEN public.st_project_access(t.project_id) THEN t.description ELSE '' END,'kind',t.kind,'origin',t.origin) ORDER BY t.created_at DESC) FROM public.st_tasks t JOIN public.st_projects p ON p.id=t.project_id WHERE t.deleted_at IS NULL AND t.state='open' AND p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION public.st_cloud_jobs_view(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录正式成员账号'; END IF;
 RETURN jsonb_build_object('workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active,'expires_at',expires_at,'max_jobs',max_jobs,'claimed_jobs',claimed_jobs,'available',public.st_worker_valid(id) AND claimed_jobs<max_jobs) ORDER BY created_at DESC) FROM public.st_cloud_workers),'[]'::jsonb) ELSE '[]'::jsonb END,
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT j.id,j.project_id,j.task_id,j.state,j.stage,j.progress,j.file_name,j.byte_size,j.sha256,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests,j.source_expires_at,j.delivery_id,j.created_at,j.updated_at,p.title AS project_title FROM public.st_cloud_jobs j JOIN public.st_projects p ON p.id=j.project_id WHERE public.st_project_access(j.project_id) AND (p_project IS NULL OR j.project_id=p_project) ORDER BY j.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $$;

CREATE OR REPLACE FUNCTION public.st_cloud_prepare(p_worker uuid,p_stream_title text,p_timestamp text,p_filename text,p_mime text,p_size bigint,p_sha256 text,p_max_seconds integer DEFAULT 60,p_max_text integer DEFAULT 20,p_max_secondary integer DEFAULT 2) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p jsonb;j uuid;
BEGIN
 IF NOT public.st_owner() OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=p_worker AND public.st_worker_valid(id) AND claimed_jobs<max_jobs) THEN RAISE EXCEPTION '仅组长可派发已批准的云任务'; END IF;
 IF length(p_filename) NOT BETWEEN 1 AND 200 OR p_filename ~ '[/\\]' THEN RAISE EXCEPTION '文件名错误'; END IF;
 p:=public.st_create_named_codex_project(p_stream_title,p_timestamp,'云端 AI 初稿；需成员认领并人工听校。');
 INSERT INTO public.st_cloud_jobs(project_id,task_id,requested_by,worker_id,file_name,mime_type,byte_size,sha256,max_video_seconds,max_text_requests,max_secondary_requests)
 VALUES((p->>'project_id')::uuid,(p->>'task_id')::uuid,public.st_actor(),p_worker,p_filename,p_mime,p_size,p_sha256,p_max_seconds,p_max_text,p_max_secondary) RETURNING id INTO j;
 RETURN jsonb_build_object('job_id',j,'project_id',p->>'project_id','task_id',p->>'task_id','object_prefix',j::text,'chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $$;

CREATE OR REPLACE FUNCTION public.st_cloud_clip_create(p_source_url text,p_topic text,
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
  select id into assigned from public.st_cloud_workers where public.st_worker_valid(id) AND claimed_jobs<max_jobs and (p_worker is null or id=p_worker)
    order by created_at desc limit 1;
  if assigned is null then raise exception 'active_assigned_worker_required'; end if;
  pid:=public.st_clip_create_project(jid,'云端剪辑 · 等待识别');
  if pid is null then raise exception 'project_creation_not_confirmed'; end if;
  insert into public.st_cloud_clip_jobs(id,project_id,source_url,topic,authorization_scope,
    max_clip_seconds,max_text_requests,max_qwen_requests,worker_id)
  values(jid,pid,u,btrim(p_topic),'clip-'||jid::text,p_max_clip_seconds,p_max_text_requests,p_max_qwen_requests,assigned);
  return jsonb_build_object('state','queued','job_id',jid,'project_id',pid);
end $$;

CREATE OR REPLACE FUNCTION public.st_cloud_worker_call(p_key text,p_action text,p_job uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE w public.st_cloud_workers;j public.st_cloud_jobs;t public.st_tasks;p public.st_projects;f jsonb;b bytea;files jsonb;content text;d uuid;r uuid;v integer;parent uuid;total bigint:=0;names text[]:='{}';
BEGIN
 IF p_payload IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR pg_column_size(p_payload)>4100000 THEN RAISE EXCEPTION 'Invalid cloud payload'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('claim','heartbeat','stop','publish') THEN RAISE EXCEPTION '不支持的云端操作'; END IF;
 IF p_key IS NULL OR p_key !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '云执行身份无效'; END IF;
 SELECT * INTO w FROM public.st_cloud_workers WHERE public.st_worker_valid(id) AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
 IF w.id IS NULL THEN RAISE EXCEPTION '云执行身份无效或已撤销'; END IF;
 IF p_action='claim' THEN
  SELECT q.* INTO j FROM public.st_cloud_jobs q JOIN public.st_projects proj ON proj.id=q.project_id JOIN public.st_tasks taskrow ON taskrow.id=q.task_id
   WHERE q.worker_id=w.id AND q.state='queued' AND q.source_expires_at>now() AND proj.deleted_at IS NULL AND proj.state='active' AND taskrow.deleted_at IS NULL AND taskrow.state='open' AND (p_job IS NULL OR q.id=p_job) ORDER BY q.created_at FOR UPDATE OF q SKIP LOCKED LIMIT 1;
  IF j.id IS NULL THEN RETURN jsonb_build_object('state','no_job'); END IF;
  UPDATE public.st_cloud_jobs SET state='running',stage='云端已领取',lease_id=gen_random_uuid(),lease_until=now()+interval '45 minutes',updated_at=now() WHERE id=j.id RETURNING * INTO j;
  RETURN jsonb_build_object('job_id',j.id,'lease_id',j.lease_id,'state',j.state,'file_name',j.file_name,'mime_type',j.mime_type,'byte_size',j.byte_size,'sha256',j.sha256,'sources',j.sources,'source_expires_at',j.source_expires_at,'max_video_seconds',j.max_video_seconds,'max_text_requests',j.max_text_requests,'max_secondary_requests',j.max_secondary_requests);
 END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job AND worker_id=w.id FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION '无此云任务权限'; END IF;
 IF p_action='publish' AND j.state='succeeded' AND j.lease_id::text=p_payload->>'lease_id' THEN RETURN jsonb_build_object('state','succeeded','delivery_id',j.delivery_id); END IF;
 IF j.state<>'running' OR j.lease_until<=now() OR j.lease_id::text IS DISTINCT FROM p_payload->>'lease_id' THEN RAISE EXCEPTION '任务已停止或租约已失效'; END IF;
 SELECT * INTO p FROM public.st_projects WHERE id=j.project_id FOR UPDATE;
 SELECT * INTO t FROM public.st_tasks WHERE id=j.task_id FOR UPDATE;
 IF t.deleted_at IS NOT NULL OR p.deleted_at IS NOT NULL OR p.state<>'active' THEN RAISE EXCEPTION '项目或任务已关闭'; END IF;
 IF p_action='heartbeat' THEN
  IF length(coalesce(p_payload->>'stage',''))>120 OR pg_column_size(coalesce(p_payload->'progress','{}'::jsonb))>4096 THEN RAISE EXCEPTION '状态信息过大'; END IF;
  UPDATE public.st_cloud_jobs SET lease_until=now()+interval '45 minutes',stage=coalesce(p_payload->>'stage',stage),progress=coalesce(p_payload->'progress',progress),updated_at=now() WHERE id=j.id;
  RETURN jsonb_build_object('state','running','lease_seconds',2700);
 ELSIF p_action='stop' THEN
  IF p_payload->>'state' NOT IN ('waiting_configuration','waiting_reconciliation','failed') THEN RAISE EXCEPTION '停止状态错误'; END IF;
  UPDATE public.st_cloud_jobs SET state=p_payload->>'state',stage=left(coalesce(p_payload->>'stage','执行停止'),120),progress=coalesce(p_payload->'progress','{}'::jsonb),lease_until=NULL,updated_at=now() WHERE id=j.id;
  RETURN jsonb_build_object('state',p_payload->>'state');
 ELSIF p_action<>'publish' THEN RAISE EXCEPTION '不支持的云端操作'; END IF;
 IF t.state<>'open' OR EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND released_at IS NULL) THEN RAISE EXCEPTION '任务已被认领，请人工核对后发布'; END IF;
 files:=p_payload->'files';
 IF jsonb_typeof(files) IS DISTINCT FROM 'array' OR jsonb_array_length(files) NOT BETWEEN 8 AND 16 OR pg_column_size(files)>4000000 THEN RAISE EXCEPTION '交付文件包错误或过大'; END IF;
 FOR f IN SELECT value FROM jsonb_array_elements(files) LOOP
  IF coalesce(f->>'name','') !~ '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\.(ass|srt|json)$' OR f->>'name'=ANY(names) OR f->>'base64' IS NULL OR f->>'bytes' IS NULL OR f->>'sha256' IS NULL THEN RAISE EXCEPTION '交付文件名错误、重复或字段缺失'; END IF;
  names:=array_append(names,f->>'name');b:=decode(f->>'base64','base64');total:=total+octet_length(b);
  IF octet_length(b)>500000 OR total>2000000 OR f->>'sha256' IS DISTINCT FROM encode(sha256(b),'hex') OR (f->>'bytes')::integer<>octet_length(b) THEN RAISE EXCEPTION '交付文件校验失败'; END IF;
  IF f->>'name'='Bilingual.ass' THEN content:=convert_from(b,'UTF8'); END IF;
 END LOOP;
 IF NOT ARRAY['Chinese.ass','Bilingual.ass','Chinese.srt','Bilingual.srt','cues.json','quality.json','recognition-provenance.json','manifest.json','usage.json']<@names OR content IS NULL OR position('[Events]' in content)=0 THEN RAISE EXCEPTION '必要交付缺失'; END IF;
 INSERT INTO public.st_agent_runs(project_id,provider,external_run_id,initiated_by,model_label,summary)
 VALUES(j.project_id,'codex','cloud-job-'||j.id::text,j.requested_by,left(coalesce(p_payload->>'model','gpt-6-luna'),80),'云端自动交付 AI 初稿，需人工听校；不产生人工贡献或积分。') RETURNING id INTO r;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,agent_run_id,parent_id,content_text,content_sha256,notes)
 VALUES(t.id,t.project_id,v,'codex',j.requested_by,r,parent,content,encode(sha256(convert_to(content,'UTF8')),'hex'),'云端自动生成；完整 ASS/SRT、识别来源、质量与用量报告请从云任务交付下载。需要人工原音听校。') RETURNING id INTO d;
 UPDATE public.st_cloud_jobs SET state='succeeded',stage='AI 初稿已交付，等待人工认领听校',delivery_id=d,delivery_files=files,progress=coalesce(p_payload->'progress','{}'::jsonb),lease_until=NULL,updated_at=now() WHERE id=j.id;
 RETURN jsonb_build_object('state','succeeded','delivery_id',d,'human_review_required',true);
END; $$;

CREATE OR REPLACE FUNCTION public.st_clip_locked_job(p_key text,p_job uuid,p_lease uuid)
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
  PERFORM 1 FROM public.st_projects WHERE id=j.project_id AND deleted_at IS NULL AND state='active' FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'inactive_project' USING ERRCODE='42501'; END IF;
  PERFORM 1 FROM public.st_tasks WHERE project_id=j.project_id FOR SHARE;
  IF EXISTS(SELECT 1 FROM public.st_tasks WHERE project_id=j.project_id AND origin='codex' AND deleted_at IS NOT NULL)
  THEN RAISE EXCEPTION 'deleted_generation_task' USING ERRCODE='42501'; END IF;
  return j;
end $$;

CREATE OR REPLACE FUNCTION public.st_clip_storage_scope(p_job uuid,p_prefix text,p_name text) returns boolean
language plpgsql stable security definer set search_path=pg_catalog,public as $$
declare headers jsonb; w uuid;
begin
  begin headers:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  exception when others then return false; end;
  if headers->>'x-cloud-clip-object' is distinct from p_name or
     headers->>'x-cloud-clip-capability' is distinct from p_prefix then return false; end if;
  w:=public.st_clip_worker_identity(headers->>'x-cloud-clip-worker');
  return w is not null and exists(select 1 from public.st_cloud_clip_jobs where id=p_job and worker_id=w
    and EXISTS(SELECT 1 FROM public.st_projects WHERE id=project_id AND deleted_at IS NULL AND state='active') and state='running' and lease_expires_at>now() and authorization_expires_at>now());
end $$;


CREATE OR REPLACE FUNCTION public.st_audit_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r jsonb; before_state jsonb:='{}'; after_state jsonb:='{}'; field text;
BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 FOREACH field IN ARRAY ARRAY['state','role','role_code','deleted_at','deleted_by','lead_member_id','released_at','decision','points','worker_id','active','expires_at','claimed_jobs','max_jobs','lease_until','lease_expires_at','execution_deadline'] LOOP
  IF TG_OP<>'INSERT' AND to_jsonb(OLD) ? field THEN before_state:=before_state||jsonb_build_object(field,to_jsonb(OLD)->field); END IF;
  IF TG_OP<>'DELETE' AND to_jsonb(NEW) ? field THEN after_state:=after_state||jsonb_build_object(field,to_jsonb(NEW)->field); END IF;
 END LOOP;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,coalesce(r->>'id',r->>'member_id',r->>'version'),TG_OP,
 jsonb_strip_nulls(jsonb_build_object('project_id',r->>'project_id','task_id',r->>'task_id',
 'state',r->>'state','source',r->>'source','deleted_at',r->>'deleted_at','deleted_by',r->>'deleted_by','worker_id',r->>'worker_id','job_id',r->>'job_id',
 'before',before_state,'after',after_state)));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END; $$;
CREATE OR REPLACE FUNCTION public.st_cloud_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r jsonb; before_state jsonb:='{}'; after_state jsonb:='{}'; field text;
BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 FOREACH field IN ARRAY ARRAY['state','role','role_code','deleted_at','deleted_by','lead_member_id','released_at','decision','points','worker_id','active','expires_at','claimed_jobs','max_jobs','lease_until','lease_expires_at','execution_deadline'] LOOP
  IF TG_OP<>'INSERT' AND to_jsonb(OLD) ? field THEN before_state:=before_state||jsonb_build_object(field,to_jsonb(OLD)->field); END IF;
  IF TG_OP<>'DELETE' AND to_jsonb(NEW) ? field THEN after_state:=after_state||jsonb_build_object(field,to_jsonb(NEW)->field); END IF;
 END LOOP;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,coalesce(r->>'id',r->>'member_id',r->>'version'),TG_OP,
 jsonb_strip_nulls(jsonb_build_object('project_id',r->>'project_id','task_id',r->>'task_id',
 'state',r->>'state','source',r->>'source','deleted_at',r->>'deleted_at','deleted_by',r->>'deleted_by','worker_id',r->>'worker_id','job_id',r->>'job_id',
 'before',before_state,'after',after_state)));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END; $$;
-- Clip workflow did not previously have business audit triggers.
CREATE TRIGGER st_clip_audit AFTER INSERT OR UPDATE OR DELETE ON public.st_cloud_clip_jobs
 FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE TRIGGER st_clip_attempt_audit AFTER INSERT ON public.st_cloud_clip_attempts
 FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE TRIGGER st_clip_media_audit AFTER INSERT OR UPDATE ON public.st_cloud_clip_media
 FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE TRIGGER st_clip_package_immutable BEFORE UPDATE OR DELETE ON public.st_cloud_clip_packages
 FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation();
CREATE TRIGGER st_clip_attempt_immutable BEFORE UPDATE OR DELETE ON public.st_cloud_clip_attempts
 FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation();
-- Defend against inherited/default service-role grants on these newer tables.
REVOKE ALL ON public.st_cloud_clip_jobs,public.st_cloud_clip_attempts,public.st_cloud_clip_media,public.st_cloud_clip_packages FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.st_worker_valid(uuid),public.st_cloud_job_guard(),public.st_review_resource_guard() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.st_blocked_membership_guard(),public.st_security_members(uuid),public.st_set_member_state(uuid,text,text),public.st_set_project_block(uuid,uuid,boolean,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_security_members(uuid),public.st_set_member_state(uuid,text,text),public.st_set_project_block(uuid,uuid,boolean,text) TO authenticated;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'st_%' LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM service_role',f.signature);
 END LOOP;
END $$;
INSERT INTO public.st_schema_migrations(version) VALUES('032_security_boundaries');
COMMIT;
