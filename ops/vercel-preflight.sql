-- READ ONLY. SQL Editor, ORIGINAL Supabase project. No secrets or personal records are output.
begin read only;
select to_regclass('public.profiles') as profiles, to_regclass('auth.users') as auth_users,
       to_regclass('auth.sessions') as auth_sessions,
       to_regclass('public.unt_topics') as unt_topics,
       to_regclass('public.unt_tasks') as unt_tasks;
select column_name,data_type from information_schema.columns
where table_schema='public' and table_name='profiles' order by ordinal_position;
select role,count(*) as accounts from public.profiles group by role;
select count(*) as auth_accounts from auth.users;
select n.nspname,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in ('unt_workspace','unt_submit_answer','unt_edit_task','unt_revoke_access');
rollback;
