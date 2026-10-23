BEGIN;
DO $$
DECLARE owner_subject text; p uuid; t uuid; d uuid; board jsonb; blocked boolean;
BEGIN
 SELECT m.auth_subject INTO owner_subject FROM public.st_members m JOIN public.st_member_roles r ON r.member_id=m.id WHERE r.role_code='owner' LIMIT 1;
 IF owner_subject IS NULL THEN RAISE EXCEPTION 'Missing approved owner'; END IF;
 PERFORM set_config('request.jwt.claim.sub',owner_subject,true);
 EXECUTE 'SET LOCAL ROLE authenticated';
 p:=public.st_create_project('transaction-only-authenticated-role-test','');
 t:=public.st_create_task(p,'transaction-only-test','test','translate');
 PERFORM public.st_claim_task(t);
 d:=public.st_submit(t,'Role-bound test subtitles','manual','temporary verification','');
 board:=public.st_board(p);
 IF (board->'me'->>'owner')::boolean IS DISTINCT FROM true OR jsonb_array_length(board->'tasks')<>1 OR board->'tasks'->0->>'state'<>'submitted' THEN RAISE EXCEPTION 'Authenticated workflow failed'; END IF;
 IF jsonb_array_length(public.st_task_detail(t)->'deliveries')<>1 THEN RAISE EXCEPTION 'Authenticated detail read failed'; END IF;
 blocked:=false; BEGIN PERFORM public.st_review(d,'approved','test',1,'test'); EXCEPTION WHEN raise_exception THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'Self review rejection failed'; END IF;
 blocked:=false; BEGIN PERFORM 1 FROM public.st_members; EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
 IF NOT blocked THEN RAISE EXCEPTION 'Direct member table access must remain denied'; END IF;
 EXECUTE 'RESET ROLE';
END;
$$;
SELECT 'PASS: authenticated role can create project/task, claim, submit and read via approved interfaces; cannot self-review or directly read member table. All test records rolled back.' AS authenticated_role_verification;
ROLLBACK;
