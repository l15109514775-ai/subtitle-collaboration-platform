BEGIN;
CREATE FUNCTION public.st_validate_codex_project_name() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.origin='codex' AND NEW.title !~ '^.+｜[^｜]+｜AI字幕初稿$' THEN RAISE EXCEPTION 'Codex 项目须按直播标题｜时间戳｜AI字幕初稿命名'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_codex_project_name BEFORE INSERT OR UPDATE OF title,origin ON public.st_projects FOR EACH ROW EXECUTE FUNCTION public.st_validate_codex_project_name();
CREATE FUNCTION public.st_create_named_codex_project(p_stream_title text,p_timestamp text,p_description text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE title text; BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION '仅组长或受控 Codex 入口可登记 AI 项目'; END IF;
 IF p_stream_title IS NULL OR length(btrim(p_stream_title))=0 OR p_timestamp IS NULL OR length(btrim(p_timestamp)) NOT BETWEEN 1 AND 80 OR strpos(p_timestamp,'｜')>0 THEN RAISE EXCEPTION '请填写直播标题和时间戳'; END IF;
 title:=btrim(p_stream_title)||'｜'||btrim(p_timestamp)||'｜AI字幕初稿';
 IF length(title)>160 THEN RAISE EXCEPTION '直播标题加时间戳后不能超过 160 字，请缩短标题'; END IF;
 RETURN public.st_create_codex_project(title,p_description,title,'对 AI 字幕初稿进行人工听校、修订和复核。');
END; $$;
REVOKE ALL ON FUNCTION public.st_validate_codex_project_name(),public.st_create_named_codex_project(text,text,text) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_create_named_codex_project(text,text,text) TO authenticated;
-- Title verified from YouTube's public oEmbed metadata for NFJIVFSgFUs.
UPDATE public.st_projects SET title='【#猫汰つな新衣装】　すごく！可愛いから！見てー！！【ぶいすぽ / 猫汰つな】｜01:00–11:00｜AI字幕初稿' WHERE id='4e00b597-f065-400a-8947-24fdfd7e0013' AND title='AI 交付试跑 20261020' AND origin='codex';
UPDATE public.st_tasks SET title='【#猫汰つな新衣装】　すごく！可愛いから！見てー！！【ぶいすぽ / 猫汰つな】｜01:00–11:00｜AI字幕初稿' WHERE project_id='4e00b597-f065-400a-8947-24fdfd7e0013' AND title='NFJIVFSgFUs｜01:00–11:00 AI 字幕初稿';
INSERT INTO public.st_schema_migrations(version) VALUES('019_codex_project_names');
COMMIT;
