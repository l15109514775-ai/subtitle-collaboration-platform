BEGIN;
-- A worker is a separate capability identity, never a business member or admin.
CREATE TABLE public.st_cloud_workers(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),label text NOT NULL CHECK(length(label) BETWEEN 1 AND 80),
 key_hash text UNIQUE NOT NULL,created_by uuid NOT NULL REFERENCES public.st_members(id),
 active boolean NOT NULL DEFAULT true,created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_cloud_jobs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),project_id uuid NOT NULL REFERENCES public.st_projects(id),
 task_id uuid NOT NULL REFERENCES public.st_tasks(id),requested_by uuid NOT NULL REFERENCES public.st_members(id),
 worker_id uuid NOT NULL REFERENCES public.st_cloud_workers(id),
 state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','queued','running','waiting_configuration','waiting_reconciliation','failed','cancelled','succeeded')),
 stage text NOT NULL DEFAULT '等待原视频',file_name text NOT NULL,byte_size bigint NOT NULL CHECK(byte_size BETWEEN 1 AND 1073741824),
 mime_type text NOT NULL CHECK(mime_type IN ('video/mp4','video/webm','video/quicktime','video/x-matroska')),
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),sources jsonb,
 source_expires_at timestamptz,max_video_seconds integer NOT NULL CHECK(max_video_seconds BETWEEN 1 AND 7200),
 max_text_requests integer NOT NULL CHECK(max_text_requests BETWEEN 1 AND 400),
 max_secondary_requests integer NOT NULL CHECK(max_secondary_requests BETWEEN 1 AND 100),
 lease_id uuid,lease_until timestamptz,progress jsonb NOT NULL DEFAULT '{}'::jsonb,
 delivery_id uuid REFERENCES public.st_deliveries(id),delivery_files jsonb,
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.st_cloud_workers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.st_cloud_jobs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_cloud_workers,public.st_cloud_jobs FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX st_cloud_queue ON public.st_cloud_jobs(worker_id,state,created_at);
-- Do not audit capability hashes, signed URLs, or private file bodies.
CREATE FUNCTION public.st_cloud_audit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,NEW.id::text,TG_OP,
 jsonb_build_object('state',to_jsonb(NEW)->>'state','worker_id',to_jsonb(NEW)->>'worker_id'));
 RETURN NEW;
END; $$;
CREATE TRIGGER st_cloud_audit AFTER INSERT OR UPDATE ON public.st_cloud_jobs FOR EACH ROW EXECUTE FUNCTION public.st_cloud_audit();
CREATE TRIGGER st_cloud_worker_audit AFTER INSERT OR UPDATE ON public.st_cloud_workers FOR EACH ROW EXECUTE FUNCTION public.st_cloud_audit();
CREATE FUNCTION public.st_cloud_worker_create(p_label text DEFAULT 'subtitle-cloud-worker') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE k text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');w uuid;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可创建云执行身份'; END IF;
 INSERT INTO public.st_cloud_workers(label,key_hash,created_by) VALUES(p_label,encode(sha256(convert_to(k,'UTF8')),'hex'),public.st_actor()) RETURNING id INTO w;
 RETURN jsonb_build_object('id',w,'key',k,'label',p_label);
END; $$;
CREATE FUNCTION public.st_cloud_worker_revoke(p_worker uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可撤销云执行身份'; END IF;
 UPDATE public.st_cloud_workers SET active=false WHERE id=p_worker;
END; $$;
CREATE FUNCTION public.st_cloud_prepare(p_worker uuid,p_stream_title text,p_timestamp text,p_filename text,p_mime text,p_size bigint,p_sha256 text,p_max_seconds integer DEFAULT 60,p_max_text integer DEFAULT 20,p_max_secondary integer DEFAULT 2) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p jsonb;j uuid;
BEGIN
 IF NOT public.st_owner() OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=p_worker AND active) THEN RAISE EXCEPTION '仅组长可派发已批准的云任务'; END IF;
 IF length(p_filename) NOT BETWEEN 1 AND 200 OR p_filename ~ '[/\\]' THEN RAISE EXCEPTION '文件名错误'; END IF;
 p:=public.st_create_named_codex_project(p_stream_title,p_timestamp,'云端 AI 初稿；需成员认领并人工听校。');
 INSERT INTO public.st_cloud_jobs(project_id,task_id,requested_by,worker_id,file_name,mime_type,byte_size,sha256,max_video_seconds,max_text_requests,max_secondary_requests)
 VALUES((p->>'project_id')::uuid,(p->>'task_id')::uuid,public.st_actor(),p_worker,p_filename,p_mime,p_size,p_sha256,p_max_seconds,p_max_text,p_max_secondary) RETURNING id INTO j;
 RETURN jsonb_build_object('job_id',j,'project_id',p->>'project_id','task_id',p->>'task_id','object_prefix',j::text,'chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $$;
CREATE FUNCTION public.st_cloud_source_write(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.requested_by=public.st_actor() AND public.st_owner() AND j.state='uploading'
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$$;
CREATE FUNCTION public.st_cloud_source_read(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE public.st_project_access(j.project_id)
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$$;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('subtitle-inputs','subtitle-inputs',false,4194304,ARRAY['video/mp4','video/webm','video/quicktime','video/x-matroska']);
CREATE POLICY st_cloud_input_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='subtitle-inputs' AND public.st_cloud_source_write(name));
CREATE POLICY st_cloud_input_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='subtitle-inputs' AND public.st_cloud_source_read(name));
CREATE FUNCTION public.st_cloud_source_ready(p_job uuid,p_sources jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j public.st_cloud_jobs;i integer;o storage.objects;src jsonb;path text;bytes bigint;
BEGIN
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job FOR UPDATE;
 IF NOT public.st_owner() OR j.requested_by IS DISTINCT FROM public.st_actor() OR j.state NOT IN ('uploading','queued','waiting_configuration') THEN RAISE EXCEPTION '此素材不可提交'; END IF;
 IF jsonb_typeof(p_sources) IS DISTINCT FROM 'array' OR jsonb_array_length(p_sources)<>(j.byte_size+4194303)/4194304 THEN RAISE EXCEPTION '素材分片不完整'; END IF;
 FOR i IN 0..jsonb_array_length(p_sources)-1 LOOP
  path:=j.id::text||'/part-'||lpad(i::text,4,'0');bytes:=least(4194304,j.byte_size-i::bigint*4194304);src:=p_sources->i;
  SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-inputs' AND name=path;
  IF o.id IS NULL OR o.created_at<j.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>bytes OR o.metadata->>'mimetype' IS DISTINCT FROM j.mime_type OR (o.owner_id IS DISTINCT FROM auth.uid() AND o.owner_id IS DISTINCT FROM '') THEN RAISE EXCEPTION '实际素材大小、类型或归属不符'; END IF;
  IF src->>'path' IS DISTINCT FROM path OR (src->>'byte_size')::bigint IS DISTINCT FROM bytes OR coalesce(src->>'url','') !~ '^https://example-env\.api\.tcloudbasegateway\.com/' OR strpos(replace(coalesce(src->>'url',''),'%2F','/'),'subtitle-inputs/'||path)=0 THEN RAISE EXCEPTION '素材地址错误'; END IF;
 END LOOP;
 UPDATE public.st_cloud_jobs SET sources=p_sources,source_expires_at=now()+interval '23 hours',state='queued',stage='等待云端领取',updated_at=now() WHERE id=j.id;
END; $$;
CREATE FUNCTION public.st_cloud_jobs_view(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录正式成员账号'; END IF;
 RETURN jsonb_build_object('workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active) ORDER BY created_at DESC) FROM public.st_cloud_workers),'[]'::jsonb) ELSE '[]'::jsonb END,
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT j.id,j.project_id,j.task_id,j.state,j.stage,j.progress,j.file_name,j.byte_size,j.sha256,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests,j.source_expires_at,j.delivery_id,j.created_at,j.updated_at,p.title AS project_title FROM public.st_cloud_jobs j JOIN public.st_projects p ON p.id=j.project_id WHERE public.st_project_access(j.project_id) AND (p_project IS NULL OR j.project_id=p_project) ORDER BY j.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_cloud_cancel(p_job uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可取消云任务'; END IF;
 UPDATE public.st_cloud_jobs SET state='cancelled',stage='已取消',lease_until=NULL,updated_at=now() WHERE id=p_job AND state<>'succeeded';
END; $$;
CREATE FUNCTION public.st_cloud_files(p_job uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j public.st_cloud_jobs;
BEGIN
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job;
 IF j.id IS NULL OR NOT public.st_project_access(j.project_id) THEN RAISE EXCEPTION '无此交付权限'; END IF;
 RETURN coalesce(j.delivery_files,'[]'::jsonb);
END; $$;
CREATE FUNCTION public.st_cloud_worker_call(p_key text,p_action text,p_job uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE w public.st_cloud_workers;j public.st_cloud_jobs;t public.st_tasks;p public.st_projects;f jsonb;b bytea;files jsonb;content text;d uuid;r uuid;v integer;parent uuid;total bigint:=0;names text[]:='{}';
BEGIN
 IF p_action IS NULL OR p_action NOT IN ('claim','heartbeat','stop','publish') THEN RAISE EXCEPTION '不支持的云端操作'; END IF;
 IF p_key IS NULL OR p_key !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '云执行身份无效'; END IF;
 SELECT * INTO w FROM public.st_cloud_workers WHERE active AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
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
 SELECT * INTO t FROM public.st_tasks WHERE id=j.task_id FOR UPDATE;
 SELECT * INTO p FROM public.st_projects WHERE id=j.project_id FOR UPDATE;
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
REVOKE ALL ON FUNCTION public.st_cloud_audit(),public.st_cloud_worker_create(text),public.st_cloud_worker_revoke(uuid),public.st_cloud_prepare(uuid,text,text,text,text,bigint,text,integer,integer,integer),public.st_cloud_source_write(text),public.st_cloud_source_read(text),public.st_cloud_source_ready(uuid,jsonb),public.st_cloud_jobs_view(uuid),public.st_cloud_cancel(uuid),public.st_cloud_files(uuid),public.st_cloud_worker_call(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_create(text),public.st_cloud_worker_revoke(uuid),public.st_cloud_prepare(uuid,text,text,text,text,bigint,text,integer,integer,integer),public.st_cloud_source_write(text),public.st_cloud_source_read(text),public.st_cloud_source_ready(uuid,jsonb),public.st_cloud_jobs_view(uuid),public.st_cloud_cancel(uuid),public.st_cloud_files(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) TO anon,authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('021_cloud_jobs');
COMMIT;
