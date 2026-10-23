-- Pending deployment; preserves existing job history, RLS and ACLs.
BEGIN;
CREATE OR REPLACE FUNCTION public.st_cloud_prepare(p_worker uuid,p_stream_title text,p_timestamp text,p_filename text,p_mime text,p_size bigint,p_sha256 text,p_max_seconds integer DEFAULT 1200,p_max_text integer DEFAULT 400,p_max_secondary integer DEFAULT 40) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE p jsonb;j uuid;
BEGIN
 IF NOT public.st_owner() OR NOT EXISTS(SELECT 1 FROM public.st_cloud_workers WHERE id=p_worker AND public.st_worker_valid(id) AND claimed_jobs<max_jobs) THEN RAISE EXCEPTION '仅组长可派发已批准的云任务'; END IF;
 IF length(p_filename) NOT BETWEEN 1 AND 200 OR p_filename ~ '[/\\]' THEN RAISE EXCEPTION '文件名错误'; END IF;
 IF p_max_seconds IS NULL OR p_max_seconds NOT BETWEEN 1 AND 1200 OR p_max_text IS NULL OR p_max_text NOT BETWEEN 1 AND 400 OR p_max_secondary IS NULL OR p_max_secondary NOT BETWEEN 1 AND 40 THEN RAISE EXCEPTION '云端字幕限额：最长20分钟、文字最多400次、千问最多40次'; END IF;
 p:=public.st_create_named_codex_project(p_stream_title,p_timestamp,'云端 AI 初稿；需成员认领并人工听校。');
 INSERT INTO public.st_cloud_jobs(project_id,task_id,requested_by,worker_id,file_name,mime_type,byte_size,sha256,max_video_seconds,max_text_requests,max_secondary_requests)
 VALUES((p->>'project_id')::uuid,(p->>'task_id')::uuid,public.st_actor(),p_worker,p_filename,p_mime,p_size,p_sha256,p_max_seconds,p_max_text,p_max_secondary) RETURNING id INTO j;
 RETURN jsonb_build_object('job_id',j,'project_id',p->>'project_id','task_id',p->>'task_id','object_prefix',j::text,'chunk_size',4194304,'part_count',(p_size+4194303)/4194304);
END; $$;
INSERT INTO public.st_schema_migrations(version) VALUES ('033_subtitle_20min_limits') ON CONFLICT(version) DO NOTHING;
COMMIT;
