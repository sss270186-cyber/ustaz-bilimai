-- ONLY a new, empty, separate staging project. NOT a Production migration.
-- In SQL Editor paste SET bilimai.environment = 'staging'; immediately above
-- this entire file, after checking the Dashboard project ref is NOT Production.
-- The GUC is an operator acknowledgement, not proof of project identity.
begin;
do $$
begin
  if current_setting('bilimai.environment', true) is distinct from 'staging' then
    raise exception 'Staging acknowledgement missing';
  end if;
  if to_regclass('public.profiles') is not null or to_regclass('public.unt_topics') is not null then
    raise exception 'Expected an empty staging project: application tables already exist';
  end if;
  if exists (select 1 from auth.users) then
    raise exception 'Expected an empty staging project: Auth users already exist';
  end if;
end;
$$;
create table public.profiles (
  id uuid primary key references auth.users(id),
  username text unique,
  full_name text not null,
  class_name text check (class_name in ('9', '10', '11')),
  role text not null check (role in ('teacher', 'student')),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
revoke all on public.profiles from public, anon, authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update on public.profiles to service_role;
create policy profile_read_self on public.profiles for select to authenticated
  using (id = auth.uid());
-- No client INSERT/UPDATE/DELETE policies. Only trusted server/DB owner writes profiles.
-- No automatic promotion from user_metadata and no signup trigger assigning teacher.
commit;
