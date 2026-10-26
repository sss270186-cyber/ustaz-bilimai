-- Vercel/Supabase management, access revocation and profile hardening.
-- PREPARED ONLY: do not execute on Production without a separate release authorization.
begin;
create table unt_private.session_cutoffs (
 user_id uuid primary key references auth.users(id), not_before timestamptz not null
);
create table unt_private.task_versions (
 task_id text not null references public.unt_tasks(id), revision integer not null,
 task_data jsonb not null, key_data jsonb not null, changed_by uuid references auth.users(id),
 created_at timestamptz not null default now(), primary key(task_id,revision)
);
revoke all on unt_private.session_cutoffs, unt_private.task_versions from public, anon, authenticated;
alter table unt_private.session_cutoffs enable row level security;
alter table unt_private.task_versions enable row level security;

create function public.unt_session_valid() returns boolean
language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); cutoff timestamptz; sid text;
begin
 if actor is null then return false; end if;
 select not_before into cutoff from unt_private.session_cutoffs where user_id=actor;
 if not found then return true; end if;
 sid:=coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'session_id';
 if sid is null or sid !~ '^[0-9a-fA-F-]{36}$' then return false; end if;
 -- Refreshing an old JWT must not bypass a password reset: check session creation,
 -- not the access-token iat. auth.sessions is read only; it is never modified here.
 return exists(select 1 from auth.sessions where id=sid::uuid and user_id=actor and created_at>=cutoff);
end;
$$;
create or replace function public.unt_is_teacher() returns boolean
language sql stable security definer set search_path='' as $$
 select public.unt_session_valid() and exists(select 1 from public.unt_teachers where user_id=auth.uid());
$$;
create or replace function public.unt_is_member() returns boolean
language sql stable security definer set search_path='' as $$
 select public.unt_session_valid() and (public.unt_is_teacher() or exists(select 1 from public.profiles where id=auth.uid() and role='student'));
$$;

-- Keep every profile and existing policy. Remove client writes, including explicit
-- column grants, and add restrictive self/session checks to existing read policies.
alter table public.profiles enable row level security;
revoke all on public.profiles from public, anon, authenticated;
do $$ declare col record; begin
 for col in select attname from pg_attribute where attrelid='public.profiles'::regclass and attnum>0 and not attisdropped loop
  execute format('revoke insert (%I), update (%I), references (%I) on public.profiles from public, anon, authenticated',col.attname,col.attname,col.attname);
 end loop;
end $$;
grant select on public.profiles to authenticated;
grant select,insert,update on public.profiles to service_role;
create policy unt_profile_self_read on public.profiles for select to authenticated using(id=auth.uid());
create policy unt_profile_self_session on public.profiles as restrictive for all to authenticated
 using(id=auth.uid() and public.unt_session_valid()) with check(false);
do $$ declare name text; begin
 foreach name in array array['unt_teachers','unt_enrollments','unt_topics','unt_tasks','unt_attempts'] loop
  execute format('create policy unt_current_session on public.%I as restrictive for all to authenticated using(public.unt_session_valid()) with check(public.unt_session_valid())',name);
 end loop;
end $$;

create function public.unt_account_access() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.unt_is_member() then raise insufficient_privilege; end if;
 return jsonb_build_object('user_id',auth.uid(),'teacher',public.unt_is_teacher());
end;
$$;
create function public.unt_teacher_students() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'full_name',p.full_name,'class_name',p.class_name) order by p.created_at)
  from public.profiles p join public.unt_enrollments e on e.student_id=p.id where e.teacher_id=auth.uid()),'[]'::jsonb);
end;
$$;
create function public.unt_student_target(p_username text) returns uuid
language plpgsql stable security definer set search_path='' as $$
declare target uuid;
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 select p.id into target from public.profiles p join public.unt_enrollments e on e.student_id=p.id
 where e.teacher_id=auth.uid() and p.username=p_username and p.role='student';
 if target is null then raise insufficient_privilege; end if;
 return target;
end;
$$;
create function public.unt_enroll_student(p_username text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 select id into target from public.profiles where username=p_username and role='student' for update;
 if target is null then raise exception 'Оқушы табылмады'; end if;
 if exists(select 1 from public.unt_enrollments where student_id=target and teacher_id<>auth.uid()) then raise insufficient_privilege; end if;
 insert into public.unt_enrollments(teacher_id,student_id) values(auth.uid(),target) on conflict do nothing;
 return jsonb_build_object('ok',true);
end;
$$;
create function public.unt_revoke_access(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.unt_is_member() then raise insufficient_privilege; end if;
 if p_user_id<>auth.uid() and (not public.unt_is_teacher() or not exists(
  select 1 from public.unt_enrollments e join public.profiles p on p.id=e.student_id
  where e.teacher_id=auth.uid() and e.student_id=p_user_id and p.role='student')) then raise insufficient_privilege; end if;
 insert into unt_private.session_cutoffs(user_id,not_before) values(p_user_id,clock_timestamp())
 on conflict(user_id) do update set not_before=excluded.not_before;
 return jsonb_build_object('ok',true,'reauthenticate',true);
end;
$$;

create function public.unt_task_for_edit(p_task_id text) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 select to_jsonb(t)||jsonb_build_object('answer',k.answer,'steps',k.steps,'explanation',k.explanation) into result
 from public.unt_tasks t join unt_private.answer_keys k on k.task_id=t.id where t.id=p_task_id;
 if result is null then raise exception 'Тапсырма табылмады'; end if;
 return result;
end;
$$;
create function public.unt_edit_task(p_task_id text,p_revision integer,p_data jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.unt_tasks%rowtype; k unt_private.answer_keys%rowtype; field text; item jsonb; fmt text; ans text;
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 select * into t from public.unt_tasks where id=p_task_id for update;
 if not found then raise exception 'Тапсырма табылмады'; end if;
 if p_revision is null or p_revision<>t.revision then raise exception 'Тапсырма өзгерген. Редакторды қайта ашыңыз'; end if;
 if p_data is null or jsonb_typeof(p_data)<>'object' then raise exception 'Тапсырма пішімі дұрыс емес'; end if;
 foreach field in array array['title','prompt','given_data','find_value','unit','answer','explanation','code'] loop
  if jsonb_typeof(p_data->field) is distinct from 'string' or length(p_data->>field)>(case when field='code' then 20000 else 5000 end)
   or (field<>'code' and trim(p_data->>field)='') then raise exception 'Барлық міндетті өрісті толтырыңыз'; end if;
 end loop;
 foreach field in array array['steps','formulas'] loop
  if jsonb_typeof(p_data->field) is distinct from 'array' then raise exception 'Формула мен қадамдарды тізіммен беріңіз'; end if;
  if jsonb_array_length(p_data->field)>(case when field='steps' then 20 else 10 end) or
   jsonb_array_length(p_data->field)<(case when field='formulas' then 1 when t.level='C' then 3 else 2 end) then raise exception 'Формула немесе шешу қадамдары жеткіліксіз'; end if;
  for item in select value from jsonb_array_elements(p_data->field) loop
   if jsonb_typeof(item)<>'string' or length(item#>>'{}')>4000 or trim(item#>>'{}')='' then raise exception 'Қадамдар бос болмауы керек'; end if;
  end loop;
 end loop;
 fmt:=p_data->>'answer_format'; ans:=trim(p_data->>'answer');
 if fmt is null or fmt not in ('number','text','sequence') or length(ans)>256 then raise exception 'Жауап пішімі дұрыс емес'; end if;
 if fmt='number' and (length(ans)>64 or ans !~ '^[+-]?[0-9]+([.][0-9]+)?$') then raise exception 'Дұрыс сандық жауапты нүктемен жазыңыз'; end if;
 select * into k from unt_private.answer_keys where task_id=t.id;
 insert into unt_private.task_versions(task_id,revision,task_data,key_data,changed_by)
 values(t.id,t.revision,to_jsonb(t),to_jsonb(k),auth.uid()) on conflict do nothing;
 update public.unt_tasks set title=trim(p_data->>'title'),prompt=trim(p_data->>'prompt'),given_data=trim(p_data->>'given_data'),
 find_value=trim(p_data->>'find_value'),unit=trim(p_data->>'unit'),code=p_data->>'code',formulas=p_data->'formulas',answer_format=fmt,revision=t.revision+1 where id=t.id;
 update unt_private.answer_keys set answer=ans,steps=p_data->'steps',explanation=trim(p_data->>'explanation'),
 error_feedback='Шешіміңізді түсіндірмемен салыстырыңыз: '||trim(p_data->>'explanation'),mistakes='{}'::jsonb where task_id=t.id;
 insert into unt_private.task_versions(task_id,revision,task_data,key_data,changed_by)
 select t.id,q.revision,to_jsonb(q),to_jsonb(a),auth.uid() from public.unt_tasks q join unt_private.answer_keys a on a.task_id=q.id where q.id=t.id;
 return jsonb_build_object('ok',true,'revision',t.revision+1);
end;
$$;
create function public.unt_results_export() returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.unt_is_teacher() then raise insufficient_privilege; end if;
 return coalesce((select jsonb_agg(to_jsonb(x) order by x.id desc) from (
  select a.id,p.username,p.full_name,a.task_id,a.task_revision,a.submitted_answer,a.correct,a.created_at
  from public.unt_attempts a join public.unt_enrollments e on e.student_id=a.student_id join public.profiles p on p.id=a.student_id
  where e.teacher_id=auth.uid() order by a.id desc limit 10000
 ) x),'[]'::jsonb);
end;
$$;

revoke all on function public.unt_session_valid(),public.unt_account_access(),public.unt_teacher_students(),public.unt_student_target(text),public.unt_enroll_student(text),public.unt_revoke_access(uuid),public.unt_task_for_edit(text),public.unt_edit_task(text,integer,jsonb),public.unt_results_export() from public,anon;
grant execute on function public.unt_session_valid(),public.unt_account_access(),public.unt_teacher_students(),public.unt_student_target(text),public.unt_enroll_student(text),public.unt_revoke_access(uuid),public.unt_task_for_edit(text),public.unt_edit_task(text,integer,jsonb),public.unt_results_export() to authenticated;
-- Grade implementation with an edit/grade consistency lock is appended below.

create or replace function public.unt_submit_answer(p_task_id text, p_answer text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); cleaned text; value numeric; key unt_private.answer_keys%rowtype;
 task public.unt_tasks%rowtype; is_correct boolean; attempt_id bigint;
begin
 if actor is null or not public.unt_is_member() then raise insufficient_privilege; end if;
 if p_answer is null or length(p_answer) > 256 or trim(p_answer) = '' then raise exception 'Жауап енгізіңіз (256 таңбаға дейін)'; end if;
 select * into task from public.unt_tasks where id = p_task_id and active for share;
 if not found then raise exception 'Тапсырма қолжетімсіз'; end if;
 select * into key from unt_private.answer_keys where task_id = task.id;
 if not found then raise exception 'Тапсырма тексеруге дайын емес'; end if;
 -- Serialize submissions per account so concurrent requests cannot bypass the limit.
 perform pg_advisory_xact_lock(hashtextextended(actor::text, 0));
 if (select count(*) from public.unt_attempts where student_id = actor and created_at > clock_timestamp() - interval '1 minute') >= 20 then
  raise exception 'Бір минуттағы тексеру саны шектелді. Сәл күтіңіз.';
 end if;
 if task.answer_format = 'number' then
  if length(p_answer) > 64 then raise exception 'Сандық жауап тым ұзын'; end if;
  cleaned := replace(replace(replace(trim(p_answer), ' ', ''), chr(160), ''), ',', '.');
  if cleaned !~ '^[+-]?[0-9]+([.][0-9]+)?$' then raise exception 'Тек сан енгізіңіз. Өлшем бірлігін жазбаңыз.'; end if;
  is_correct := cleaned::numeric = key.answer::numeric;
 elsif task.answer_format = 'sequence' then
  cleaned := regexp_replace(lower(trim(p_answer)), '[,;[:space:]]+', ' ', 'g');
  is_correct := cleaned = regexp_replace(lower(trim(key.answer)), '[,;[:space:]]+', ' ', 'g');
 else
  cleaned := regexp_replace(lower(trim(p_answer)), '[[:space:]]+', ' ', 'g');
  is_correct := cleaned = regexp_replace(lower(trim(key.answer)), '[[:space:]]+', ' ', 'g');
 end if;
 insert into public.unt_attempts(student_id, task_id, submitted_answer, correct,task_revision,task_snapshot)
 values(actor, task.id, cleaned, is_correct,task.revision,to_jsonb(task)) returning id into attempt_id;
 return jsonb_build_object('attempt_id', attempt_id, 'correct', is_correct,
  'answer', key.answer, 'unit', task.unit, 'steps', key.steps, 'explanation', key.explanation, 'feedback', case when is_correct then null else coalesce(key.mistakes ->> cleaned,key.error_feedback) end);
end;
$$;
commit;
