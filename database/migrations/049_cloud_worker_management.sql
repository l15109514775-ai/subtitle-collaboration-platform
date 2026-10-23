BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.st_cloud_workers ADD COLUMN deleted_at timestamptz,
 ADD COLUMN deleted_by uuid REFERENCES public.st_members(id),
 ADD CONSTRAINT st_cloud_worker_deleted_state CHECK
 ((deleted_at IS NULL AND deleted_by IS NULL) OR (deleted_at IS NOT NULL AND deleted_by IS NOT NULL AND NOT active));

CREATE FUNCTION public.st_cloud_worker_set_deleted(p_worker uuid,p_deleted boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog' AS $$
DECLARE w public.st_cloud_workers;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可删除或恢复云执行身份' USING ERRCODE='42501'; END IF;
 IF p_deleted IS NULL THEN RAISE EXCEPTION '缺少删除操作'; END IF;
 SELECT * INTO w FROM public.st_cloud_workers WHERE id=p_worker FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '云执行身份不存在'; END IF;
 IF p_deleted AND w.active THEN RAISE EXCEPTION '请先撤销身份，再删除'; END IF;
 IF (w.deleted_at IS NOT NULL)=p_deleted THEN RETURN jsonb_build_object('id',w.id,'deleted',p_deleted,'active',w.active); END IF;
 UPDATE public.st_cloud_workers SET deleted_at=CASE WHEN p_deleted THEN clock_timestamp() ELSE NULL END,
 deleted_by=CASE WHEN p_deleted THEN public.st_actor() ELSE NULL END WHERE id=w.id;
 RETURN jsonb_build_object('id',w.id,'deleted',p_deleted,'active',false);
END; $$;

CREATE FUNCTION public.st_cloud_worker_rename(p_worker uuid,p_label text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog' AS $$
DECLARE w public.st_cloud_workers;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可修改云执行身份备注' USING ERRCODE='42501'; END IF;
 p_label:=btrim(p_label);
 IF p_label IS NULL OR char_length(p_label) NOT BETWEEN 1 AND 80 OR p_label ~ '[[:cntrl:]]' THEN RAISE EXCEPTION '身份备注须为1至80字，不能包含控制字符'; END IF;
 SELECT * INTO w FROM public.st_cloud_workers WHERE id=p_worker AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '身份不存在或已删除，请先恢复'; END IF;
 IF w.label IS DISTINCT FROM p_label THEN
  UPDATE public.st_cloud_workers SET label=p_label WHERE id=w.id;
  INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
  VALUES(auth.uid(),session_user,'st_cloud_workers',w.id::text,'UPDATE',
   jsonb_build_object('action','worker_rename','before_label',w.label,'after_label',p_label));
 END IF;
 RETURN jsonb_build_object('id',w.id,'label',p_label);
END; $$;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_create(p_label text DEFAULT 'subtitle-cloud-worker'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE k text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');w uuid;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可创建云执行身份'; END IF;
 p_label:=btrim(p_label);
 IF p_label IS NULL OR char_length(p_label) NOT BETWEEN 1 AND 80 OR p_label ~ '[[:cntrl:]]' THEN RAISE EXCEPTION '身份备注须为1至80字，不能包含控制字符'; END IF;
 INSERT INTO public.st_cloud_workers(label,key_hash,created_by) VALUES(p_label,encode(sha256(convert_to(k,'UTF8')),'hex'),public.st_actor()) RETURNING id INTO w;
 RETURN jsonb_build_object('id',w,'key',k,'label',p_label);
END; $function$;
CREATE OR REPLACE FUNCTION public.st_cloud_jobs_view(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录正式成员账号'; END IF;
 RETURN jsonb_build_object('workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active,'expires_at',expires_at,'max_jobs',max_jobs,'claimed_jobs',claimed_jobs,'available',public.st_worker_valid(id) AND claimed_jobs<max_jobs) ORDER BY created_at DESC) FROM public.st_cloud_workers WHERE deleted_at IS NULL),'[]'::jsonb) ELSE '[]'::jsonb END,
 'deleted_workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active,'deleted_at',deleted_at) ORDER BY deleted_at DESC,id) FROM public.st_cloud_workers WHERE deleted_at IS NOT NULL),'[]'::jsonb) ELSE '[]'::jsonb END,
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT j.id,j.project_id,j.task_id,j.state,j.stage,j.progress,j.file_name,j.byte_size,j.sha256,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests,j.source_expires_at,j.delivery_id,j.created_at,j.updated_at,p.title AS project_title FROM public.st_cloud_jobs j JOIN public.st_projects p ON p.id=j.project_id WHERE public.st_project_access(j.project_id) AND (p_project IS NULL OR j.project_id=p_project) ORDER BY j.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $function$;
REVOKE ALL ON FUNCTION public.st_cloud_worker_set_deleted(uuid,boolean),public.st_cloud_worker_rename(uuid,text)
 FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_set_deleted(uuid,boolean),public.st_cloud_worker_rename(uuid,text) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('049_cloud_worker_management');
COMMIT;
