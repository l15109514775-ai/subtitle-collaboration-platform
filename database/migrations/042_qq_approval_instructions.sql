-- Candidate: deployment requires approval of the additional read-only scope.
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.st_qq_notification_settings
 ADD COLUMN approval_enabled boolean NOT NULL DEFAULT false,
 ADD COLUMN approval_activated_at timestamptz;
CREATE OR REPLACE FUNCTION public.st_qq_notification_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,NEW.gateway_id::text,TG_OP,
 jsonb_build_object('enabled',NEW.enabled,'owner_id',NEW.owner_id,'approval_enabled',NEW.approval_enabled,
 'approval_activated_at',NEW.approval_activated_at,
 'previous_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.enabled ELSE NULL END,
 'previous_approval_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.approval_enabled ELSE NULL END));
 RETURN NEW;
END; $$;
CREATE FUNCTION public.st_qq_approval_feed(p_key text,p_sender text,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid; start_at timestamptz; result jsonb;
BEGIN
 g:=public.st_qq_notification_access(p_key,p_sender);
 SELECT approval_activated_at INTO start_at FROM public.st_qq_notification_settings
 WHERE gateway_id=g AND approval_enabled;
 IF start_at IS NULL THEN RAISE EXCEPTION 'Approval notification access disabled' USING ERRCODE='42501'; END IF;
 IF (p_after IS NULL)<>(p_after_id IS NULL) OR p_after>now()+interval '1 minute'
 OR cardinality(p_ids)>10 THEN RAISE EXCEPTION 'Invalid cursor or event ids'; END IF;
 -- No title, member profile, source URL, credentials, approval or execution capability.
 SELECT jsonb_build_object('enabled',true,'events',coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at,x.id),'[]'::jsonb)) INTO result
 FROM (SELECT n.id,j.id AS job_id,n.created_at
 FROM public.st_subtitle_notifications n
 JOIN public.st_subtitle_requests r ON r.id=n.request_id AND r.state='approved'
 JOIN public.st_cloud_jobs j ON j.id=r.job_id AND j.state='queued'
 JOIN public.st_projects p ON p.id=j.project_id AND p.deleted_at IS NULL AND p.state='active'
 JOIN public.st_tasks t ON t.id=j.task_id AND t.state='open' AND t.deleted_at IS NULL
 WHERE n.event='approved' AND n.created_at>=start_at
 AND j.lease_id IS NULL AND j.source_expires_at>now()
 AND public.st_worker_valid(j.worker_id)
 AND EXISTS(SELECT 1 FROM public.st_cloud_workers w WHERE w.id=j.worker_id AND w.claimed_jobs<w.max_jobs)
 AND NOT EXISTS(SELECT 1 FROM public.st_cloud_request_reservations q WHERE q.job_id=j.id)
 AND (p_after IS NULL OR (n.created_at,n.id)>(p_after,p_after_id))
 AND (p_ids IS NULL OR n.id=ANY(p_ids))
 ORDER BY n.created_at,n.id LIMIT 50) x;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.st_qq_approval_feed(text,text,timestamptz,uuid,uuid[]) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_qq_approval_feed(text,text,timestamptz,uuid,uuid[]) TO anon;
INSERT INTO public.st_schema_migrations(version) VALUES('042_qq_approval_instructions');
COMMIT;
