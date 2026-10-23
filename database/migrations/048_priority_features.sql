BEGIN;
SET LOCAL lock_timeout='5s';

CREATE FUNCTION public.st_my_work(p_scope text DEFAULT 'mine',p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); result jsonb;
BEGIN
 IF a IS NULL OR NOT public.st_formal_member() THEN RAISE EXCEPTION '请先登录正式成员账号' USING ERRCODE='42501'; END IF;
 IF p_scope IS NULL OR p_scope NOT IN ('mine','team') OR p_offset IS NULL OR p_offset<0 OR p_offset>1000000 THEN RAISE EXCEPTION '无效待办参数'; END IF;
 IF p_scope='team' AND NOT public.st_owner() THEN RAISE EXCEPTION '仅组长可查看全组待办' USING ERRCODE='42501'; END IF;
 WITH eligible AS (
  SELECT t.id,t.project_id,t.title,t.kind,t.state,t.due_at,t.created_at,p.title AS project_title,
   c.member_id AS assignee_id,m.display_name AS assignee_name,c.member_id=a AS mine,
   t.state='submitted' AND d.id IS NOT NULL AND d.submitted_by<>a AND public.st_project_review(t.project_id) AS needs_review,
   t.state='claimed' AND c.member_id=a AND r.decision='changes_requested' AND r.delivery_id=d.id AS returned,
   t.due_at<now() AS overdue
  FROM public.st_tasks t JOIN public.st_projects p ON p.id=t.project_id
  LEFT JOIN public.st_claims c ON c.task_id=t.id AND c.released_at IS NULL
  LEFT JOIN public.st_members m ON m.id=c.member_id
  LEFT JOIN LATERAL (SELECT id,submitted_by FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1) d ON true
  LEFT JOIN LATERAL (SELECT decision,delivery_id FROM public.st_reviews WHERE task_id=t.id ORDER BY created_at DESC,id DESC LIMIT 1) r ON true
  WHERE t.deleted_at IS NULL AND t.state IN ('open','claimed','submitted') AND public.st_project_access(p.id)
 ), visible AS (
  SELECT * FROM eligible WHERE p_scope='team' OR mine OR needs_review
 ), page AS (
  SELECT * FROM visible ORDER BY overdue DESC NULLS LAST,returned DESC NULLS LAST,needs_review DESC NULLS LAST,due_at NULLS LAST,created_at,id LIMIT 50 OFFSET p_offset
 )
 SELECT jsonb_build_object('scope',p_scope,'owner',public.st_owner(),'offset',p_offset,
  'summary',(SELECT jsonb_build_object('total',count(*),'mine',count(*) FILTER(WHERE mine),'review',count(*) FILTER(WHERE needs_review),'returned',count(*) FILTER(WHERE returned),'overdue',count(*) FILTER(WHERE overdue)) FROM visible),
  'items',coalesce((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.overdue DESC NULLS LAST,x.returned DESC NULLS LAST,x.needs_review DESC NULLS LAST,x.due_at NULLS LAST,x.created_at,x.id) FROM page x),'[]'::jsonb)) INTO result;
 RETURN result;
END; $$;

-- Opens a task beyond the board's latest-200 window using the same resource check.
CREATE FUNCTION public.st_task_work_context(p_task uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks;
BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task AND deleted_at IS NULL;
 IF t.id IS NULL OR NOT public.st_formal_member() OR NOT public.st_project_access(t.project_id) THEN RAISE EXCEPTION '无此任务权限' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('task',to_jsonb(t),'claim',(SELECT to_jsonb(c) FROM public.st_claims c WHERE task_id=t.id AND released_at IS NULL));
END; $$;

CREATE FUNCTION public.st_task_deadline(p_task uuid,p_due timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE t public.st_tasks;
BEGIN
 SELECT * INTO t FROM public.st_tasks WHERE id=p_task FOR UPDATE;
 IF t.id IS NULL OR t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR NOT public.st_project_manage(t.project_id) THEN RAISE EXCEPTION '仅组长或本项目负责人可设置截止时间' USING ERRCODE='42501'; END IF;
 IF t.state NOT IN ('open','claimed','submitted') THEN RAISE EXCEPTION '已结束任务不能设置截止时间'; END IF;
 IF p_due IS NOT NULL AND (NOT isfinite(p_due) OR p_due<now()-interval '10 years' OR p_due>now()+interval '5 years') THEN RAISE EXCEPTION '截止时间超出范围'; END IF;
 IF t.due_at IS DISTINCT FROM p_due THEN
  UPDATE public.st_tasks SET due_at=p_due WHERE id=t.id;
  INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
   VALUES(auth.uid(),session_user,'st_tasks',t.id::text,'UPDATE',jsonb_build_object('action','deadline','before',t.due_at,'after',p_due));
 END IF;
END; $$;

CREATE TABLE public.st_cloud_result_events(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 job_id uuid NOT NULL REFERENCES public.st_cloud_jobs(id) ON DELETE CASCADE,
 state text NOT NULL CHECK(state IN ('succeeded','failed','waiting_reconciliation')),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
ALTER TABLE public.st_cloud_result_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_cloud_result_events FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX st_cloud_result_events_cursor ON public.st_cloud_result_events(created_at,id);
CREATE INDEX st_cloud_result_events_job ON public.st_cloud_result_events(job_id,created_at DESC,id DESC);
CREATE FUNCTION public.st_cloud_result_event() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.state IN ('succeeded','failed','waiting_reconciliation') AND (TG_OP='INSERT' OR OLD.state IS DISTINCT FROM NEW.state) THEN
  INSERT INTO public.st_cloud_result_events(job_id,state) VALUES(NEW.id,NEW.state);
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_cloud_result_event AFTER INSERT OR UPDATE OF state ON public.st_cloud_jobs
 FOR EACH ROW EXECUTE FUNCTION public.st_cloud_result_event();

ALTER TABLE public.st_qq_notification_settings ADD COLUMN result_enabled boolean NOT NULL DEFAULT false,
 ADD COLUMN result_activated_at timestamptz;
CREATE OR REPLACE FUNCTION public.st_qq_notification_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,NEW.gateway_id::text,TG_OP,
 jsonb_build_object('enabled',NEW.enabled,'owner_id',NEW.owner_id,'approval_enabled',NEW.approval_enabled,
 'approval_activated_at',NEW.approval_activated_at,'result_enabled',NEW.result_enabled,'result_activated_at',NEW.result_activated_at,
 'previous_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.enabled ELSE NULL END,
 'previous_approval_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.approval_enabled ELSE NULL END,
 'previous_result_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.result_enabled ELSE NULL END));
 RETURN NEW;
END; $$;
CREATE FUNCTION public.st_qq_result_feed(p_key text,p_sender text,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_ids uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid; start_at timestamptz; result jsonb;
BEGIN
 g:=public.st_qq_notification_access(p_key,p_sender);
 SELECT result_activated_at INTO start_at FROM public.st_qq_notification_settings WHERE gateway_id=g AND result_enabled;
 IF start_at IS NULL THEN RAISE EXCEPTION 'Result notification access disabled' USING ERRCODE='42501'; END IF;
 IF (p_after IS NULL)<>(p_after_id IS NULL) OR p_after>now()+interval '1 minute' OR cardinality(p_ids)>10 THEN RAISE EXCEPTION 'Invalid cursor or event ids'; END IF;
 SELECT jsonb_build_object('enabled',true,'events',coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at,x.id),'[]'::jsonb)) INTO result
 FROM (SELECT e.id,e.job_id,e.state,e.created_at
 FROM public.st_cloud_result_events e JOIN public.st_cloud_jobs j ON j.id=e.job_id AND j.state=e.state
 JOIN public.st_projects p ON p.id=j.project_id AND p.deleted_at IS NULL AND p.state='active'
 JOIN public.st_tasks t ON t.id=j.task_id AND t.deleted_at IS NULL
 WHERE e.created_at>=start_at AND (p_after IS NULL OR (e.created_at,e.id)>(p_after,p_after_id))
 AND (p_ids IS NULL OR e.id=ANY(p_ids))
 AND NOT EXISTS(SELECT 1 FROM public.st_subtitle_requests r WHERE r.job_id=j.id AND r.deleted_at IS NOT NULL)
 AND NOT EXISTS(SELECT 1 FROM public.st_cloud_result_events newer WHERE newer.job_id=e.job_id AND (newer.created_at,newer.id)>(e.created_at,e.id))
 ORDER BY e.created_at,e.id LIMIT 50) x;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.st_my_work(text,integer),public.st_task_work_context(uuid),public.st_task_deadline(uuid,timestamptz),public.st_cloud_result_event(),public.st_qq_result_feed(text,text,timestamptz,uuid,uuid[]) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_my_work(text,integer),public.st_task_work_context(uuid),public.st_task_deadline(uuid,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.st_qq_result_feed(text,text,timestamptz,uuid,uuid[]) TO anon;
INSERT INTO public.st_schema_migrations(version) VALUES('048_priority_features');
COMMIT;
