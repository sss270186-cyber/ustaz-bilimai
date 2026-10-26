-- READ ONLY. Run in the selected project's SQL Editor or psql.
-- Results are PRIVATE backup evidence: do not commit/export them to GitHub.
-- Assumes the existing app's public.profiles and hosted Supabase Auth schemas.
begin transaction isolation level repeatable read read only;
set local statement_timeout = '60s';
set local lock_timeout = '5s';
set local timezone = 'UTC';

select current_database() as database_name, version() as postgres_version,
       current_setting('transaction_read_only') as read_only,
       now() as inventory_time_utc;

select nspname as schema_name from pg_namespace
where nspname !~ '^pg_' and nspname <> 'information_schema' order by 1;

-- Counts and aggregate fingerprints; no email, name, password or password hash returned.
-- Fingerprints require restricted handling too; compare only matching snapshots.
select count(*) as auth_user_count,
       count(nullif(encrypted_password, '')) as users_with_password_hash,
       md5(coalesce(string_agg(id::text || ':' || coalesce(encrypted_password, ''), '|' order by id), '')) as auth_user_fingerprint
from auth.users;
select count(*) as identity_count from auth.identities;
select count(*) as profile_count,
       md5(coalesce(string_agg(to_jsonb(p)::text, '|' order by id), '')) as profile_fingerprint
from public.profiles p;
select role, count(*) as profile_count from public.profiles group by role order by role;
select count(*) as profiles_without_auth_user from public.profiles p
where not exists (select 1 from auth.users u where u.id = p.id);

select n.nspname as schema_name, c.relname as table_name,
       c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p') and (n.nspname in ('public', 'auth', 'storage') or n.nspname like 'unt%')
order by 1, 2;
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies where schemaname in ('public', 'auth', 'storage') or schemaname like 'unt%'
order by schemaname, tablename, policyname;
select table_schema, table_name, grantee, privilege_type
from information_schema.table_privileges
where table_schema in ('public', 'auth', 'storage') or table_schema like 'unt%'
order by 1, 2, 3, 4;
select table_schema, table_name, column_name, grantee, privilege_type
from information_schema.column_privileges
where table_schema = 'public' and table_name = 'profiles'
order by 1, 2, 3, 4, 5;
select n.nspname as schema_name, c.relname as table_name, t.tgname,
       pg_get_triggerdef(t.oid) as trigger_definition
from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
where not t.tgisinternal and n.nspname in ('public', 'auth', 'storage') order by 1, 2, 3;
select n.nspname as schema_name, p.proname, pg_get_function_identity_arguments(p.oid) as arguments,
       p.prosecdef as security_definer, p.proconfig as function_settings, p.proacl as grants
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' or n.nspname like 'unt%' order by 1, 2, 3;
select extname, extversion from pg_extension order by extname;
select pubname, schemaname, tablename from pg_publication_tables order by 1, 2, 3;

-- Copy the generated statements and run them READ ONLY for exact application row counts.
-- These statements are returned as text, not executed here.
select format('SELECT %L AS table_name, count(*) AS rows FROM %I.%I;',
              n.nspname || '.' || c.relname, n.nspname, c.relname) as exact_count_sql
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p') and (n.nspname = 'public' or n.nspname like 'unt%') order by 1;
rollback;
