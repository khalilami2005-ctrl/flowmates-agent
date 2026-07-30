-- Flowmates backend — the three functions the agent calls by name.
--
-- Return shapes are read field by field on the client. The parsers are:
--   get_user_entitlements              entitlements.rs:37-59
--   upsert_anonymous_product_analytics anonymous_analytics.rs:167-172
--   submit_product_feedback            anonymous_analytics.rs:294-296
-- Argument names matter as much as types: PostgREST matches the JSON body keys
-- to parameter names, so `p_anonymous_id` cannot become `anonymous_id`.

-- ---------------------------------------------------------------------------
-- get_user_entitlements() -> json
--
-- The client reads exactly four things and ignores the rest:
--   plan, status, team_ids[], features.{sync,cloud_ai,integrations}
-- It also derives active_team_id from team_ids[0] (entitlements.rs:55), so the
-- ordering of that array is not cosmetic — it decides which team the agent
-- uploads to. Oldest membership first is the stable choice; anything based on
-- row order would silently reassign a user's team when a row is rewritten.
-- ---------------------------------------------------------------------------
create or replace function public.get_user_entitlements()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_sub      public.subscriptions%rowtype;
  v_team_ids uuid[];
  v_expired  boolean;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  select * into v_sub from public.subscriptions where user_id = v_uid;

  select coalesce(array_agg(tm.team_id order by tm.joined_at), '{}')
    into v_team_ids
    from public.team_members tm
   where tm.user_id = v_uid;

  -- A subscription row that has run out is not a paid subscription. Reading
  -- `features` without checking the period would keep paid flags alive forever
  -- on a lapsed account.
  v_expired := v_sub.current_period_end is not null
               and v_sub.current_period_end < now();

  if v_sub.user_id is null or v_expired or v_sub.status <> 'active' then
    return json_build_object(
      'plan',     v_sub.plan,
      'status',   case
                    when v_sub.user_id is null then 'free'
                    when v_expired then 'expired'
                    else coalesce(v_sub.status, 'free')
                  end,
      'team_ids', to_json(v_team_ids),
      'features', json_build_object(
                    'sync', false, 'cloud_ai', false, 'integrations', false)
    );
  end if;

  return json_build_object(
    'plan',     v_sub.plan,
    'status',   v_sub.status,
    'team_ids', to_json(v_team_ids),
    'features', json_build_object(
      'sync',         coalesce((v_sub.features ->> 'sync')::boolean, false),
      'cloud_ai',     coalesce((v_sub.features ->> 'cloud_ai')::boolean, false),
      'integrations', coalesce((v_sub.features ->> 'integrations')::boolean, false)
    )
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- upsert_anonymous_product_analytics(...)
--
-- Called with the anon key as the bearer (anonymous_analytics.rs:177) — the
-- caller may never have signed in. SECURITY DEFINER is what lets it write to a
-- table that grants nothing to `anon`, so a caller can add a row without being
-- able to read anyone else's.
--
-- Withdrawing consent is a real operation, not a no-op: it wipes the payload
-- and keeps only the flag, so the previously collected series does not linger.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_anonymous_product_analytics(
  p_anonymous_id            text,
  p_consented               boolean,
  p_daily_usage             jsonb default '[]'::jsonb,
  p_weekly_primary_activity text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_anonymous_id is null or length(trim(p_anonymous_id)) = 0 then
    raise exception 'p_anonymous_id is required' using errcode = '22023';
  end if;

  if length(p_anonymous_id) > 128 then
    raise exception 'p_anonymous_id too long' using errcode = '22023';
  end if;

  if jsonb_typeof(coalesce(p_daily_usage, '[]'::jsonb)) <> 'array' then
    raise exception 'p_daily_usage must be an array' using errcode = '22023';
  end if;

  -- 7 entries is what the agent sends (anonymous_analytics.rs:202). The ceiling
  -- is there so a crafted call cannot park an unbounded blob in the row.
  if jsonb_array_length(coalesce(p_daily_usage, '[]'::jsonb)) > 90 then
    raise exception 'p_daily_usage too long' using errcode = '22023';
  end if;

  insert into public.anonymous_product_analytics as a (
    anonymous_id, consented, daily_usage, weekly_primary_activity, updated_at
  )
  values (
    p_anonymous_id,
    coalesce(p_consented, false),
    case when coalesce(p_consented, false)
         then coalesce(p_daily_usage, '[]'::jsonb)
         else '[]'::jsonb end,
    case when coalesce(p_consented, false)
         then left(p_weekly_primary_activity, 64)
         else null end,
    now()
  )
  on conflict (anonymous_id) do update
    set consented               = excluded.consented,
        daily_usage             = excluded.daily_usage,
        weekly_primary_activity = excluded.weekly_primary_activity,
        updated_at              = now();
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_product_feedback(...)
-- Same anon-key path as above.
-- ---------------------------------------------------------------------------
create or replace function public.submit_product_feedback(
  p_message      text,
  p_anonymous_id text default null,
  p_app_version  text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_message is null or length(trim(p_message)) = 0 then
    raise exception 'p_message is required' using errcode = '22023';
  end if;

  insert into public.product_feedback (message, anonymous_id, app_version)
  values (
    left(p_message, 4000),
    left(p_anonymous_id, 128),
    left(p_app_version, 64)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
--
-- PostgREST exposes a function to a role only if that role may execute it.
-- The default `public` grant is revoked first so the list below is the whole
-- truth about who can call what.
-- ---------------------------------------------------------------------------
revoke execute on function public.get_user_entitlements() from public;
revoke execute on function
  public.upsert_anonymous_product_analytics(text, boolean, jsonb, text) from public;
revoke execute on function
  public.submit_product_feedback(text, text, text) from public;

grant execute on function public.get_user_entitlements() to authenticated;

grant execute on function
  public.upsert_anonymous_product_analytics(text, boolean, jsonb, text)
  to anon, authenticated;

grant execute on function
  public.submit_product_feedback(text, text, text)
  to anon, authenticated;
