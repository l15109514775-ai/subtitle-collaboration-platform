BEGIN;
CREATE OR REPLACE FUNCTION public.st_cloud_worker_reset_claims(
 p_worker uuid,p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $function$
DECLARE w public.st_cloud_workers;
BEGIN
 IF NOT public.st_owner() THEN
  RAISE EXCEPTION '仅组长可重置领取计数' USING ERRCODE='42501';
 END IF;
 IF p_reason IS NULL OR char_length(btrim(p_reason)) NOT BETWEEN 1 AND 300 THEN
  RAISE EXCEPTION '请填写1至300字的操作原因';
 END IF;
 SELECT * INTO w FROM public.st_cloud_workers
  WHERE id=p_worker AND deleted_at IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION '执行器不存在或已删除'; END IF;
 IF EXISTS(SELECT 1 FROM public.st_cloud_jobs
   WHERE worker_id=p_worker AND state IN ('uploading','queued','running','waiting_configuration','waiting_reconciliation')) THEN
  RAISE EXCEPTION '执行器仍有未完成任务，不能重置领取计数';
 END IF;
 IF w.claimed_jobs<>0 THEN
  UPDATE public.st_cloud_workers SET claimed_jobs=0 WHERE id=w.id;
  INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
  VALUES(auth.uid(),session_user,'st_cloud_workers',w.id::text,'UPDATE',
   jsonb_build_object('action','worker_reset_claims','before_claimed_jobs',w.claimed_jobs,
    'after_claimed_jobs',0,'max_jobs',w.max_jobs,'reason',btrim(p_reason)));
 END IF;
 RETURN jsonb_build_object('id',w.id,'claimed_jobs',0,'max_jobs',w.max_jobs);
END; $function$;
REVOKE ALL ON FUNCTION public.st_cloud_worker_reset_claims(uuid,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_cloud_worker_reset_claims(uuid,text) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('051_api_worker_reset_claims');
COMMIT;
