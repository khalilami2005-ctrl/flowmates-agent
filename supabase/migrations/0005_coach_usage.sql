-- Daily quota for the cloud AI coach.
--
-- The agent's local assistant counts nothing — it runs on the user's machine.
-- The cloud coach bills a third-party model per message, so this one does.
-- Shape dictated by coach_chat.rs:130-136, which reads
-- {used, limit, remaining, planId, allowed}.

create table if not exists public.coach_usage (
  user_id    uuid not null references auth.users (id) on delete cascade,
  usage_date date not null default current_date,
  used       integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, usage_date)
);

alter table public.coach_usage enable row level security;

-- Readable by its owner so a client can show the counter without a round trip
-- through the Edge Function; writable only through consume_coach_message(),
-- because a client that could UPDATE this row could reset its own quota.
drop policy if exists coach_usage_select_self on public.coach_usage;
create policy coach_usage_select_self on public.coach_usage
  for select to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Per-plan daily allowance. A free account gets nothing: require_feature()
-- already refuses cloud_ai there, so a row for it would never be read.
-- ---------------------------------------------------------------------------
create or replace function public.coach_daily_limit(p_plan text)
returns integer
language sql
immutable
as $$
  select case p_plan
    when 'individual' then 50
    when 'team'       then 200
    else 0
  end;
$$;

-- ---------------------------------------------------------------------------
-- get_coach_usage() -> json
--
-- Read-only. Returns today's counter without consuming anything, for the GET
-- branch of the coach-chat function.
-- ---------------------------------------------------------------------------
create or replace function public.get_coach_usage()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_plan  text;
  v_limit integer;
  v_used  integer;
begin
  if v_uid is null then
    raise exception 'You must be signed in.' using errcode = '28000';
  end if;

  select s.plan into v_plan
    from public.subscriptions s
   where s.user_id = v_uid
     and s.status = 'active'
     and (s.current_period_end is null or s.current_period_end > now());

  v_limit := public.coach_daily_limit(v_plan);

  select coalesce(u.used, 0) into v_used
    from public.coach_usage u
   where u.user_id = v_uid and u.usage_date = current_date;

  v_used := coalesce(v_used, 0);

  return json_build_object(
    'used',      v_used,
    'limit',     v_limit,
    'remaining', greatest(v_limit - v_used, 0),
    'planId',    coalesce(v_plan, 'free'),
    'allowed',   v_used < v_limit
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- consume_coach_message() -> json
--
-- Claims one message and returns the usage *after* the claim. Called before
-- the model runs, not after: a crash mid-generation should cost the user a
-- message rather than hand them a free retry loop against a paid API.
--
-- The INSERT ... ON CONFLICT is what makes the counter safe under concurrency —
-- two devices sending at once both land on the same row and the second waits
-- for the first, instead of both reading `used` and writing `used + 1`.
-- ---------------------------------------------------------------------------
create or replace function public.consume_coach_message()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_plan  text;
  v_limit integer;
  v_used  integer;
begin
  if v_uid is null then
    raise exception 'You must be signed in.' using errcode = '28000';
  end if;

  select s.plan into v_plan
    from public.subscriptions s
   where s.user_id = v_uid
     and s.status = 'active'
     and (s.current_period_end is null or s.current_period_end > now());

  v_limit := public.coach_daily_limit(v_plan);

  if v_limit = 0 then
    raise exception 'The AI coach requires an Individual or Team license.'
      using errcode = '22023';
  end if;

  insert into public.coach_usage as u (user_id, usage_date, used)
  values (v_uid, current_date, 1)
  on conflict (user_id, usage_date) do update
    set used = u.used + 1, updated_at = now()
  returning u.used into v_used;

  if v_used > v_limit then
    -- Undo the claim so the counter reflects reality, then refuse.
    update public.coach_usage
       set used = v_limit, updated_at = now()
     where user_id = v_uid and usage_date = current_date;

    raise exception 'Daily coach limit reached (% messages). It resets at midnight.', v_limit
      using errcode = '22023';
  end if;

  return json_build_object(
    'used',      v_used,
    'limit',     v_limit,
    'remaining', greatest(v_limit - v_used, 0),
    'planId',    v_plan,
    'allowed',   true
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- cloud_insights needs an INSERT policy after all.
--
-- 0002 gave it SELECT only, on the assumption that the generate-insights
-- function would write as the service role. It doesn't — it acts as the caller
-- so that auth.uid() identifies the author and RLS still applies, which means
-- the insert needs a policy like any other client write.
--
-- Scoped to self: a caller can only file an insight under its own user_id, and
-- only against a team it belongs to.
-- ---------------------------------------------------------------------------
drop policy if exists cloud_insights_insert_self on public.cloud_insights;
create policy cloud_insights_insert_self on public.cloud_insights
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and (team_id is null or public.is_team_member(team_id))
  );

revoke execute on function public.coach_daily_limit(text)    from public;
revoke execute on function public.get_coach_usage()          from public;
revoke execute on function public.consume_coach_message()     from public;

grant execute on function public.get_coach_usage()       to authenticated;
grant execute on function public.consume_coach_message() to authenticated;
