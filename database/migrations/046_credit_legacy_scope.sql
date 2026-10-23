BEGIN;
SET LOCAL lock_timeout='5s';
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

 'contributions',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.st_contributions c WHERE c.project_id=p_project AND (public.st_owner() OR c.member_id=a)),'[]'::jsonb),

 'revocations',coalesce((SELECT jsonb_agg(to_jsonb(r)) FROM public.st_contribution_revocations r JOIN public.st_contributions c ON c.id=r.contribution_id WHERE c.project_id=p_project AND (public.st_owner() OR c.member_id=a)),'[]'::jsonb),

 'points',coalesce((SELECT jsonb_agg(to_jsonb(e)) FROM public.st_point_entries e JOIN public.st_contributions c ON c.id=e.contribution_id WHERE c.project_id=p_project AND (public.st_owner() OR c.member_id=a)),'[]'::jsonb),

 'can_manage',CASE WHEN p_project IS NULL THEN public.st_owner() ELSE public.st_project_manage(p_project) END,

 'can_review',CASE WHEN p_project IS NULL THEN false ELSE public.st_project_review(p_project) END

 ) INTO result; RETURN result;

END; $function$
;
INSERT INTO public.st_schema_migrations(version) VALUES('046_credit_legacy_scope');
COMMIT;
