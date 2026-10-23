BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.st_point_adjustments(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),request_id uuid NOT NULL UNIQUE,
 contribution_id uuid NOT NULL,member_id uuid NOT NULL,delta integer NOT NULL CHECK(delta BETWEEN -10000 AND 10000 AND delta<>0),
 reason text NOT NULL CHECK(length(btrim(reason)) BETWEEN 5 AND 300),recorded_by uuid NOT NULL REFERENCES public.st_members(id),created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 FOREIGN KEY(contribution_id,member_id) REFERENCES public.st_contributions(id,member_id));
ALTER TABLE public.st_point_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.st_point_adjustments FROM PUBLIC,anon,authenticated,service_role;
CREATE INDEX st_point_adjustment_contribution ON public.st_point_adjustments(contribution_id,created_at);
CREATE TRIGGER st_immutable BEFORE UPDATE OR DELETE ON public.st_point_adjustments FOR EACH ROW EXECUTE FUNCTION public.st_reject_mutation();
CREATE TRIGGER st_audit AFTER INSERT OR UPDATE OR DELETE ON public.st_point_adjustments FOR EACH ROW EXECUTE FUNCTION public.st_audit_change();

CREATE FUNCTION public.st_credit_adjust(p_contribution uuid,p_delta integer,p_reason text,p_request uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE c public.st_contributions; prior public.st_point_adjustments; total bigint; result uuid; a uuid:=public.st_actor();
BEGIN
 IF NOT public.st_owner() OR NOT public.st_formal_member() THEN RAISE EXCEPTION '仅组长可调整积分' USING ERRCODE='42501'; END IF;
 IF p_request IS NULL OR p_delta IS NULL OR p_delta=0 OR p_delta NOT BETWEEN -10000 AND 10000 OR p_reason IS NULL OR length(btrim(p_reason)) NOT BETWEEN 5 AND 300 THEN RAISE EXCEPTION '请输入非零整数积分及5至300字调整原因'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request::text,45));
 SELECT * INTO prior FROM public.st_point_adjustments WHERE request_id=p_request;
 IF prior.id IS NOT NULL THEN
  IF prior.contribution_id IS DISTINCT FROM p_contribution OR prior.delta<>p_delta OR prior.reason<>btrim(p_reason) OR prior.recorded_by<>a THEN RAISE EXCEPTION '该请求编号已使用，请重新打开调整窗口'; END IF;
  RETURN prior.id;
 END IF;
 SELECT * INTO c FROM public.st_contributions WHERE id=p_contribution FOR UPDATE;
 IF c.id IS NULL OR EXISTS(SELECT 1 FROM public.st_contribution_revocations WHERE contribution_id=c.id) OR NOT EXISTS(SELECT 1 FROM public.st_reviews r JOIN public.st_deliveries d ON d.id=r.delivery_id WHERE r.id=c.review_id AND r.decision='approved' AND d.source='manual') THEN RAISE EXCEPTION '仅可调整有效的已审核人工贡献积分'; END IF;
 SELECT coalesce((SELECT sum(points) FROM public.st_point_entries WHERE contribution_id=c.id),0)+coalesce((SELECT sum(delta) FROM public.st_point_adjustments WHERE contribution_id=c.id),0) INTO total;
 IF total+p_delta NOT BETWEEN 0 AND 10000 THEN RAISE EXCEPTION '单份贡献调整后的积分必须在0至10000之间'; END IF;
 INSERT INTO public.st_point_adjustments(request_id,contribution_id,member_id,delta,reason,recorded_by) VALUES(p_request,c.id,c.member_id,p_delta,btrim(p_reason),a) RETURNING id INTO result;
 RETURN result;
END; $$;

CREATE FUNCTION public.st_credit_report(p_member uuid DEFAULT NULL,p_project uuid DEFAULT NULL,p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE a uuid:=public.st_actor(); owner_access boolean:=public.st_owner(); result jsonb;
BEGIN
 IF a IS NULL OR NOT public.st_formal_member() THEN RAISE EXCEPTION '仅正式成员可查看贡献积分' USING ERRCODE='42501'; END IF;
 IF NOT owner_access AND p_member IS NOT NULL AND p_member<>a THEN RAISE EXCEPTION '仅可查看本人积分' USING ERRCODE='42501'; END IF;
 IF p_offset IS NULL OR p_offset<0 OR p_offset>100000 THEN RAISE EXCEPTION '分页参数错误'; END IF;
 WITH scope AS MATERIALIZED(
  SELECT c.*,p.title AS project_title,t.title AS task_title,m.display_name AS member_name,r.display_name AS reviewer_name,d.version_no,d.content_sha256,
   EXISTS(SELECT 1 FROM public.st_contribution_revocations v WHERE v.contribution_id=c.id) AS revoked
  FROM public.st_contributions c JOIN public.st_projects p ON p.id=c.project_id JOIN public.st_tasks t ON t.id=c.task_id
  JOIN public.st_members m ON m.id=c.member_id JOIN public.st_members r ON r.id=c.attested_by JOIN public.st_deliveries d ON d.id=c.delivery_id
  WHERE (owner_access OR c.member_id=a) AND (p_member IS NULL OR c.member_id=p_member)
 ), chosen AS MATERIALIZED(SELECT * FROM scope WHERE p_project IS NULL OR project_id=p_project),
 ledger AS MATERIALIZED(
  SELECT e.id,e.contribution_id,e.member_id,e.points,e.reason,e.recorded_by,e.created_at,CASE WHEN e.reverses_entry_id IS NULL THEN 'award' ELSE 'reversal' END AS entry_type FROM public.st_point_entries e JOIN chosen c ON c.id=e.contribution_id
  UNION ALL SELECT e.id,e.contribution_id,e.member_id,e.delta,e.reason,e.recorded_by,e.created_at,'adjustment' FROM public.st_point_adjustments e JOIN chosen c ON c.id=e.contribution_id
 ), balances AS(SELECT contribution_id,sum(points)::bigint AS points FROM ledger GROUP BY contribution_id)
 SELECT jsonb_build_object('owner',owner_access,'offset',p_offset,'page_size',50,
  'summary',jsonb_build_object('points',coalesce((SELECT sum(points) FROM ledger),0),'verified',(SELECT count(*) FROM chosen WHERE NOT revoked),'revoked',(SELECT count(*) FROM chosen WHERE revoked),'adjustments',(SELECT count(*) FROM ledger WHERE entry_type='adjustment')),
  'members',coalesce((SELECT jsonb_agg(jsonb_build_object('id',m.id,'name',m.display_name) ORDER BY m.display_name,m.id) FROM public.st_members m WHERE (owner_access OR m.id=a) AND (m.state='active' OR EXISTS(SELECT 1 FROM scope c WHERE c.member_id=m.id))),'[]'::jsonb),
  'projects',coalesce((SELECT jsonb_agg(to_jsonb(p) ORDER BY p.title,p.id) FROM(SELECT DISTINCT project_id AS id,project_title AS title FROM scope)p),'[]'::jsonb),
  'member_totals',coalesce((SELECT jsonb_agg(to_jsonb(m) ORDER BY m.points DESC,m.id) FROM(SELECT c.member_id AS id,c.member_name AS name,count(*) FILTER(WHERE NOT c.revoked) AS verified,coalesce(sum(b.points),0) AS points FROM chosen c LEFT JOIN balances b ON b.contribution_id=c.id GROUP BY c.member_id,c.member_name)m),'[]'::jsonb),
  'ledger_count',(SELECT count(*) FROM ledger),'contribution_count',(SELECT count(*) FROM chosen),
  'ledger',coalesce((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.created_at DESC,e.id DESC) FROM(SELECT l.*,c.member_name,c.project_title,c.task_title,m.display_name AS operator FROM ledger l JOIN chosen c ON c.id=l.contribution_id JOIN public.st_members m ON m.id=l.recorded_by ORDER BY l.created_at DESC,l.id DESC LIMIT 50 OFFSET p_offset)e),'[]'::jsonb),
  'contributions',coalesce((SELECT jsonb_agg(to_jsonb(c) ORDER BY c.created_at DESC,c.id DESC) FROM(SELECT c.*,coalesce(b.points,0) AS points FROM chosen c LEFT JOIN balances b ON b.contribution_id=c.id ORDER BY c.created_at DESC,c.id DESC LIMIT 50 OFFSET p_offset)c),'[]'::jsonb)
 ) INTO result;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.st_credit_adjust(uuid,integer,text,uuid),public.st_credit_report(uuid,uuid,integer) FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.st_credit_adjust(uuid,integer,text,uuid),public.st_credit_report(uuid,uuid,integer) TO authenticated;
INSERT INTO public.st_schema_migrations(version) VALUES('045_credit_reporting');
COMMIT;
