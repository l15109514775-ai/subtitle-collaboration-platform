BEGIN;
ALTER TABLE public.st_uploads ADD COLUMN chunk_size integer CHECK(chunk_size=4194304);
ALTER TABLE public.st_artifacts ADD COLUMN parts jsonb CHECK(parts IS NULL OR jsonb_typeof(parts)='array');
CREATE FUNCTION public.st_upload_begin_chunked(p_task uuid,p_filename text,p_mime text,p_size bigint,p_sha256 text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE result jsonb; BEGIN
 result:=public.st_upload_begin(p_task,p_filename,p_mime,p_size,p_sha256);
 UPDATE public.st_uploads SET chunk_size=4194304 WHERE id=(result->>'id')::uuid;
 RETURN result||jsonb_build_object('chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $$;
CREATE OR REPLACE FUNCTION public.st_storage_write(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE (CASE WHEN u.chunk_size IS NULL THEN u.object_path=p_path ELSE EXISTS(SELECT 1 FROM generate_series(0,((u.byte_size-1)/u.chunk_size)::integer) AS part_no WHERE p_path=u.object_path||'/part-'||lpad(part_no::text,4,'0')) END) AND u.member_id=public.st_actor() AND u.delivery_id IS NULL AND u.expires_at>now() AND t.deleted_at IS NULL AND t.state NOT IN ('approved','archived') AND public.st_project_access(u.project_id) AND EXISTS(SELECT 1 FROM public.st_claims c WHERE c.task_id=t.id AND c.member_id=u.member_id AND c.released_at IS NULL))
$$;
CREATE OR REPLACE FUNCTION public.st_storage_read(p_path text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.st_uploads u JOIN public.st_tasks t ON t.id=u.task_id WHERE (CASE WHEN u.chunk_size IS NULL THEN u.object_path=p_path ELSE EXISTS(SELECT 1 FROM generate_series(0,((u.byte_size-1)/u.chunk_size)::integer) AS part_no WHERE p_path=u.object_path||'/part-'||lpad(part_no::text,4,'0')) END) AND public.st_project_access(u.project_id) AND t.deleted_at IS NULL AND (u.delivery_id IS NOT NULL OR (u.member_id=public.st_actor() AND u.expires_at>now())))
$$;
CREATE OR REPLACE FUNCTION public.st_upload_finish(p_upload uuid,p_notes text DEFAULT '') RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE u public.st_uploads; t public.st_tasks; o storage.objects; d uuid; v integer; parent uuid; a uuid:=public.st_actor(); part_no integer; part_path text; part_bytes bigint; part_list jsonb:='[]'::jsonb; BEGIN
 SELECT * INTO u FROM public.st_uploads WHERE id=p_upload FOR UPDATE;
 IF u.id IS NULL OR a IS NULL OR u.member_id<>a THEN RAISE EXCEPTION '无此上传权限'; END IF;
 IF u.delivery_id IS NOT NULL THEN RETURN u.delivery_id; END IF;
 SELECT * INTO t FROM public.st_tasks WHERE id=u.task_id FOR UPDATE;
 IF t.deleted_at IS NOT NULL OR NOT public.st_project_access(t.project_id) OR t.state IN ('approved','archived') OR u.expires_at<=now() OR NOT EXISTS(SELECT 1 FROM public.st_claims WHERE task_id=t.id AND member_id=a AND released_at IS NULL) THEN RAISE EXCEPTION '任务或上传会话已失效'; END IF;
 IF u.chunk_size IS NOT NULL THEN
  FOR part_no IN 0..((u.byte_size-1)/u.chunk_size)::integer LOOP
   part_path:=u.object_path||'/part-'||lpad(part_no::text,4,'0');
   part_bytes:=least(u.chunk_size,u.byte_size-part_no::bigint*u.chunk_size);
   SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=part_path;
   IF o.id IS NULL OR (o.owner_id IS DISTINCT FROM (SELECT auth.uid()) AND o.owner_id IS DISTINCT FROM '') OR o.created_at<u.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>part_bytes OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件分片未完整上传，或实际大小/类型不符'; END IF;
   part_list:=part_list||jsonb_build_array(jsonb_build_object('path',part_path,'byte_size',part_bytes));
  END LOOP;
 ELSE
 SELECT * INTO o FROM storage.objects WHERE bucket_id='subtitle-deliveries' AND name=u.object_path;
 IF o.id IS NULL OR (o.owner_id IS DISTINCT FROM (SELECT auth.uid()) AND o.owner_id IS DISTINCT FROM '') OR o.created_at<u.created_at OR coalesce((o.metadata->>'size')::bigint,-1)<>u.byte_size OR o.metadata->>'mimetype' IS DISTINCT FROM u.mime_type THEN RAISE EXCEPTION '文件尚未完整上传，或实际大小/类型不符'; END IF;
 END IF;
 INSERT INTO public.st_artifacts(id,project_id,object_path,file_name,sha256,byte_size,mime_type,uploaded_by,storage_etag,parts) VALUES(u.id,u.project_id,u.object_path,u.file_name,u.sha256,u.byte_size,u.mime_type,a,CASE WHEN u.chunk_size IS NULL THEN o.metadata->>'eTag' END,CASE WHEN u.chunk_size IS NOT NULL THEN part_list END);
 SELECT coalesce(max(version_no),0)+1 INTO v FROM public.st_deliveries WHERE task_id=t.id;
 SELECT id INTO parent FROM public.st_deliveries WHERE task_id=t.id ORDER BY version_no DESC LIMIT 1;
 INSERT INTO public.st_deliveries(task_id,project_id,version_no,source,submitted_by,parent_id,artifact_id,content_sha256,notes) VALUES(t.id,t.project_id,v,'manual',a,parent,u.id,u.sha256,p_notes) RETURNING id INTO d;
 UPDATE public.st_tasks SET state='submitted' WHERE id=t.id;
 UPDATE public.st_uploads SET delivery_id=d WHERE id=u.id;
 RETURN d;
END; $$;


REVOKE ALL ON FUNCTION public.st_upload_begin_chunked(uuid,text,text,bigint,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.st_upload_begin_chunked(uuid,text,text,bigint,text) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('011_chunked_media');
COMMIT;
