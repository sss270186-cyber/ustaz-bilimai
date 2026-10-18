-- Adds new curriculum fields. Existing accounts, results and old seeds are preserved.
begin;
alter table public.unt_tasks add column code text not null default '';
alter table public.unt_tasks add column answer_format text not null default 'number' check(answer_format in ('number','text','sequence'));
alter table unt_private.answer_keys alter column answer type text using answer::text;
alter table unt_private.answer_keys add column explanation text not null default '';
create or replace function public.unt_submit_answer(p_task_id text, p_answer text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid(); cleaned text; value numeric; key unt_private.answer_keys%rowtype;
 task public.unt_tasks%rowtype; is_correct boolean; attempt_id bigint;
begin
 if actor is null or not public.unt_is_member() then raise insufficient_privilege; end if;
 if p_answer is null or length(p_answer) > 256 or trim(p_answer) = '' then raise exception 'Жауап енгізіңіз (256 таңбаға дейін)'; end if;
 select * into task from public.unt_tasks where id = p_task_id and active;
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
 insert into public.unt_attempts(student_id, task_id, submitted_answer, correct)
 values(actor, task.id, cleaned, is_correct) returning id into attempt_id;
 return jsonb_build_object('attempt_id', attempt_id, 'correct', is_correct,
  'answer', key.answer, 'unit', task.unit, 'steps', key.steps, 'explanation', key.explanation);
end;
$$;

commit;
