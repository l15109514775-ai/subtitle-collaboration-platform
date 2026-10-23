BEGIN;
CREATE TABLE public.st_member_applications(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 auth_subject text UNIQUE NOT NULL,
 display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
 state text NOT NULL DEFAULT 'pending' CHECK(state IN ('pending','approved','rejected')),
 created_at timestamptz NOT NULL DEFAULT now(),
 decided_at timestamptz, decided_by uuid REFERENCES public.st_members(id)
);
ALTER TABLE public.st_member_applications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_member_applications FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER st_audit AFTER INSERT OR UPDATE OR DELETE ON public.st_member_applications FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();
CREATE FUNCTION public.st_membership_status() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE s text:=auth.uid(); m public.st_members; a public.st_member_applications; BEGIN
 IF s IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=s) THEN RAISE EXCEPTION '请先登录'; END IF;
 SELECT * INTO m FROM public.st_members WHERE auth_subject=s;
 IF m.id IS NOT NULL THEN RETURN jsonb_build_object('state',CASE WHEN m.state='active' THEN 'active' ELSE 'suspended' END,'display_name',m.display_name); END IF;
 SELECT * INTO a FROM public.st_member_applications WHERE auth_subject=s;
 RETURN jsonb_build_object('state',coalesce(a.state,'unsubmitted'),'display_name',a.display_name);
END; $$;
CREATE FUNCTION public.st_apply_membership(p_name text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE s text:=auth.uid(); BEGIN
 IF s IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users u WHERE COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=s) THEN RAISE EXCEPTION '请先登录'; END IF;
 IF p_name IS NULL OR length(btrim(p_name)) NOT BETWEEN 1 AND 80 THEN RAISE EXCEPTION '请填写 1 至 80 字的组内昵称'; END IF;
 IF EXISTS(SELECT 1 FROM public.st_members WHERE auth_subject=s) THEN RETURN public.st_membership_status(); END IF;
 INSERT INTO public.st_member_applications(auth_subject,display_name) VALUES(s,btrim(p_name)) ON CONFLICT(auth_subject) DO NOTHING;
 RETURN public.st_membership_status();
END; $$;
CREATE FUNCTION public.st_pending_members() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可查看注册申请'; END IF;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',a.id,'display_name',a.display_name,'username',COALESCE(to_jsonb(u)->>'username',to_jsonb(u)->'user_metadata'->>'username'),'created_at',a.created_at) ORDER BY a.created_at) FROM public.st_member_applications a JOIN auth.users u ON COALESCE(to_jsonb(u)->>'sub',to_jsonb(u)->>'id')=a.auth_subject WHERE a.state='pending'),'[]'::jsonb);
END; $$;
CREATE FUNCTION public.st_decide_member(p_application uuid,p_approve boolean,p_project uuid DEFAULT NULL,p_role text DEFAULT 'contributor') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
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
END; $$;
REVOKE ALL ON FUNCTION public.st_membership_status(),public.st_apply_membership(text),public.st_pending_members(),public.st_decide_member(uuid,boolean,uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_membership_status(),public.st_apply_membership(text),public.st_pending_members(),public.st_decide_member(uuid,boolean,uuid,text) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('014_member_applications');
COMMIT;
