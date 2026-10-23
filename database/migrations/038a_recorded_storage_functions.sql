-- Recovered function definitions only. No business rows or account data.
BEGIN;
CREATE OR REPLACE FUNCTION public.st_cloud_source_read(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE public.st_project_access(j.project_id)
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$function$
;
CREATE OR REPLACE FUNCTION public.st_cloud_source_write(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 SELECT EXISTS(SELECT 1 FROM public.st_cloud_jobs j WHERE j.requested_by=public.st_actor() AND public.st_owner() AND j.state='uploading'
 AND EXISTS(SELECT 1 FROM generate_series(0,((j.byte_size-1)/4194304)::integer) n WHERE p_path=j.id::text||'/part-'||lpad(n::text,4,'0')))
$function$
;
COMMIT;