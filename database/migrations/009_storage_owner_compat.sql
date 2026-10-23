BEGIN;
-- CloudBase Storage currently persists owner_id as an empty string. The immutable random object path remains bound to the caller's upload reservation by INSERT RLS, and finish checks the caller, active claim, size, MIME, and creation time.
CREATE OR REPLACE FUNCTION public.st_upload_finish(p_upload uuid,p_notes text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u public.st_uploads; t public.st_tasks; o storage.objects; d uuid; v integer; parent uuid; a uuid:=public.st_actor(); BEGIN
 SELECT * INTO u FROM public.st_uploads WHERE id=p_upload FOR UPDATE;
 IF u.id IS NULL OR a IS NULL OR u.member_id<>a THEN RAISE EXCEPTION '无此上传权限'; END IF;
 IF u.delivery_id IS NOT NULL THEN RETURN u.delivery_id; END IF;
 SELECT * INTO t FROM public.st_tasks WHERE id=u.task_id FOR UPDATE;
 IF t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR t.state IN ('approved','archived') OR u.expires_at<=now() OR NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '任务或上传会话已失效'; END IF;
 SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=u.object_path;
 IF o.id IS NULL OR (o.owner_id IS DISTINCT FROM (SELECT auth.uid()) AND o.owner_id IS DISTINCT FROM '') OR o.created_at<u.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>u.byte_size OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件尚未完整上传，或实际大小/类型不符'; END IF;
 INSERT INTO public.st_artifacts(id,project_id,object_path,file_name,sha256,byte_size,mime_type,uploaded_by,storage_etag) VALUES(u.id,u.project_id,u.object_path,u.file_name,u.sha256,u.byte_size,u.mime_type,a,o.metadata->>'eTag');
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,parent_id,artifact_id,content_sha256,notes) VALUES(t.id,t.project_id,v,'manual',a,parent,u.id,u.sha256,p_notes) RETURNING id INTO d;
 UPDATE public.st_tasks SET state='submitted' WHERE id=t.id;
 UPDATE public.st_uploads SET delivery_id=d WHERE id=u.id;
 RETURN d;
END; $$;

INSERT INTO public.st_schema_migrations(version) VALUES('009_storage_owner_compat');
COMMIT;