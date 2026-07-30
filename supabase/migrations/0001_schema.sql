-- Flowmates backend — tables.
--
-- Shapes here are dictated by the desktop client; they are not a fresh design.
-- Every column below is written or read by a call in apps/agent/src-tauri/src/.
-- Renaming one silently breaks the agent, because PostgREST answers 400 and the
-- client surfaces it as an opaque sync failure.
--
-- Source of truth for each table is noted above it.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- profiles — sync.rs:800, upserted on team join with Prefer: merge-duplicates
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_url   text,
  role         text not null default 'worker',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.profiles is
  'One row per auth user. Upserted by the agent on team join (sync.rs).';

-- ---------------------------------------------------------------------------
-- teams — not queried directly by the agent, but every team_id points here.
-- Without it, team_id is an unconstrained string and orphan rows accumulate.
-- ---------------------------------------------------------------------------
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  owner_id   uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- team_members — sync.rs:663 (select team_id,role,joined_at) and sync.rs:873
--
-- The unique constraint MUST be named `unique_team_user`: sync.rs:908 matches
-- that exact string in the error body to tell "already a member" apart from a
-- real failure. Renaming it turns a harmless re-join into a user-facing error.
-- ---------------------------------------------------------------------------
create table if not exists public.team_members (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  role       text not null default 'member',
  joined_at  timestamptz not null default now(),
  constraint unique_team_user unique (team_id, user_id)
);

create index if not exists team_members_user_id_idx on public.team_members (user_id);
create index if not exists team_members_team_id_idx on public.team_members (team_id);

-- ---------------------------------------------------------------------------
-- invitations — sync.rs:824 reads by token, sync.rs:916 marks it used
--
-- `token` is the secret. It is the only thing standing between a stranger and a
-- team, so it must be unguessable — hence a uuid default rather than anything
-- derived from the email or the team.
-- ---------------------------------------------------------------------------
create table if not exists public.invitations (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams (id) on delete cascade,
  email      text,
  token      text not null unique default replace(gen_random_uuid()::text, '-', ''),
  expires_at timestamptz not null default (now() + interval '14 days'),
  used_at    timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists invitations_token_idx on public.invitations (token);

-- ---------------------------------------------------------------------------
-- work_sessions — sync.rs:536, one row per summarised working session
-- ---------------------------------------------------------------------------
create table if not exists public.work_sessions (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references auth.users (id) on delete cascade,
  team_id            uuid references public.teams (id) on delete set null,
  duration_seconds   integer not null default 0,
  summary            text,
  category_breakdown jsonb not null default '{}'::jsonb,
  jira_breakdown     jsonb not null default '{}'::jsonb,
  session_date       date not null default current_date,
  created_at         timestamptz not null default now()
);

create index if not exists work_sessions_user_date_idx
  on public.work_sessions (user_id, session_date desc);
create index if not exists work_sessions_team_date_idx
  on public.work_sessions (team_id, session_date desc);

-- ---------------------------------------------------------------------------
-- activity_reports — sync.rs:574 / sync.rs:627, the granular stream
--
-- `description` holds model-written prose about the screen. It is the most
-- sensitive column in this schema: RLS on it is not a formality.
-- ---------------------------------------------------------------------------
create table if not exists public.activity_reports (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references auth.users (id) on delete cascade,
  team_id          uuid references public.teams (id) on delete set null,
  description      text,
  category         text,
  jira_ticket_id   text,
  duration_seconds integer not null default 0,
  captured_at      timestamptz not null default now(),
  created_at       timestamptz not null default now()
);

create index if not exists activity_reports_user_captured_idx
  on public.activity_reports (user_id, captured_at desc);
create index if not exists activity_reports_team_captured_idx
  on public.activity_reports (team_id, captured_at desc);

-- ---------------------------------------------------------------------------
-- cloud_insights — entitlements.rs:175, read with select=*&order=created_at.desc
-- Written by the generate-insights Edge Function, never by the agent.
-- ---------------------------------------------------------------------------
create table if not exists public.cloud_insights (
  id           uuid primary key default gen_random_uuid(),
  team_id      uuid references public.teams (id) on delete cascade,
  user_id      uuid references auth.users (id) on delete cascade,
  period_days  integer not null default 7,
  title        text,
  body         text,
  metrics      jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists cloud_insights_team_created_idx
  on public.cloud_insights (team_id, created_at desc);

-- ---------------------------------------------------------------------------
-- subscriptions — backs get_user_entitlements() (entitlements.rs:91)
--
-- `features` is the exact object the client reads: it looks up features->>'sync',
-- 'cloud_ai' and 'integrations' and nothing else (entitlements.rs:56-58).
-- ---------------------------------------------------------------------------
create table if not exists public.subscriptions (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  plan               text,
  status             text not null default 'free',
  features           jsonb not null default
                       '{"sync": false, "cloud_ai": false, "integrations": false}'::jsonb,
  current_period_end timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- anonymous_product_analytics — upsert_anonymous_product_analytics RPC
--
-- Deliberately carries no user_id and no foreign key. It is written with the
-- anon key by a client that may never have signed in; joining it back to a
-- person would defeat its only purpose.
-- ---------------------------------------------------------------------------
create table if not exists public.anonymous_product_analytics (
  anonymous_id            text primary key,
  consented               boolean not null default false,
  daily_usage             jsonb not null default '[]'::jsonb,
  weekly_primary_activity text,
  first_seen_at           timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- product_feedback — submit_product_feedback RPC
-- ---------------------------------------------------------------------------
create table if not exists public.product_feedback (
  id           uuid primary key default gen_random_uuid(),
  message      text not null,
  anonymous_id text,
  app_version  text,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists subscriptions_touch on public.subscriptions;
create trigger subscriptions_touch before update on public.subscriptions
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Every new auth user gets a profile and a free subscription immediately.
-- Without this, get_user_entitlements() has nothing to read on first sign-in
-- and the agent would fall back to Entitlements::free() through an error path
-- rather than a legitimate answer.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      'User'
    ),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;

  insert into public.subscriptions (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
