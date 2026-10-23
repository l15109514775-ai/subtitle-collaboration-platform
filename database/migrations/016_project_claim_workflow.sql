BEGIN;
ALTER TABLE public.st_projects ADD COLUMN origin text NOT NULL DEFAULT 'manual' CHECK(origin IN ('manual','codex'));
ALTER TABLE public.st_projects ADD COLUMN lead_member_id uuid REFERENCES public.st_members(id);
UPDATE public.st_projects p SET lead_member_id=coalesce((SELECT pm.member_id FROM public.st_project_members pm WHERE pm.project_id=p.id AND pm.role='lead' ORDER BY pm.joined_at,pm.member_id LIMIT 1),p.created_by);
INSERT INTO public.st_project_members(project_id,member_id,role) SELECT id,lead_member_id,'lead' FROM public.st_projects WHERE lead_member_id IS NOT NULL ON CONFLICT(project_id,member_id) DO UPDATE SET role='lead';
CREATE FUNCTION public.st_formal_member() RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_member_roles WHERE member_id=public.st_actor() AND role_code IN ('owner','manager','reviewer','contributor'));
$$;
CREATE OR REPLACE FUNCTION public.st_create_project(p_title text,p_description text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid; a uuid:=public.st_actor(); BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可新建项目'; END IF;
 INSERT INTO public.st_projects(title,description,created_by,origin,lead_member_id) VALUES(p_title,p_description,a,'manual',a) RETURNING id INTO p;
 INSERT INTO public.st_project_members(project_id,member_id,role) VALUES(p,a,'lead'); RETURN p;
END; $$;
CREATE FUNCTION public.st_create_codex_project(p_title text,p_description text DEFAULT '',p_task_title text DEFAULT 'AI 字幕校对',p_task_description text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p uuid; t uuid; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长或后续受控 Codex 入口可发起 AI 项目'; END IF;
 INSERT INTO public.st_projects(title,description,created_by,origin) VALUES(p_title,p_description,public.st_actor(),'codex') RETURNING id INTO p;
 INSERT INTO public.st_tasks(project_id,title,description,kind,origin,created_by) VALUES(p,p_task_title,p_task_description,'proofread','codex',public.st_actor()) RETURNING id INTO t;
 RETURN jsonb_build_object('project_id',p,'task_id',t);
END; $$;
CREATE FUNCTION public.st_claim_project(p_project uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
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
END; $$;
CREATE OR REPLACE FUNCTION public.st_claim_task(p_task uuid) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
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
END; $$;
CREATE FUNCTION public.st_work_catalog() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可浏览待认领目录'; END IF;
 RETURN jsonb_build_object(
 'projects',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'title',p.title,'description',p.description,'origin',p.origin,'lead_member_id',p.lead_member_id,'lead_name',m.display_name,'can_access',public.st_project_access(p.id)) ORDER BY p.created_at DESC) FROM public.st_projects p LEFT JOIN public.st_members m ON m.id=p.lead_member_id WHERE p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb),
 'tasks',coalesce((SELECT jsonb_agg(jsonb_build_object('id',t.id,'project_id',t.project_id,'title',t.title,'description',t.description,'kind',t.kind,'origin',t.origin) ORDER BY t.created_at DESC) FROM public.st_tasks t JOIN public.st_projects p ON p.id=t.project_id WHERE t.deleted_at IS NULL AND t.state='open' AND p.deleted_at IS NULL AND p.state='active'),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_normalize_ai_task() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.kind='translate' AND (NEW.origin='codex' OR EXISTS(SELECT 1 FROM public.st_projects WHERE id=NEW.project_id AND origin='codex')) THEN NEW.kind:='proofread'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_ai_task_kind BEFORE INSERT OR UPDATE OF kind,origin,project_id ON public.st_tasks FOR EACH ROW EXECUTE FUNCTION public.st_normalize_ai_task();
CREATE FUNCTION public.st_classify_ai_draft() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.source='codex' THEN UPDATE public.st_tasks SET kind='proofread',origin='codex' WHERE id=NEW.task_id AND kind='translate' AND state IN ('open','claimed','submitted'); END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_ai_delivery_kind AFTER INSERT ON public.st_deliveries FOR EACH ROW EXECUTE FUNCTION public.st_classify_ai_draft();
UPDATE public.st_tasks t SET kind='proofread',origin='codex' WHERE t.kind='translate' AND t.state IN ('open','claimed','submitted') AND (t.origin='codex' OR EXISTS(SELECT 1 FROM public.st_deliveries d WHERE d.task_id=t.id AND d.source='codex'));
REVOKE ALL ON FUNCTION public.st_formal_member(),public.st_create_codex_project(text,text,text,text),public.st_claim_project(uuid),public.st_work_catalog(),public.st_normalize_ai_task(),public.st_classify_ai_draft() FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_codex_project(text,text,text,text),public.st_claim_project(uuid),public.st_work_catalog() TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('016_project_claim_workflow');
COMMIT;
