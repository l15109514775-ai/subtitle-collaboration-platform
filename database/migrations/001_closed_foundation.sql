BEGIN;
CREATE TABLE public.st_schema_migrations(version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_members(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), auth_subject text UNIQUE NOT NULL,
 display_name text NOT NULL CHECK(length(display_name) BETWEEN 1 AND 80),
 state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','suspended')),
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_roles(code text PRIMARY KEY, label text NOT NULL);
INSERT INTO public.st_roles VALUES ('owner','组长'),('manager','项目管理'),('reviewer','审核'),('contributor','成员'),('bot','自动化服务');
CREATE TABLE public.st_member_roles(
 member_id uuid NOT NULL REFERENCES public.st_members(id), role_code text NOT NULL REFERENCES public.st_roles(code),
 granted_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(member_id,role_code));
CREATE TABLE public.st_projects(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), title text NOT NULL CHECK(length(title) BETWEEN 1 AND 160),
 description text NOT NULL DEFAULT '', state text NOT NULL DEFAULT 'active' CHECK(state IN ('active','archived')),
 created_by uuid REFERENCES public.st_members(id), created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_project_members(
 project_id uuid NOT NULL REFERENCES public.st_projects(id), member_id uuid NOT NULL REFERENCES public.st_members(id),
 role text NOT NULL DEFAULT 'contributor' CHECK(role IN ('lead','reviewer','contributor')),
 joined_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(project_id,member_id));
CREATE TABLE public.st_agent_runs(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.st_projects(id),
 provider text NOT NULL CHECK(provider IN ('codex','astrbot','qqbot','other')),
 external_run_id text NOT NULL, initiated_by uuid REFERENCES public.st_members(id),
 model_label text, summary text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(provider,external_run_id), UNIQUE(id,project_id));
CREATE TABLE public.st_tasks(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.st_projects(id),
 title text NOT NULL CHECK(length(title) BETWEEN 1 AND 160), description text NOT NULL DEFAULT '',
 kind text NOT NULL CHECK(kind IN ('clip','translate','timing','proofread','encode','publish','other')),
 origin text NOT NULL DEFAULT 'manual' CHECK(origin IN ('manual','codex','bot')),
 state text NOT NULL DEFAULT 'open' CHECK(state IN ('open','claimed','submitted','approved','archived')),
 created_by uuid REFERENCES public.st_members(id), due_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,project_id));
CREATE TABLE public.st_claims(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), task_id uuid NOT NULL, project_id uuid NOT NULL,
 member_id uuid NOT NULL REFERENCES public.st_members(id), claimed_at timestamptz NOT NULL DEFAULT now(),
 released_at timestamptz, release_reason text,
 FOREIGN KEY(task_id,project_id) REFERENCES public.st_tasks(id,project_id),
 CHECK(released_at IS NULL OR released_at>=claimed_at));
CREATE UNIQUE INDEX st_one_active_claim ON public.st_claims(task_id) WHERE released_at IS NULL;
CREATE TABLE public.st_artifacts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL REFERENCES public.st_projects(id),
 object_path text NOT NULL CHECK(length(object_path)>0), file_name text NOT NULL,
 sha256 text NOT NULL CHECK(sha256 ~ '^[0-9a-f]{64}$'), byte_size bigint NOT NULL CHECK(byte_size>=0),
 mime_type text NOT NULL DEFAULT 'application/octet-stream', uploaded_by uuid REFERENCES public.st_members(id),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(id,project_id));
CREATE TABLE public.st_deliveries(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), task_id uuid NOT NULL, project_id uuid NOT NULL,
 version_no integer NOT NULL CHECK(version_no>0), source text NOT NULL CHECK(source IN ('manual','codex','bot')),
 submitted_by uuid NOT NULL REFERENCES public.st_members(id), agent_run_id uuid,
 parent_id uuid, artifact_id uuid, content_text text, notes text NOT NULL DEFAULT '',
 content_sha256 text NOT NULL CHECK(content_sha256 ~ '^[0-9a-f]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(task_id,version_no), UNIQUE(id,task_id,project_id),
 FOREIGN KEY(task_id,project_id) REFERENCES public.st_tasks(id,project_id),
 FOREIGN KEY(agent_run_id,project_id) REFERENCES public.st_agent_runs(id,project_id),
 FOREIGN KEY(artifact_id,project_id) REFERENCES public.st_artifacts(id,project_id),
 FOREIGN KEY(parent_id,task_id,project_id) REFERENCES public.st_deliveries(id,task_id,project_id),
 CHECK(content_text IS NOT NULL OR artifact_id IS NOT NULL),
 CHECK((source='manual' AND agent_run_id IS NULL) OR (source<>'manual' AND agent_run_id IS NOT NULL)));
CREATE TABLE public.st_reviews(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), delivery_id uuid NOT NULL, task_id uuid NOT NULL, project_id uuid NOT NULL,
 reviewer_id uuid NOT NULL REFERENCES public.st_members(id), decision text NOT NULL CHECK(decision IN ('approved','changes_requested')),
 feedback text NOT NULL DEFAULT '', created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(delivery_id,task_id,project_id) REFERENCES public.st_deliveries(id,task_id,project_id),
 UNIQUE(delivery_id,reviewer_id), UNIQUE(id,delivery_id,task_id,project_id));
CREATE TABLE public.st_contributions(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), project_id uuid NOT NULL, task_id uuid NOT NULL, delivery_id uuid NOT NULL,
 review_id uuid NOT NULL, member_id uuid NOT NULL REFERENCES public.st_members(id),
 contribution_kind text NOT NULL CHECK(contribution_kind IN ('clip','translate','timing','proofread','encode','publish','other')),
 human_work_description text NOT NULL CHECK(length(human_work_description)>0),
 units numeric(12,2) NOT NULL CHECK(units>0), unit_label text NOT NULL,
 attested_by uuid NOT NULL REFERENCES public.st_members(id), created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(review_id,delivery_id,task_id,project_id) REFERENCES public.st_reviews(id,delivery_id,task_id,project_id),
 UNIQUE(delivery_id,member_id,contribution_kind), UNIQUE(id,member_id));
CREATE TABLE public.st_contribution_revocations(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), contribution_id uuid UNIQUE NOT NULL REFERENCES public.st_contributions(id),
 reason text NOT NULL CHECK(length(reason)>0), revoked_by uuid NOT NULL REFERENCES public.st_members(id),
 created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE public.st_point_entries(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), member_id uuid NOT NULL REFERENCES public.st_members(id),
 contribution_id uuid NOT NULL, points integer NOT NULL CHECK(points<>0),
 reverses_entry_id uuid UNIQUE REFERENCES public.st_point_entries(id),
 reason text NOT NULL CHECK(length(reason)>0), recorded_by uuid NOT NULL REFERENCES public.st_members(id),
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(contribution_id,member_id) REFERENCES public.st_contributions(id,member_id),
 CHECK((reverses_entry_id IS NULL AND points>0) OR (reverses_entry_id IS NOT NULL AND points<0)));
CREATE UNIQUE INDEX st_one_award ON public.st_point_entries(contribution_id) WHERE reverses_entry_id IS NULL;
CREATE TABLE public.st_audit_events(
 id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 actor_subject text, database_role text NOT NULL, entity_table text NOT NULL, entity_id text,
 operation text NOT NULL CHECK(operation IN ('INSERT','UPDATE','DELETE')), metadata jsonb NOT NULL DEFAULT '{}'::jsonb);
CREATE FUNCTION public.st_reject_mutation() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN RAISE EXCEPTION 'Immutable record: create a new version, revocation or reversal instead'; END; $$;
CREATE FUNCTION public.st_audit_change() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r jsonb; BEGIN
 r:=CASE WHEN TG_OP='DELETE' THEN to_jsonb(OLD) ELSE to_jsonb(NEW) END;
 INSERT INTO public.st_audit_events(actor_subject,database_role,entity_table,entity_id,operation,metadata)
 VALUES(auth.uid(),session_user,TG_TABLE_NAME,coalesce(r->>'id',r->>'member_id',r->>'version'),TG_OP,
 jsonb_strip_nulls(jsonb_build_object('project_id',r->>'project_id','task_id',r->>'task_id','state',r->>'state','source',r->>'source')));
 RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
END; $$;
CREATE FUNCTION public.st_validate_review() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.st_deliveries WHERE id=NEW.delivery_id AND submitted_by=NEW.reviewer_id)
 THEN RAISE EXCEPTION 'Self-review is not allowed'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_review_guard BEFORE INSERT ON public.st_reviews FOR EACH ROW EXECUTE FUNCTION public.st_validate_review();
CREATE FUNCTION public.st_validate_contribution() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.st_reviews WHERE id=NEW.review_id AND decision='approved' AND reviewer_id=NEW.attested_by)
 THEN RAISE EXCEPTION 'Contribution requires an approving reviewer attestation'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_contribution_guard BEFORE INSERT ON public.st_contributions FOR EACH ROW EXECUTE FUNCTION public.st_validate_contribution();
CREATE FUNCTION public.st_validate_points() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
 IF NEW.reverses_entry_id IS NULL THEN
  IF EXISTS(SELECT 1 FROM public.st_contribution_revocations WHERE contribution_id=NEW.contribution_id)
  THEN RAISE EXCEPTION 'Cannot award a revoked contribution'; END IF;
 ELSE
  IF NOT EXISTS(SELECT 1 FROM public.st_point_entries p WHERE p.id=NEW.reverses_entry_id AND p.reverses_entry_id IS NULL
   AND p.member_id=NEW.member_id AND p.contribution_id=NEW.contribution_id AND p.points=-NEW.points)
  THEN RAISE EXCEPTION 'Reversal must exactly offset the original award'; END IF;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER st_points_guard BEFORE INSERT ON public.st_point_entries FOR EACH ROW EXECUTE FUNCTION public.st_validate_points();
DO $$ DECLARE t text; BEGIN
 FOREACH t IN ARRAY ARRAY['st_schema_migrations','st_members','st_roles','st_member_roles','st_projects','st_project_members','st_agent_runs','st_tasks','st_claims','st_artifacts','st_deliveries','st_reviews','st_contributions','st_contribution_revocations','st_point_entries','st_audit_events'] LOOP
  EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
  EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC,anon,authenticated,service_role',t);
  IF t<>'st_audit_events' THEN
   EXECUTE format('CREATE TRIGGER st_audit AFTER INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.st_audit_change()',t);
  END IF;
 END LOOP;
 FOREACH t IN ARRAY ARRAY['st_schema_migrations','st_agent_runs','st_artifacts','st_deliveries','st_reviews','st_contributions','st_contribution_revocations','st_point_entries','st_audit_events'] LOOP
  EXECUTE format('CREATE TRIGGER st_immutable BEFORE UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation()',t);
 END LOOP;
END; $$;
REVOKE ALL ON SEQUENCE public.st_audit_events_id_seq FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.st_reject_mutation(),public.st_audit_change(),public.st_validate_review(),public.st_validate_contribution(),public.st_validate_points() FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX st_members_subject ON public.st_members(auth_subject,state);
CREATE INDEX st_project_members_member ON public.st_project_members(member_id,project_id);
CREATE INDEX st_tasks_project ON public.st_tasks(project_id,state);
CREATE INDEX st_claims_member ON public.st_claims(member_id);
CREATE INDEX st_deliveries_task ON public.st_deliveries(task_id,version_no DESC);
CREATE INDEX st_contributions_member ON public.st_contributions(member_id,project_id);
CREATE INDEX st_audit_entity ON public.st_audit_events(entity_table,entity_id,occurred_at DESC);
INSERT INTO public.st_schema_migrations(version) VALUES('001_closed_foundation');
COMMIT;
