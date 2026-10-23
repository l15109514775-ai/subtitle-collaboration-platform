BEGIN;
CREATE FUNCTION public.st_actor() RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT id FROM public.st_members WHERE auth_subject=(SELECT auth.uid()) AND state='active' $$;
CREATE FUNCTION public.st_owner() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=public.st_actor() AND role_code='owner') $$;
CREATE FUNCTION public.st_project_access(p_project uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project) $$;
CREATE FUNCTION public.st_project_manage(p_project uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project AND role='lead') $$;
CREATE FUNCTION public.st_project_review(p_project uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$ SELECT public.st_owner() OR EXISTS(SELECT 1 FROM public.st_project_members WHERE member_id=public.st_actor() AND project_id=p_project AND role IN ('lead','reviewer')) $$;
CREATE FUNCTION public.st_board(p_project uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); result jsonb; BEGIN
 IF a IS NULL THEN RAISE EXCEPTION '账号尚未由组长开通成员权限，或已停用'; END IF;
 IF p_project IS NOT NULL AND NOT public.st_project_access(p_project) THEN RAISE EXCEPTION '无此项目权限'; END IF;
 SELECT jsonb_build_object(
 'me',(SELECT jsonb_build_object('id',id,'display_name',display_name,'owner',public.st_owner()) FROM public.st_members WHERE id=a),
 'projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC) FROM public.st_projects p WHERE public.st_project_access(p.id)),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC) FROM (SELECT * FROM public.st_tasks WHERE project_id=p_project ORDER BY created_at DESC LIMIT 200) t),'[]'::jsonb),
 'claims',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.st_claims c WHERE c.project_id=p_project AND released_at IS NULL),'[]'::jsonb),
 'members',coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'display_name',m.display_name,'state',m.state,'project_role',pm.role)) FROM public.st_members m LEFT JOIN public.st_project_members pm ON pm.member_id=m.id AND pm.project_id=p_project WHERE (public.st_owner() OR pm.project_id=p_project) AND m.state='active'),'[]'::jsonb),
 'contributions',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.st_contributions c WHERE c.project_id=p_project),'[]'::jsonb),
 'revocations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM public.st_contribution_revocations r JOIN public.st_contributions c ON c.id=r.contribution_id WHERE c.project_id=p_project),'[]'::jsonb),
 'points',coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM public.st_point_entries e JOIN public.st_contributions c ON c.id=e.contribution_id WHERE c.project_id=p_project),'[]'::jsonb),
 'can_manage',CASE WHEN p_project IS NULL THEN public.st_owner() ELSE public.st_project_manage(p_project) END,
 'can_review',CASE WHEN p_project IS NULL THEN false ELSE public.st_project_review(p_project) END
 ) INTO result; RETURN result;
END; $$;
CREATE FUNCTION public.st_task_detail(p_task uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid; BEGIN
 SELECT project_id INTO p FROM public.st_tasks WHERE id=p_task;
 IF p IS NULL OR NOT public.st_project_access(p) THEN RAISE EXCEPTION '无此任务权限'; END IF;
 RETURN jsonb_build_object('deliveries',coalesce((SELECT jsonb_agg(to_jsonb(d) ORDER BY version_no DESC) FROM public.st_deliveries d WHERE task_id=p_task),'[]'::jsonb),'reviews',coalesce((SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at DESC) FROM public.st_reviews r WHERE task_id=p_task),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_create_project(p_title text,p_description text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可创建项目'; END IF;
 INSERT INTO public.st_projects(title,description,created_by) VALUES(p_title,p_description,public.st_actor()) RETURNING id INTO p;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p,public.st_actor(),'lead'); RETURN p;
END; $$;
CREATE FUNCTION public.st_create_task(p_project uuid,p_title text,p_description text,p_kind text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t uuid; BEGIN
 IF NOT public.st_project_access(p_project) OR NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p_project AND state='active') THEN RAISE EXCEPTION '项目未开放或无权限'; END IF;
 INSERT INTO public.st_tasks(project_id,title,description,kind,created_by) VALUES(p_project,p_title,p_description,p_kind,public.st_actor()) RETURNING id INTO t; RETURN t;
END; $$;
CREATE FUNCTION public.st_claim_task(p_task uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; c uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF a IS NULL OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '无任务权限'; END IF;
 SELECT id INTO c FROM public.st_claims WHERE task_id=p_task AND member_id=a AND released_at IS NULL;
 IF c IS NOT NULL THEN RETURN c; END IF;
 IF t.state<>'open' THEN RAISE EXCEPTION '任务已被认领或已结束'; END IF;
 INSERT INTO public.st_claims(task_id,project_id,member_id) VALUES(t.id,t.project_id,a) RETURNING id INTO c;
 UPDATE public.st_tasks SET state='claimed' WHERE id=t.id; RETURN c;
END; $$;
CREATE FUNCTION public.st_release_task(p_task uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF NOT public.st_project_access(t.project_id) OR t.state<>'claimed' THEN RAISE EXCEPTION '当前任务不可释放'; END IF;
 IF NOT public.st_project_manage(t.project_id) AND NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=public.st_actor() AND released_at IS NULL) THEN RAISE EXCEPTION '只可释放本人认领'; END IF;
 UPDATE public.st_claims SET released_at=now(),release_reason='released by member or lead' WHERE task_id=t.id AND released_at IS NULL;
 UPDATE public.st_tasks SET state='open' WHERE id=t.id;
END; $$;
CREATE FUNCTION public.st_submit(p_task uuid,p_content text,p_source text DEFAULT 'manual',p_notes text DEFAULT '',p_model text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks; a uuid:=public.st_actor(); v integer; d uuid; run uuid; parent uuid; BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF a IS NULL OR NOT public.st_project_access(t.project_id) OR p_source NOT IN ('manual','codex') THEN RAISE EXCEPTION '无提交权限或来源不支持'; END IF;
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
CREATE FUNCTION public.st_review(p_delivery uuid,p_decision text,p_feedback text,p_points integer DEFAULT 0,p_human_work text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE d public.st_deliveries; t public.st_tasks; r uuid; c uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO d FROM public.st_deliveries WHERE id=p_delivery;
 SELECT * INTO t FROM public.st_tasks WHERE id=d.task_id FOR UPDATE;
 IF a IS NULL OR NOT public.st_project_review(d.project_id) OR a=d.submitted_by THEN RAISE EXCEPTION '无审核权限，且不能审核自己的交付'; END IF;
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
CREATE FUNCTION public.st_enroll_member(p_subject text,p_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE m uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可开通成员'; END IF;
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=p_subject) THEN RAISE EXCEPTION '请先在 CloudBase 身份认证中创建账号，再复制用户 ID'; END IF;
 INSERT INTO public.st_members(auth_subject,display_name) VALUES(p_subject,p_name) RETURNING id INTO m;
 INSERT INTO public.st_member_roles(member_id,role_code) VALUES(m,'contributor'); RETURN m;
END; $$;
CREATE FUNCTION public.st_assign_member(p_project uuid,p_member uuid,p_role text DEFAULT 'contributor') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可分配项目角色'; END IF;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p_project,p_member,p_role) ON CONFLICT(project_id,member_id) DO UPDATE SET role=EXCLUDED.role;
END; $$;
DO $$ DECLARE f record; BEGIN
 FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname LIKE 'st_%' LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated,service_role',f.sig);
 END LOOP;
END; $$;
INSERT INTO public.st_schema_migrations(version) VALUES('002_closed_application_functions');
COMMIT;


