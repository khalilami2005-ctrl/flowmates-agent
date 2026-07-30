-- Flowmates backend — row level security.
--
-- Two things drive every choice in this file.
--
-- 1. A policy on team_members that itself queries team_members recurses and
--    Postgres aborts the whole request. The helpers below are SECURITY DEFINER
--    precisely to break that loop: they run as owner, so RLS does not re-enter.
--
-- 2. PostgREST answers a denied row with 403, and sync.rs:560 reads *any* 403 as
--    "License expired or invalid". A policy that is merely too strict therefore
--    does not read as a permission problem to the user — it reads as a billing
--    problem. Policies here are written so that a legitimate call never lands in
--    that branch.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.is_team_member(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = auth.uid()
  );
$$;

comment on function public.is_team_member(uuid) is
  'SECURITY DEFINER on purpose: called from policies on team_members itself, '
  'where a plain subquery would recurse.';

create or replace function public.is_team_admin(p_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.team_members tm
    where tm.team_id = p_team_id
      and tm.user_id = auth.uid()
      and tm.role in ('admin', 'owner', 'manager')
  );
$$;

create or replace function public.my_team_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select tm.team_id from public.team_members tm where tm.user_id = auth.uid();
$$;

grant execute on function public.is_team_member(uuid) to authenticated;
grant execute on function public.is_team_admin(uuid)  to authenticated;
grant execute on function public.my_team_ids()        to authenticated;

-- ---------------------------------------------------------------------------
alter table public.profiles                    enable row level security;
alter table public.teams                       enable row level security;
alter table public.team_members                enable row level security;
alter table public.invitations                 enable row level security;
alter table public.work_sessions               enable row level security;
alter table public.activity_reports            enable row level security;
alter table public.cloud_insights              enable row level security;
alter table public.subscriptions               enable row level security;
alter table public.anonymous_product_analytics enable row level security;
alter table public.product_feedback            enable row level security;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or exists (
      select 1 from public.team_members tm
      where tm.user_id = profiles.id
        and tm.team_id in (select public.my_team_ids())
    )
  );

-- The agent upserts its own profile on team join (sync.rs:800). Both halves of
-- the upsert need a policy or `resolution=merge-duplicates` fails on the second
-- run, when the row already exists.
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- teams
-- ---------------------------------------------------------------------------
drop policy if exists teams_select on public.teams;
create policy teams_select on public.teams
  for select to authenticated
  using (owner_id = auth.uid() or public.is_team_member(id));

drop policy if exists teams_insert on public.teams;
create policy teams_insert on public.teams
  for insert to authenticated
  with check (owner_id = auth.uid());

drop policy if exists teams_update_owner on public.teams;
create policy teams_update_owner on public.teams
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- team_members
-- ---------------------------------------------------------------------------
drop policy if exists team_members_select on public.team_members;
create policy team_members_select on public.team_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_team_member(team_id));

-- Joining is a self-service insert: sync.rs:873 posts the caller's own row after
-- validating an invitation. Restricting this to admins would make join_team
-- impossible, since the joiner is by definition not yet a member.
drop policy if exists team_members_insert_self on public.team_members;
create policy team_members_insert_self on public.team_members
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists team_members_delete on public.team_members;
create policy team_members_delete on public.team_members
  for delete to authenticated
  using (user_id = auth.uid() or public.is_team_admin(team_id));

-- ---------------------------------------------------------------------------
-- invitations
--
-- sync.rs:824 fetches an invitation by token *before* the caller is a member of
-- anything, so membership cannot gate this read. The token is the secret: it is
-- a 32-hex-character random value and the only credential involved. What the
-- policy can still enforce is that a spent or expired invitation is invisible.
-- ---------------------------------------------------------------------------
drop policy if exists invitations_select_by_token on public.invitations;
create policy invitations_select_by_token on public.invitations
  for select to authenticated
  using (
    public.is_team_admin(team_id)
    or (used_at is null and expires_at > now())
  );

drop policy if exists invitations_insert_admin on public.invitations;
create policy invitations_insert_admin on public.invitations
  for insert to authenticated
  with check (public.is_team_admin(team_id) and created_by = auth.uid());

-- sync.rs:916 marks the invitation used right after joining. Only the still-open
-- ones can be touched, so a used invitation cannot be revived.
drop policy if exists invitations_mark_used on public.invitations;
create policy invitations_mark_used on public.invitations
  for update to authenticated
  using (used_at is null and expires_at > now())
  with check (true);

-- ---------------------------------------------------------------------------
-- work_sessions
-- ---------------------------------------------------------------------------
drop policy if exists work_sessions_insert_self on public.work_sessions;
create policy work_sessions_insert_self on public.work_sessions
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (team_id is null or public.is_team_member(team_id))
  );

drop policy if exists work_sessions_select on public.work_sessions;
create policy work_sessions_select on public.work_sessions
  for select to authenticated
  using (user_id = auth.uid() or public.is_team_admin(team_id));

-- ---------------------------------------------------------------------------
-- activity_reports
--
-- `description` is model-written prose about what was on screen. It is the most
-- revealing column in the database, so reading someone else's row is limited to
-- team admins rather than to every teammate.
-- ---------------------------------------------------------------------------
drop policy if exists activity_reports_insert_self on public.activity_reports;
create policy activity_reports_insert_self on public.activity_reports
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (team_id is null or public.is_team_member(team_id))
  );

drop policy if exists activity_reports_select on public.activity_reports;
create policy activity_reports_select on public.activity_reports
  for select to authenticated
  using (user_id = auth.uid() or public.is_team_admin(team_id));

-- ---------------------------------------------------------------------------
-- cloud_insights — written by the generate-insights function, never by a client
-- ---------------------------------------------------------------------------
drop policy if exists cloud_insights_select on public.cloud_insights;
create policy cloud_insights_select on public.cloud_insights
  for select to authenticated
  using (user_id = auth.uid() or public.is_team_member(team_id));

-- ---------------------------------------------------------------------------
-- subscriptions — readable by its owner, writable only by the service role.
-- A client that could write this row could grant itself paid features; that is
-- the whole reason entitlements are not stored client-side in the first place.
-- ---------------------------------------------------------------------------
drop policy if exists subscriptions_select_self on public.subscriptions;
create policy subscriptions_select_self on public.subscriptions
  for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- anonymous_product_analytics and product_feedback
--
-- No policy at all, deliberately. RLS is on and nothing matches, so PostgREST
-- can neither read nor write these tables directly. The only way in is through
-- the SECURITY DEFINER functions in 0003_rpc.sql, which is what keeps a caller
-- holding nothing but the anon key from enumerating the analytics of others.
-- ---------------------------------------------------------------------------

revoke all on public.anonymous_product_analytics from anon, authenticated;
revoke all on public.product_feedback            from anon, authenticated;
