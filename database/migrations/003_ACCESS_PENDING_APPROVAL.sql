-- STOP: The following separate transaction expands application access.
-- Run only after the user approves administrator ownership and member-scoped access.
BEGIN;
-- Assign the first owner separately using database/admin/01_set_owner.sql.
GRANT EXECUTE ON FUNCTION public.st_board(uuid),public.st_task_detail(uuid),public.st_create_project(text,text),public.st_create_task(uuid,text,text,text),public.st_claim_task(uuid),public.st_release_task(uuid),public.st_submit(uuid,text,text,text,text),public.st_review(uuid,text,text,integer,text),public.st_enroll_member(text,text),public.st_assign_member(uuid,uuid,text) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('003_approved_application_access');
COMMIT;

