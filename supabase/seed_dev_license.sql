-- Development licence codes. Run in the SQL Editor.
--
-- Not a migration: these rows are for testing on this project and have no place
-- in a production database. Kept out of migrations/ for that reason.

insert into public.licenses (code, plan, features, duration_days)
values
  ('FS-DEV1-2026', 'individual',
   '{"sync": true, "cloud_ai": true, "integrations": true}'::jsonb, 365),
  ('FS-DEV2-2026', 'individual',
   '{"sync": true, "cloud_ai": false, "integrations": false}'::jsonb, 365)
on conflict (code) do nothing;

-- What was created, and whether anyone has claimed it yet.
select code, plan, duration_days, claimed_by, claimed_at from public.licenses order by code;
