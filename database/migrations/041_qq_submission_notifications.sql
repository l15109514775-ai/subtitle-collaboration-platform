-- Review candidate. Defaults disabled. No existing business RPC is replaced.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.st_schema_migrations WHERE version='040_qq_bridge')
 OR NOT EXISTS(SELECT 1 FROM public.st_schema_migrations WHERE version='039_member_subtitle_requests')
 THEN RAISE EXCEPTION 'Expected request and QQ bridge migrations'; END IF;
END; $$;
CREATE TABLE public.st_qq_notification_settings (
 gateway_id uuid PRIMARY KEY REFERENCES public.st_qq_gateways(id),
 owner_id uuid NOT NULL REFERENCES public.st_members(id),
 enabled boolean NOT NULL DEFAULT false,
 activated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.st_qq_notification_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_qq_notification_settings FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.st_qq_notification_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,NEW.gateway_id::text,TG_OP,
 jsonb_build_object('enabled',NEW.enabled,'owner_id',NEW.owner_id,'previous_enabled',CASE WHEN TG_OP='UPDATE' THEN OLD.enabled ELSE NULL END));
 RETURN NEW;
END; $$;
CREATE TRIGGER st_qq_notification_settings_audit AFTER INSERT OR UPDATE ON public.st_qq_notification_settings
 FOR EACH ROW EXECUTE FUNCTION public.st_qq_notification_audit();

CREATE FUNCTION public.st_qq_notification_access(p_key text,p_sender text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid;
BEGIN
 IF p_key IS NULL OR p_key !~ '^[0-9a-f]{64}$' OR p_sender IS NULL OR p_sender !~ '^[0-9a-f]{64}$'
 THEN RAISE EXCEPTION 'Notification access denied' USING ERRCODE='42501'; END IF;
 SELECT s.gateway_id INTO g FROM public.st_qq_notification_settings s
 JOIN public.st_qq_gateways q ON q.id=s.gateway_id AND q.active
 JOIN public.st_qq_links l ON l.gateway_id=q.id AND l.member_id=s.owner_id AND l.sender_hash=p_sender
 JOIN public.st_members m ON m.id=s.owner_id AND m.state='active'
 WHERE s.enabled AND q.key_hash=encode(sha256(convert_to(p_key,'UTF8')),'hex')
 AND EXISTS(SELECT 1 FROM public.st_member_roles r WHERE r.member_id=m.id AND r.role_code='owner');
 IF g IS NULL THEN RAISE EXCEPTION 'Notification access denied' USING ERRCODE='42501'; END IF;
 RETURN g;
END; $$;

CREATE FUNCTION public.st_qq_notification_feed(p_key text,p_sender text,p_after timestamptz DEFAULT NULL,p_after_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE g uuid; start_at timestamptz; result jsonb;
BEGIN
 g:=public.st_qq_notification_access(p_key,p_sender);
 SELECT activated_at INTO start_at FROM public.st_qq_notification_settings WHERE gateway_id=g;
 IF (p_after IS NULL)<>(p_after_id IS NULL) THEN RAISE EXCEPTION 'Complete cursor required'; END IF;
 IF p_after>now()+interval '1 minute' THEN RAISE EXCEPTION 'Invalid cursor'; END IF;
 -- Minimal metadata only: no title/name, notes, object keys, URLs, media, instructions or credentials.
 SELECT jsonb_build_object('enabled',true,'events',coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at,x.id),'[]'::jsonb)) INTO result
 FROM (SELECT n.id,n.request_id,n.created_at FROM public.st_subtitle_notifications n
 JOIN public.st_subtitle_requests r ON r.id=n.request_id AND r.state='pending'
 WHERE n.event='submitted' AND n.created_at>=start_at
 AND (p_after IS NULL OR (n.created_at,n.id)>(p_after,p_after_id))
 ORDER BY n.created_at,n.id LIMIT 50) x;
 RETURN result;
END; $$;

CREATE FUNCTION public.st_qq_notification_configure(p_gateway uuid,p_enabled boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor();
BEGIN
 IF NOT public.st_owner() OR p_enabled IS NULL THEN RAISE EXCEPTION 'Owner required' USING ERRCODE='42501'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.st_qq_links l JOIN public.st_qq_gateways g ON g.id=l.gateway_id AND g.active
 WHERE l.gateway_id=p_gateway AND l.member_id=a) THEN RAISE EXCEPTION 'Owner QQ binding required' USING ERRCODE='42501'; END IF;
 INSERT INTO public.st_qq_notification_settings(gateway_id,owner_id,enabled) VALUES(p_gateway,a,p_enabled)
 ON CONFLICT(gateway_id) DO UPDATE SET owner_id=a,enabled=p_enabled,
 activated_at=CASE WHEN NOT st_qq_notification_settings.enabled AND p_enabled THEN now() ELSE st_qq_notification_settings.activated_at END;
 RETURN jsonb_build_object('enabled',p_enabled,'new_submissions_only',true);
END; $$;
REVOKE ALL ON FUNCTION public.st_qq_notification_audit(),public.st_qq_notification_access(text,text),public.st_qq_notification_feed(text,text,timestamptz,uuid),public.st_qq_notification_configure(uuid,boolean) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_qq_notification_feed(text,text,timestamptz,uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.st_qq_notification_configure(uuid,boolean) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('041_qq_submission_notifications');
COMMIT;
