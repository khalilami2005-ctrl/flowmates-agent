-- Verification de la premiere synchro reelle.

select 'work_sessions' as source, count(*) as lignes from public.work_sessions
union all
select 'activity_reports', count(*) from public.activity_reports
union all
select 'team_members', count(*) from public.team_members
union all
select 'teams', count(*) from public.teams
union all
select 'profiles', count(*) from public.profiles;

-- Le detail de ce qui est monte
select session_date, duration_seconds, category_breakdown, left(summary, 200) as debut_resume, created_at
from public.work_sessions
order by created_at desc
limit 5;

select category, duration_seconds, left(description, 200) as debut_description, captured_at
from public.activity_reports
order by captured_at desc
limit 5;

-- La licence est-elle bien reclamee, et par qui
select code, plan, claimed_by, claimed_at from public.licenses order by code;
select user_id, plan, status, features, current_period_end from public.subscriptions;
