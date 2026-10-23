-- Recovered function definitions only. No business rows or account data.
BEGIN;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_revoke(p_worker uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可撤销云执行身份'; END IF;
 UPDATE public.st_cloud_workers SET active=false WHERE id=p_worker;
END; $function$
;
CREATE OR REPLACE FUNCTION public.st_cloud_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_create(p_label text DEFAULT 'subtitle-cloud-worker'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE k text:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');w uuid;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可创建云执行身份'; END IF;
 INSERT INTO public.st_cloud_workers(label,key_hash,created_by) VALUES(p_label,encode(sha256(convert_to(k,'UTF8')),'hex'),public.st_actor()) RETURNING id INTO w;
 RETURN jsonb_build_object('id',w,'key',k,'label',p_label);
END; $function$
;
CREATE OR REPLACE FUNCTION public.st_worker_valid(p_worker uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_workers w
 JOIN public.st_members m ON m.id=w.created_by AND m.state='active'
 JOIN public.st_member_roles r ON r.member_id=m.id AND r.role_code='owner'
 WHERE w.id=p_worker AND w.active AND w.expires_at>now());
$function$
;
CREATE OR REPLACE FUNCTION public.st_cloud_jobs_view(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录正式成员账号'; END IF;
 RETURN jsonb_build_object('workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active,'expires_at',expires_at,'max_jobs',max_jobs,'claimed_jobs',claimed_jobs,'available',public.st_worker_valid(id) AND claimed_jobs<max_jobs) ORDER BY created_at DESC) FROM public.st_cloud_workers),'[]'::jsonb) ELSE '[]'::jsonb END,
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT j.id,j.project_id,j.task_id,j.state,j.stage,j.progress,j.file_name,j.byte_size,j.sha256,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests,j.source_expires_at,j.delivery_id,j.created_at,j.updated_at,p.title AS project_title FROM public.st_cloud_jobs j JOIN public.st_projects p ON p.id=j.project_id WHERE public.st_project_access(j.project_id) AND (p_project IS NULL OR j.project_id=p_project) ORDER BY j.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $function$
;
COMMIT;