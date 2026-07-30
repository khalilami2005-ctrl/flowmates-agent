-- Flowmates backend — the two RPCs the renderer calls that 0001-0003 missed.
--
--   ensure_personal_team()   auth-service.js:98   -> { "team_id": "<uuid>" }
--   claim_license(p_code)    auth-service.js:109
--
-- Both were found by calling them against the live project and getting a 404,
-- not by reading the client — worth remembering, because nothing in the Rust
-- side references either one. They exist only in the renderer.

-- ---------------------------------------------------------------------------
-- licenses — the codes typed into Profile ("FS-XXXX-XXXX")
--
-- No RLS policy is written for this table on purpose. RLS is enabled and no
-- policy matches, so PostgREST cannot read it at all: a client that could list
-- this table could read unclaimed codes and grant itself a paid plan. The only
-- way in is claim_license(), which is SECURITY DEFINER.
-- ---------------------------------------------------------------------------
create table if not exists public.licenses (
  code          text primary key,
  plan          text not null check (plan in ('individual', 'team')),
  features      jsonb not null default
                  '{"sync": true, "cloud_ai": true, "integrations": true}'::jsonb,
  duration_days integer not null default 365,
  team_id       uuid references public.teams (id) on delete set null,
  claimed_by    uuid references auth.users (id) on delete set null,
  claimed_at    timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.licenses enable row level security;
revoke all on public.licenses from anon, authenticated;

-- ---------------------------------------------------------------------------
-- ensure_personal_team() -> json
--
-- Called when an `individual` plan has no team yet. It must be idempotent: the
-- renderer calls it on sign-in *and* again right after a license is claimed
-- (index.html:3970), so a second call has to return the same team rather than
-- pile up a new one each time.
-- ---------------------------------------------------------------------------
create or replace function public.ensure_personal_team()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_team_id uuid;
  v_name    text;
begin
  if v_uid is null then
    raise exception 'You must be signed in to create a team.' using errcode = '28000';
  end if;

  -- Already in a team? Reuse it. Oldest first, to match the ordering
  -- get_user_entitlements() uses for team_ids — otherwise the two disagree
  -- about which team is "the" active one.
  select tm.team_id into v_team_id
    from public.team_members tm
   where tm.user_id = v_uid
   order by tm.joined_at
   limit 1;

  if v_team_id is not null then
    return json_build_object('team_id', v_team_id);
  end if;

  select coalesce(nullif(trim(p.display_name), ''), 'My') into v_name
    from public.profiles p
   where p.id = v_uid;

  insert into public.teams (name, owner_id)
  values (coalesce(v_name, 'My') || '''s workspace', v_uid)
  returning id into v_team_id;

  insert into public.team_members (team_id, user_id, role)
  values (v_team_id, v_uid, 'owner')
  on conflict on constraint unique_team_user do nothing;

  return json_build_object('team_id', v_team_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_license(p_code) -> json
--
-- The renderer ignores what this returns and re-reads entitlements afterwards
-- (index.html:3966-3974), so the real contract is the side effect: after a
-- successful call, get_user_entitlements() must report an active plan.
--
-- Error messages reach the user verbatim (auth-service.js:111), so they are
-- written to be read by a person, not by a developer.
-- ---------------------------------------------------------------------------
create or replace function public.claim_license(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_lic     public.licenses%rowtype;
  v_code    text := upper(trim(coalesce(p_code, '')));
  v_expires timestamptz;
begin
  if v_uid is null then
    raise exception 'You must be signed in to activate a license.' using errcode = '28000';
  end if;

  if v_code = '' then
    raise exception 'Enter your license code.' using errcode = '22023';
  end if;

  -- FOR UPDATE, not a plain select: two devices claiming the same code at the
  -- same moment would otherwise both pass the "unclaimed" check.
  select * into v_lic from public.licenses where code = v_code for update;

  if v_lic.code is null then
    raise exception 'This license code does not exist.' using errcode = '22023';
  end if;

  -- Re-entering your own code is not an error. The renderer retries after a
  -- failed refresh, and telling the owner their own code is taken would be
  -- both wrong and alarming.
  if v_lic.claimed_by is not null and v_lic.claimed_by <> v_uid then
    raise exception 'This license code has already been used.' using errcode = '22023';
  end if;

  v_expires := now() + make_interval(days => greatest(v_lic.duration_days, 1));

  update public.licenses
     set claimed_by = v_uid,
         claimed_at = coalesce(claimed_at, now())
   where code = v_code;

  insert into public.subscriptions (user_id, plan, status, features, current_period_end)
  values (v_uid, v_lic.plan, 'active', v_lic.features, v_expires)
  on conflict (user_id) do update
    set plan               = excluded.plan,
        status             = 'active',
        features           = excluded.features,
        current_period_end = excluded.current_period_end,
        updated_at         = now();

  -- A team license carries its team with it: without this the user lands in
  -- the "not assigned to a team yet" dead end at auth-service.js:162.
  if v_lic.plan = 'team' and v_lic.team_id is not null then
    insert into public.team_members (team_id, user_id, role)
    values (v_lic.team_id, v_uid, 'member')
    on conflict on constraint unique_team_user do nothing;
  end if;

  return json_build_object(
    'plan',       v_lic.plan,
    'status',     'active',
    'expires_at', v_expires
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke execute on function public.ensure_personal_team()  from public;
revoke execute on function public.claim_license(text)     from public;

grant execute on function public.ensure_personal_team()  to authenticated;
grant execute on function public.claim_license(text)     to authenticated;
