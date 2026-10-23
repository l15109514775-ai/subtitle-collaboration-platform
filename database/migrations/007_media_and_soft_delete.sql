BEGIN;
ALTER TABLE public.st_projects ADD COLUMN deleted_at timestamptz, ADD COLUMN deleted_by uuid REFERENCES public.st_members(id);
ALTER TABLE public.st_tasks ADD COLUMN deleted_at timestamptz, ADD COLUMN deleted_by uuid REFERENCES public.st_members(id);
ALTER TABLE public.st_tasks DROP CONSTRAINT st_tasks_kind_check;
ALTER TABLE public.st_tasks ADD CONSTRAINT st_tasks_kind_check CHECK(kind IN ('clip','translate','timing','proofread','encode','cover','publish','other'));
ALTER TABLE public.st_contributions DROP CONSTRAINT st_contributions_contribution_kind_check;
ALTER TABLE public.st_contributions ADD CONSTRAINT st_contributions_contribution_kind_check CHECK(contribution_kind IN ('clip','translate','timing','proofread','encode','cover','publish','other'));
ALTER TABLE public.st_artifacts ADD COLUMN storage_etag text;
CREATE UNIQUE INDEX st_artifact_path_unique ON public.st_artifacts(object_path);
CREATE TABLE public.st_uploads(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),task_id uuid NOT NULL,project_id uuid NOT NULL,
 member_id uuid NOT NULL REFERENCES public.st_members(id),file_name text NOT NULL,
 object_path text UNIQUE NOT NULL,mime_type text NOT NULL,byte_size bigint NOT NULL CHECK(byte_size>0 AND byte_size<=1073741824),
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'),created_at timestamptz NOT NULL DEFAULT now(),
 expires_at timestamptz NOT NULL DEFAULT now()+interval '24 hours',delivery_id uuid REFERENCES public.st_deliveries(id),
 FOREIGN KEY(task_id,project_id) REFERENCES public.st_tasks(id,project_id));
ALTER TABLE public.st_uploads ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_uploads FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER st_audit AFTER INSERT OR UPDATE OR DELETE ON public.st_uploads FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE OR REPLACE FUNCTION public.st_audit_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r jsonb; BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,coalesce(r->>'id',r->>'member_id',r->>'version'),TG_OP,
 jsonb_strip_nulls(jsonb_build_object('project_id',r->>'project_id','task_id',r->>'task_id','state',r->>'state','source',r->>'source','deleted_at',r->>'deleted_at','deleted_by',r->>'deleted_by')));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END; $$;
CREATE FUNCTION public.st_delete_project(p_project uuid,p_confirmation text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p public.st_projects; BEGIN
 SELECT * INTO p FROM public.st_projects WHERE id=p_project FOR UPDATE;
 IF p.id IS NULL OR NOT public.st_project_manage(p.id) THEN RAISE EXCEPTION '仅组长和该项目负责人可删除项目'; END IF;
 IF p_confirmation IS DISTINCT FROM p.title THEN RAISE EXCEPTION '请输入完整项目名称确认删除'; END IF;
 IF p.deleted_at IS NULL THEN UPDATE public.st_projects SET deleted_at=now(),deleted_by=public.st_actor() WHERE id=p.id; END IF;
END; $$;
CREATE FUNCTION public.st_delete_task(p_task uuid,p_confirmation text) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR NOT public.st_project_manage(t.project_id) OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '仅组长和该项目负责人可删除任务'; END IF;
 IF p_confirmation IS DISTINCT FROM t.title THEN RAISE EXCEPTION '请输入完整任务名称确认删除'; END IF;
 IF t.deleted_at IS NULL THEN
  UPDATE public.st_tasks SET deleted_at=now(),deleted_by=public.st_actor() WHERE id=t.id;
  UPDATE public.st_claims SET released_at=now(),release_reason='task moved to recycle bin' WHERE task_id=t.id AND released_at IS NULL;
 END IF;
END; $$;
CREATE FUNCTION public.st_deleted_items(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录有效成员账号'; END IF;
 RETURN jsonb_build_object('projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY deleted_at DESC) FROM public.st_projects p WHERE p.deleted_at IS NOT NULL AND public.st_project_manage(p.id)),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY deleted_at DESC) FROM public.st_tasks t WHERE t.project_id=p_project AND t.deleted_at IS NOT NULL AND public.st_project_manage(t.project_id) AND public.st_project_access(t.project_id)),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_restore_project(p_project uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_project_manage(p_project) THEN RAISE EXCEPTION '仅组长和该项目负责人可恢复项目'; END IF;
 UPDATE public.st_projects SET deleted_at=NULL,deleted_by=NULL WHERE id=p_project AND deleted_at IS NOT NULL;
END; $$;
CREATE FUNCTION public.st_restore_task(p_task uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR NOT public.st_project_manage(t.project_id) OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '请先恢复项目，且仅组长和项目负责人可恢复任务'; END IF;
 UPDATE public.st_tasks SET deleted_at=NULL,deleted_by=NULL,state=CASE WHEN state IN ('claimed','submitted') THEN 'open' ELSE state END WHERE id=t.id AND deleted_at IS NOT NULL;
END; $$;
CREATE FUNCTION public.st_upload_begin(p_task uuid,p_filename text,p_mime text,p_size bigint,p_sha256 text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; u uuid:=gen_random_uuid(); path text; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF a IS NULL OR t.id IS NULL OR t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR t.state IN ('approved','archived') THEN RAISE EXCEPTION '任务未开放或无权限'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '请先认领任务'; END IF;
 IF p_filename IS NULL OR length(p_filename) NOT BETWEEN 1 AND 180 OR p_filename ~ '[/\\[:cntrl:]]' OR p_size IS NULL OR p_size<=0 OR p_sha256 IS NULL OR p_sha256 !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '文件信息不完整'; END IF;
 IF t.kind IN ('clip','encode') THEN
  IF p_size>1073741824 OR NOT ((lower(p_filename) LIKE '%.mp4' AND p_mime='video/mp4') OR (lower(p_filename) LIKE '%.mkv' AND p_mime='video/x-matroska') OR (lower(p_filename) LIKE '%.mov' AND p_mime='video/quicktime') OR (lower(p_filename) LIKE '%.webm' AND p_mime='video/webm')) THEN RAISE EXCEPTION '剪辑/压制请上传 1GB 以内的 MP4/MKV/MOV/WebM 视频'; END IF;
 ELSIF t.kind='cover' THEN
  IF p_size>20971520 OR NOT ((lower(p_filename) ~ '\.(jpg|jpeg)$' AND p_mime='image/jpeg') OR (lower(p_filename) LIKE '%.png' AND p_mime='image/png') OR (lower(p_filename) LIKE '%.webp' AND p_mime='image/webp')) THEN RAISE EXCEPTION '封面请上传 20MB 以内的 JPG/PNG/WebP 图片'; END IF;
 ELSE RAISE EXCEPTION '该任务应通过字幕/文本入口交付'; END IF;
 path:=t.project_id::text||'/'||t.id::text||'/'||u::text||'.'||lower(regexp_replace(p_filename,'^.*\.',''));
 INSERT INTO public.st_uploads(id,task_id,project_id,member_id,file_name,object_path,mime_type,byte_size,sha256) VALUES(u,t.id,t.project_id,a,p_filename,path,p_mime,p_size,p_sha256);
 RETURN jsonb_build_object('id',u,'bucket','subtitle-deliveries','path',path,'mime_type',p_mime,'byte_size',p_size);
END; $$;
CREATE FUNCTION public.st_storage_write(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE u.object_path=p_path AND u.member_id=public.st_actor() AND u.delivery_id IS NULL AND u.expires_at>now() AND t.deleted_at IS NULL AND t.state NOT IN ('approved','archived') AND public.st_project_access(u.project_id) AND EXISTS(SELECT 1 FROM public.st_claims c WHERE c.task_id=t.id AND c.member_id=u.member_id AND c.released_at IS NULL))
$$;
CREATE FUNCTION public.st_storage_read(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE u.object_path=p_path AND public.st_project_access(u.project_id) AND t.deleted_at IS NULL AND (u.delivery_id IS NOT NULL OR (u.member_id=public.st_actor() AND u.expires_at>now())))
$$;
CREATE FUNCTION public.st_upload_finish(p_upload uuid,p_notes text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u public.st_uploads; t public.st_tasks; o storage.objects; d uuid; v integer; parent uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO u FROM public.st_uploads WHERE id=p_upload FOR UPDATE;
 IF u.id IS NULL OR a IS NULL OR u.member_id<>a THEN RAISE EXCEPTION '无此上传权限'; END IF;
 IF u.delivery_id IS NOT NULL THEN RETURN u.delivery_id; END IF;
 SELECT * INTO t FROM public.st_tasks WHERE id=u.task_id FOR UPDATE;
 IF t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR t.state IN ('approved','archived') OR u.expires_at<=now() OR NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '任务或上传会话已失效'; END IF;
 SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=u.object_path;
 IF o.id IS NULL OR o.owner_id IS DISTINCT FROM (SELECT auth.uid()) OR coalesce((o.metadata->>'size')::bigint,-1)<>u.byte_size OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件尚未完整上传，或实际大小/类型不符'; END IF;
 INSERT INTO public.st_artifacts(id,project_id,object_path,file_name,sha256,byte_size,mime_type,uploaded_by,storage_etag) VALUES(u.id,u.project_id,u.object_path,u.file_name,u.sha256,u.byte_size,u.mime_type,a,o.metadata->>'eTag');
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,parent_id,artifact_id,content_sha256,notes) VALUES(t.id,t.project_id,v,'manual',a,parent,u.id,u.sha256,p_notes) RETURNING id INTO d;
 UPDATE public.st_tasks SET state='submitted' WHERE id=t.id;
 UPDATE public.st_uploads SET delivery_id=d WHERE id=u.id;
 RETURN d;
END; $$;
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types) VALUES('subtitle-deliveries','subtitle-deliveries',false,1073741824,ARRAY['video/mp4','video/x-matroska','video/quicktime','video/webm','image/jpeg','image/png','image/webp']);
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
CREATE POLICY st_delivery_bucket_read ON storage.buckets FOR SELECT TO authenticated USING(id='subtitle-deliveries' AND public.st_actor() IS NOT NULL);
CREATE POLICY st_delivery_object_read ON storage.objects FOR SELECT TO authenticated USING(bucket_id='subtitle-deliveries' AND public.st_storage_read(name));
CREATE POLICY st_delivery_object_insert ON storage.objects FOR INSERT TO authenticated WITH CHECK(bucket_id='subtitle-deliveries' AND owner_id=(SELECT auth.uid()) AND public.st_storage_write(name));
REVOKE ALL ON FUNCTION public.st_delete_project(uuid,text),public.st_delete_task(uuid,text),public.st_deleted_items(uuid),public.st_restore_project(uuid),public.st_restore_task(uuid),public.st_upload_begin(uuid,text,text,bigint,text),public.st_storage_read(text),public.st_storage_write(text),public.st_upload_finish(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_delete_project(uuid,text),public.st_delete_task(uuid,text),public.st_deleted_items(uuid),public.st_restore_project(uuid),public.st_restore_task(uuid),public.st_upload_begin(uuid,text,text,bigint,text),public.st_storage_read(text),public.st_storage_write(text),public.st_upload_finish(uuid,text),public.st_actor() TO authenticated;

CREATE OR REPLACE FUNCTION public.st_project_access(p_project uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND deleted_at IS NULL AND state='active') AND (public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project)) $$;
CREATE OR REPLACE FUNCTION public.st_board(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); result jsonb; BEGIN
 IF a IS NULL THEN RAISE EXCEPTION '账号尚未由组长开通成员权限，或已停用'; END IF;
 IF p_project IS NOT NULL AND NOT public.st_project_access(p_project) THEN RAISE EXCEPTION '无此项目权限'; END IF;
 SELECT jsonb_build_object(
 'me',(SELECT jsonb_build_object('id',id,'display_name',display_name,'owner',public.st_owner()) FROM public.st_members WHERE id=a),
 'projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC) FROM public.st_projects p WHERE p.deleted_at IS NULL AND public.st_project_access(p.id)),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC) FROM (SELECT * FROM public.st_tasks WHERE project_id=p_project AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 200) t),'[]'::jsonb),
 'claims',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.st_claims c WHERE c.project_id=p_project AND released_at IS NULL),'[]'::jsonb),
 'members',coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'display_name',m.display_name,'state',m.state,'project_role',pm.role)) FROM public.st_members m LEFT JOIN public.st_project_members pm ON pm.member_id=m.id AND pm.project_id=p_project WHERE (public.st_owner() OR pm.project_id=p_project) AND m.state='active'),'[]'::jsonb),
 'contributions',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.st_contributions c WHERE c.project_id=p_project),'[]'::jsonb),
 'revocations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM public.st_contribution_revocations r JOIN public.st_contributions c ON c.id=r.contribution_id WHERE c.project_id=p_project),'[]'::jsonb),
 'points',coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM public.st_point_entries e JOIN public.st_contributions c ON c.id=e.contribution_id WHERE c.project_id=p_project),'[]'::jsonb),
 'can_manage',CASE WHEN p_project IS NULL THEN public.st_owner() ELSE public.st_project_manage(p_project) END,
 'can_review',CASE WHEN p_project IS NULL THEN false ELSE public.st_project_review(p_project) END
 ) INTO result; RETURN result;
END; $$;
CREATE OR REPLACE FUNCTION public.st_task_detail(p_task uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid; BEGIN
 SELECT project_id INTO p FROM public.st_tasks WHERE id=p_task AND deleted_at IS NULL;
 IF p IS NULL OR NOT public.st_project_access(p) THEN RAISE EXCEPTION '无此任务权限'; END IF;
 RETURN jsonb_build_object('artifacts',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM public.st_artifacts a JOIN public.st_deliveries d ON d.artifact_id=a.id WHERE d.task_id=p_task),'[]'::jsonb),'deliveries',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY version_no DESC) FROM public.st_deliveries d WHERE task_id=p_task),'[]'::jsonb),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at DESC) FROM public.st_reviews r WHERE task_id=p_task),'[]'::jsonb));
END; $$;
CREATE OR REPLACE FUNCTION public.st_claim_task(p_task uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; c uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF a IS NULL OR t.id IS NULL OR t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '无任务权限'; END IF;
 SELECT id INTO c FROM public.st_claims WHERE task_id=p_task AND member_id=a AND released_at IS NULL;
 IF c IS NOT NULL THEN RETURN c; END IF;
 IF t.state<>'open' THEN RAISE EXCEPTION '任务已被认领或已结束'; END IF;
 INSERT INTO public.st_claims(task_id,project_id,member_id) VALUES(t.id,t.project_id,a) RETURNING id INTO c;
 UPDATE public.st_tasks SET state='claimed' WHERE id=t.id; RETURN c;
END; $$;
CREATE OR REPLACE FUNCTION public.st_release_task(p_task uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF NOT public.st_project_access(t.project_id) OR t.deleted_at IS NOT NULL OR t.state<>'claimed' THEN RAISE EXCEPTION '当前任务不可释放'; END IF;
 IF NOT public.st_project_manage(t.project_id) AND NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=public.st_actor() AND released_at IS NULL) THEN RAISE EXCEPTION '只可释放本人认领'; END IF;
 UPDATE public.st_claims SET released_at=now(),release_reason='released by member or lead' WHERE task_id=t.id AND released_at IS NULL;
 UPDATE public.st_tasks SET state='open' WHERE id=t.id;
END; $$;
CREATE OR REPLACE FUNCTION public.st_submit(p_task uuid,p_content text,p_source text DEFAULT 'manual',p_notes text DEFAULT '',p_model text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; a uuid:=public.st_actor(); v integer; d uuid; run uuid; parent uuid; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF a IS NULL OR NOT public.st_project_access(t.project_id) OR p_source NOT IN ('manual','codex') THEN RAISE EXCEPTION '无提交权限或来源不支持'; END IF;
 IF t.deleted_at IS NOT NULL OR t.kind IN ('clip','encode','cover') THEN RAISE EXCEPTION '剪辑/压制需上传视频，封面需上传图片'; END IF;
 IF length(p_content) NOT BETWEEN 1 AND 500000 THEN RAISE EXCEPTION '交付内容须为 1 至 500000 字符'; END IF;
 IF t.state IN ('approved','archived') THEN RAISE EXCEPTION '任务已结束'; END IF;
 IF p_source='codex' THEN
  IF NOT public.st_project_manage(t.project_id) THEN RAISE EXCEPTION '仅项目负责人可放入 Codex 待认领稿'; END IF;
  IF t.state<>'open' THEN RAISE EXCEPTION 'Codex 初稿只可放入待认领任务'; END IF;
  INSERT INTO public.st_agent_runs(project_id,provider,external_run_id,initiated_by,model_label,summary) VALUES(t.project_id,'codex','human-upload-'||gen_random_uuid()::text,a,p_model,'由成员手动导入的 Codex 稿，尚未接通自动回传') RETURNING id INTO run;
 ELSE
  IF NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '请先认领此任务'; END IF;
 END IF;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,agent_run_id,parent_id,content_text,content_sha256,notes)
 VALUES(t.id,t.project_id,v,p_source,a,run,parent,p_content,encode(sha256(convert_to(p_content,'UTF8')),'hex'),p_notes) RETURNING id INTO d;
 IF p_source='manual' THEN UPDATE public.st_tasks SET state='submitted' WHERE id=t.id; END IF;
 RETURN d;
END; $$;
CREATE OR REPLACE FUNCTION public.st_review(p_delivery uuid,p_decision text,p_feedback text,p_points integer DEFAULT 0,p_human_work text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE d public.st_deliveries; t public.st_tasks; r uuid; c uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO d FROM public.st_deliveries WHERE id=p_delivery;
 SELECT * INTO t FROM public.st_tasks WHERE id=d.task_id FOR UPDATE;
 IF a IS NULL OR t.deleted_at IS NOT NULL OR NOT public.st_project_access(d.project_id) OR NOT public.st_project_review(d.project_id) OR a=d.submitted_by THEN RAISE EXCEPTION '无审核权限，且不能审核自己的交付'; END IF;
 IF t.state<>'submitted' OR d.version_no<>(SELECT max(version_no) FROM public.st_deliveries WHERE task_id=t.id) THEN RAISE EXCEPTION '仅可审核待审任务的最新版本'; END IF;
 IF p_decision NOT IN ('approved','changes_requested') OR p_points NOT BETWEEN 0 AND 10000 THEN RAISE EXCEPTION '审核参数错误'; END IF;
 IF p_decision='approved' AND length(p_human_work)=0 THEN RAISE EXCEPTION '请填写核验的人工贡献说明'; END IF;
 INSERT INTO public.st_reviews(delivery_id,task_id,project_id,reviewer_id,decision,feedback) VALUES(d.id,d.task_id,d.project_id,a,p_decision,p_feedback) RETURNING id INTO r;
 IF p_decision='approved' THEN
  IF d.source<>'manual' THEN RAISE EXCEPTION 'AI 初稿须由成员加工并提交人工版本后认可贡献'; END IF;
  INSERT INTO public.st_contributions(project_id,task_id,delivery_id,review_id,member_id,contribution_kind,human_work_description,units,unit_label,attested_by) VALUES(d.project_id,d.task_id,d.id,r,d.submitted_by,t.kind,p_human_work,1,'项',a) RETURNING id INTO c;
  IF p_points>0 THEN INSERT INTO public.st_point_entries(member_id,contribution_id,points,reason,recorded_by) VALUES(d.submitted_by,c,p_points,p_human_work,a); END IF;
  UPDATE public.st_tasks SET state='approved' WHERE id=t.id;
  UPDATE public.st_claims SET released_at=now(),release_reason='completed' WHERE task_id=t.id AND released_at IS NULL;
 ELSE UPDATE public.st_tasks SET state='claimed' WHERE id=t.id; END IF;
 RETURN r;
END; $$;
INSERT INTO public.st_schema_migrations(version) VALUES('007_media_and_soft_delete');
COMMIT;
