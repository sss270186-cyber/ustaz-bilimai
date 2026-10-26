-- READ ONLY. Run after authorized release; never inserts a real test attempt.
begin read only;
select t.position,t.title,count(*) filter(where q.level='B') as b,
       count(*) filter(where q.level='C') as c,
       count(*) filter(where q.active) as active
from public.unt_topics t left join public.unt_tasks q on q.topic_id=t.id
group by t.id order by t.position;
select (select count(*) from public.unt_tasks) as tasks,
       (select count(*) from unt_private.answer_keys) as keys,
       (select count(*) from public.unt_teachers) as teachers,
       (select count(*) from public.unt_enrollments) as enrollments,
       (select count(*) from public.unt_attempts) as attempts;
select has_column_privilege('authenticated','public.profiles','role','UPDATE') as student_can_update_role,
       has_table_privilege('anon','unt_private.answer_keys','SELECT') as anonymous_can_read_keys,
       has_table_privilege('authenticated','unt_private.answer_keys','SELECT') as student_can_read_keys;
select tablename,policyname,permissive from pg_policies
where schemaname='public' and (tablename='profiles' or tablename like 'unt_%') order by tablename,policyname;
rollback;
