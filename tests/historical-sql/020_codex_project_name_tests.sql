BEGIN;
DO $$
DECLARE own text; j jsonb; p uuid; t uuid; blocked boolean; BEGIN
 SELECT m.auth_subject INTO own FROM public.st_members m JOIN public.st_member_roles r ON r.member_id=m.id WHERE r.role_code='owner' LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',own,true);EXECUTE 'SET LOCAL ROLE authenticated';
 j:=public.st_create_named_codex_project('标题测试','01:00–11:00');p:=(j->>'project_id')::uuid;t:=(j->>'task_id')::uuid;
 blocked:=false;BEGIN PERFORM public.st_create_named_codex_project('标题',' ');EXCEPTION WHEN raise_exception THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Missing timestamp accepted';END IF;
 blocked:=false;BEGIN PERFORM public.st_create_codex_project('unformatted legacy name');EXCEPTION WHEN raise_exception THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Name enforcement bypassed';END IF;
 EXECUTE 'RESET ROLE';
 IF NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=p AND title='标题测试｜01:00–11:00｜AI字幕初稿' AND lead_member_id IS NULL AND origin='codex') THEN RAISE EXCEPTION 'Project naming or lead regression';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.st_tasks WHERE id=t AND title='标题测试｜01:00–11:00｜AI字幕初稿' AND kind='proofread') THEN RAISE EXCEPTION 'Task classification regression';END IF;
 IF has_function_privilege('anon','public.st_create_named_codex_project(text,text,text)','EXECUTE') THEN RAISE EXCEPTION 'Anonymous intake';END IF;
END; $$;
SELECT 'PASS: live title plus explicit timestamp plus AI subtitle draft; missing timestamp and legacy bypass rejected; initial project remains unclaimed; task remains proofreading; anonymous denied. Fixtures rolled back.' AS naming_verification;
ROLLBACK;
