BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.st_subtitle_requests DROP CONSTRAINT st_request_delete_withdrawn;
ALTER TABLE public.st_subtitle_requests ADD CONSTRAINT st_request_delete_terminal CHECK(deleted_at IS NULL OR (state='withdrawn' AND job_id IS NULL) OR (state='approved' AND job_id IS NOT NULL));
CREATE OR REPLACE FUNCTION public.st_subtitle_requests_list(p_request uuid,p_deleted boolean) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可查看申请' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('qq_status','not_configured','requests',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (
 SELECT r.id,r.requested_by,r.deleted_at,((r.state='withdrawn' AND r.job_id IS NULL AND (public.st_owner() OR r.requested_by=public.st_actor())) OR (r.state='approved' AND public.st_owner() AND j.state='cancelled' AND (j.lease_until IS NULL OR j.lease_until<=now()))) AS can_delete,m.display_name AS submitter,r.stream_title,r.timestamp_label,r.notes,r.file_name,r.byte_size,r.mime_type,r.declared_seconds,r.state,r.review_note,r.reviewed_at,r.job_id,r.created_at,r.upload_until,
 j.state AS job_state,j.source_expires_at,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests
 FROM public.st_subtitle_requests r JOIN public.st_members m ON m.id=r.requested_by LEFT JOIN public.st_cloud_jobs j ON j.id=r.job_id
 WHERE (r.deleted_at IS NOT NULL)=p_deleted AND (public.st_owner() OR r.requested_by=public.st_actor()) AND (p_request IS NULL OR r.id=p_request) ORDER BY r.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $$;


CREATE OR REPLACE FUNCTION public.st_subtitle_request_set_deleted(p_request uuid,p_deleted boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests; j public.st_cloud_jobs;
BEGIN
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF NOT public.st_formal_member() OR r.id IS NULL OR (r.requested_by IS DISTINCT FROM public.st_actor() AND NOT public.st_owner()) THEN
  RAISE EXCEPTION '无此申请权限' USING ERRCODE='42501';
 END IF;
 IF p_deleted IS NULL THEN RAISE EXCEPTION '删除参数错误'; END IF;
 IF r.state='approved' AND r.job_id IS NOT NULL THEN
  IF NOT public.st_owner() THEN RAISE EXCEPTION '已批准申请仅组长可删除或恢复' USING ERRCODE='42501'; END IF;
  SELECT * INTO j FROM public.st_cloud_jobs WHERE id=r.job_id FOR UPDATE;
  IF j.id IS NULL OR j.state<>'cancelled' OR (j.lease_until IS NOT NULL AND j.lease_until>now()) THEN RAISE EXCEPTION '请先取消云任务并等待执行租约结束，再删除申请'; END IF;
 ELSIF r.state<>'withdrawn' OR r.job_id IS NOT NULL THEN RAISE EXCEPTION '仅已撤回申请或云任务已取消的已批准申请可删除'; END IF;
 IF (r.deleted_at IS NOT NULL)=p_deleted THEN RETURN; END IF;
 UPDATE public.st_subtitle_requests SET deleted_at=CASE WHEN p_deleted THEN clock_timestamp() END,deleted_by=CASE WHEN p_deleted THEN public.st_actor() END,updated_at=clock_timestamp() WHERE id=r.id;
END; $$;

CREATE FUNCTION public.st_deleted_request_job_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF (NEW.state<>'cancelled' OR (NEW.lease_until IS NOT NULL AND NEW.lease_until>now())) AND EXISTS(SELECT 1 FROM public.st_subtitle_requests WHERE job_id=NEW.id AND deleted_at IS NOT NULL) THEN
  RAISE EXCEPTION '申请已删除，请先恢复申请后再操作云任务';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_deleted_request_job_guard BEFORE UPDATE ON public.st_cloud_jobs FOR EACH ROW EXECUTE FUNCTION public.st_deleted_request_job_guard();
REVOKE ALL ON FUNCTION public.st_deleted_request_job_guard() FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO public.st_schema_migrations(version) VALUES('047_cancelled_request_delete');
COMMIT;
