BEGIN;
-- API-facing aliases keep the existing worker/claim contract stable while the
-- Codex-specific public names are retired from new deployments.
CREATE OR REPLACE VIEW public.st_api_workers AS
 SELECT id,label,key_hash,created_by,active,created_at,expires_at,max_jobs,claimed_jobs,deleted_at,deleted_by
 FROM public.st_cloud_workers;
REVOKE ALL ON public.st_api_workers FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.st_api_worker_call(
 p_key text,p_action text,p_job uuid DEFAULT NULL::uuid,p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $$
 SELECT public.st_cloud_worker_call(p_key,p_action,p_job,p_payload)
$$;
REVOKE ALL ON FUNCTION public.st_api_worker_call(text,text,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_api_worker_call(text,text,uuid,jsonb) TO anon,authenticated;

INSERT INTO public.st_schema_migrations(version) VALUES('050_api_worker_aliases');
COMMIT;
