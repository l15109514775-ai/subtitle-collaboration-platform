-- REVIEW CANDIDATE: no paid calls, credentials, or notification agent enabled.
BEGIN;
CREATE TABLE public.st_subtitle_requests(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),requested_by uuid NOT NULL REFERENCES public.st_members(id),
 stream_title text NOT NULL CHECK(length(stream_title) BETWEEN 1 AND 125),
 timestamp_label text NOT NULL CHECK(length(timestamp_label) BETWEEN 1 AND 40),
 notes text NOT NULL DEFAULT '' CHECK(length(notes)<=1000),
 file_name text NOT NULL CHECK(length(file_name) BETWEEN 1 AND 200),
 mime_type text NOT NULL CHECK(mime_type IN ('video/mp4','video/webm','video/quicktime','video/x-matroska')),
 byte_size bigint NOT NULL CHECK(byte_size BETWEEN 1 AND 1073741824),sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),
 declared_seconds integer NOT NULL CHECK(declared_seconds BETWEEN 1 AND 1200),
 state text NOT NULL DEFAULT 'uploading' CHECK(state IN ('uploading','pending','approved','rejected','withdrawn')),
 reviewed_by uuid REFERENCES public.st_members(id),reviewed_at timestamptz,review_note text CHECK(length(review_note)<=300),
 job_id uuid UNIQUE REFERENCES public.st_cloud_jobs(id),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 upload_until timestamptz NOT NULL DEFAULT (now()+interval '24 hours'),
 CHECK((state='approved')=(job_id IS NOT NULL)),
 CHECK(length(stream_title||'｜'||timestamp_label||'｜AI字幕初稿')<=160));
ALTER TABLE public.st_subtitle_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_subtitle_requests FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX st_subtitle_requests_member ON public.st_subtitle_requests(requested_by,created_at DESC);
CREATE TABLE public.st_subtitle_notifications(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL REFERENCES public.st_subtitle_requests(id),
 event text NOT NULL CHECK(event IN ('submitted','approved','rejected','withdrawn','source_refreshed')),
 created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.st_subtitle_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_subtitle_notifications FROM PUBLIC,anon,authenticated,service_role;
CREATE UNIQUE INDEX st_subtitle_notification_once ON public.st_subtitle_notifications(request_id,event) WHERE event<>'source_refreshed';
CREATE TRIGGER st_subtitle_request_audit AFTER INSERT OR UPDATE ON public.st_subtitle_requests FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE TRIGGER st_subtitle_notification_audit AFTER INSERT ON public.st_subtitle_notifications FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE TRIGGER st_subtitle_notification_immutable BEFORE UPDATE OR DELETE ON public.st_subtitle_notifications FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation();

CREATE FUNCTION public.st_subtitle_request_prepare(p_title text,p_timestamp text,p_notes text,p_filename text,p_mime text,p_size bigint,p_sha256 text,p_seconds integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor();rid uuid;
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可登记字幕申请' USING ERRCODE='42501'; END IF;
 -- Serialize admission checks for one member; a double click cannot bypass the cap.
 PERFORM 1 FROM public.st_members WHERE id=a FOR UPDATE;
 IF (SELECT count(*) FROM public.st_subtitle_requests WHERE requested_by=a AND (state='pending' OR (state='uploading' AND upload_until>now())))>=3
 THEN RAISE EXCEPTION '最多保留3项待处理申请，请先撤回或等待审批'; END IF;
 IF p_filename IS NULL OR p_filename ~ '[/\\]' OR p_filename !~* '\.(mp4|mkv|mov|webm)$'
 OR p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 125
 OR p_timestamp IS NULL OR length(btrim(p_timestamp)) NOT BETWEEN 1 AND 40 OR strpos(p_timestamp,'｜')>0
 OR p_seconds IS NULL OR p_seconds NOT BETWEEN 1 AND 1200 OR p_notes IS NULL
 THEN RAISE EXCEPTION '请检查视频格式、标题、时间戳和20分钟上限'; END IF;
 INSERT INTO public.st_subtitle_requests(requested_by,stream_title,timestamp_label,notes,file_name,mime_type,byte_size,sha256,declared_seconds)
 VALUES(a,btrim(p_title),btrim(p_timestamp),p_notes,p_filename,p_mime,p_size,p_sha256,p_seconds) RETURNING id INTO rid;
 RETURN jsonb_build_object('request_id',rid,'object_prefix','requests/'||rid::text,'chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $$;

-- Preserve original cloud-job storage rules while adding isolated intake paths.
CREATE OR REPLACE FUNCTION public.st_cloud_source_write(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.requested_by=public.st_actor() AND public.st_owner() AND j.state='uploading'
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
 OR (public.st_formal_member() AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.requested_by=public.st_actor() AND r.state='uploading' AND r.upload_until>now()
 AND EXISTS(SELECT 1 FROM generate_series(0,((r.byte_size-1)/4194304)::integer) n WHERE p_path='requests/'||r.id::text||'/part-'||lpad(n::text,4,'0'))));
$$;
CREATE OR REPLACE FUNCTION public.st_cloud_source_read(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE public.st_project_access(j.project_id)
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
 OR (public.st_formal_member() AND EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.state IN ('uploading','pending','approved')
 AND (public.st_owner() OR (r.requested_by=public.st_actor() AND (r.job_id IS NULL OR EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.id=r.job_id AND public.st_project_access(j.project_id)))))
 AND EXISTS(SELECT 1 FROM generate_series(0,((r.byte_size-1)/4194304)::integer) n WHERE p_path='requests/'||r.id::text||'/part-'||lpad(n::text,4,'0'))));
$$;

-- Private validator; callers hold the request row lock. Never logs signed URLs.
CREATE FUNCTION public.st_subtitle_source_check(p_request uuid,p_sources jsonb DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;o storage.objects;src jsonb;path text;part_bytes bigint;i integer;subject text;
BEGIN
 SELECT * INTO STRICT r FROM public.st_subtitle_requests WHERE id=p_request;
 SELECT auth_subject INTO subject FROM public.st_members WHERE id=r.requested_by AND state='active';
 IF subject IS NULL THEN RAISE EXCEPTION '提交成员已停用'; END IF;
 IF p_sources IS NOT NULL AND (jsonb_typeof(p_sources) IS DISTINCT FROM 'array' OR jsonb_array_length(p_sources)<>(r.byte_size+4194303)/4194304 OR pg_column_size(p_sources)>524288)
 THEN RAISE EXCEPTION '素材分片不完整或过大'; END IF;
 FOR i IN 0..((r.byte_size-1)/4194304)::integer LOOP
  path:='requests/'||r.id::text||'/part-'||lpad(i::text,4,'0');part_bytes:=least(4194304,r.byte_size-i::bigint*4194304);
  SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-inputs' AND name=path;
  IF o.id IS NULL OR o.created_at<r.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>part_bytes
  OR o.metadata->>'mimetype' IS DISTINCT FROM r.mime_type OR (o.owner_id IS DISTINCT FROM subject AND o.owner_id IS DISTINCT FROM '')
  THEN RAISE EXCEPTION '实际素材大小、类型或归属不符'; END IF;
  IF p_sources IS NOT NULL THEN
   src:=p_sources->i;
   IF src->>'path' IS DISTINCT FROM path OR (src->>'byte_size')::bigint IS DISTINCT FROM part_bytes
   OR coalesce(src->>'url','') !~ ('^https://example-env[.]api[.]tcloudbasegateway[.]com/v1/storages/object/(sign/)?subtitle-inputs/'||path||'[?][^[:space:]]+$')
   THEN RAISE EXCEPTION '素材授权地址不匹配'; END IF;
  END IF;
 END LOOP;
END; $$;

CREATE FUNCTION public.st_subtitle_request_submit(p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;
BEGIN
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF NOT public.st_formal_member() OR r.requested_by IS DISTINCT FROM public.st_actor() THEN RAISE EXCEPTION '无此申请权限' USING ERRCODE='42501'; END IF;
 IF r.state='pending' THEN RETURN jsonb_build_object('state','pending','request_id',r.id); END IF;
 IF r.state<>'uploading' OR r.upload_until<=now() THEN RAISE EXCEPTION '申请已关闭或上传已过期'; END IF;
 PERFORM public.st_subtitle_source_check(r.id);
 UPDATE public.st_subtitle_requests SET state='pending',updated_at=now() WHERE id=r.id;
 INSERT INTO public.st_subtitle_notifications(request_id,event) VALUES(r.id,'submitted');
 RETURN jsonb_build_object('state','pending','request_id',r.id);
END; $$;

CREATE FUNCTION public.st_subtitle_request_decide(p_request uuid,p_decision text,p_worker uuid DEFAULT NULL,p_max_seconds integer DEFAULT 1200,p_max_text integer DEFAULT 400,p_max_secondary integer DEFAULT 40,p_note text DEFAULT '',p_sources jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;p jsonb;j uuid;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可批准额度或驳回申请' USING ERRCODE='42501'; END IF;
 IF p_decision IS NULL OR p_decision NOT IN ('approved','rejected') OR p_note IS NULL OR length(btrim(p_note))>300 THEN RAISE EXCEPTION '审批参数无效'; END IF;
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF r.id IS NULL THEN RAISE EXCEPTION '申请不存在'; END IF;
 IF r.state=p_decision THEN RETURN jsonb_build_object('state',r.state,'request_id',r.id,'job_id',r.job_id); END IF;
 IF r.state<>'pending' THEN RAISE EXCEPTION '申请已处理，请刷新状态'; END IF;
 IF p_decision='rejected' THEN
  IF length(btrim(p_note))=0 THEN RAISE EXCEPTION '请填写驳回原因'; END IF;
  UPDATE public.st_subtitle_requests SET state='rejected',reviewed_by=public.st_actor(),reviewed_at=now(),review_note=btrim(p_note),updated_at=now() WHERE id=r.id;
 ELSE
  IF p_max_seconds IS NULL OR p_max_seconds NOT BETWEEN r.declared_seconds AND 1200
  OR p_max_text IS NULL OR p_max_text NOT BETWEEN 1 AND 400 OR p_max_secondary IS NULL OR p_max_secondary NOT BETWEEN 1 AND 40
  OR p_worker IS NULL OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=p_worker AND public.st_worker_valid(id) AND claimed_jobs<max_jobs)
  OR p_sources IS NULL THEN RAISE EXCEPTION '请核对有效执行身份、素材授权及每视频额度'; END IF;
  PERFORM public.st_subtitle_source_check(r.id,p_sources);
  p:=public.st_create_named_codex_project(r.stream_title,r.timestamp_label,'成员登记，经组长批准的云端 AI 初稿；需人工听校。');
  j:=gen_random_uuid();
  INSERT INTO public.st_cloud_jobs(id,project_id,task_id,requested_by,worker_id,file_name,mime_type,byte_size,sha256,max_video_seconds,max_text_requests,max_secondary_requests,sources,source_expires_at,state,stage)
  VALUES(j,(p->>'project_id')::uuid,(p->>'task_id')::uuid,r.requested_by,p_worker,r.file_name,r.mime_type,r.byte_size,r.sha256,p_max_seconds,p_max_text,p_max_secondary,p_sources,now()+interval '23 hours','queued','组长已批准，等待人工在 Codex Cloud 启动');
  INSERT INTO public.st_project_members(project_id,member_id,role) VALUES((p->>'project_id')::uuid,r.requested_by,'contributor') ON CONFLICT DO NOTHING;
  UPDATE public.st_subtitle_requests SET state='approved',job_id=j,reviewed_by=public.st_actor(),reviewed_at=now(),review_note=btrim(p_note),updated_at=now() WHERE id=r.id;
 END IF;
 INSERT INTO public.st_subtitle_notifications(request_id,event) VALUES(r.id,p_decision);
 RETURN jsonb_build_object('state',p_decision,'request_id',r.id,'job_id',j);
END; $$;

CREATE FUNCTION public.st_subtitle_request_withdraw(p_request uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;
BEGIN
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF NOT public.st_formal_member() OR (r.requested_by IS DISTINCT FROM public.st_actor() AND NOT public.st_owner()) OR r.id IS NULL
 THEN RAISE EXCEPTION '无此申请权限' USING ERRCODE='42501'; END IF;
 IF r.state='withdrawn' THEN RETURN; END IF;
 IF r.state NOT IN ('uploading','pending') THEN RAISE EXCEPTION '已审批申请不能撤回；请由组长取消对应云任务'; END IF;
 UPDATE public.st_subtitle_requests SET state='withdrawn',updated_at=now() WHERE id=r.id;
 INSERT INTO public.st_subtitle_notifications(request_id,event) VALUES(r.id,'withdrawn');
END; $$;

CREATE FUNCTION public.st_subtitle_request_refresh(p_request uuid,p_sources jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;j public.st_cloud_jobs;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可刷新素材授权' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF r.id IS NULL OR r.state<>'approved' OR p_sources IS NULL THEN RAISE EXCEPTION '申请尚未批准'; END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=r.job_id FOR UPDATE;
 IF j.state<>'queued' OR j.lease_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.st_cloud_request_reservations WHERE job_id=j.id)
 THEN RAISE EXCEPTION '仅未启动的排队任务可刷新；执行停止后需人工核对'; END IF;
 PERFORM public.st_subtitle_source_check(r.id,p_sources);
 UPDATE public.st_cloud_jobs SET sources=p_sources,source_expires_at=now()+interval '23 hours',updated_at=now() WHERE id=j.id;
 INSERT INTO public.st_subtitle_notifications(request_id,event) VALUES(r.id,'source_refreshed');
 RETURN jsonb_build_object('state','queued','job_id',j.id);
END; $$;

CREATE FUNCTION public.st_subtitle_requests_view(p_request uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可查看申请' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('qq_status','not_configured','requests',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (
 SELECT r.id,r.requested_by,m.display_name AS submitter,r.stream_title,r.timestamp_label,r.notes,r.file_name,r.byte_size,r.mime_type,r.declared_seconds,r.state,r.review_note,r.reviewed_at,r.job_id,r.created_at,r.upload_until,
 j.state AS job_state,j.source_expires_at,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests
 FROM public.st_subtitle_requests r JOIN public.st_members m ON m.id=r.requested_by LEFT JOIN public.st_cloud_jobs j ON j.id=r.job_id
 WHERE (public.st_owner() OR r.requested_by=public.st_actor()) AND (p_request IS NULL OR r.id=p_request) ORDER BY r.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $$;

CREATE FUNCTION public.st_subtitle_execution_instruction(p_job uuid) RETURNS text LANGUAGE sql IMMUTABLE SET search_path=pg_catalog AS $$
 SELECT '请在已发布的字幕交付 Cloud 环境中仅处理网站作业 '||p_job::text||'。先按 PRODUCTION_FLOW.md 核对固定环境，再运行 .venv/bin/python platform_worker.py --job-id '||p_job::text||' --work-root /workspace/subtitle-platform-production --execute。单视频上限20分钟、文字400次、千问40次，并服从服务端更低限额。遇到未知请求结果立即停止核对，不重复发送，不修改代码、权限、有效期或账本。按正常流程自动回传九个私有字幕/报告文件后停止；保持人工听校和审核，不发放人工积分。';
$$;
CREATE FUNCTION public.st_subtitle_request_packet(p_request uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;j public.st_cloud_jobs;packet jsonb;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可获取执行指令和通知摘要' USING ERRCODE='42501'; END IF;
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request;
 IF r.id IS NULL THEN RAISE EXCEPTION '申请不存在'; END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=r.job_id;
 packet:=jsonb_build_object('request_id',r.id,'state',r.state,'submitter',(SELECT display_name FROM public.st_members WHERE id=r.requested_by),'title',r.stream_title,'timestamp',r.timestamp_label,'seconds',r.declared_seconds,
 'website_url','https://example-site.tcloudbaseapp.com/?request='||r.id::text,'qq_status','not_configured');
 IF r.state='approved' AND j.state='queued' AND j.source_expires_at>now() AND public.st_worker_valid(j.worker_id)
 AND EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=j.worker_id AND claimed_jobs<max_jobs)
 AND public.st_project_access(j.project_id) AND EXISTS(SELECT 1 FROM public.st_tasks WHERE id=j.task_id AND state='open' AND deleted_at IS NULL)
 THEN packet:=packet||jsonb_build_object('job_id',j.id,'max_text_requests',j.max_text_requests,'max_secondary_requests',j.max_secondary_requests,'source_expires_at',j.source_expires_at,'instruction',public.st_subtitle_execution_instruction(j.id)); END IF;
 RETURN packet;
END; $$;

-- Future QQ integration reads this through a dedicated restricted adapter.
-- For now ONLY the logged-in owner may inspect it; no bot key/grant exists.
CREATE FUNCTION public.st_subtitle_notification_queue(p_after timestamptz DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可查看通知队列' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('delivery_enabled',false,'events',coalesce((SELECT jsonb_agg(jsonb_build_object('event_id',v.id,'event',v.event,'created_at',v.created_at,'packet',public.st_subtitle_request_packet(v.request_id)) ORDER BY v.created_at,v.id)
 FROM (SELECT * FROM public.st_subtitle_notifications WHERE p_after IS NULL OR created_at>=p_after ORDER BY created_at,id LIMIT 100) v),'[]'::jsonb));
END; $$;

REVOKE ALL ON FUNCTION public.st_subtitle_request_prepare(text,text,text,text,text,bigint,text,integer),public.st_subtitle_source_check(uuid,jsonb),public.st_subtitle_request_submit(uuid),public.st_subtitle_request_decide(uuid,text,uuid,integer,integer,integer,text,jsonb),public.st_subtitle_request_withdraw(uuid),public.st_subtitle_request_refresh(uuid,jsonb),public.st_subtitle_requests_view(uuid),public.st_subtitle_execution_instruction(uuid),public.st_subtitle_request_packet(uuid),public.st_subtitle_notification_queue(timestamptz) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_subtitle_request_prepare(text,text,text,text,text,bigint,text,integer),public.st_subtitle_request_submit(uuid),public.st_subtitle_request_decide(uuid,text,uuid,integer,integer,integer,text,jsonb),public.st_subtitle_request_withdraw(uuid),public.st_subtitle_request_refresh(uuid,jsonb),public.st_subtitle_requests_view(uuid),public.st_subtitle_request_packet(uuid),public.st_subtitle_notification_queue(timestamptz) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('039_member_subtitle_requests');
COMMIT;
