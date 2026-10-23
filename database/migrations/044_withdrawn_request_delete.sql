BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.st_subtitle_requests ADD COLUMN deleted_at timestamptz, ADD COLUMN deleted_by uuid REFERENCES public.st_members(id);
ALTER TABLE public.st_subtitle_requests ADD CONSTRAINT st_request_delete_withdrawn CHECK(deleted_at IS NULL OR (state='withdrawn' AND job_id IS NULL));
CREATE FUNCTION public.st_subtitle_requests_list(p_request uuid,p_deleted boolean) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式组员可查看申请' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('qq_status','not_configured','requests',coalesce((SELECT jsonb_agg(to_jsonb(v) ORDER BY v.created_at DESC) FROM (
 SELECT r.id,r.requested_by,r.deleted_at,(public.st_owner() OR r.requested_by=public.st_actor()) AS can_delete,m.display_name AS submitter,r.stream_title,r.timestamp_label,r.notes,r.file_name,r.byte_size,r.mime_type,r.declared_seconds,r.state,r.review_note,r.reviewed_at,r.job_id,r.created_at,r.upload_until,
 j.state AS job_state,j.source_expires_at,j.max_video_seconds,j.max_text_requests,j.max_secondary_requests
 FROM public.st_subtitle_requests r JOIN public.st_members m ON m.id=r.requested_by LEFT JOIN public.st_cloud_jobs j ON j.id=r.job_id
 WHERE (r.deleted_at IS NOT NULL)=p_deleted AND (public.st_owner() OR r.requested_by=public.st_actor()) AND (p_request IS NULL OR r.id=p_request) ORDER BY r.created_at DESC LIMIT 100) v),'[]'::jsonb));
END; $$;


CREATE OR REPLACE FUNCTION public.st_subtitle_requests_view(p_request uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT public.st_subtitle_requests_list(p_request,false)
$$;
CREATE FUNCTION public.st_subtitle_requests_trash() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT public.st_subtitle_requests_list(NULL,true)
$$;
CREATE FUNCTION public.st_subtitle_request_set_deleted(p_request uuid,p_deleted boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r public.st_subtitle_requests;
BEGIN
 SELECT * INTO r FROM public.st_subtitle_requests WHERE id=p_request FOR UPDATE;
 IF NOT public.st_formal_member() OR r.id IS NULL OR (r.requested_by IS DISTINCT FROM public.st_actor() AND NOT public.st_owner()) THEN
  RAISE EXCEPTION '无此申请权限' USING ERRCODE='42501';
 END IF;
 IF p_deleted IS NULL OR r.state<>'withdrawn' OR r.job_id IS NOT NULL THEN RAISE EXCEPTION '仅已撤回且未生成云任务的申请可删除或恢复'; END IF;
 IF (r.deleted_at IS NOT NULL)=p_deleted THEN RETURN; END IF;
 UPDATE public.st_subtitle_requests SET deleted_at=CASE WHEN p_deleted THEN clock_timestamp() END,deleted_by=CASE WHEN p_deleted THEN public.st_actor() END,updated_at=clock_timestamp() WHERE id=r.id;
END; $$;
REVOKE ALL ON FUNCTION public.st_subtitle_requests_list(uuid,boolean),public.st_subtitle_requests_trash(),public.st_subtitle_request_set_deleted(uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_subtitle_requests_trash(),public.st_subtitle_request_set_deleted(uuid,boolean) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('044_withdrawn_request_delete');
COMMIT;
