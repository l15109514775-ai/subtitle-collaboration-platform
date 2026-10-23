BEGIN;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_call(p_key text,p_action text,p_job uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}'::jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
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
INSERT INTO public.st_schema_migrations(version) VALUES('023_cloud_usage_required');
COMMIT;
