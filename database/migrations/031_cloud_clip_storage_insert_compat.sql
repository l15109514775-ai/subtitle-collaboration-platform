-- Measured compatibility fix: temporary deny-only native HTTP diagnostic
-- confirmed object/capability/worker=true, size_present=mime_present=false.
-- Keep original worker/header checks; validate metadata at finish_media.
-- Main task must transaction-test/deploy, then authorize bounded HTTP recheck.
begin;

-- Native storage may initially insert metadata NULL and fill size/mimetype only
-- after receiving bytes. Those fields are mandatory at finish_media, never
-- permission to publish here. Exact reserved object, worker, job, lease, expiry
-- and insert-only native API rules remain unchanged. No new SELECT/UPDATE/DELETE.
create or replace function public.st_clip_storage_insert_allowed(p_bucket text,p_name text,p_metadata jsonb)
returns boolean language sql stable security definer set search_path=pg_catalog,public as $$
  select p_bucket='subtitle-deliveries' and exists (
    select 1 from public.st_cloud_clip_media m
    join public.st_cloud_clip_jobs j on j.id=m.job_id
    cross join lateral jsonb_array_elements(m.parts) part
    where m.state='reserved' and m.expires_at>now() and j.state='running'
      and j.lease_id=m.lease_id and j.lease_expires_at>now() and j.authorization_expires_at>now()
      and public.st_clip_storage_scope(m.job_id,m.object_prefix,p_name)
      and part->>'object_name'=p_name
  );
$$;

revoke all on function public.st_clip_storage_insert_allowed(text,text,jsonb) from public,authenticated;
grant execute on function public.st_clip_storage_insert_allowed(text,text,jsonb) to anon;
insert into public.st_schema_migrations(version) values('031_cloud_clip_storage_insert_compat');
commit;

