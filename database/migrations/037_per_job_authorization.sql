-- REVIEW CANDIDATE. Not deployed. No credential, role, RLS or worker expiry changes.
-- Preserve trial history; only newly inserted jobs use the new protocol.
BEGIN;
ALTER TABLE public.st_cloud_jobs ADD COLUMN workflow_version text NOT NULL DEFAULT 'trial-20min-v1';
CREATE FUNCTION public.st_cloud_new_job_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.max_video_seconds NOT BETWEEN 1 AND 1200 OR NEW.max_text_requests NOT BETWEEN 1 AND 400
 OR NEW.max_secondary_requests NOT BETWEEN 1 AND 40 THEN RAISE EXCEPTION 'Per-video limits exceeded'; END IF;
 NEW.workflow_version:='per-job-v1';
 RETURN NEW;
END; $$;
CREATE TRIGGER st_cloud_new_job_guard BEFORE INSERT ON public.st_cloud_jobs
FOR EACH ROW EXECUTE FUNCTION public.st_cloud_new_job_guard();

CREATE TABLE public.st_cloud_request_reservations(
 job_id uuid NOT NULL REFERENCES public.st_cloud_jobs(id),
 request_id uuid NOT NULL,provider text NOT NULL CHECK(provider IN ('text','qwen')),
 lease_id uuid NOT NULL,ordinal integer NOT NULL CHECK(ordinal>0),created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(job_id,request_id),UNIQUE(job_id,provider,ordinal));
ALTER TABLE public.st_cloud_request_reservations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_cloud_request_reservations FROM PUBLIC,anon,authenticated,service_role;
CREATE TRIGGER st_cloud_request_immutable BEFORE UPDATE OR DELETE ON public.st_cloud_request_reservations
FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation();
CREATE TRIGGER st_cloud_request_audit AFTER INSERT ON public.st_cloud_request_reservations
FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();

-- Keep the existing validated claim/heartbeat/publish implementation private.
ALTER FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) RENAME TO st_cloud_worker_call_v033;
REVOKE ALL ON FUNCTION public.st_cloud_worker_call_v033(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.st_cloud_worker_call(p_key text,p_action text,p_job uuid DEFAULT NULL,p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE j public.st_cloud_jobs; result jsonb; w uuid; rid uuid; provider_name text; previous public.st_cloud_request_reservations;
 nt integer; nq integer; count_used integer; cap integer;
BEGIN
 IF p_payload IS NULL OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR pg_column_size(p_payload)>4100000
 THEN RAISE EXCEPTION 'Invalid cloud payload'; END IF;
 IF p_job IS NULL THEN RAISE EXCEPTION 'Exact job required'; END IF;
 SELECT id INTO w FROM public.st_cloud_workers WHERE public.st_worker_valid(id)
 AND p_key ~ '^[0-9a-f]{64}$' AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
 IF w IS NULL THEN RAISE EXCEPTION 'Inactive worker' USING ERRCODE='42501'; END IF;
 SELECT * INTO j FROM public.st_cloud_jobs WHERE id=p_job AND worker_id=w FOR UPDATE;
 IF j.id IS NULL THEN RAISE EXCEPTION 'Unauthorized job' USING ERRCODE='42501'; END IF;
 IF p_action='claim' AND j.workflow_version='per-job-v1'
 AND p_payload->>'workflow_version' IS DISTINCT FROM 'per-job-v1'
 THEN RAISE EXCEPTION 'Updated per-job worker required'; END IF;
 IF p_action='reserve' THEN
  IF j.workflow_version<>'per-job-v1' OR j.state<>'running' OR j.lease_until<=now()
  OR j.execution_deadline<=now() OR j.lease_id::text IS DISTINCT FROM p_payload->>'lease_id'
  OR NOT EXISTS(SELECT 1 FROM public.st_projects WHERE id=j.project_id AND state='active' AND deleted_at IS NULL)
  OR NOT EXISTS(SELECT 1 FROM public.st_tasks WHERE id=j.task_id AND state='open' AND deleted_at IS NULL)
  THEN RAISE EXCEPTION 'Inactive job or lease' USING ERRCODE='42501'; END IF;
  provider_name:=p_payload->>'provider'; rid:=(p_payload->>'request_id')::uuid;
  IF provider_name IS NULL OR provider_name NOT IN ('text','qwen') OR rid IS NULL THEN RAISE EXCEPTION 'Invalid reservation'; END IF;
  SELECT * INTO previous FROM public.st_cloud_request_reservations WHERE job_id=j.id AND request_id=rid;
  IF previous.request_id IS NOT NULL AND (previous.provider<>provider_name OR previous.lease_id<>j.lease_id)
  THEN RAISE EXCEPTION 'Reservation identity conflict'; END IF;
  SELECT count(*) FILTER(WHERE provider='text'),count(*) FILTER(WHERE provider='qwen') INTO nt,nq
  FROM public.st_cloud_request_reservations WHERE job_id=j.id;
  count_used:=CASE WHEN provider_name='text' THEN nt ELSE nq END;
  cap:=CASE WHEN provider_name='text' THEN least(j.max_text_requests,400) ELSE least(j.max_secondary_requests,40) END;
  IF previous.request_id IS NULL THEN
   IF count_used>=cap THEN RAISE EXCEPTION 'Job request allowance exhausted'; END IF;
   INSERT INTO public.st_cloud_request_reservations(job_id,request_id,provider,lease_id,ordinal)
   VALUES(j.id,rid,provider_name,j.lease_id,count_used+1);
   IF provider_name='text' THEN nt:=nt+1; ELSE nq:=nq+1; END IF;
  END IF;
  UPDATE public.st_cloud_jobs SET progress=progress||jsonb_build_object('text_requests',nt,'secondary_requests',nq),updated_at=now() WHERE id=j.id;
  RETURN jsonb_build_object('state','reserved','authorization_scope','job-'||j.id::text,'counts',jsonb_build_object('text',nt,'qwen',nq));
 END IF;
 IF j.workflow_version='per-job-v1' AND p_action IN ('heartbeat','stop','publish') THEN
  SELECT count(*) FILTER(WHERE provider='text'),count(*) FILTER(WHERE provider='qwen') INTO nt,nq
  FROM public.st_cloud_request_reservations WHERE job_id=j.id;
  p_payload:=jsonb_set(p_payload,'{progress}',coalesce(p_payload->'progress','{}')||jsonb_build_object('text_requests',nt,'secondary_requests',nq));
 END IF;
 result:=public.st_cloud_worker_call_v033(p_key,p_action,p_job,p_payload);
 IF p_action='claim' AND result->>'state'='running' AND j.workflow_version='per-job-v1' THEN
  result:=result||jsonb_build_object('authorization_scope','job-'||j.id::text,'workflow_version',j.workflow_version);
 END IF;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.st_cloud_new_job_guard(),public.st_cloud_worker_call(text,text,uuid,jsonb)
FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_call(text,text,uuid,jsonb) TO anon,authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('037_per_job_authorization');
COMMIT;
