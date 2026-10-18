-- Stage 1, additive migration. Back up the live database BEFORE applying.
-- Run as database owner in a staging copy first. No old table/policy is changed.
begin;
create schema if not exists unt_private;
revoke all on schema unt_private from public, anon, authenticated;

create table public.unt_teachers (
  user_id uuid primary key references auth.users(id),
  created_at timestamptz not null default now()
);
-- Freeze existing teacher authority; clients cannot promote themselves via profiles.
insert into public.unt_teachers(user_id) select id from public.profiles where role = 'teacher';
create table public.unt_enrollments (
  teacher_id uuid not null references public.unt_teachers(user_id),
  student_id uuid not null references auth.users(id),
  primary key(teacher_id, student_id)
);
-- Preserve the existing single-teacher roster without guessing multi-teacher ownership.
insert into public.unt_enrollments(teacher_id, student_id)
select t.user_id, p.id from public.unt_teachers t cross join public.profiles p
where p.role = 'student' and (select count(*) from public.unt_teachers) = 1;
create table public.unt_topics (
  id text primary key, position smallint not null unique, title text not null,
  ready boolean not null default false
);
create table public.unt_tasks (
  id text primary key, topic_id text not null references public.unt_topics(id),
  level text not null check (level in ('B', 'C')), position smallint not null,
  title text not null, prompt text not null, given_data text not null,
  find_value text not null, formulas jsonb not null, unit text not null,
  active boolean not null default true, unique(topic_id, level, position)
);
create table unt_private.answer_keys (
  task_id text primary key references public.unt_tasks(id),
  answer numeric not null, steps jsonb not null check (jsonb_typeof(steps) = 'array')
);
create table public.unt_attempts (
  id bigint generated always as identity primary key,
  student_id uuid not null references auth.users(id), task_id text not null references public.unt_tasks(id),
  submitted_answer text not null, correct boolean not null,
  created_at timestamptz not null default now()
);
create index unt_attempts_student_time on public.unt_attempts(student_id, created_at desc);
create index unt_attempts_task_student on public.unt_attempts(task_id, student_id, id);
create index unt_enrollments_student on public.unt_enrollments(student_id);

create function public.unt_is_teacher() returns boolean
language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.unt_teachers where user_id = auth.uid());
$$;
create function public.unt_is_member() returns boolean
language sql stable security definer set search_path = '' as $$
 select public.unt_is_teacher() or exists(select 1 from public.profiles where id = auth.uid() and role = 'student');
$$;

alter table public.unt_teachers enable row level security;
alter table public.unt_enrollments enable row level security;
alter table public.unt_topics enable row level security;
alter table public.unt_tasks enable row level security;
alter table public.unt_attempts enable row level security;
alter table unt_private.answer_keys enable row level security;
revoke all on public.unt_teachers, public.unt_enrollments, public.unt_topics, public.unt_tasks, public.unt_attempts from anon, authenticated;
revoke all on unt_private.answer_keys from public, anon, authenticated;
revoke all on sequence public.unt_attempts_id_seq from public, anon, authenticated;
grant select on public.unt_teachers, public.unt_enrollments, public.unt_topics, public.unt_tasks, public.unt_attempts to authenticated;
-- Existing server-side student-registration endpoint uses only these new tables.
grant select, insert on public.unt_enrollments to service_role;
grant select on public.unt_teachers to service_role;
create policy unt_teacher_self on public.unt_teachers for select to authenticated using (user_id = auth.uid());
create policy unt_roster_self on public.unt_enrollments for select to authenticated using (teacher_id = auth.uid() or student_id = auth.uid());
create policy unt_topics_read on public.unt_topics for select to authenticated using (public.unt_is_member());
create policy unt_tasks_read on public.unt_tasks for select to authenticated using (public.unt_is_member() and (active or public.unt_is_teacher()));
create policy unt_attempts_read on public.unt_attempts for select to authenticated using (
 student_id = auth.uid() or exists(select 1 from public.unt_enrollments e where e.teacher_id = auth.uid() and e.student_id = unt_attempts.student_id)
);

create function public.unt_workspace() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := auth.uid(); teacher boolean := public.unt_is_teacher(); result jsonb;
begin
 if actor is null or not public.unt_is_member() then raise insufficient_privilege; end if;
 select jsonb_build_object(
  'role', case when teacher then 'teacher' else 'student' end,
  'topics', coalesce((select jsonb_agg(to_jsonb(t) order by t.position) from public.unt_topics t), '[]'::jsonb),
  'tasks', coalesce((select jsonb_agg(to_jsonb(t) order by t.level, t.position) from public.unt_tasks t where t.active or teacher), '[]'::jsonb),
  'attempts', coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from (
    select a.*, t.topic_id, t.level from public.unt_attempts a join public.unt_tasks t on t.id = a.task_id
    where a.student_id = actor or (teacher and exists(select 1 from public.unt_enrollments e where e.teacher_id = actor and e.student_id = a.student_id))
    order by a.id desc limit 200
  ) a), '[]'::jsonb),
  'summary', coalesce((select jsonb_agg(to_jsonb(s)) from (
    select a.student_id, t.topic_id, t.level, count(*)::int as attempted,
     count(*) filter(where a.correct)::int as first_correct,
     count(*) filter(where not a.correct)::int as first_wrong
    from (select distinct on(student_id, task_id) student_id, task_id, correct
     from public.unt_attempts where student_id = actor or (teacher and exists(
       select 1 from public.unt_enrollments e where e.teacher_id = actor and e.student_id = unt_attempts.student_id))
     order by student_id, task_id, id) a
    join public.unt_tasks t on t.id = a.task_id group by a.student_id, t.topic_id, t.level
  ) s), '[]'::jsonb),
  'roster', case when teacher then coalesce((select jsonb_agg(jsonb_build_object(
    'id', p.id, 'username', p.username, 'full_name', p.full_name, 'class_name', p.class_name))
    from public.profiles p join public.unt_enrollments e on e.student_id = p.id where e.teacher_id = actor), '[]'::jsonb) else '[]'::jsonb end
 ) into result;
 return result;
end;
$$;

create function public.unt_submit_answer(p_task_id text, p_answer text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); cleaned text; value numeric; key unt_private.answer_keys%rowtype;
 task public.unt_tasks%rowtype; is_correct boolean; attempt_id bigint;
begin
 if actor is null or not public.unt_is_member() then raise insufficient_privilege; end if;
 if p_answer is null or length(p_answer) > 64 then raise exception 'Сандық жауап енгізіңіз'; end if;
 cleaned := replace(replace(replace(trim(p_answer), ' ', ''), chr(160), ''), ',', '.');
 if cleaned !~ '^[+-]?[0-9]+([.][0-9]+)?$' then raise exception 'Тек сан енгізіңіз. Өлшем бірлігін жазбаңыз.'; end if;
 value := cleaned::numeric;
 select * into task from public.unt_tasks where id = p_task_id and active;
 if not found then raise exception 'Тапсырма қолжетімсіз'; end if;
 select * into key from unt_private.answer_keys where task_id = task.id;
 if not found then raise exception 'Тапсырма тексеруге дайын емес'; end if;
 -- Serialize submissions per account so concurrent requests cannot bypass the limit.
 perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
 if (select count(*) from public.unt_attempts where student_id = actor and created_at > clock_timestamp() - interval '1 minute') >= 20 then
  raise exception 'Бір минуттағы тексеру саны шектелді. Сәл күтіңіз.';
 end if;
 is_correct := value = key.answer;
 insert into public.unt_attempts(student_id, task_id, submitted_answer, correct)
 values(actor, task.id, cleaned, is_correct) returning id into attempt_id;
 return jsonb_build_object('attempt_id', attempt_id, 'correct', is_correct,
  'answer', key.answer::text, 'unit', task.unit, 'steps', key.steps);
end;
$$;

create function public.unt_set_task_active(p_task_id text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is null or not public.unt_is_teacher() then raise insufficient_privilege; end if;
 if p_active is null then raise exception 'Күйді таңдаңыз'; end if;
 update public.unt_tasks set active = p_active where id = p_task_id;
 if not found then raise exception 'Тапсырма табылмады'; end if;
 return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.unt_is_teacher(), public.unt_is_member(), public.unt_workspace(), public.unt_submit_answer(text,text), public.unt_set_task_active(text,boolean) from public, anon;
grant execute on function public.unt_is_teacher(), public.unt_is_member(), public.unt_workspace(), public.unt_submit_answer(text,text), public.unt_set_task_active(text,boolean) to authenticated;
commit;
