BEGIN;
DO $$
DECLARE own text;m uuid;w jsonb;j jsonb;blocked boolean;
BEGIN
 SELECT s.auth_subject,s.id INTO own,m FROM public.st_members s JOIN public.st_member_roles r ON r.member_id=s.id WHERE r.role_code='owner' LIMIT 1;
 PERFORM set_config('request.jwt.claim.sub',own,true);EXECUTE 'SET LOCAL ROLE authenticated';
 w:=public.st_cloud_worker_create('offline-claim-guard-fixture');
 j:=public.st_cloud_prepare((w->>'id')::uuid,'云端认领竞态测试','00:00–01:00','fixture.mp4','video/mp4',1000,repeat('b',64),60,20,2);
 blocked:=false;
 BEGIN PERFORM public.st_claim_task((j->>'task_id')::uuid);EXCEPTION WHEN raise_exception THEN IF SQLERRM LIKE '云端初稿尚在生成%' THEN blocked:=true;ELSE RAISE;END IF;END;
 IF NOT blocked THEN RAISE EXCEPTION 'Human claimed an unfinished AI task'; END IF;
 EXECUTE 'RESET ROLE';
 IF EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=(j->>'task_id')::uuid AND released_at IS NULL) OR (SELECT lead_member_id FROM public.st_projects WHERE id=(j->>'project_id')::uuid) IS NOT NULL THEN RAISE EXCEPTION 'Rejected claim left ownership or claim side effects';END IF;
 EXECUTE 'SET LOCAL ROLE authenticated';
 PERFORM public.st_claim_project((j->>'project_id')::uuid);
 EXECUTE 'RESET ROLE';
 IF (SELECT lead_member_id FROM public.st_projects WHERE id=(j->>'project_id')::uuid) IS DISTINCT FROM m THEN RAISE EXCEPTION 'Pending project cannot be claimed by its first human lead'; END IF;
 -- Terminal state is an isolated test fixture, not a real AI delivery.
 UPDATE public.st_cloud_jobs SET state='succeeded' WHERE id=(j->>'job_id')::uuid;
 EXECUTE 'SET LOCAL ROLE authenticated';
 PERFORM public.st_claim_task((j->>'task_id')::uuid);
 EXECUTE 'RESET ROLE';
 IF NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=(j->>'task_id')::uuid AND member_id=m AND released_at IS NULL) THEN RAISE EXCEPTION 'Ready proofreading task cannot be claimed'; END IF;
END; $$;
ROLLBACK;
