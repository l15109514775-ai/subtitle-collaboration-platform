-- Recovered function definitions only. No business rows or account data.
BEGIN;
CREATE OR REPLACE FUNCTION public.st_audit_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE r jsonb; BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,coalesce(r->>'id',r->>'member_id',r->>'version'),TG_OP,
 jsonb_strip_nulls(jsonb_build_object('project_id',r->>'project_id','task_id',r->>'task_id','state',r->>'state','source',r->>'source','deleted_at',r->>'deleted_at','deleted_by',r->>'deleted_by')));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_audit_change() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_validate_review()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$ BEGIN IF EXISTS(SELECT 1 FROM public.st_deliveries WHERE id=NEW.delivery_id AND submitted_by=NEW.reviewer_id) THEN RAISE EXCEPTION 'Self-review is not allowed'; END IF; RETURN NEW; END; $function$
;
REVOKE ALL ON FUNCTION public.st_validate_review() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_validate_contribution()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$ BEGIN IF NOT EXISTS(SELECT 1 FROM public.st_reviews WHERE id=NEW.review_id AND decision='approved' AND reviewer_id=NEW.attested_by) THEN RAISE EXCEPTION 'Contribution requires an approving reviewer attestation'; END IF; RETURN NEW; END; $function$
;
REVOKE ALL ON FUNCTION public.st_validate_contribution() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_validate_points()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$ BEGIN IF NEW.reverses_entry_id IS NULL THEN IF EXISTS(SELECT 1 FROM public.st_contribution_revocations WHERE contribution_id=NEW.contribution_id) THEN RAISE EXCEPTION 'Cannot award a revoked contribution'; END IF; ELSE IF NOT EXISTS(SELECT 1 FROM public.st_point_entries p WHERE p.id=NEW.reverses_entry_id AND p.reverses_entry_id IS NULL AND p.member_id=NEW.member_id AND p.contribution_id=NEW.contribution_id AND p.points=-NEW.points) THEN RAISE EXCEPTION 'Reversal must exactly offset the original award'; END IF; END IF; RETURN NEW; END; $function$
;
REVOKE ALL ON FUNCTION public.st_validate_points() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_reject_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$ BEGIN RAISE EXCEPTION 'Immutable record: create a new version, revocation or reversal instead'; END; $function$
;
REVOKE ALL ON FUNCTION public.st_reject_mutation() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_project_access(p_project uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ SELECT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND deleted_at IS NULL AND state='active') AND (public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project)) $function$
;
REVOKE ALL ON FUNCTION public.st_project_access(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_enroll_member(p_subject text, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE m uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可开通成员'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=p_subject) THEN RAISE EXCEPTION '请先在 CloudBase 身份认证中创建账号，再复制用户 ID'; END IF;
 INSERT INTO public.st_members(auth_subject,display_name) VALUES(p_subject,p_name) RETURNING id INTO m;
 INSERT INTO public.st_member_roles(member_id,role_code) VALUES(m,'contributor'); RETURN m;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_enroll_member(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_enroll_member(text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ SELECT EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=public.st_actor() AND role_code='owner') $function$
;
REVOKE ALL ON FUNCTION public.st_owner() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_project_manage(p_project uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ SELECT public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project AND role='lead') $function$
;
REVOKE ALL ON FUNCTION public.st_project_manage(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_project_review(p_project uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ SELECT public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project AND role IN ('lead','reviewer')) $function$
;
REVOKE ALL ON FUNCTION public.st_project_review(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_task_detail(p_task uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p uuid; BEGIN
 SELECT project_id INTO p FROM public.st_tasks WHERE id=p_task AND deleted_at IS NULL;
 IF p IS NULL OR NOT public.st_project_access(p) THEN RAISE EXCEPTION '无此任务权限'; END IF;
 RETURN jsonb_build_object('artifacts',coalesce((SELECT jsonb_agg(to_jsonb(a)) FROM public.st_artifacts a JOIN public.st_deliveries d ON d.artifact_id=a.id WHERE d.task_id=p_task),'[]'::jsonb),'deliveries',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY version_no DESC) FROM public.st_deliveries d WHERE task_id=p_task),'[]'::jsonb),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at DESC) FROM public.st_reviews r WHERE task_id=p_task),'[]'::jsonb));
END; $function$
;
REVOKE ALL ON FUNCTION public.st_task_detail(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_task_detail(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_storage_write(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE (CASE WHEN u.chunk_size IS NULL THEN u.object_path=p_path ELSE EXISTS(SELECT 1 FROM generate_series(0,((u.byte_size-1)/u.chunk_size)::integer) AS part_no WHERE p_path=u.object_path||'/part-'||lpad(part_no::text,4,'0')) END) AND u.member_id=public.st_actor() AND u.delivery_id IS NULL AND u.expires_at>now() AND t.deleted_at IS NULL AND t.state NOT IN ('approved','archived') AND public.st_project_access(u.project_id) AND EXISTS(SELECT 1 FROM public.st_claims c WHERE c.task_id=t.id AND c.member_id=u.member_id AND c.released_at IS NULL))
$function$
;
REVOKE ALL ON FUNCTION public.st_storage_write(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_storage_write(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_actor()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ SELECT id FROM public.st_members WHERE auth_subject=(SELECT auth.uid()) AND state='active' $function$
;
REVOKE ALL ON FUNCTION public.st_actor() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_actor() TO authenticated;
CREATE OR REPLACE FUNCTION public.st_release_task(p_task uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF NOT public.st_project_access(t.project_id) OR t.deleted_at IS NOT NULL OR t.state<>'claimed' THEN RAISE EXCEPTION '当前任务不可释放'; END IF;
 IF NOT public.st_project_manage(t.project_id) AND NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=public.st_actor() AND released_at IS NULL) THEN RAISE EXCEPTION '只可释放本人认领'; END IF;
 UPDATE public.st_claims SET released_at=now(),release_reason='released by member or lead' WHERE task_id=t.id AND released_at IS NULL;
 UPDATE public.st_tasks SET state='open' WHERE id=t.id;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_release_task(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_release_task(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_submit(p_task uuid, p_content text, p_source text DEFAULT 'manual'::text, p_notes text DEFAULT ''::text, p_model text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_submit(uuid,text,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_submit(uuid,text,text,text,text) TO authenticated;
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
REVOKE ALL ON FUNCTION public.st_cloud_worker_revoke(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_revoke(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_board(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_board(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_board(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_create_project(p_title text, p_description text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p uuid; a uuid:=public.st_actor(); BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可新建项目'; END IF;
 INSERT INTO public.st_projects(title,description,created_by,origin,lead_member_id) VALUES(p_title,p_description,a,'manual',a) RETURNING id INTO p;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p,a,'lead'); RETURN p;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_create_project(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_project(text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_create_task(p_project uuid, p_title text, p_description text, p_kind text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE t uuid; BEGIN
 IF NOT public.st_project_access(p_project) OR NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND state='active') THEN RAISE EXCEPTION '项目未开放或无权限'; END IF;
 INSERT INTO public.st_tasks(project_id,title,description,kind,created_by) VALUES(p_project,p_title,p_description,p_kind,public.st_actor()) RETURNING id INTO t; RETURN t;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_create_task(uuid,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_task(uuid,text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_claim_task(p_task uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE t public.st_tasks; p public.st_projects; c uuid; a uuid:=public.st_actor(); pid uuid; BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可认领任务'; END IF;
 SELECT project_id INTO pid FROM public.st_tasks WHERE id=p_task;
 -- Every claim locks the project first, including claims on different tasks.
 SELECT * INTO p FROM public.st_projects WHERE id=pid FOR UPDATE;
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR t.deleted_at IS NOT NULL OR p.id IS NULL OR p.deleted_at IS NOT NULL OR p.state<>'active' THEN RAISE EXCEPTION '项目或任务已关闭'; END IF;
 SELECT id INTO c FROM public.st_claims WHERE task_id=p_task AND member_id=a AND released_at IS NULL;
 IF c IS NOT NULL THEN RETURN c; END IF;
 IF t.state<>'open' THEN RAISE EXCEPTION '任务已被认领或已结束'; END IF;
 IF p.lead_member_id IS NULL THEN
  PERFORM public.st_claim_project(p.id);
 ELSE
  INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p.id,a,'contributor') ON CONFLICT DO NOTHING;
 END IF;
 INSERT INTO public.st_claims(task_id,project_id,member_id) VALUES(t.id,t.project_id,a) RETURNING id INTO c;
 UPDATE public.st_tasks SET state='claimed' WHERE id=t.id; RETURN c;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_claim_task(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_claim_task(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_assign_member(p_project uuid, p_member uuid, p_role text DEFAULT 'contributor'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可分配项目角色'; END IF;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p_project,p_member,p_role) ON CONFLICT(project_id,member_id) DO UPDATE SET role=EXCLUDED.role;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_assign_member(uuid,uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_assign_member(uuid,uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_restore_project(p_project uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_project_manage(p_project) THEN RAISE EXCEPTION '仅组长和该项目负责人可恢复项目'; END IF;
 UPDATE public.st_projects SET deleted_at=NULL,deleted_by=NULL WHERE id=p_project AND deleted_at IS NOT NULL;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_restore_project(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_restore_project(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_delete_project(p_project uuid, p_confirmation text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p public.st_projects; BEGIN
 SELECT * INTO p FROM public.st_projects WHERE id=p_project FOR UPDATE;
 IF p.id IS NULL OR NOT public.st_project_manage(p.id) THEN RAISE EXCEPTION '仅组长和该项目负责人可删除项目'; END IF;
 IF p_confirmation IS DISTINCT FROM p.title THEN RAISE EXCEPTION '请输入完整项目名称确认删除'; END IF;
 IF p.deleted_at IS NULL THEN UPDATE public.st_projects SET deleted_at=now(),deleted_by=public.st_actor() WHERE id=p.id; END IF;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_delete_project(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_delete_project(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_delete_task(p_task uuid, p_confirmation text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR NOT public.st_project_manage(t.project_id) OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '仅组长和该项目负责人可删除任务'; END IF;
 IF p_confirmation IS DISTINCT FROM t.title THEN RAISE EXCEPTION '请输入完整任务名称确认删除'; END IF;
 IF t.deleted_at IS NULL THEN
  UPDATE public.st_tasks SET deleted_at=now(),deleted_by=public.st_actor() WHERE id=t.id;
  UPDATE public.st_claims SET released_at=now(),release_reason='task moved to recycle bin' WHERE task_id=t.id AND released_at IS NULL;
 END IF;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_delete_task(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_delete_task(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_deleted_items(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录有效成员账号'; END IF;
 RETURN jsonb_build_object('projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY deleted_at DESC) FROM public.st_projects p WHERE p.deleted_at IS NOT NULL AND public.st_project_manage(p.id)),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY deleted_at DESC) FROM public.st_tasks t WHERE t.project_id=p_project AND t.deleted_at IS NOT NULL AND public.st_project_manage(t.project_id) AND public.st_project_access(t.project_id)),'[]'::jsonb));
END; $function$
;
REVOKE ALL ON FUNCTION public.st_deleted_items(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_deleted_items(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_restore_task(p_task uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR NOT public.st_project_manage(t.project_id) OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '请先恢复项目，且仅组长和项目负责人可恢复任务'; END IF;
 UPDATE public.st_tasks SET deleted_at=NULL,deleted_by=NULL,state=CASE WHEN state IN ('claimed','submitted') THEN 'open' ELSE state END WHERE id=t.id AND deleted_at IS NOT NULL;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_restore_task(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_restore_task(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_upload_begin(p_task uuid, p_filename text, p_mime text, p_size bigint, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_upload_begin(uuid,text,text,bigint,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_upload_begin(uuid,text,text,bigint,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_storage_read(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE (CASE WHEN u.chunk_size IS NULL THEN u.object_path=p_path ELSE EXISTS(SELECT 1 FROM generate_series(0,((u.byte_size-1)/u.chunk_size)::integer) AS part_no WHERE p_path=u.object_path||'/part-'||lpad(part_no::text,4,'0')) END) AND public.st_project_access(u.project_id) AND t.deleted_at IS NULL AND (u.delivery_id IS NOT NULL OR (u.member_id=public.st_actor() AND u.expires_at>now())))
$function$
;
REVOKE ALL ON FUNCTION public.st_storage_read(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_storage_read(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_review(p_delivery uuid, p_decision text, p_feedback text, p_points integer DEFAULT 0, p_human_work text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_review(uuid,text,text,integer,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_review(uuid,text,text,integer,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_upload_finish(p_upload uuid, p_notes text DEFAULT ''::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE u public.st_uploads; t public.st_tasks; o storage.objects; d uuid; v integer; parent uuid; a uuid:=public.st_actor(); part_no integer; part_path text; part_bytes bigint; part_list jsonb:='[]'::jsonb; BEGIN
 SELECT * INTO u FROM public.st_uploads WHERE id=p_upload FOR UPDATE;
 IF u.id IS NULL OR a IS NULL OR u.member_id<>a THEN RAISE EXCEPTION '无此上传权限'; END IF;
 IF u.delivery_id IS NOT NULL THEN RETURN u.delivery_id; END IF;
 SELECT * INTO t FROM public.st_tasks WHERE id=u.task_id FOR UPDATE;
 IF t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR t.state IN ('approved','archived') OR u.expires_at<=now() OR NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '任务或上传会话已失效'; END IF;
 IF u.chunk_size IS NOT NULL THEN
  FOR part_no IN 0..((u.byte_size-1)/u.chunk_size)::integer LOOP
   part_path:=u.object_path||'/part-'||lpad(part_no::text,4,'0');
   part_bytes:=least(u.chunk_size,u.byte_size-part_no::bigint*u.chunk_size);
   SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=part_path;
   IF o.id IS NULL OR (o.owner_id IS DISTINCT FROM (SELECT auth.uid()) AND o.owner_id IS DISTINCT FROM '') OR o.created_at<u.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>part_bytes OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件分片未完整上传，或实际大小/类型不符'; END IF;
   part_list:=part_list||jsonb_build_array(jsonb_build_object('path',part_path,'byte_size',part_bytes));
  END LOOP;
 ELSE
 SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=u.object_path;
 IF o.id IS NULL OR (o.owner_id IS DISTINCT FROM (SELECT auth.uid()) AND o.owner_id IS DISTINCT FROM '') OR o.created_at<u.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>u.byte_size OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件尚未完整上传，或实际大小/类型不符'; END IF;
 END IF;
 INSERT INTO public.st_artifacts(id,project_id,object_path,file_name,sha256,byte_size,mime_type,uploaded_by,storage_etag,parts) VALUES(u.id,u.project_id,u.object_path,u.file_name,u.sha256,u.byte_size,u.mime_type,a,CASE WHEN u.chunk_size IS NULL THEN o.metadata->>'eTag' END,CASE WHEN u.chunk_size IS NOT NULL THEN part_list END);
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,parent_id,artifact_id,content_sha256,notes) VALUES(t.id,t.project_id,v,'manual',a,parent,u.id,u.sha256,p_notes) RETURNING id INTO d;
 UPDATE public.st_tasks SET state='submitted' WHERE id=t.id;
 UPDATE public.st_uploads SET delivery_id=d WHERE id=u.id;
 RETURN d;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_upload_finish(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_upload_finish(uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_upload_begin_chunked(p_task uuid, p_filename text, p_mime text, p_size bigint, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE result jsonb; BEGIN
 result:=public.st_upload_begin(p_task,p_filename,p_mime,p_size,p_sha256);
 UPDATE public.st_uploads SET chunk_size=4194304 WHERE id=(result->>'id')::uuid;
 RETURN result||jsonb_build_object('chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_upload_begin_chunked(uuid,text,text,bigint,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_upload_begin_chunked(uuid,text,text,bigint,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_call(p_key text, p_action text, p_job uuid DEFAULT NULL::uuid, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_apply_membership(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE s text:=auth.uid(); BEGIN
 IF s IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=s) THEN RAISE EXCEPTION '请先登录'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION '请填写 1 至 80 字的组内昵称'; END IF;
 IF EXISTS(SELECT 1 FROM public.st_members WHERE auth_subject=s) THEN RETURN public.st_membership_status(); END IF;
 INSERT INTO public.st_member_applications(auth_subject,display_name) VALUES(s,btrim(p_name)) ON CONFLICT(auth_subject) DO NOTHING;
 RETURN public.st_membership_status();
END; $function$
;
REVOKE ALL ON FUNCTION public.st_apply_membership(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_apply_membership(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_pending_members()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可查看注册申请'; END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',a.id,'display_name',a.display_name,'username',COALESCE(to_jsonb(u)->>'username',to_jsonb(u)->'user_metadata'->>'username'),'created_at',a.created_at) ORDER BY a.created_at) FROM public.st_member_applications a JOIN auth.users u ON COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=a.auth_subject WHERE a.state='pending'),'[]'::jsonb);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_pending_members() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_pending_members() TO authenticated;
CREATE OR REPLACE FUNCTION public.st_membership_status()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE s text:=auth.uid(); m public.st_members; a public.st_member_applications; BEGIN
 IF s IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=s) THEN RAISE EXCEPTION '请先登录'; END IF;
 SELECT * INTO m FROM public.st_members WHERE auth_subject=s;
 IF m.id IS NOT NULL THEN RETURN jsonb_build_object('state',CASE WHEN m.state='active' THEN 'active' ELSE 'suspended' END,'display_name',m.display_name); END IF;
 SELECT * INTO a FROM public.st_member_applications WHERE auth_subject=s;
 RETURN jsonb_build_object('state',coalesce(a.state,'unsubmitted'),'display_name',a.display_name);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_membership_status() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_membership_status() TO authenticated;
CREATE OR REPLACE FUNCTION public.st_decide_member(p_application uuid, p_approve boolean, p_project uuid DEFAULT NULL::uuid, p_role text DEFAULT 'contributor'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE a public.st_member_applications; m uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可审批注册申请'; END IF;
 IF p_approve IS NULL THEN RAISE EXCEPTION '请选择审批结果'; END IF;
 SELECT * INTO a FROM public.st_member_applications WHERE id=p_application FOR UPDATE;
 IF a.id IS NULL OR a.state<>'pending' THEN RAISE EXCEPTION '申请已处理或不存在'; END IF;
 IF p_approve THEN
  IF p_project IS NULL OR NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND deleted_at IS NULL AND state='active') OR p_role IS NULL OR p_role NOT IN ('lead','reviewer','contributor') THEN RAISE EXCEPTION '请先选择有效项目和身份'; END IF;
  IF EXISTS(SELECT 1 FROM public.st_members WHERE auth_subject=a.auth_subject) THEN RAISE EXCEPTION '此账号已开通或被停用，请勿重复审批'; END IF;
  IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=a.auth_subject) THEN RAISE EXCEPTION '认证账号已不存在'; END IF;
  m:=public.st_enroll_member(a.auth_subject,a.display_name);
  PERFORM public.st_assign_member(p_project,m,p_role);
 END IF;
 UPDATE public.st_member_applications SET state=CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,decided_at=now(),decided_by=public.st_actor() WHERE id=a.id;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_decide_member(uuid,boolean,uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_decide_member(uuid,boolean,uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_formal_member()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=public.st_actor() AND role_code IN ('owner','manager','reviewer','contributor'));
$function$
;
REVOKE ALL ON FUNCTION public.st_formal_member() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_normalize_ai_task()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NEW.kind='translate' AND (NEW.origin='codex' OR EXISTS(SELECT 1 FROM public.st_projects WHERE id=NEW.project_id AND origin='codex')) THEN NEW.kind:='proofread'; END IF;
 RETURN NEW;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_normalize_ai_task() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_claim_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NEW.released_at IS NULL AND EXISTS(SELECT 1 FROM public.st_cloud_jobs WHERE task_id=NEW.task_id AND state IN ('uploading','queued','running','waiting_configuration','waiting_reconciliation')) THEN
  RAISE EXCEPTION '云端初稿尚在生成，完成后可认领校对；目前可以先认领项目担任负责人。';
 END IF;
 RETURN NEW;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_claim_guard() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_create_codex_project(p_title text, p_description text DEFAULT ''::text, p_task_title text DEFAULT 'AI 字幕校对'::text, p_task_description text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p uuid; t uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长或后续受控 Codex 入口可发起 AI 项目'; END IF;
 INSERT INTO public.st_projects(title,description,created_by,origin) VALUES(p_title,p_description,public.st_actor(),'codex') RETURNING id INTO p;
 INSERT INTO public.st_tasks(project_id,title,description,kind,origin,created_by) VALUES(p,p_task_title,p_task_description,'proofread','codex',public.st_actor()) RETURNING id INTO t;
 RETURN jsonb_build_object('project_id',p,'task_id',t);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_create_codex_project(text,text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_codex_project(text,text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_claim_project(p_project uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p public.st_projects; a uuid:=public.st_actor(); BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可认领项目'; END IF;
 SELECT * INTO p FROM public.st_projects WHERE id=p_project FOR UPDATE;
 IF p.id IS NULL OR p.deleted_at IS NOT NULL OR p.state<>'active' THEN RAISE EXCEPTION '项目已关闭或不存在'; END IF;
 IF p.lead_member_id IS NOT NULL THEN
  IF p.lead_member_id=a THEN RETURN a; END IF;
  RAISE EXCEPTION '项目已被认领，请刷新列表';
 END IF;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p.id,a,'lead') ON CONFLICT(project_id,member_id) DO UPDATE SET role='lead';
 UPDATE public.st_projects SET lead_member_id=a WHERE id=p.id;
 RETURN a;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_claim_project(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_claim_project(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_work_catalog()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可浏览待认领目录'; END IF;
 RETURN jsonb_build_object(
 'projects',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'description',p.description,'origin',p.origin,'lead_member_id',p.lead_member_id,'lead_name',m.display_name,'can_access',public.st_project_access(p.id)) ORDER BY p.created_at DESC) FROM public.st_projects p LEFT JOIN public.st_members m ON m.id=p.lead_member_id WHERE p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(jsonb_build_object('id',t.id,'project_id',t.project_id,'title',t.title,'description',t.description,'kind',t.kind,'origin',t.origin) ORDER BY t.created_at DESC) FROM public.st_tasks t JOIN public.st_projects p ON p.id=t.project_id WHERE t.deleted_at IS NULL AND t.state='open' AND p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb));
END; $function$
;
REVOKE ALL ON FUNCTION public.st_work_catalog() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_work_catalog() TO authenticated;
CREATE OR REPLACE FUNCTION public.st_classify_ai_draft()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NEW.source='codex' THEN UPDATE public.st_tasks SET kind='proofread',origin='codex' WHERE id=NEW.task_id AND kind='translate' AND state IN ('open','claimed','submitted'); END IF;
 RETURN NEW;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_classify_ai_draft() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_validate_codex_project_name()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NEW.origin='codex' AND NEW.title !~ '^.+｜[^｜]+｜AI字幕初稿$' THEN RAISE EXCEPTION 'Codex 项目须按直播标题｜时间戳｜AI字幕初稿命名'; END IF;
 RETURN NEW;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_validate_codex_project_name() FROM PUBLIC,anon,authenticated,service_role;
CREATE OR REPLACE FUNCTION public.st_create_named_codex_project(p_stream_title text, p_timestamp text, p_description text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE title text; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长或受控 Codex 入口可登记 AI 项目'; END IF;
 IF p_stream_title IS NULL OR length(btrim(p_stream_title))=0 OR p_timestamp IS NULL OR length(btrim(p_timestamp)) NOT BETWEEN 1 AND 80 OR strpos(p_timestamp,'｜')>0 THEN RAISE EXCEPTION '请填写直播标题和时间戳'; END IF;
 title:=btrim(p_stream_title)||'｜'||btrim(p_timestamp)||'｜AI字幕初稿';
 IF length(title)>160 THEN RAISE EXCEPTION '直播标题加时间戳后不能超过 160 字，请缩短标题'; END IF;
 RETURN public.st_create_codex_project(title,p_description,title,'对 AI 字幕初稿进行人工听校、修订和复核。');
END; $function$
;
REVOKE ALL ON FUNCTION public.st_create_named_codex_project(text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_named_codex_project(text,text,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,NEW.id::text,TG_OP,
 jsonb_build_object('state',to_jsonb(NEW)->>'state','worker_id',to_jsonb(NEW)->>'worker_id'));
 RETURN NEW;
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_audit() FROM PUBLIC,anon,authenticated,service_role;
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
REVOKE ALL ON FUNCTION public.st_cloud_worker_create(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_create(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_prepare(p_worker uuid, p_stream_title text, p_timestamp text, p_filename text, p_mime text, p_size bigint, p_sha256 text, p_max_seconds integer DEFAULT 60, p_max_text integer DEFAULT 20, p_max_secondary integer DEFAULT 2)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE p jsonb;j uuid;
BEGIN
 IF NOT public.st_owner() OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=p_worker AND active) THEN RAISE EXCEPTION '仅组长可派发已批准的云任务'; END IF;
 IF length(p_filename) NOT BETWEEN 1 AND 200 OR p_filename ~ '[/\\]' THEN RAISE EXCEPTION '文件名错误'; END IF;
 p:=public.st_create_named_codex_project(p_stream_title,p_timestamp,'云端 AI 初稿；需成员认领并人工听校。');
 INSERT INTO public.st_cloud_jobs(project_id,task_id,requested_by,worker_id,file_name,mime_type,byte_size,sha256,max_video_seconds,max_text_requests,max_secondary_requests)
 VALUES((p->>'project_id')::uuid,(p->>'task_id')::uuid,public.st_actor(),p_worker,p_filename,p_mime,p_size,p_sha256,p_max_seconds,p_max_text,p_max_secondary) RETURNING id INTO j;
 RETURN jsonb_build_object('job_id',j,'project_id',p->>'project_id','task_id',p->>'task_id','object_prefix',j::text,'chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_prepare(uuid,text,text,text,text,bigint,text,integer,integer,integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_prepare(uuid,text,text,text,text,bigint,text,integer,integer,integer) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_source_write(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.requested_by=public.st_actor() AND public.st_owner() AND j.state='uploading'
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$function$
;
REVOKE ALL ON FUNCTION public.st_cloud_source_write(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_source_write(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_source_read(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE public.st_project_access(j.project_id)
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$function$
;
REVOKE ALL ON FUNCTION public.st_cloud_source_read(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_source_read(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_source_ready(p_job uuid, p_sources jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
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
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_source_ready(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_source_ready(uuid,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_jobs_view(p_project uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION '请先登录正式成员账号'; END IF;
 RETURN jsonb_build_object('workers',CASE WHEN public.st_owner() THEN coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'label',label,'active',active) ORDER BY created_at DESC) FROM public.st_cloud_workers),'[]'::jsonb) ELSE '[]'::jsonb END,
 'jobs',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (SELECT j.id,j.project_id,j.task_id,j.state,j.stage,j.progress,j.file_name,j.byte_size,j.sha256,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests,j.source_expires_at,j.delivery_id,j.created_at,j.updated_at,p.title AS project_title FROM public.st_cloud_jobs j JOIN public.st_projects p ON p.id=j.project_id WHERE public.st_project_access(j.project_id) AND (p_project IS NULL OR j.project_id=p_project) ORDER BY j.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_jobs_view(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_jobs_view(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_cancel(p_job uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可取消云任务'; END IF;
 UPDATE public.st_cloud_jobs SET state='cancelled',stage='已取消',lease_until=NULL,updated_at=now() WHERE id=p_job AND state<>'succeeded';
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_cancel(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_cancel(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_cloud_files(p_job uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE j public.st_cloud_jobs;
BEGIN
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job;
 IF j.id IS NULL OR NOT public.st_project_access(j.project_id) THEN RAISE EXCEPTION '无此交付权限'; END IF;
 RETURN coalesce(j.delivery_files,'[]'::jsonb);
END; $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_files(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_files(uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.st_clip_worker_identity(p_key text)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select id from public.st_cloud_workers where active and key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_worker_identity(text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_worker_identity(text) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_worker_is_active(p_worker uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select exists(select 1 from public.st_cloud_workers where id=p_worker and active);
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_worker_is_active(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_worker_is_active(uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_is_owner()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$ select public.st_owner(); $function$
;
REVOKE ALL ON FUNCTION public.st_clip_is_owner() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_is_owner() TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_project_access(p_project uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select public.st_owner() or exists(select 1 from public.st_project_members pm join public.st_members m on m.id=pm.member_id
    where pm.project_id=p_project and m.state='active' and m.auth_subject=current_setting('request.jwt.claim.sub',true));
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_project_access(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_project_access(uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_create_project(p_job uuid, p_title text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
end $function$
;
REVOKE ALL ON FUNCTION public.st_clip_create_project(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_create_project(uuid,text) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_record_selection(p_project uuid, p_selection jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare a integer:=(p_selection->>'start')::numeric::integer; b integer:=(p_selection->>'end')::numeric::integer; stamp text;
begin
  stamp:=lpad((a/3600)::text,2,'0')||':'||lpad((a/60%60)::text,2,'0')||':'||lpad((a%60)::text,2,'0')||'–'||
    lpad((b/3600)::text,2,'0')||':'||lpad((b/60%60)::text,2,'0')||':'||lpad((b%60)::text,2,'0');
  update public.st_projects set title=left(replace(p_selection->>'source_title','｜',' '),120)||'｜'||stamp||'｜AI字幕初稿'
    where id=p_project and origin='codex';
end $function$
;
REVOKE ALL ON FUNCTION public.st_clip_record_selection(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_record_selection(uuid,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_register_delivery(p_job uuid, p_package jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
end $function$
;
REVOKE ALL ON FUNCTION public.st_clip_register_delivery(uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_register_delivery(uuid,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_storage_scope(p_job uuid, p_prefix text, p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare headers jsonb; w uuid;
begin
  begin headers:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  exception when others then return false; end;
  if headers->>'x-cloud-clip-object' is distinct from p_name or
     headers->>'x-cloud-clip-capability' is distinct from p_prefix then return false; end if;
  w:=public.st_clip_worker_identity(headers->>'x-cloud-clip-worker');
  return w is not null and exists(select 1 from public.st_cloud_clip_jobs where id=p_job and worker_id=w
    and state='running' and lease_expires_at>now() and authorization_expires_at>now());
end $function$
;
REVOKE ALL ON FUNCTION public.st_clip_storage_scope(uuid,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_storage_scope(uuid,text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_locked_job(p_key text, p_job uuid, p_lease uuid)
 RETURNS st_cloud_clip_jobs
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
end $function$
;
REVOKE ALL ON FUNCTION public.st_clip_locked_job(text,uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_locked_job(text,uuid,uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_storage_read_allowed(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select p_bucket='subtitle-deliveries' and exists(select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id cross join lateral jsonb_array_elements(m.parts) part
    where part->>'object_name'=p_name and m.expires_at>now() and j.lease_id=m.lease_id
      and public.st_clip_storage_scope(m.job_id,m.object_prefix,p_name));
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_storage_read_allowed(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_storage_read_allowed(text,text) TO anon;
GRANT EXECUTE ON FUNCTION public.st_clip_storage_read_allowed(text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_clip_call(p_key text, p_action text, p_job uuid, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
       selection_data->>'source_sha256' !~ '^[0-9a-f]{64}$' or
       length(coalesce(selection_data->>'source_title','')) not between 1 and 500 or
       jsonb_typeof(selection_data->'source_sha256') is distinct from 'string' or
       jsonb_typeof(selection_data->'source_duration') is distinct from 'number' or
       jsonb_typeof(selection_data->'start') is distinct from 'number' or
       jsonb_typeof(selection_data->'end') is distinct from 'number' or
       (selection_data->>'source_duration')::numeric > 21600 or
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
end $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_clip_call(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_call(text,text,uuid,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_call(text,text,uuid,jsonb) TO service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_clip_cancel(p_job uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  if not public.st_clip_is_owner() then raise exception 'owner_required' using errcode='42501'; end if;
  update public.st_cloud_clip_jobs set state='cancelled',updated_at=now() where id=p_job and state<>'succeeded';
  return jsonb_build_object('state','cancelled');
end $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_clip_cancel(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_cancel(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_cancel(uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_clip_files(p_job uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare j public.st_cloud_clip_jobs; result jsonb;
begin
  select * into j from public.st_cloud_clip_jobs where id=p_job;
  if not found or j.state<>'succeeded' or not public.st_clip_project_access(j.project_id) then
    raise exception 'project_access_required' using errcode='42501'; end if;
  select files into result from public.st_cloud_clip_packages where job_id=p_job;
  return jsonb_build_object('job_id',p_job,'files',result);
end $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_clip_files(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_files(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_files(uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_member_storage_read_allowed(p_bucket text, p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select p_bucket='subtitle-deliveries' and exists(select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id cross join lateral jsonb_array_elements(m.parts) part
    where j.state='succeeded' and part->>'object_name'=p_name and public.st_clip_project_access(j.project_id));
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_member_storage_read_allowed(text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_member_storage_read_allowed(text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_clip_member_storage_read_allowed(text,text) TO service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_clip_create(p_source_url text, p_topic text, p_max_clip_seconds integer DEFAULT 4200, p_max_text_requests integer DEFAULT 20, p_max_qwen_requests integer DEFAULT 2, p_worker uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
end $function$
;
REVOKE ALL ON FUNCTION public.st_cloud_clip_create(text,text,integer,integer,integer,uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_create(text,text,integer,integer,integer,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_create(text,text,integer,integer,integer,uuid) TO service_role;
CREATE OR REPLACE FUNCTION public.st_cloud_clip_board()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id',j.id,'project_id',j.project_id,
    'project_name',coalesce(j.source_title,'云端剪辑')||' · AI字幕初稿','source_title',j.source_title,
    'state',j.state,'text_requests',j.text_requests,'qwen_requests',j.qwen_requests,'delivery_id',j.delivery_id,
    'media',case when j.state='succeeded' then (select jsonb_agg(jsonb_build_object('id',m.id,'role',m.role,
      'filename',m.filename,'mime',m.mime,'bytes',m.total_bytes,'sha256',m.sha256,'artifact_id',m.artifact_id,'task_id',m.task_id))
      from public.st_cloud_clip_media m where m.job_id=j.id) else '[]'::jsonb end)
    order by j.created_at desc),'[]'::jsonb)
  from public.st_cloud_clip_jobs j join public.st_projects p on p.id=j.project_id where p.deleted_at is null and public.st_clip_project_access(j.project_id);
$function$
;
REVOKE ALL ON FUNCTION public.st_cloud_clip_board() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_board() TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_clip_board() TO service_role;
CREATE OR REPLACE FUNCTION public.st_clip_storage_insert_allowed(p_bucket text, p_name text, p_metadata jsonb)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select p_bucket='subtitle-deliveries' and exists (
    select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id
    cross join lateral jsonb_array_elements(m.parts) part
    where m.state='reserved' and m.expires_at>now() and j.state='running'
      and j.lease_id=m.lease_id and j.lease_expires_at>now() and j.authorization_expires_at>now()
      and public.st_clip_storage_scope(m.job_id,m.object_prefix,p_name)
      and part->>'object_name'=p_name
  );
$function$
;
REVOKE ALL ON FUNCTION public.st_clip_storage_insert_allowed(text,text,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_clip_storage_insert_allowed(text,text,jsonb) TO anon;
GRANT EXECUTE ON FUNCTION public.st_clip_storage_insert_allowed(text,text,jsonb) TO service_role;
COMMIT;