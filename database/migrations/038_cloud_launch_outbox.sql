-- REVIEW CANDIDATE. Requires 037. No launcher is enabled or billed by this file.
BEGIN;
CREATE TABLE public.st_cloud_launches(
 job_id uuid PRIMARY KEY REFERENCES public.st_cloud_jobs(id),request_id uuid NOT NULL UNIQUE,
 requested_by uuid NOT NULL REFERENCES public.st_members(id),
 state text NOT NULL CHECK(state IN ('requested','submitting','submitted','unknown')),
 task_url text CHECK(task_url IS NULL OR task_url ~ '^https://chatgpt[.]com/(local/[0-9a-f-]{36}|codex/tasks/[A-Za-z0-9_-]{1,120})$'),
 created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.st_cloud_launches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_cloud_launches FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER st_cloud_launch_audit AFTER INSERT OR UPDATE ON public.st_cloud_launches
FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();

CREATE FUNCTION public.st_cloud_launch_request(p_job uuid,p_request uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j public.st_cloud_jobs; launch public.st_cloud_launches;
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION 'Owner required' USING ERRCODE='42501'; END IF;
 IF p_request IS NULL THEN RAISE EXCEPTION 'Request id required'; END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job FOR UPDATE;
 IF j.id IS NULL OR NOT public.st_project_access(j.project_id) THEN RAISE EXCEPTION 'Unavailable job' USING ERRCODE='42501'; END IF;
 SELECT * INTO launch FROM public.st_cloud_launches WHERE job_id=j.id;
 IF launch.job_id IS NOT NULL THEN
  RETURN jsonb_build_object('job_id',j.id,'request_id',launch.request_id,'state',launch.state,'task_url',launch.task_url);
 END IF;
 IF j.workflow_version<>'per-job-v1' OR j.state<>'queued' OR j.source_expires_at<=now()
 OR NOT public.st_worker_valid(j.worker_id)
 OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=j.worker_id AND claimed_jobs<max_jobs)
 OR NOT EXISTS(SELECT 1 FROM public.st_tasks WHERE id=j.task_id AND state='open' AND deleted_at IS NULL)
 THEN RAISE EXCEPTION 'Job is not launchable'; END IF;
 INSERT INTO public.st_cloud_launches(job_id,request_id,requested_by,state) VALUES(j.id,p_request,public.st_actor(),'requested');
 RETURN jsonb_build_object('job_id',j.id,'request_id',p_request,'state','requested');
END; $$;

CREATE FUNCTION public.st_cloud_dispatch_call(p_key text,p_job uuid,p_request uuid,p_action text,p_task_url text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE w uuid;j public.st_cloud_jobs;l public.st_cloud_launches;
BEGIN
 SELECT id INTO w FROM public.st_cloud_workers WHERE public.st_worker_valid(id)
 AND p_key ~ '^[0-9a-f]{64}$' AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
 IF w IS NULL THEN RAISE EXCEPTION 'Inactive dispatcher identity' USING ERRCODE='42501'; END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job AND worker_id=w FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Unauthorized job' USING ERRCODE='42501'; END IF;
 SELECT * INTO l FROM public.st_cloud_launches WHERE job_id=j.id AND request_id=p_request FOR UPDATE;
 IF l.job_id IS NULL THEN RAISE EXCEPTION 'Owner launch authorization required'; END IF;
 IF p_action='begin' THEN
  IF l.state<>'requested' THEN RETURN jsonb_build_object('state',l.state,'may_submit',false,'task_url',l.task_url); END IF;
  IF j.state<>'queued' OR j.source_expires_at<=now()
  OR NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=j.project_id AND state='active' AND deleted_at IS NULL)
  THEN RAISE EXCEPTION 'Job unavailable'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.st_tasks WHERE id=j.task_id AND state='open' AND deleted_at IS NULL)
  OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=w AND claimed_jobs<max_jobs)
  THEN RAISE EXCEPTION 'Task or worker unavailable'; END IF;
  UPDATE public.st_cloud_launches SET state='submitting',updated_at=now() WHERE job_id=j.id;
  RETURN jsonb_build_object('state','submitting','may_submit',true,'job_id',j.id);
 ELSIF p_action IN ('submitted','unknown') THEN
  IF l.state<>'submitting' THEN RETURN jsonb_build_object('state',l.state,'may_submit',false,'task_url',l.task_url); END IF;
  IF p_action='submitted' AND (p_task_url IS NULL OR p_task_url !~ '^https://chatgpt[.]com/(local/[0-9a-f-]{36}|codex/tasks/[A-Za-z0-9_-]{1,120})$')
  THEN RAISE EXCEPTION 'Invalid task URL'; END IF;
  UPDATE public.st_cloud_launches SET state=p_action,task_url=CASE WHEN p_action='submitted' THEN p_task_url END,updated_at=now() WHERE job_id=j.id;
  RETURN jsonb_build_object('state',p_action,'task_url',CASE WHEN p_action='submitted' THEN p_task_url END);
 END IF;
 RAISE EXCEPTION 'Invalid dispatch action';
END; $$;
REVOKE ALL ON FUNCTION public.st_cloud_launch_request(uuid,uuid),public.st_cloud_dispatch_call(text,uuid,uuid,text,text)
FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_launch_request(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_cloud_dispatch_call(text,uuid,uuid,text,text) TO anon;
INSERT INTO public.st_schema_migrations(version) VALUES('038_cloud_launch_outbox');
COMMIT;
