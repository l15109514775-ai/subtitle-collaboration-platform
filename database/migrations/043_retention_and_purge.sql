-- REVIEW CANDIDATE. Disabled until the account-specific activation is approved.
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.st_purge_config(id integer PRIMARY KEY CHECK(id=1),owner_id uuid NOT NULL REFERENCES public.st_members(id),gateway_id uuid NOT NULL REFERENCES public.st_qq_gateways(id),enabled boolean NOT NULL DEFAULT false,activated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_source_retention(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),source_kind text NOT NULL CHECK(source_kind IN ('request','job')),source_id uuid NOT NULL,uploaded_at timestamptz NOT NULL,delete_after timestamptz NOT NULL,cleaned_at timestamptz,UNIQUE(source_kind,source_id),CHECK(delete_after>=uploaded_at+interval '7 days'));
CREATE TABLE public.st_purge_jobs(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),kind text NOT NULL CHECK(kind IN ('project','task','source')),target_id uuid NOT NULL,requested_by uuid REFERENCES public.st_members(id),state text NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','deleting','completed','blocked')),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),lease_hash text,lease_until timestamptz,completed_at timestamptz,UNIQUE(kind,target_id));
CREATE TABLE public.st_purge_objects(job_id uuid NOT NULL REFERENCES public.st_purge_jobs(id),object_id uuid NOT NULL,bucket_id text NOT NULL CHECK(bucket_id IN ('subtitle-inputs','subtitle-deliveries')),name text NOT NULL,created_at timestamptz NOT NULL,PRIMARY KEY(job_id,object_id));
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['st_purge_config','st_source_retention','st_purge_jobs','st_purge_objects'] LOOP
 EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
 EXECUTE format('REVOKE ALL ON public.%I FROM PUBLIC,anon,authenticated,service_role',t);
END LOOP;END; $$;
CREATE INDEX st_source_due ON public.st_source_retention(delete_after) WHERE cleaned_at IS NULL;
CREATE INDEX st_purge_pending ON public.st_purge_jobs(state,updated_at);

CREATE FUNCTION public.st_purge_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT public.st_owner() AND EXISTS(SELECT 1 FROM public.st_purge_config WHERE id=1 AND enabled AND owner_id=public.st_actor())
$$;
CREATE FUNCTION public.st_retention_record() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_OP='INSERT' OR (TG_TABLE_NAME='st_subtitle_requests' AND NEW.state='pending' AND OLD.state='uploading') OR (TG_TABLE_NAME='st_cloud_jobs' AND NEW.state='queued' AND OLD.state='uploading') THEN
  INSERT INTO public.st_source_retention(source_kind,source_id,uploaded_at,delete_after)
  VALUES(CASE TG_TABLE_NAME WHEN 'st_subtitle_requests' THEN 'request' ELSE 'job' END,NEW.id,clock_timestamp(),clock_timestamp()+interval '7 days')
  ON CONFLICT(source_kind,source_id) DO UPDATE SET uploaded_at=EXCLUDED.uploaded_at,delete_after=EXCLUDED.delete_after;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_retention_request AFTER INSERT OR UPDATE ON public.st_subtitle_requests FOR EACH ROW EXECUTE FUNCTION public.st_retention_record();
CREATE TRIGGER st_retention_cloud AFTER INSERT OR UPDATE ON public.st_cloud_jobs FOR EACH ROW EXECUTE FUNCTION public.st_retention_record();
-- Existing inputs get a conservative seven-day window from activation preparation.
INSERT INTO public.st_source_retention(source_kind,source_id,uploaded_at,delete_after)
 SELECT 'request',id,now(),now()+interval '7 days' FROM public.st_subtitle_requests;
INSERT INTO public.st_source_retention(source_kind,source_id,uploaded_at,delete_after)
 SELECT 'job',id,now(),now()+interval '7 days' FROM public.st_cloud_jobs;

CREATE FUNCTION public.st_purge_matches(p_kind text,p_target uuid,p_project uuid,p_task uuid) RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT CASE p_kind WHEN 'project' THEN p_project=p_target WHEN 'task' THEN p_task=p_target ELSE false END
$$;
CREATE FUNCTION public.st_purge_inventory(p_kind text,p_target uuid)
RETURNS TABLE(object_id uuid,bucket_id text,name text,created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT DISTINCT o.id,o.bucket_id,o.name,o.created_at FROM storage.objects o WHERE
 (o.bucket_id='subtitle-inputs' AND EXISTS(
  SELECT 1 FROM public.st_source_retention s WHERE
   ((p_kind='source' AND s.id=p_target) OR
    (s.source_kind='job' AND EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.id=s.source_id AND public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id))) OR
    (s.source_kind='request' AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r JOIN public.st_cloud_jobs j ON j.id=r.job_id WHERE r.id=s.source_id AND public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id))))
   AND o.name ~ ('^'||CASE s.source_kind WHEN 'request' THEN 'requests/' ELSE '' END||s.source_id::text||'/part-[0-9]{4}$')))
 OR (p_kind<>'source' AND o.bucket_id='subtitle-deliveries' AND (
  EXISTS(SELECT 1 FROM public.st_uploads u WHERE public.st_purge_matches(p_kind,p_target,u.project_id,u.task_id)
   AND (o.name=u.object_path OR (u.chunk_size IS NOT NULL AND left(o.name,length(u.object_path)+1)=u.object_path||'/' AND substr(o.name,length(u.object_path)+2) ~ '^part-[0-9]{4}$')))
  OR EXISTS(SELECT 1 FROM public.st_artifacts a WHERE a.project_id=CASE WHEN p_kind='project' THEN p_target ELSE a.project_id END
   AND (p_kind='project' OR EXISTS(SELECT 1 FROM public.st_deliveries d WHERE d.artifact_id=a.id AND d.task_id=p_target))
   AND (o.name=a.object_path OR EXISTS(SELECT 1 FROM jsonb_array_elements(coalesce(a.parts,'[]'::jsonb)) part WHERE part->>'path'=o.name)))))
$$;
CREATE FUNCTION public.st_purge_busy(p_kind text,p_target uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE
 (public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id) OR
  (p_kind='source' AND EXISTS(SELECT 1 FROM public.st_source_retention s WHERE s.id=p_target AND
   ((s.source_kind='job' AND s.source_id=j.id) OR (s.source_kind='request' AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.id=s.source_id AND r.job_id=j.id))))))
 AND (j.state IN ('running','waiting_reconciliation') OR (j.lease_until IS NOT NULL AND j.lease_until>now())))
$$;
CREATE FUNCTION public.st_purge_lock(p_kind text,p_target uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid;
BEGIN
 FOR p IN SELECT DISTINCT j.project_id FROM public.st_cloud_jobs j WHERE
  public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id) OR
  (p_kind='source' AND EXISTS(SELECT 1 FROM public.st_source_retention s WHERE s.id=p_target AND ((s.source_kind='job' AND s.source_id=j.id) OR (s.source_kind='request' AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.id=s.source_id AND r.job_id=j.id)))))
 UNION SELECT p_target WHERE p_kind='project'
 UNION SELECT project_id FROM public.st_tasks WHERE p_kind='task' AND id=p_target ORDER BY 1 LOOP
  PERFORM pg_advisory_xact_lock(hashtextextended(p::text,43));
 END LOOP;
END; $$;
CREATE FUNCTION public.st_purge_not_before(p_kind text,p_target uuid) RETURNS timestamptz LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT greatest(
  (SELECT max(s.delete_after) FROM public.st_source_retention s WHERE
    (p_kind='source' AND s.id=p_target) OR
    (s.source_kind='job' AND EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.id=s.source_id AND public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id))) OR
    (s.source_kind='request' AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r JOIN public.st_cloud_jobs j ON j.id=r.job_id WHERE r.id=s.source_id AND public.st_purge_matches(p_kind,p_target,j.project_id,j.task_id)))),
  (SELECT max(i.created_at+interval '7 days') FROM public.st_purge_inventory(p_kind,p_target) i JOIN storage.objects o ON o.id=i.object_id WHERE i.bucket_id='subtitle-inputs' OR coalesce(o.metadata->>'mimetype','') LIKE 'video/%'))
$$;
CREATE FUNCTION public.st_purge_preview(p_kind text,p_target uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE title text; deleted timestamptz; eligible timestamptz; count_files bigint; bytes numeric; job public.st_purge_jobs;
BEGIN
 IF NOT public.st_purge_owner() THEN RAISE EXCEPTION '仅指定组长账号可永久删除' USING ERRCODE='42501'; END IF;
 IF p_kind='project' THEN SELECT p.title,p.deleted_at INTO title,deleted FROM public.st_projects p WHERE id=p_target;
 ELSIF p_kind='task' THEN SELECT t.title,t.deleted_at INTO title,deleted FROM public.st_tasks t WHERE id=p_target;
 ELSE RAISE EXCEPTION 'Unsupported purge target'; END IF;
 IF title IS NULL OR deleted IS NULL THEN RAISE EXCEPTION '请先将目标移入回收站'; END IF;
 eligible:=public.st_purge_not_before(p_kind,p_target);
 SELECT count(*),coalesce(sum(coalesce((o.metadata->>'size')::bigint,0)),0) INTO count_files,bytes FROM public.st_purge_inventory(p_kind,p_target) i JOIN storage.objects o ON o.id=i.object_id;
 SELECT * INTO job FROM public.st_purge_jobs WHERE kind=p_kind AND target_id=p_target;
 RETURN jsonb_build_object('kind',p_kind,'id',p_target,'title',title,'files',count_files,'bytes',bytes,'not_before',eligible,'busy',public.st_purge_busy(p_kind,p_target),'state',job.state,'job_id',job.id,
  'notice','永久清除文件与交付正文，保留最小审计、贡献与积分凭据；完成后不可恢复。');
END; $$;
CREATE FUNCTION public.st_purge_begin(p_kind text,p_target uuid,p_confirmation text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE v jsonb;j uuid;
BEGIN
 IF NOT public.st_purge_owner() THEN RAISE EXCEPTION '仅指定组长账号可永久删除' USING ERRCODE='42501'; END IF;
 PERFORM public.st_purge_lock(p_kind,p_target);
 IF p_kind='project' THEN PERFORM 1 FROM public.st_projects WHERE id=p_target FOR UPDATE;
 ELSIF p_kind='task' THEN PERFORM 1 FROM public.st_tasks WHERE id=p_target FOR UPDATE; END IF;
 v:=public.st_purge_preview(p_kind,p_target);
 IF p_confirmation IS DISTINCT FROM '永久删除 '||(v->>'title') THEN RAISE EXCEPTION '请完整输入“永久删除 项目或任务名称”'; END IF;
 IF (v->>'busy')::boolean OR (v->>'not_before')::timestamptz>now() THEN RAISE EXCEPTION '视频仍在七天保留期内，或云任务尚未停止'; END IF;
 SELECT id INTO j FROM public.st_purge_jobs WHERE kind=p_kind AND target_id=p_target;
 IF j IS NOT NULL THEN
  IF EXISTS(SELECT 1 FROM public.st_purge_jobs WHERE id=j AND state='blocked') THEN
   UPDATE public.st_purge_jobs SET state='queued',updated_at=clock_timestamp(),lease_hash=NULL,lease_until=NULL WHERE id=j;
   INSERT INTO public.st_purge_objects SELECT j,* FROM public.st_purge_inventory(p_kind,p_target) ON CONFLICT DO NOTHING;
   INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata) VALUES(auth.uid(),session_user,'st_purge_jobs',j::text,'UPDATE',jsonb_build_object('action','owner_reconfirmed_blocked_purge','files',v->'files'));
  END IF;
  RETURN j;
 END IF;
 INSERT INTO public.st_purge_jobs(kind,target_id,requested_by) VALUES(p_kind,p_target,public.st_actor()) RETURNING id INTO j;
 INSERT INTO public.st_purge_objects SELECT j,* FROM public.st_purge_inventory(p_kind,p_target);
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,'st_purge_jobs',j::text,'INSERT',jsonb_build_object('kind',p_kind,'target_id',p_target,'files',v->'files'));
 RETURN j;
END; $$;

-- A purge lock must also stop restore and cloud-claim races.
CREATE FUNCTION public.st_purge_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='st_cloud_jobs' THEN
  IF NEW.state IN ('running','queued') AND OLD.state IS DISTINCT FROM NEW.state THEN PERFORM pg_advisory_xact_lock(hashtextextended(NEW.project_id::text,43)); END IF;
  IF NEW.state IN ('running','queued') AND OLD.state IS DISTINCT FROM NEW.state AND (
   EXISTS(SELECT 1 FROM public.st_purge_jobs q WHERE q.kind<>'source' AND q.state IN ('queued','deleting','completed') AND public.st_purge_matches(q.kind,q.target_id,NEW.project_id,NEW.task_id)) OR
   EXISTS(SELECT 1 FROM public.st_source_retention s WHERE s.delete_after<=now() AND ((s.source_kind='job' AND s.source_id=NEW.id) OR (s.source_kind='request' AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.id=s.source_id AND r.job_id=NEW.id)))))
  THEN RAISE EXCEPTION '原视频已到期或目标正在永久删除，不得重新启动'; END IF;
 ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL AND EXISTS(SELECT 1 FROM public.st_purge_jobs q WHERE q.kind=CASE TG_TABLE_NAME WHEN 'st_projects' THEN 'project' ELSE 'task' END AND q.target_id=NEW.id AND q.state IN ('queued','deleting','completed','blocked')) THEN
  RAISE EXCEPTION '目标已进入永久删除流程，不可恢复';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_purge_restore_project BEFORE UPDATE ON public.st_projects FOR EACH ROW EXECUTE FUNCTION public.st_purge_guard();
CREATE TRIGGER st_purge_restore_task BEFORE UPDATE ON public.st_tasks FOR EACH ROW EXECUTE FUNCTION public.st_purge_guard();
CREATE TRIGGER st_purge_claim_guard BEFORE UPDATE ON public.st_cloud_jobs FOR EACH ROW EXECUTE FUNCTION public.st_purge_guard();

-- Permit only narrowly defined content redaction inside the private finalizer.
-- All contribution, point, event and schema records remain immutable.
CREATE OR REPLACE FUNCTION public.st_reject_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE j public.st_purge_jobs; oldj jsonb:=to_jsonb(OLD);newj jsonb;
BEGIN
 IF TG_OP='UPDATE' AND TG_TABLE_NAME IN ('st_deliveries','st_reviews','st_agent_runs') THEN
  SELECT * INTO j FROM public.st_purge_jobs WHERE id=nullif(current_setting('subtitle.purge_job',true),'')::uuid AND state='deleting';
  IF j.id IS NOT NULL AND public.st_purge_matches(j.kind,j.target_id,(oldj->>'project_id')::uuid,(oldj->>'task_id')::uuid) THEN
   newj:=to_jsonb(NEW);
   IF TG_TABLE_NAME='st_deliveries' AND (newj-ARRAY['content_text','notes'])=(oldj-ARRAY['content_text','notes']) AND newj->>'content_text'='' AND newj->>'notes'='' THEN RETURN NEW;
   ELSIF TG_TABLE_NAME='st_reviews' AND (newj-'feedback')=(oldj-'feedback') AND newj->>'feedback'='' THEN RETURN NEW;
   ELSIF TG_TABLE_NAME='st_agent_runs' AND (newj-'summary')=(oldj-'summary') AND newj->>'summary'='' THEN RETURN NEW; END IF;
  END IF;
 END IF;
 RAISE EXCEPTION 'Immutable record: create a new version, revocation or reversal instead';
END; $$;

CREATE FUNCTION public.st_purge_finish(p_job uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j public.st_purge_jobs;
BEGIN
 SELECT * INTO j FROM public.st_purge_jobs WHERE id=p_job FOR UPDATE;
 IF j.state<>'deleting' OR public.st_purge_busy(j.kind,j.target_id) THEN RAISE EXCEPTION 'Purge not ready'; END IF;
 IF EXISTS(SELECT 1 FROM public.st_purge_inventory(j.kind,j.target_id)) THEN RAISE EXCEPTION 'Storage objects still remain'; END IF;
 IF j.kind='source' THEN
  UPDATE public.st_source_retention SET cleaned_at=clock_timestamp() WHERE id=j.target_id;
 ELSE
  PERFORM set_config('subtitle.purge_job',j.id::text,true);
  UPDATE public.st_deliveries SET content_text='',notes='' WHERE public.st_purge_matches(j.kind,j.target_id,project_id,task_id);
  UPDATE public.st_reviews SET feedback='' WHERE public.st_purge_matches(j.kind,j.target_id,project_id,task_id);
  IF j.kind='project' THEN
   UPDATE public.st_agent_runs SET summary='' WHERE project_id=j.target_id;
   UPDATE public.st_projects SET title=CASE WHEN origin='codex' THEN '已永久删除项目｜已删除｜AI字幕初稿' ELSE '已永久删除项目' END,description='',state='archived' WHERE id=j.target_id;
  END IF;
  UPDATE public.st_tasks SET title='已永久删除任务',description='',state='archived' WHERE public.st_purge_matches(j.kind,j.target_id,project_id,id);
  UPDATE public.st_cloud_jobs SET sources=NULL,delivery_files=NULL,progress='{}'::jsonb,source_expires_at=NULL WHERE public.st_purge_matches(j.kind,j.target_id,project_id,task_id);
  UPDATE public.st_subtitle_requests r SET stream_title='已永久删除项目素材',timestamp_label='已删除',notes='',review_note='' FROM public.st_cloud_jobs c WHERE c.id=r.job_id AND public.st_purge_matches(j.kind,j.target_id,c.project_id,c.task_id);
 END IF;
 UPDATE public.st_purge_jobs SET state='completed',completed_at=clock_timestamp(),updated_at=clock_timestamp(),lease_hash=NULL,lease_until=NULL WHERE id=j.id;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata) VALUES(NULL,session_user,'st_purge_jobs',j.id::text,'UPDATE',jsonb_build_object('kind',j.kind,'target_id',j.target_id,'result','completed','requested_by',j.requested_by));
END; $$;

CREATE FUNCTION public.st_purge_object_access(p_object uuid,p_bucket text,p_name text,p_created timestamptz) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_purge_objects o JOIN public.st_purge_jobs j ON j.id=o.job_id
 JOIN public.st_purge_config c ON c.id=1 AND c.enabled
 JOIN public.st_qq_gateways g ON g.id=c.gateway_id AND g.active
 JOIN public.st_qq_notification_settings s ON s.gateway_id=g.id AND s.enabled AND s.owner_id=c.owner_id
 JOIN public.st_members m ON m.id=c.owner_id AND m.state='active'
 WHERE o.object_id=p_object AND o.bucket_id=p_bucket AND o.name=p_name AND o.created_at=p_created
 AND j.state='deleting' AND j.lease_until>now() AND NOT public.st_purge_busy(j.kind,j.target_id)
 AND coalesce(public.st_purge_not_before(j.kind,j.target_id),'-infinity'::timestamptz)<=now()
 AND EXISTS(SELECT 1 FROM public.st_member_roles r WHERE r.member_id=m.id AND r.role_code='owner')
 AND EXISTS(SELECT 1 FROM public.st_qq_links l WHERE l.gateway_id=g.id AND l.member_id=m.id)
 AND j.lease_hash=encode(sha256(convert_to(coalesce(nullif(current_setting('request.headers',true),'')::jsonb->>'x-subtitle-purge',''),'UTF8')),'hex'))
$$;
CREATE POLICY st_purge_exact_delete ON storage.objects FOR DELETE TO anon,authenticated USING(public.st_purge_object_access(id,bucket_id,name,created_at));
CREATE POLICY st_purge_exact_read ON storage.objects FOR SELECT TO anon,authenticated USING(public.st_purge_object_access(id,bucket_id,name,created_at));

CREATE FUNCTION public.st_purge_worker(p_key text,p_sender text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid;c public.st_purge_config;s public.st_source_retention;j public.st_purge_jobs;k text;remaining jsonb;
BEGIN
 g:=public.st_qq_notification_access(p_key,p_sender);
 SELECT * INTO c FROM public.st_purge_config WHERE id=1 AND enabled AND gateway_id=g;
 IF c.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.st_qq_notification_settings WHERE gateway_id=g AND owner_id=c.owner_id) THEN RAISE EXCEPTION 'Cleanup worker denied' USING ERRCODE='42501'; END IF;
 -- Bound jobs are locked by the SQL guard when claiming a source after expiry.
 FOR s IN SELECT * FROM public.st_source_retention WHERE cleaned_at IS NULL AND delete_after<=now() ORDER BY delete_after,id LIMIT 20 LOOP
  PERFORM public.st_purge_lock('source',s.id);
  IF NOT public.st_purge_busy('source',s.id) AND coalesce(public.st_purge_not_before('source',s.id),'-infinity'::timestamptz)<=now() THEN
   INSERT INTO public.st_purge_jobs(kind,target_id) VALUES('source',s.id) ON CONFLICT(kind,target_id) DO UPDATE SET state='queued',updated_at=clock_timestamp() WHERE st_purge_jobs.state='blocked';
  END IF;
 END LOOP;
 SELECT * INTO j FROM public.st_purge_jobs WHERE state IN ('queued','deleting') ORDER BY updated_at,id LIMIT 1 FOR UPDATE SKIP LOCKED;
 IF j.id IS NULL THEN RETURN jsonb_build_object('idle',true); END IF;
 PERFORM public.st_purge_lock(j.kind,j.target_id);
 IF public.st_purge_busy(j.kind,j.target_id) OR coalesce(public.st_purge_not_before(j.kind,j.target_id),'-infinity'::timestamptz)>now() THEN
  UPDATE public.st_purge_jobs SET updated_at=clock_timestamp() WHERE id=j.id;RETURN jsonb_build_object('idle',true,'deferred',true);
 END IF;
 IF j.kind='source' AND j.state='queued' THEN
  INSERT INTO public.st_purge_objects SELECT j.id,* FROM public.st_purge_inventory(j.kind,j.target_id) ON CONFLICT DO NOTHING;
 END IF;
 -- Existing manifest entries are exact object identities, never wildcard prefixes.
 IF EXISTS(SELECT 1 FROM public.st_purge_inventory(j.kind,j.target_id) i WHERE NOT EXISTS(SELECT 1 FROM public.st_purge_objects o WHERE o.job_id=j.id AND o.object_id=i.object_id AND o.name=i.name AND o.created_at=i.created_at)) THEN
  UPDATE public.st_purge_jobs SET state='blocked',updated_at=clock_timestamp() WHERE id=j.id;
  RETURN jsonb_build_object('idle',true,'blocked',true);
 END IF;
 UPDATE public.st_purge_jobs SET state='deleting',updated_at=clock_timestamp() WHERE id=j.id;
 SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) INTO remaining FROM (
  SELECT o.object_id,o.bucket_id,o.name FROM public.st_purge_objects o JOIN storage.objects f ON f.id=o.object_id AND f.bucket_id=o.bucket_id AND f.name=o.name AND f.created_at=o.created_at WHERE o.job_id=j.id ORDER BY o.bucket_id,o.name LIMIT 20) x;
 IF jsonb_array_length(remaining)=0 THEN PERFORM public.st_purge_finish(j.id);RETURN jsonb_build_object('idle',false,'completed',true,'job_id',j.id); END IF;
 k:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 UPDATE public.st_purge_jobs SET lease_hash=encode(sha256(convert_to(k,'UTF8')),'hex'),lease_until=now()+interval '10 minutes' WHERE id=j.id;
 RETURN jsonb_build_object('idle',false,'job_id',j.id,'capability',k,'objects',remaining);
END; $$;

CREATE FUNCTION public.st_purge_console() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_purge_owner() THEN RETURN jsonb_build_object('allowed',false); END IF;
 RETURN jsonb_build_object('allowed',true,'jobs',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'kind',kind,'target_id',target_id,'state',state,'completed_at',completed_at) ORDER BY created_at DESC) FROM (SELECT * FROM public.st_purge_jobs ORDER BY created_at DESC,id LIMIT 200) latest),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_source_retention_status(p_requests uuid[]) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() OR cardinality(p_requests)>100 THEN RAISE EXCEPTION 'Retention status denied' USING ERRCODE='42501'; END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.id,'delete_after',s.delete_after,'cleaned_at',s.cleaned_at)) FROM public.st_subtitle_requests r JOIN public.st_source_retention s ON s.source_kind='request' AND s.source_id=r.id WHERE r.id=ANY(p_requests) AND (r.requested_by=public.st_actor() OR public.st_owner())),'[]'::jsonb);
END; $$;
CREATE FUNCTION public.st_retention_approval_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.state='approved' AND OLD.state IS DISTINCT FROM 'approved' AND EXISTS(SELECT 1 FROM public.st_source_retention s WHERE s.source_kind='request' AND s.source_id=NEW.id AND (s.delete_after<=now() OR s.cleaned_at IS NOT NULL)) THEN
  RAISE EXCEPTION '原视频已到七天保留期，请重新上传后申请';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_retention_approval_guard BEFORE UPDATE ON public.st_subtitle_requests FOR EACH ROW EXECUTE FUNCTION public.st_retention_approval_guard();
-- Remove completed tombstones from the normal recycle bin; audit/points remain intact.
CREATE OR REPLACE FUNCTION public.st_deleted_items(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录有效成员账号'; END IF;
 RETURN jsonb_build_object('projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY deleted_at DESC) FROM public.st_projects p WHERE p.deleted_at IS NOT NULL AND public.st_project_manage(p.id) AND NOT EXISTS(SELECT 1 FROM public.st_purge_jobs q WHERE q.kind='project' AND q.target_id=p.id AND q.state='completed')),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY deleted_at DESC) FROM public.st_tasks t WHERE t.project_id=p_project AND t.deleted_at IS NOT NULL AND public.st_project_manage(t.project_id) AND public.st_project_access(t.project_id) AND NOT EXISTS(SELECT 1 FROM public.st_purge_jobs q WHERE q.kind='task' AND q.target_id=t.id AND q.state='completed')),'[]'::jsonb));
END; $$;
DO $$ DECLARE f record; BEGIN FOR f IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND (p.proname LIKE 'st_purge_%' OR p.proname IN ('st_retention_record','st_retention_approval_guard','st_source_retention_status')) LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f.signature);
END LOOP;END; $$;
GRANT EXECUTE ON FUNCTION public.st_purge_owner(),public.st_purge_preview(text,uuid),public.st_purge_begin(text,uuid,text),public.st_purge_console() TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_source_retention_status(uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_purge_object_access(uuid,text,text,timestamptz) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.st_purge_worker(text,text) TO anon;
INSERT INTO public.st_schema_migrations(version) VALUES('043_retention_and_purge');
COMMIT;
