BEGIN;
CREATE FUNCTION public.st_cloud_claim_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.released_at IS NULL AND EXISTS(SELECT 1 FROM public.st_cloud_jobs WHERE task_id=NEW.task_id AND state IN ('uploading','queued','running','waiting_configuration','waiting_reconciliation')) THEN
  RAISE EXCEPTION '云端初稿尚在生成，完成后可认领校对；目前可以先认领项目担任负责人。';
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_cloud_claim_guard BEFORE INSERT OR UPDATE OF released_at ON public.st_claims FOR EACH ROW EXECUTE FUNCTION public.st_cloud_claim_guard();
REVOKE ALL ON FUNCTION public.st_cloud_claim_guard() FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO public.st_schema_migrations(version) VALUES('024_cloud_claim_guard');
COMMIT;
