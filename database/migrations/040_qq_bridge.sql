BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
-- New endpoints only; existing web sessions/permissions are not impersonated.
CREATE TABLE public.st_qq_gateways(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), app_id text NOT NULL UNIQUE,
 key_hash text NOT NULL UNIQUE CHECK(key_hash ~ '^[0-9a-f]{64}$'), active boolean NOT NULL DEFAULT true,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_qq_links(
 gateway_id uuid NOT NULL REFERENCES public.st_qq_gateways(id),
 sender_hash text NOT NULL CHECK(sender_hash ~ '^[0-9a-f]{64}$'),
 member_id uuid NOT NULL REFERENCES public.st_members(id), linked_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(gateway_id,sender_hash), UNIQUE(gateway_id,member_id));
CREATE TABLE public.st_qq_codes(
 gateway_id uuid NOT NULL REFERENCES public.st_qq_gateways(id),
 code_hash text PRIMARY KEY CHECK(code_hash ~ '^[0-9a-f]{64}$'),
 sender_hash text NOT NULL, expires_at timestamptz NOT NULL, used_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_qq_rate(
 gateway_id uuid NOT NULL REFERENCES public.st_qq_gateways(id),sender_hash text NOT NULL,
 window_at timestamptz NOT NULL, hits integer NOT NULL,PRIMARY KEY(gateway_id,sender_hash));
ALTER TABLE public.st_qq_gateways ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.st_qq_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.st_qq_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.st_qq_rate ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_qq_gateways,public.st_qq_links,public.st_qq_codes,public.st_qq_rate FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.st_qq_gateway_register(p_app text,p_hash text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid;
BEGIN
 IF NOT public.st_owner() OR p_app !~ '^[0-9]{5,30}$' OR p_hash !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'Owner and valid gateway required' USING ERRCODE='42501'; END IF;
 INSERT INTO public.st_qq_gateways(app_id,key_hash) VALUES(p_app,p_hash) RETURNING id INTO g;
 RETURN g;
END; $$;
CREATE FUNCTION public.st_qq_gateway_disable(p_gateway uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF NOT public.st_owner() THEN RAISE EXCEPTION 'Owner required' USING ERRCODE='42501'; END IF;
 UPDATE public.st_qq_gateways SET active=false WHERE id=p_gateway;
END; $$;

-- Only this gateway-authenticated function accepts a sender identity. It cannot
-- change projects, submissions, claims, reviews, points, or auth subjects.
CREATE FUNCTION public.st_qq_dispatch(p_key text,p_sender text,p_action text,p_arg text DEFAULT '') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid; a uuid; h text; c text; n integer; task_id uuid; result jsonb;
BEGIN
 IF p_key IS NULL OR p_key !~ '^[0-9a-f]{64}$' OR p_sender IS NULL OR p_sender !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'Gateway unavailable' USING ERRCODE='42501'; END IF;
 SELECT id INTO g FROM public.st_qq_gateways WHERE active AND key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex');
 IF g IS NULL THEN RAISE EXCEPTION 'Gateway unavailable' USING ERRCODE='42501'; END IF;
 IF p_action IS NULL OR p_action NOT IN ('bind','status','projects','mine','tasks','detail','unlink') OR length(coalesce(p_arg,''))>200
 THEN RAISE EXCEPTION 'Unsupported operation'; END IF;
 INSERT INTO public.st_qq_rate VALUES(g,p_sender,date_trunc('minute',clock_timestamp()),1)
 ON CONFLICT(gateway_id,sender_hash) DO UPDATE SET window_at=EXCLUDED.window_at,
 hits=CASE WHEN st_qq_rate.window_at=EXCLUDED.window_at THEN st_qq_rate.hits+1 ELSE 1 END RETURNING hits INTO n;
 -- Return (not raise) so denied attempts also retain their counter.
 IF n>20 THEN RETURN jsonb_build_object('error','too_many_requests'); END IF;
 SELECT l.member_id INTO a FROM public.st_qq_links l JOIN public.st_members m ON m.id=l.member_id AND m.state='active'
 WHERE l.gateway_id=g AND l.sender_hash=p_sender;
 IF p_action='bind' THEN
  IF a IS NOT NULL THEN RETURN jsonb_build_object('state','already_bound'); END IF;
  UPDATE public.st_qq_codes SET used_at=now() WHERE gateway_id=g AND sender_hash=p_sender AND used_at IS NULL;
  DELETE FROM public.st_qq_codes WHERE expires_at<now()-interval '1 day';
  c:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  INSERT INTO public.st_qq_codes(gateway_id,code_hash,sender_hash,expires_at)
  VALUES(g,encode(sha256(convert_to(c,'UTF8')),'hex'),p_sender,now()+interval '5 minutes');
  RETURN jsonb_build_object('state','pending','code',c,'expires_in',300);
 END IF;
 IF a IS NULL THEN RETURN jsonb_build_object('state','unbound'); END IF;
 IF p_action='unlink' THEN
  DELETE FROM public.st_qq_links WHERE gateway_id=g AND sender_hash=p_sender;
  RETURN jsonb_build_object('state','unbound');
 END IF;
 IF p_action='status' THEN RETURN jsonb_build_object('state','bound','name',(SELECT display_name FROM public.st_members WHERE id=a)); END IF;
 IF p_action='detail' THEN
  IF p_arg IS NULL OR p_arg !~ '^[0-9a-fA-F-]{36}$' THEN RETURN jsonb_build_object('error','invalid_task'); END IF;
  BEGIN task_id:=p_arg::uuid; EXCEPTION WHEN invalid_text_representation THEN RETURN jsonb_build_object('error','invalid_task'); END;
 END IF;
 -- Current membership, suspension, project blocks and deletions are checked on
 -- EVERY query. No table-wide board/version/content export is granted to QQ.
 WITH accessible AS (
  SELECT p.id,p.title FROM public.st_projects p WHERE p.deleted_at IS NULL AND p.state='active'
   AND (EXISTS(SELECT 1 FROM public.st_member_roles r WHERE r.member_id=a AND r.role_code='owner')
    OR (EXISTS(SELECT 1 FROM public.st_project_members pm WHERE pm.project_id=p.id AND pm.member_id=a)
     AND NOT EXISTS(SELECT 1 FROM public.st_project_blocks b WHERE b.project_id=p.id AND b.member_id=a)))
 ), selected AS (
  SELECT t.id,t.title,t.state,t.kind,t.project_id,p.title AS project_title,
   CASE WHEN p_action='detail' THEN left(t.description,1000) ELSE NULL END AS description,
   EXISTS(SELECT 1 FROM public.st_claims c WHERE c.task_id=t.id AND c.member_id=a AND c.released_at IS NULL) AS mine
  FROM public.st_tasks t JOIN accessible p ON p.id=t.project_id
  WHERE t.deleted_at IS NULL AND
   CASE p_action WHEN 'mine' THEN EXISTS(SELECT 1 FROM public.st_claims c WHERE c.task_id=t.id AND c.member_id=a AND c.released_at IS NULL)
   WHEN 'tasks' THEN t.state='open' WHEN 'detail' THEN t.id=task_id ELSE false END
  ORDER BY t.created_at DESC,t.id LIMIT 20
 ) SELECT CASE WHEN p_action='projects' THEN jsonb_build_object('projects',coalesce((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT * FROM accessible ORDER BY title,id LIMIT 20)x),'[]'::jsonb))
 ELSE jsonb_build_object('tasks',coalesce((SELECT jsonb_agg(to_jsonb(s)) FROM selected s),'[]'::jsonb)) END INTO result;
 RETURN result;
END; $$;

CREATE FUNCTION public.st_qq_link_status() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); BEGIN
 IF a IS NULL THEN RAISE EXCEPTION 'Active member required' USING ERRCODE='42501'; END IF;
 RETURN jsonb_build_object('links',coalesce((SELECT jsonb_agg(jsonb_build_object('gateway',g.id,'app_id',g.app_id,'active',g.active,'linked_at',l.linked_at)) FROM public.st_qq_links l JOIN public.st_qq_gateways g ON g.id=l.gateway_id WHERE l.member_id=a),'[]'::jsonb));
END; $$;
CREATE FUNCTION public.st_qq_link_confirm(p_code text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); c public.st_qq_codes; app text; BEGIN
 IF a IS NULL OR p_code IS NULL OR p_code !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION '请登录正式成员账号并输入有效绑定码'; END IF;
 SELECT * INTO c FROM public.st_qq_codes WHERE code_hash=encode(sha256(convert_to(p_code,'UTF8')),'hex') AND used_at IS NULL AND expires_at>now() FOR UPDATE;
 IF c.code_hash IS NULL THEN RAISE EXCEPTION '绑定码无效、已使用或已过期'; END IF;
 SELECT app_id INTO app FROM public.st_qq_gateways WHERE id=c.gateway_id AND active;
 IF app IS NULL THEN RAISE EXCEPTION '机器人连接已停用'; END IF;
 -- Refuse silent replacement on either side. Explicit unlink first.
 IF EXISTS(SELECT 1 FROM public.st_qq_links WHERE gateway_id=c.gateway_id AND (member_id=a OR sender_hash=c.sender_hash))
 THEN RAISE EXCEPTION '账号或 QQ 已有绑定，请先解除原绑定'; END IF;
 INSERT INTO public.st_qq_links(gateway_id,sender_hash,member_id) VALUES(c.gateway_id,c.sender_hash,a);
 UPDATE public.st_qq_codes SET used_at=now() WHERE code_hash=c.code_hash;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,'st_qq_links',a::text,'INSERT',jsonb_build_object('action','qq_link_confirm','gateway',c.gateway_id));
 RETURN jsonb_build_object('state','bound','app_id',app);
END; $$;
CREATE FUNCTION public.st_qq_link_remove(p_gateway uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 IF public.st_actor() IS NULL THEN RAISE EXCEPTION 'Active member required'; END IF;
 DELETE FROM public.st_qq_links WHERE gateway_id=p_gateway AND member_id=public.st_actor();
 IF FOUND THEN
  INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
  VALUES(auth.uid(),session_user,'st_qq_links',public.st_actor()::text,'DELETE',jsonb_build_object('action','qq_link_remove','gateway',p_gateway));
 END IF;
END; $$;
REVOKE ALL ON FUNCTION public.st_qq_gateway_register(text,text),public.st_qq_gateway_disable(uuid),public.st_qq_dispatch(text,text,text,text),public.st_qq_link_status(),public.st_qq_link_confirm(text),public.st_qq_link_remove(uuid) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_qq_dispatch(text,text,text,text) TO anon;
GRANT EXECUTE ON FUNCTION public.st_qq_gateway_register(text,text),public.st_qq_gateway_disable(uuid),public.st_qq_link_status(),public.st_qq_link_confirm(text),public.st_qq_link_remove(uuid) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('040_qq_bridge');
COMMIT;
