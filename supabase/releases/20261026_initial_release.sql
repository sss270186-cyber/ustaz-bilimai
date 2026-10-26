-- PREPARED ONLY: requires separate Production release authorization.
-- INITIAL INSTALL ONLY, same Supabase project; preserves Auth users and profile rows.
-- One transaction: any failure rolls back the entire installation.
begin;
do $preflight$
declare item text;
begin
 if to_regclass('public.profiles') is null or to_regclass('auth.users') is null or to_regclass('auth.sessions') is null then
  raise exception 'Required original profiles/Auth tables are missing. Do not continue on a different project.';
 end if;
 foreach item in array array['id','username','full_name','role','class_name','created_at'] loop
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name=item) then
   raise exception 'Required profiles column missing: %', item;
  end if;
 end loop;
 if not exists(select 1 from public.profiles where role='teacher') then
  raise exception 'No existing teacher profile. Verify the original project and teacher before installation.';
 end if;
 if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname like 'unt\_%' escape '\')
 or exists(select 1 from pg_namespace where nspname='unt_private') then
  raise exception 'UNT objects already exist. Use only reviewed pending migrations; never reapply the initial release.';
 end if;
end;
$preflight$;

-- SOURCE: 202610180001_learning.sql
-- Stage 1, additive migration. Back up the live database BEFORE applying.
-- Run as database owner in a staging copy first. No old table/policy is changed.

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


-- SOURCE: 202610180002_measurement_seed.sql
-- Generated by node scripts/build-seed.cjs. Private: never serve this file.

insert into public.unt_topics(id,position,title,ready) values ('hardware',0,'Аппараттық жасақтама',false);
insert into public.unt_topics(id,position,title,ready) values ('software',1,'Программалық жасақтама',false);
insert into public.unt_topics(id,position,title,ready) values ('memory',2,'Компьютер жады',false);
insert into public.unt_topics(id,position,title,ready) values ('measurement',3,'Ақпаратты өлшеу',true);
insert into public.unt_topics(id,position,title,ready) values ('alphabet',4,'Ақпарат көлемін алфавиттік тәсілмен есептеу',false);
insert into public.unt_topics(id,position,title,ready) values ('encoding',5,'Ақпаратты кодтау: екілік код, ASCII, Unicode',false);
insert into public.unt_topics(id,position,title,ready) values ('number-systems',6,'Санау жүйелері',false);
insert into public.unt_topics(id,position,title,ready) values ('networks',7,'Компьютерлік желілер',false);
insert into public.unt_topics(id,position,title,ready) values ('bandwidth',8,'Желінің өткізу қабілеті',false);
insert into public.unt_topics(id,position,title,ready) values ('ip',9,'IP-адрестер және маска',false);
insert into public.unt_topics(id,position,title,ready) values ('dns',10,'DNS — домендік атаулар жүйесі',false);
insert into public.unt_topics(id,position,title,ready) values ('logic',11,'Логикалық элементтер, блок-схемалар, ақиқат кестелері',false);
insert into public.unt_topics(id,position,title,ready) values ('spreadsheets',12,'Электрондық кестелер',false);
insert into public.unt_topics(id,position,title,ready) values ('python',13,'Python алгоритмдері, тізімдер, массивтер, сұрыптау',false);
insert into public.unt_topics(id,position,title,ready) values ('functions',14,'Python функциялары мен процедуралары',false);
insert into public.unt_topics(id,position,title,ready) values ('html-css',15,'HTML және CSS',false);
insert into public.unt_topics(id,position,title,ready) values ('sql',16,'SQL дерекқорлары',false);
insert into public.unt_topics(id,position,title,ready) values ('ai',17,'Жасанды интеллект',false);
insert into public.unt_topics(id,position,title,ready) values ('neural-networks',18,'Нейрондық желілер',false);
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-b01','measurement','B',1,'Өлшем бірлігін түрлендіру','Көлемі 1,75 МиБ файлдың көлемін КиБ-пен өрнектеңіз.','V = 1,75 МиБ; 1 МиБ = 1024 КиБ.','V, КиБ','["V(КиБ) = V(МиБ) × 1024"]','КиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-b01','1792','["МиБ-тен КиБ-ке өту үшін 1024-ке көбейтеміз.","1,75 × 1024 = 1792 КиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-b02','measurement','B',2,'Аралас бірліктер','Хабарлама 3 КиБ деректен және 96 бит қосымша өрістен тұрады. Жалпы көлемін байтпен табыңыз.','Деректер — 3 КиБ; қосымша өріс — 96 бит.','V, байт','["V = 3 × 1024 + 96 / 8"]','байт');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-b02','3084','["Деректер: 3 × 1024 = 3072 байт.","Қосымша өріс: 96 / 8 = 12 байт.","Жалпы көлем: 3072 + 12 = 3084 байт."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c01','measurement','C',1,'Көпсатылы түрлендіру','Архивке 3,5 МиБ, 768 КиБ және 4096 бит көлеміндегі үш файл біріктірілді. Архив қысылмайды, қызметтік дерек қосылмайды. Көлемін КиБ-пен табыңыз.','V₁ = 3,5 МиБ; V₂ = 768 КиБ; V₃ = 4096 бит.','Vжалпы, КиБ','["Vжалпы = V₁ × 1024 + V₂ + V₃ / (8 × 1024)"]','КиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c01','4352.5','["Бірінші файл: 3,5 × 1024 = 3584 КиБ.","Үшінші файл: 4096 / 8 = 512 байт; 512 / 1024 = 0,5 КиБ.","3584 + 768 + 0,5 = 4352,5 КиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c02','measurement','C',2,'Мәтіннің құрылымы','Құжатта 24 бет, әр бетте 40 жол, әр жолда бос орындарды қоса 64 таңба бар. Әр таңба дәл 16 битпен сақталады. Жол соңы, пішімдеу және басқа үстеме деректер жоқ. Көлемін КиБ-пен табыңыз.','P = 24; L = 40; K = 64; i = 16 бит/таңба.','V, КиБ','["N = P × L × K","V = N × i / (8 × 1024)"]','КиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c02','120','["Таңбалар саны: 24 × 40 × 64 = 61 440.","Көлемі: 61 440 × 16 = 983 040 бит.","983 040 / 8 = 122 880 байт; 122 880 / 1024 = 120 КиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c03','measurement','C',3,'Қор сақталған тасымалдағыш','Сыйымдылығы 2 ГиБ тасымалдағыштың 12,5%-ын бос қалдыру қажет. Онда 192 МиБ дерек бар. Қосымша көлемі 180 МиБ болатын неше толық файл сыяды? Файлдық жүйе үстемесін есептемеңіз.','D = 2 ГиБ; резерв — 12,5%; бар дерек — 192 МиБ; файл — 180 МиБ.','n, толық файл саны','["Dқол = D × 1024 × (1 − r)","n = floor((Dқол − Vбар) / Vфайл)"]','файл');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c03','8','["2 × 1024 = 2048 МиБ. Резерв: 2048 × 0,125 = 256 МиБ.","Қолдануға рұқсат етілген бос орын: 2048 − 256 − 192 = 1600 МиБ.","1600 / 180 = 8,88…; тек 8 толық файл сыяды. Қалдық — 160 МиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c04','measurement','C',4,'Қысу және тақырыпша','Әрқайсысы 512 КиБ болатын 12 файл қысылғанда әр файл бастапқы көлемінің 5/8 бөлігін алады. Әр қысылған файлға 2 КиБ тақырыпша қосылады. Барлық файлдың жаңа жалпы көлемін табыңыз.','n = 12; V = 512 КиБ; k = 5/8; h = 2 КиБ/файл.','Vжаңа, КиБ','["Vжаңа = n × (V × k + h)"]','КиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c04','3864','["Бір файлдың қысылған деректері: 512 × 5 / 8 = 320 КиБ.","Тақырыпшамен: 320 + 2 = 322 КиБ.","Барлығы: 12 × 322 = 3864 КиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c05','measurement','C',5,'Кластермен сақтау','Дискіде 900 файл бар. Әр файлдың логикалық көлемі 6 КиБ + 1 байт. Кластер көлемі 4 КиБ; әр файл жеке бүтін кластерлерде сақталады. Каталогтар мен метадеректерді есептемей, файлдарға бөлінген жалпы орынды КиБ-пен табыңыз.','n = 900; V = 6 × 1024 + 1 байт; S = 4 КиБ.','D, КиБ','["m = ceil(V / S)","D = n × m × S"]','КиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c05','7200','["Бір файл: 6 × 1024 + 1 = 6145 байт; кластер — 4096 байт.","ceil(6145 / 4096) = 2 кластер. Бір файл 8 КиБ орын алады.","900 × 8 = 7200 КиБ. Логикалық көлемді бүкіл топқа бірден дөңгелектеуге болмайды."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c06','measurement','C',6,'Бөліктерге бөлу үстемесі','Көлемі 2 МиБ + 100 байт файл деректер бөлігі ең көбі 1024 байт болатын бөліктерге бөлінеді. Әр бөлікке 24 байт тақырыпша қосылады. Соңғы деректер бөлігі толықтырылмайды. Жіберілетін жалпы байт санын табыңыз.','V = 2 МиБ + 100 байт; P = 1024 байт; H = 24 байт/бөлік.','D, байт','["n = ceil(V / P)","D = V + n × H"]','байт');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c06','2146428','["V = 2 × 1 048 576 + 100 = 2 097 252 байт.","2048 толық бөлік пен 100 байттық соңғы бөлік: n = 2049.","Тақырыпшалар: 2049 × 24 = 49 176 байт.","Жалпы: 2 097 252 + 49 176 = 2 146 428 байт."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c07','measurement','C',7,'Резервтік көшірмелер','Толық резервтік көшірме 1,5 ГиБ алады. Одан кейінгі 5 күннің әрқайсысында 240 МиБ инкременттік көшірме жасалады. Толық көшірме мен бес инкременттік көшірменің әрқайсысы екі данада сақталады. Қысусыз жалпы орынды ГиБ-пен табыңыз.','Vтолық = 1,5 ГиБ; d = 5; Vкүн = 240 МиБ; дана саны — 2.','D, ГиБ','["D = 2 × (Vтолық × 1024 + d × Vкүн) / 1024"]','ГиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c07','5.34375','["Толық көшірме: 1,5 × 1024 = 1536 МиБ.","Бес күн: 5 × 240 = 1200 МиБ; бір жинақ — 2736 МиБ.","Екі жинақ: 2 × 2736 = 5472 МиБ.","5472 / 1024 = 5,34375 ГиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c08','measurement','C',8,'Қысылмаған дыбыс','48 000 Гц жиілікпен, әр арнада 24 бит разрядтылықпен жазылған стерео PCM дыбыс 75 секундқа созылады. Екі арна бар. Қысу мен тақырыпшаны есептемей, көлемін МиБ-пен табыңыз.','f = 48 000 Гц; b = 24 бит; c = 2; t = 75 с.','V, МиБ','["V = f × b × c × t / (8 × 1024²)"]','МиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c08','20.599365234375','["Әр секундта: 48 000 × 24 × 2 = 2 304 000 бит.","75 секундта: 172 800 000 бит = 21 600 000 байт.","21 600 000 / 1 048 576 = 20,599365234375 МиБ. Дөңгелектемей енгізіңіз."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c09','measurement','C',9,'Кескін жолдарын туралау','Қысылмаған растрлық кескін 1023 × 512 пиксель, түс тереңдігі 24 бит/пиксель. Әр жол байт саны 4-ке еселік болғанша нөлдермен толықтырылады. Палитра мен файл тақырыпшасы жоқ. Көлемін МиБ-пен табыңыз.','W = 1023; H = 512; b = 24 бит/пиксель; туралау — 4 байт.','V, МиБ','["R = 4 × ceil((W × b / 8) / 4)","V = R × H / 1024²"]','МиБ');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c09','1.5','["Жолдың бастапқы көлемі: 1023 × 24 / 8 = 3069 байт.","Келесі 4-ке еселік сан — 3072: әр жолға 3 байт қосылады.","3072 × 512 = 1 572 864 байт.","1 572 864 / 1 048 576 = 1,5 МиБ."]');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit) values ('measure-c10','measurement','C',10,'Ондық және екілік бірліктер','Өндіруші дисктің сыйымдылығын 256 GB деп көрсетті (1 GB = 10⁹ байт). Оған әрқайсысы 1,5 ГиБ болатын файлдар жазылады (1 ГиБ = 2³⁰ байт). Файлдық жүйе үстемесі мен басқа файлдар жоқ. Неше толық файл сыяды?','D = 256 × 10⁹ байт; V = 1,5 × 2³⁰ байт.','n, толық файл саны','["n = floor(D / V)"]','файл');
insert into unt_private.answer_keys(task_id,answer,steps) values ('measure-c10','158','["Диск: 256 000 000 000 байт.","Бір файл: 1,5 × 1 073 741 824 = 1 610 612 736 байт.","Бөлінді 158,94…; бүтін бөлігі — 158 файл.","159 файлға 256 087 425 024 байт қажет: бұл диск сыйымдылығынан артық."]');


-- SOURCE: 202610180003_answer_formats.sql
-- Adds new curriculum fields. Existing accounts, results and old seeds are preserved.

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



-- SOURCE: 202610180004_full_curriculum.sql
-- Generated private curriculum seed. Never include this file in static output.

update public.unt_topics set title='Аппараттық жасақтама',ready=true where id='hardware';
update public.unt_topics set title='Программалық жасақтама',ready=true where id='software';
update public.unt_topics set title='Компьютер жады',ready=true where id='memory';
update public.unt_topics set title='Ақпаратты өлшеу',ready=true where id='measurement';
update public.unt_topics set title='Ақпарат көлемін алфавиттік тәсілмен есептеу',ready=true where id='alphabet';
update public.unt_topics set title='Ақпаратты кодтау: екілік код, ASCII, Unicode',ready=true where id='encoding';
update public.unt_topics set title='Санау жүйелері',ready=true where id='number-systems';
update public.unt_topics set title='Компьютерлік желілер',ready=true where id='networks';
update public.unt_topics set title='Желінің өткізу қабілеті',ready=true where id='bandwidth';
update public.unt_topics set title='IP-адрестер және маска',ready=true where id='ip';
update public.unt_topics set title='DNS — домендік атаулар жүйесі',ready=true where id='dns';
update public.unt_topics set title='Логикалық элементтер, блок-схемалар, ақиқат кестелері',ready=true where id='logic';
update public.unt_topics set title='Электрондық кестелер',ready=true where id='spreadsheets';
update public.unt_topics set title='Python алгоритмдері, тізімдер, массивтер, сұрыптау',ready=true where id='python';
update public.unt_topics set title='Python функциялары мен процедуралары',ready=true where id='functions';
update public.unt_topics set title='HTML және CSS',ready=true where id='html-css';
update public.unt_topics set title='SQL дерекқорлары',ready=true where id='sql';
update public.unt_topics set title='Жасанды интеллект',ready=true where id='ai';
update public.unt_topics set title='Нейрондық желілер',ready=true where id='neural-networks';
update unt_private.answer_keys set explanation='Үлкен бірліктен кішіге өткенде көбейтеміз; МиБ пен КиБ қатынасы1024.' where task_id='measure-b01';
update unt_private.answer_keys set explanation='Қосындыға дейін әр бөлікті бірдей байт бірлігіне келтіреміз.' where task_id='measure-b02';
update unt_private.answer_keys set explanation='Кіші бөліктегі жарты КиБ-ті жоғалтпау үшін аралық мәнді дөңгелектемейміз.' where task_id='measure-c01';
update unt_private.answer_keys set explanation='Символдың16 бит салмағы кодтау шартымен берілген, барлық мәтінге әмбебап емес.' where task_id='measure-c02';
update unt_private.answer_keys set explanation='Бос қор сақталатын жалпы көлемнен алынады, тек толық файлдар саналады.' where task_id='measure-c03';
update unt_private.answer_keys set explanation='Қысу коэффициенті қалған үлесті береді; тақырыпша әр файлға бөлек қосылады.' where task_id='measure-c04';
update unt_private.answer_keys set explanation='Әр файл жеке кластермен сақталады, сондықтан дөңгелектеу де жеке жасалады.' where task_id='measure-c05';
update unt_private.answer_keys set explanation='Соңғы дерек бөлігі толтырылмайды, бірақ оның да тақырыпшасы бар.' where task_id='measure-c06';
update unt_private.answer_keys set explanation='Толық база мен барлық инкременттер екі данаға бірдей көбейтіледі.' where task_id='measure-c07';
update unt_private.answer_keys set explanation='Қысылмаған PCM моделі жиілік, разряд, арна саны және уақытты көбейтеді.' where task_id='measure-c08';
update unt_private.answer_keys set explanation='Туралау әр жолға қолданылады; пиксельдердің жалпы санына бір рет дөңгелектеу қате.' where task_id='measure-c09';
update unt_private.answer_keys set explanation='Ондық GB пен екілік ГиБ-ты байтқа айналдырғаннан кейін ғана бөлеміз.' where task_id='measure-c10';
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-b01','hardware','B',1,'Процессор өнімділігі','3 ГГц процессор бір тактта орташа 2 нұсқау орындайды. 0,5 секундта неше миллиард нұсқау орындалады?','f=3 ГГц; IPC=2; t=0,5 с','N, миллиард нұсқау','["N = f × IPC × t"]','млрд','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-b01','3','["3 ГГц — секундына 3 миллиард такт.","3 × 2 × 0,5 = 3 миллиард нұсқау."]','Жиілік пен бір такттағы жұмыс көлемі бірге ескеріледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-b02','hardware','B',2,'Құрылғыны таңдау','Компьютерде электр өшкенде де файлдар қалуы керек. Берілген RAM, SSD, CPU, GPU тізімінен сақтау құрылғысының қысқа атауын жазыңыз.','RAM, SSD, CPU, GPU','Құрылғы атауы','["Тұрақты сақтау → энергияға тәуелсіз жад"]','атау','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-b02','SSD','["RAM — уақытша жұмыс жады.","SSD файлдарды қуатсыз да сақтайды."]','SSD-нің энергияға тәуелсіздігі оны RAM-нан ажыратады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c01','hardware','C',1,'Такт пен нұсқау','Бағдарлама 1,2 млрд нұсқаудан тұрады. CPI=1,5, жиілік 3 ГГц. Орындалу уақытын табыңыз.','N=1,2×10⁹; CPI=1,5; f=3×10⁹ Гц','t, секунд','["t = N × CPI / f"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c01','0.6','["Қажет такт: 1,2×10⁹ × 1,5 = 1,8×10⁹.","1,8×10⁹ / 3×10⁹ = 0,6 с."]','CPI — бір нұсқауға кететін орташа такт; оны IPC-пен шатастырмаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c02','hardware','C',2,'Амдал заңы','Бір ядролы есептің 80%-ы параллельденеді. 4 ядро идеал жұмыс істесе, жалпы үдеу неше есе?','p=0,8; n=4; үстеме шығын жоқ','S','["S = 1 / ((1 − p) + p/n)"]','есе','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c02','2.5','["Тізбекті үлес: 0,2.","Жаңа уақыт үлесі: 0,2+0,8/4=0,4.","Үдеу: 1/0,4=2,5."]','Тізбекті бөлік ядро көбейгенде де қысқармайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c03','hardware','C',3,'Шина өткізуі','64 биттік шина 800 МГц жиілікте әр тактта 2 тасымал жасайды. Теориялық өткізуін GB/с-пен есептеңіз, 1 GB=10⁹ байт.','w=64 бит; f=800×10⁶; k=2','B, GB/с','["B = (w/8) × f × k / 10⁹"]','GB/с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c03','12.8','["64 бит = 8 байт.","8 × 800×10⁶ × 2 = 12,8×10⁹ байт/с."]','Тасымал саны жиіліктен бөлек көбейткіш болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c04','hardware','C',4,'Қуат қоры','Құрылғылардың ең жоғары қуаты CPU 95 Вт, GPU 180 Вт, өзгелері 65 Вт. Қорек блогының қуаты бұл қосындыдан 25% артық болуы тиіс. Ең аз есептік қуатты табыңыз.','95; 180; 65 Вт; қор 25%','P, Вт','["P = ΣPқұрылғы × 1,25"]','Вт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c04','425','["Жүктеме: 95+180+65=340 Вт.","340×1,25=425 Вт."]','Бұл есептік төменгі шек; нақты блокты стандартты қуаттардан жоғары таңдайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c05','hardware','C',5,'GPU буфері','3840×2160 кескін 32 бит/пиксель форматында 3 кадрлық буферде сақталады. Керек көлемді байтпен табыңыз.','W=3840; H=2160; b=32; n=3','V, байт','["V = W × H × b/8 × n"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c05','99532800','["Бір кадр: 3840×2160×4=33 177 600 байт.","Үш кадр: 33 177 600×3=99 532 800 байт."]','Түстердің разрядтылығы мен буфер саны бөлек ескеріледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c06','hardware','C',6,'Диск айналымы','7500 айн/мин диск үшін орташа айналу кідірісін миллисекундпен табыңыз. Іздеу уақытын қоспаңыз.','n=7500 айн/мин; орташа күту — жарты айналым','t, мс','["t = (60/n) × 1000 / 2"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c06','4','["Бір айналым:60/7500=0,008 с.","Орташа кідіріс:0,008×1000/2=4 мс."]','Орташа айналу кідірісі — бір толық айналымның жартысы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c07','hardware','C',7,'Екі құрылғы сенімділігі','Екі тәуелсіз модуль тізбектей қажет. Бір күнде әрқайсысының жұмыс істеу ықтималдығы 0,98 және 0,95. Жүйенің жұмыс ықтималдығын пайызбен табыңыз.','P₁=0,98; P₂=0,95; екеуі де қажет','P, %','["P = P₁ × P₂ × 100"]','%','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c07','93.1','["Тәуелсіз және бірге қажет оқиғалар көбейтіледі.","0,98×0,95×100=93,1%."]','Екеуі де керек болғандықтан ықтималдықтар қосылмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c08','hardware','C',8,'Энергия тиімділігі','А компьютері жұмысты 40 с-та 150 Вт-пен, B компьютері 30 с-та 160 Вт-пен орындайды. B қанша джоуль энергия үнемдейді?','tA=40; PA=150; tB=30; PB=160','EA−EB, Дж','["E = P × t"]','Дж','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c08','1200','["EA=150×40=6000 Дж.","EB=160×30=4800 Дж.","Айырма: 6000−4800=1200 Дж."]','Қуаты жоғары құрылғы жылдам аяқтаса, жалпы энергиясы аз болуы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c09','hardware','C',9,'Порттың пайдалы жылдамдығы','Порттың желілік жылдамдығы 10 Гбит/с, кодтау тиімділігі 80%. 2 GB файлды жіберудің ең аз уақытын табыңыз.','R=10×10⁹ бит/с; η=0,8; V=2×10⁹ байт','t, с','["t = 8V / (Rη)"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c09','2','["Пайдалы жылдамдық: 8×10⁹ бит/с.","Файл: 16×10⁹ бит.","16/8=2 с."]','Шикі жылдамдықтың бәрі пайдалы дерекке жұмсалмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('hardware-c10','hardware','C',10,'Монитор жаңартуы','144 Гц монитор бір кадрды неше миллисекундта жаңартады? Нәтижені үш ондық таңбаға дейін дөңгелектеңіз.','f=144 Гц','T, мс','["T = 1000 / f"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('hardware-c10','6.944','["Период — жиіліктің кері шамасы.","1000/144=6,944444… мс.","Үш ондық таңбамен 6,944 мс."]','Жауап дәлдігі шартта берілгенде ғана дөңгелектеңіз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-b01','software','B',1,'Жүйелік программа','Принтерді операциялық жүйемен байланыстыратын программаның түрін жазыңыз: драйвер, мәтіндік редактор, браузер.','Құрылғы: принтер; ОЖ-мен байланыс керек','Программа түрі','["Құрылғы ↔ драйвер ↔ операциялық жүйе"]','атау','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-b01','драйвер','["Редактор құжат өңдейді, браузер web ашады.","Құрылғымен өзара әрекетті драйвер атқарады."]','Драйвер — жүйелік программалық жасақтаманың бөлігі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-b02','software','B',2,'Лицензия құны','18 компьютерге лицензия керек. Бір лицензия 8000 теңге, 10 немесе одан көп алса 15% жеңілдік. Жалпы құнын табыңыз.','n=18; p=8000; d=0,15','C, теңге','["C = n × p × (1 − d)"]','теңге','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-b02','122400','["18×8000=144 000 теңге.","144 000×0,85=122 400 теңге."]','Лицензияның шартын орындау тегін көшірме жасаумен алмастырылмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c01','software','C',1,'Файл жолы','Ағымдағы каталог /home/teacher/projects. ../materials/./unit1/../plan.txt салыстырмалы жолының толық нормаланған POSIX жолын жазыңыз.','Бастапқы: /home/teacher/projects','Абсолютті жол','[".. → ата-ана; . → ағымдағы каталог"]','жол','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c01','/home/teacher/materials/plan.txt','[".. projects каталогынан teacher-ге шығарады.","materials ішіне кіреміз; . өзгеріссіз.","unit1/.. бірін-бірі жояды: /home/teacher/materials/plan.txt."]','Абсолютті жол түбірден басталады; .. тізбегін солдан оңға өңдейміз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c02','software','C',2,'Процестер кезегі','FCFS жоспарлауында үш процесс t=0 кезінде A,B,C ретімен келеді. Орындалу ұзақтықтары 9, 3, 6 мс. Орташа күту уақытын табыңыз.','A=9; B=3; C=6 мс; келуі 0','Wорта, мс','["Wорта = (WA + WB + WC)/3"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c02','7','["A күтпейді:0. B:9. C:9+3=12 мс.","Орташа:(0+9+12)/3=7 мс."]','Күту уақытына процестің өзінің орындалуы кірмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c03','software','C',3,'Round Robin','A және B процестері t=0-де осы ретпен келді. CPU уақыты 5 және 3 мс, квант 2 мс, ауысу шығыны жоқ. A қай уақытта аяқталады?','A=5; B=3; q=2 мс','A аяқталуы, мс','["Әр кезекте min(q, қалған уақыт)"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c03','8','["0–2 A; 2–4 B; 4–6 A.","6–7 B аяқталады.","7–8 A соңғы 1 мс-ін орындайды."]','Квант біткенде аяқталмаған процесс кезектің соңына өтеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c04','software','C',4,'Жаңарту жүктемесі','40 компьютердің әрқайсысына 600 MB жаңарту керек. Кэш сервері интернеттен оны бір рет алады. Интернеттен қанша GB трафик үнемделеді? 1 GB=1000 MB.','n=40; V=600 MB','Үнем, GB','["ΔV = (n − 1) × V / 1000"]','GB','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c04','23.4','["Кэшсіз: 24 000 MB. Кэшпен: 600 MB.","Үнем: 23 400 MB=23,4 GB."]','Жергілікті желі трафигі бұл есепке кірмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c05','software','C',5,'Umask және құқықтар','Жаңа каталогқа сұралған POSIX mode777,umask027. Қосымша ACL жоқ. Нәтижедегі үш таңбалы сегіздік mode қандай?','requested777;umask027;r4,w2,x1','Сегіздік mode','["mode=requested AND NOT umask"]','код','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c05','750','["Owner:7-ден ешбір құқық алынбайды→7.","Group:жазу2 өшеді:7 AND NOT2=5.","Others:7 битінің бәрі өшеді→0;нәтиже750."]','Umask рұқсатты қосатын арифметика емес,сұралған mode-тың биттерін өшіретін маска.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c06','software','C',6,'Тәуелділік реті','A пакеті B мен C-ге, B пакеті D-ге тәуелді. Бос жүйеге A орнату керек. D,C,B,A реті жарамды ма? Иә немесе жоқ жазыңыз.','A→B,C; B→D','Реттің жарамдылығы','["Тәуелділік пакеттен бұрын орнатылады"]','жауап','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c06','иә','["D — B-ден бұрын.","B және C — A-дан бұрын.","Сондықтан D,C,B,A — жарамды топологиялық реттілік."]','Жарамды рет жалғыз болмауы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c07','software','C',7,'Жад ағыны','Программа бастапқыда 120 МиБ RAM пайдаланады. Әр сұраудан кейін босатылмаған 2 МиБ қалады. 512 МиБ шегінен аспай неше сұрау орындалады?','M₀=120; ΔM=2; шек=512 МиБ','n','["n = floor((Mmax − M₀)/ΔM)"]','сұрау','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c07','196','["Бос қор:512−120=392 МиБ.","392/2=196 сұрау.","197-сұраудан кейін514 МиБ болады."]','Операциялық жүйе жадын босату программаның ресурсты дұрыс қайтаруын алмастырмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c08','software','C',8,'Резерв нұсқасы','Файлдың базалық нұсқасы 20 MB, әр сақталған өзгеріс 3 MB. 8 өзгеріс және база сақталса, толық тоғыз 20 MB көшірмемен салыстырғанда қанша MB үнемделеді?','Vbase=20; delta=3; n=8','ΔV, MB','["ΔV = 9×Vbase − (Vbase + 8×delta)"]','MB','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c08','136','["Толық көшірмелер:9×20=180 MB.","База+өзгерістер:20+8×3=44 MB.","180−44=136 MB."]','Delta сақтау қалпына келтіру үшін базаның да сақталуын талап етеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c09','software','C',9,'Файл сәйкестігі','Жүктелген файлдың SHA-256 хэші сенімді арнадағы хэшке сәйкес емес. Файлды іске қосу керек пе? Иә немесе жоқ.','Екі SHA-256 хэш әртүрлі','Іске қосу шешімі','["Тұтастық: Hфайл = Hсенімді"]','жауап','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c09','жоқ','["Хэш сәйкес емес — байттар күткен файлдан өзгеше.","Файлды іске қоспай, сенімді көзден қайта алу керек."]','Хэш сәйкестігі тұтастықты тексереді; сенімді бастапқы хэш те қажет.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('software-c10','software','C',10,'Параллель жаңартулар','48 компьютерді бір мезгілде ең көбі 6 компьютерден жаңартуға болады. Бір топ 7 минутта бітеді, топтар қабаттаспайды. Барлық жаңарту неше минут?','n=48; k=6; t=7 мин','T, мин','["T = ceil(n/k) × t"]','мин','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('software-c10','56','["Топ саны:48/6=8.","8×7=56 минут."]','Шектеулі параллельдік жұмысты топтарға бөлуді қажет етеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-b01','memory','B',1,'Адрес разрядтылығы','Байтпен адрестелетін жадтың адресі 18 бит. Ең көп сыйымдылығын КиБ-пен табыңыз.','a=18 бит; ұяшық=1 байт','V, КиБ','["V = 2ᵃ / 1024"]','КиБ','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-b01','256','["2¹⁸=262 144 байт.","262 144/1024=256 КиБ."]','Адрес биттері санын дерек ұяшығының разрядтылығымен шатастырмаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-b02','memory','B',2,'Жад микросхемасы','Микросхемада 4096 ұяшық, әр ұяшық 16 бит. Сыйымдылығын КиБ-пен табыңыз.','N=4096; w=16 бит','V, КиБ','["V = N × w / (8×1024)"]','КиБ','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-b02','8','["4096×16=65 536 бит.","65 536/8/1024=8 КиБ."]','Ұяшық саны мен әр ұяшықтағы бит бірге есептеледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c01','memory','C',1,'Кэштің орташа кідірісі','Кэшке қарау 2 нс. Hit ықтималдығы 0,9; miss болса қосымша 80 нс кетеді. Орташа уақытты табыңыз.','tcache=2; Pmiss=0,1; penalty=80 нс','AMAT, нс','["AMAT = thit + Pmiss × penalty"]','нс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c01','10','["Кэшке қарау барлық сұрауға керек.","2+0,1×80=10 нс."]','Miss penalty бұл шартта кэшке қарау уақытына қосылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c02','memory','C',2,'Кэш адрес өрістері','32 биттік байт адресі, 16 КиБ direct-mapped cache, блок 64 байт. Tag өрісі неше бит?','a=32; C=16384 байт; B=64 байт','Tag биттері','["offset=log₂B; index=log₂(C/B); tag=a−offset−index"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c02','18','["Offset=6; жол саны=256, index=8.","Tag=32−6−8=18 бит."]','Кэштің direct-mapped болуы индекс санын анықтайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c03','memory','C',3,'Жад банктері','Бір чип 2¹⁸×8 бит. 2²⁰ ұяшықтан тұратын, әр ұяшығы16 бит жадты құрастыруға неше чип керек?','Чип:2¹⁸ ұяшық×8; мақсат:2²⁰×16','Чип саны','["n = (2²⁰/2¹⁸) × (16/8)"]','чип','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c03','8','["Адрес тереңдігі бойынша4 чиптік қатар керек.","Разрядтылық бойынша2 чип параллель.","4×2=8 чип."]','Мақсатты ұйым 2²⁰×16, жалпы көлемі2 МиБ; ұяшық пен байтты ажыратыңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c04','memory','C',4,'Беттерге бөлу','Виртуалды адрес 32 бит, бет 4 КиБ. Бір деңгейлі толық бет кестесінде әр жазба 4 байт. Кесте көлемін МиБ-пен табыңыз.','a=32; P=2¹² байт; E=4 байт','Vtable, МиБ','["V = 2^(a−log₂P) × E / 2²⁰"]','МиБ','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c04','4','["Бет саны:2²⁰.","Жазбалар:2²⁰×4 байт=4 МиБ."]','Бет offset-і бет кестесіне индекс ретінде қолданылмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c05','memory','C',5,'FIFO бет ауыстыру','Үш бос кадрға 1,2,3,1,4,1,2,5 беттері FIFO тәртібімен оқылады. Page fault санын табыңыз.','Кадр=3; тізбек=1 2 3 1 4 1 2 5','Fault саны','["Miss → ең бұрын жүктелген бетті ауыстыру"]','рет','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c05','7','["1,2,3 — алғашқы3 fault; келесі1 — hit.","4→1 ауысады; 1→2; 2→3; 5→4.","3+4=7 fault."]','FIFO hit кезінде беттің кезектегі жасын жаңартпайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c06','memory','C',6,'LRU бет ауыстыру','Үш бос кадр және 1,2,3,1,4,1,2,5 тізбегі үшін LRU page fault санын табыңыз.','Кадр=3; LRU','Fault саны','["Miss → ең ұзақ қолданылмаған бетті ауыстыру"]','рет','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c06','6','["1,2,3 —3 fault;1 қолданылған уақытын жаңартады.","4 келгенде2 шығады;1 —hit;2 келгенде3 шығады.","5 келгенде4 шығады: барлығы6 fault."]','LRU соңғы қолданылу уақытын, FIFO жүктелу ретін бақылайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c07','memory','C',7,'Қосарлы буфер','10 блоктың әрқайсысын оқу 8 мс, өңдеу 12 мс. Екі буфермен оқу мен өңдеу қабаттасады, алғашқы оқу бөлек. Жалпы ең аз уақыт?','n=10; read=8; compute=12 мс','T, мс','["T = read + compute + (n−1)×max(read,compute)"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c07','128','["Бірінші оқу8 мс; кейінгі кезеңнің ұзақтығы12 мс.","8+10×12=128 мс."]','Соңғы өңдеу де саналады, ал оқу/өңдеудің ұзын кезеңі конвейерді шектейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c08','memory','C',8,'Тураланған құрылым','Құрылымда ретімен 1 байттық char, 4 байттық int, 2 байттық short бар. Әр өріс өз өлшеміне тураланады, құрылым 4-ке еселікке толықтырылады. Бір құрылым неше байт?','Өлшемдер1,4,2; max alignment=4','Size, байт','["offset = align_up(offset, alignment)"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c08','12','["char:offset0; int:offset4, оған дейін3 padding.","short:offset8; соңғы offset10.","Құрылымды4-ке туралау:12 байт."]','Өрістер өлшемдерінің қосындысы padding-ті қамтымайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c09','memory','C',9,'Қатар адресі','32 биттік бүтіндер массиві 4096 адресінен басталады. Индекс 0-ден. A[37] бірінші байтының адресін табыңыз.','base=4096; w=4 байт; i=37','Адрес','["address = base + i×w"]','адрес','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c09','4244','["Бір элемент4 байт.","4096+37×4=4244."]','Индекс — элемент саны; адрес ығысуы байтпен есептеледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('memory-c10','memory','C',10,'Екі арналы RAM','Әр арна 64 бит, секундына 3200 миллион тасымал. Екі арнаның теориялық жиынтық өткізуін GB/с-пен табыңыз.','c=2; w=64; R=3200×10⁶ тасымал/с','B, GB/с','["B = c×(w/8)×R/10⁹"]','GB/с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('memory-c10','51.2','["Бір арна:8×3,2=25,6 GB/с.","Екі арна:51,2 GB/с."]','MT/s берілсе, DDR коэффициентін екінші рет көбейтпеңіз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-b01','alphabet','B',1,'Символ салмағы','Қуаттылығы 32 болатын алфавиттің бір символының тұрақты екілік коды неше бит?','N=32','i, бит','["i = log₂N"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-b01','5','["32=2⁵.","Бір символға5 бит жеткілікті."]','Тең ұзын код және екінің дәрежесі берілген.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-b02','alphabet','B',2,'Хабар көлемі','64 таңбалы алфавитпен 256 символ жазылды. Биттер тығыз оралған. Көлемі неше байт?','N=64; K=256','V, байт','["V = K×log₂N/8"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-b02','192','["Бір символ6 бит.","256×6/8=192 байт."]','Символ саны мен алфавит қуаттылығы әртүрлі шамалар.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c01','alphabet','C',1,'Екінің дәрежесі емес','Алфавитте 70 таңба бар. 1000 символды ең қысқа бірдей ұзындықты екілік кодпен тығыз сақтаймыз. Соңғы байт толықтырылады. Неше байт?','N=70; K=1000','V, байт','["i=ceil(log₂N); V=ceil(Ki/8)"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c01','875','["2⁶<70≤2⁷, сондықтан i=7.","1000×7=7000 бит=875 байт."]','Тұрақты код ұзындығы бүтін бит; log₂70-ті тікелей қолдануға болмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c02','alphabet','C',2,'Кері есеп','Хабарда 4096 символ бар, тығыз оралған коды 3 КиБ. Алфавит қуаттылығы 2-нің дәрежесі болса, N табыңыз.','K=4096; V=3072 байт','N','["i = 8V/K; N=2ⁱ"]','таңба','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c02','64','["i=3072×8/4096=6 бит.","N=2⁶=64."]','Көлемнен символ салмағын, одан алфавитті табамыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c03','alphabet','C',3,'Екі мәтін айырмасы','Бір мәтінде 300 символ, алфавиті16; екіншісінде200 символ, алфавиті128. Екінші мәтін біріншіден неше байт артық?','K₁=300,N₁=16; K₂=200,N₂=128','ΔV, байт','["ΔV = (K₂log₂N₂ − K₁log₂N₁)/8"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c03','25','["Бірінші:300×4=1200 бит.","Екінші:200×7=1400 бит.","Айырма200/8=25 байт."]','Әр мәтіннің өзіндік символ салмағы бар.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c04','alphabet','C',4,'Жазба толықтыруы','90 таңбалы алфавиттен 13 символдық идентификаторлар жасалады. Әр идентификатор бөлек бүтін байтпен сақталады. 800 идентификаторға неше байт?','N=90; K=13; n=800','V, байт','["V = n×ceil(K×ceil(log₂N)/8)"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c04','9600','["Бір символ7 бит; бір ID91 бит.","Бір ID ceil(91/8)=12 байт.","800×12=9600 байт."]','Дөңгелектеу әр идентификаторға бөлек жасалады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c05','alphabet','C',5,'Алфавит кеңеюі','1024 символдық мәтіннің алфавиті32-ден64-ке өсті. Символ саны өзгермейді. Тығыз кодтағы көлем неше байтқа артады?','K=1024; N₁=32; N₂=64','ΔV, байт','["ΔV = K×(log₂N₂−log₂N₁)/8"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c05','128','["Салмақ5-тен6 битке өседі.","1024×1/8=128 байт."]','Алфавит екі еселенгенде тұрақты кодқа1 бит қосылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c06','alphabet','C',6,'Символ санының шегі','1 КиБ буферге алфавиті50 болатын ең көп неше толық символ тығыз кодпен сыяды?','V=8192 бит; N=50','Kmax','["Kmax = floor(V/ceil(log₂N))"]','символ','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c06','1365','["i=6 бит.","floor(8192/6)=1365, қалдық2 бит."]','Толық символ ғана саналады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c07','alphabet','C',7,'Қызметтік дерек','Алфавиті256 хабарда512 символ бар. Әр хабарға24 байт тақырыпша қосылады. Осындай40 хабардың көлемін КиБ-пен табыңыз.','N=256; K=512; h=24; n=40','V, КиБ','["V = n×(Klog₂N/8+h)/1024"]','КиБ','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c07','20.9375','["Негізгі хабар512 байт; тақырыпшамен536.","40×536=21440 байт.","21440/1024=20,9375 КиБ."]','Тақырыпша әр хабарға қосылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c08','alphabet','C',8,'Символ кодтарының қоры','Алфавитте 130 символ, кодтары бірдей ұзындықты ең қысқа екілік код. Пайдаланылмаған код сөздерінің саны?','N=130; i=ceil(log₂130)','Бос кодтар','["R = 2ⁱ − N"]','код','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c08','126','["7 бит128-ге ғана жетеді,8 бит керек.","256−130=126 код бос."]','Алфавит қуаттылығы256-ға дейін өспесе де,8 бит бөлінеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c09','alphabet','C',9,'Тіркеу коды','Код 4 әріптен және3 цифрдан тұрады; әріп алфавиті26, цифр алфавиті10. Әр орындағы символ өз тобына сай ең қысқа тұрақты код алады. Бір код неше бит?','4 әріп;3 цифр; Nәріп=26,Nцифр=10','I, бит','["I = 4ceil(log₂26)+3ceil(log₂10)"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c09','32','["Әріпке5, цифрға4 бит.","4×5+3×4=32 бит."]','Барлық позицияға бір ортақ код емес, шарттағы екі бөлек код қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('alphabet-c10','alphabet','C',10,'Құжат пен шектеу','32 жол×48 символдан тұратын беттер алфавиті64 кодпен сақталады. 9 КиБ орынға неше толық бет сыяды?','L=32; K=48; N=64; D=9216 байт','Бет саны','["n = floor(8D/(L×K×log₂N))"]','бет','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('alphabet-c10','8','["Бір бет32×48×6=9216 бит=1152 байт.","9216/1152=8 бет."]','Биттегі бет көлемін байтқа айналдыруды ұмытпаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-b01','encoding','B',1,'ASCII коды','Негізгі ASCII кестесінде A=65. Латынның D әрпінің ондық кодын табыңыз.','A=65; әріптер тізбектес','ASCII(D)','["code(D) = code(A)+3"]','код','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-b01','68','["D әрпі A-дан3 орын кейін.","65+3=68."]','Негізгі ASCII —7 биттік128 код; кеңейтілген8 биттік кестелер бөлек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-b02','encoding','B',2,'UTF-8 көлемі','AӘ🙂 жолының UTF-8 көлемін табыңыз. A=U+0041, Ә=U+04D8, 🙂=U+1F642.','UTF-8:U+007F дейін1;U+07FF дейін2;U+FFFF дейін3; одан әрі4 байт','V, байт','["V = Σ UTF8_length(codepoint)"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-b02','7','["A1 байт; Ә2 байт.","🙂4 байт: жалпы1+2+4=7."]','Код нүктелерінің саны байт санына тең емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c01','encoding','C',1,'UTF-16 жұптары','Жолда 120 BMP таңба және30 U+1F600 emoji бар. BOM жоқ UTF-16 көлемі неше байт?','BMP=120; supplementary=30','V, байт','["V = 2×BMP + 4×supplementary"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c01','360','["BMP таңбалары240 байт.","30 суррогат жұбы120 байт.","Жалпы360 байт."]','UTF-16-да U+FFFF-тен үлкен код нүктесіне екі16 биттік бірлік керек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c02','encoding','C',2,'UTF-32 салыстыру','100 ASCII таңба мен50 қазақ BMP әрпі бар. UTF-8-де қазақ әрпі2 байт, UTF-32-де әр код нүктесі4 байт. UTF-32 қанша байт артық?','ASCII=100; қазақ=50; BOM жоқ','ΔV, байт','["ΔV = 4×(a+b) − (a+2b)"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c02','400','["UTF-8:100+100=200 байт.","UTF-32:150×4=600 байт.","Айырма400 байт."]','UTF-32 тұрақты ұзын, UTF-8 айнымалы ұзын кодтау.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c03','encoding','C',3,'Теріс сан коды','−37 санының8 биттік екілік қосымша кодын жазыңыз. Дәл8 бит енгізіңіз.','x=−37; n=8','8 биттік сөз','["code = 2⁸ − |x|"]','код','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c03','11011011','["256−37=219.","219=128+64+16+8+2+1.","Екілік сөзі11011011."]','Бұл — таңбалы8 биттік two’s complement, жеке минус таңбасы сақталмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c04','encoding','C',4,'Таңбалы интерпретация','11101010 биттік сөзін8 биттік қосымша кодтағы таңбалы сан деп оқыңыз.','bits=11101010','Ондық сан','["x = unsigned − 256, егер үлкен бит1 болса"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c04','-22','["Таңбасыз мән234.","Үлкен бит1:234−256=−22."]','Бір биттік тізбектің мәні қолданылған интерпретацияға тәуелді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c05','encoding','C',5,'Little-endian','16 биттік 0x3A7F саны little-endian жадта өсетін адрес бойынша қандай екі hex байтпен сақталады? Бос орынмен бөліңіз.','Сан=0x3A7F; кіші байт бірінші','Екі hex байт','["low = x AND 255; high = x >> 8"]','байттар','','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c05','7F 3A','["Кіші байт7F, үлкен байт3A.","Little-endian:7F алдымен,3A кейін."]','Байт реті ауысады, байт ішіндегі биттер кері айналмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c06','encoding','C',6,'Хэмминг аралығы','10110100 және10001101 сөздерінің Хэмминг аралығын табыңыз.','Екі8 биттік сөз','d','["d = popcount(a XOR b)"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c06','4','["XOR:00111001.","Бірлер саны4."]','Хэмминг аралығы — әртүрлі позициялардың саны.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c07','encoding','C',7,'XOR шифрлау','Байт 0x5A кілт 0xC3-пен XOR жасалды. Нәтижені екі hex таңбамен жазыңыз.','data=0x5A; key=0xC3','Hex нәтиже','["cipher = data XOR key"]','hex','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c07','99','["01011010 XOR11000011=10011001.","10011001₂=99₁₆."]','XOR бір кілтпен қайта қолданылса бастапқы байтты қайтарады; бұл жеке өзі қауіпсіз заманауи шифр емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c08','encoding','C',8,'Base64 өлшемі','Тақырыпшасыз1025 байт файл Base64-пен кодталады. Жол тасымалы жоқ, padding бар. Неше ASCII таңба шығады?','n=1025 байт','L, таңба','["L = 4×ceil(n/3)"]','таңба','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c08','1368','["ceil(1025/3)=342 топ.","342×4=1368 таңба."]','Соңғы топ4 таңбаға padding арқылы толықтырылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c09','encoding','C',9,'RLE тиімділігі','AAAABBBCCDAA жолы RLE-де әр серияға1 байт таңба және1 байт сан түрінде жазылады. Қысылған көлем неше байт?','Жол=AAAABBBCCDAA; серия=2 байт','V, байт','["V = 2×серия саны"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c09','10','["Сериялар:A4,B3,C2,D1,A2 —5 серия.","5×2=10 байт."]','Соңғы A сериясы алғашқы A-мен қосылмайды, өйткені арада өзге таңбалар бар.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('encoding-c10','encoding','C',10,'Префикстік код','A=0, B=10, C=110, D=111 коды берілген. 0101101110 ағынын декодтаңыз.','Префикстік кодтар; ағын0101101110','Әріптер тізбегі','["Солдан оңға толық код сөзі табылғанда бөлу"]','жол','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('encoding-c10','ABCDA','["0|10|110|111|0 деп бөлінеді.","Сәйкестіктер:A,B,C,D,A."]','Ешбір код екіншісінің префиксі болмағандықтан бірмәнді декодталады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-b01','number-systems','B',1,'Екіліктен ондыққа','110101₂ санының ондық мәнін табыңыз.','n=110101₂','n₁₀','["n = Σdᵢ2ⁱ"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-b01','53','["32+16+4+1=53.","Салмақтар оңнан0 дәрежеден басталады."]','Әр цифр өз позициясының2 дәрежесіне көбейтіледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-b02','number-systems','B',2,'Ондықтан hex-ке','254₁₀ санын hex жүйесінде екі таңбамен жазыңыз.','n=254','n₁₆','["254 = 15×16+14"]','hex','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-b02','FE','["Бөлінді15=F; қалдық14=E.","НәтижеFE."]','Hex цифрлары10–15 үшін A–F болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c01','number-systems','C',1,'Жүйелер қосындысы','2F₁₆ + 101101₂ + 73₈ қосындысын ондықпен табыңыз.','Үш түрлі негіз','Қосынды₁₀','["Σ әр санның позициялық мәні"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c01','151','["2F=47;101101=45;73₈=59.","47+45+59=151."]','Әртүрлі негіздегі цифр жазуларын тікелей қоспаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c02','number-systems','C',2,'Бөлшек екілік','101,101₂ санын ондық бөлшекпен жазыңыз.','n=101,101₂','n₁₀','["n = 2²+2⁰+2⁻¹+2⁻³"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c02','5.625','["Бүтін бөлік5.","Бөлшек0,5+0,125=0,625.","Нәтиже5,625."]','Үтірден кейінгі разрядтар2-нің теріс дәрежелері.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c03','number-systems','C',3,'Негізді табу','132ₓ саны ондықта56-ға тең. x негізін табыңыз.','1×x²+3×x+2=56; x>3','x','["x²+3x−54=0"]','негіз','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c03','6','["(x+9)(x−6)=0.","Негіз бүтін және3-тен үлкен: x=6.","Тексеру:36+18+2=56."]','Теріс түбір позициялық негіз болмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c04','number-systems','C',4,'Hex разряд саны','2²⁰−1 санын hex жүйесінде ең қысқа түрде жазыңыз.','n=1 048 575','Hex жазу','["4 бит = 1 hex цифры"]','hex','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c04','FFFFF','["2²⁰−1 —20 бірлік бит.","20/4=5 топ; әр топ1111=F."]','2 дәрежесінің алдындағы санның барлық төменгі биті1 болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c05','number-systems','C',5,'Бекітілген разряд overflow','Таңбасыз8 биттік регистрде250+19 қосылады. Тасымал алынып тасталса, регистрде қандай ондық мән қалады?','a=250;b=19;n=8','Регистр мәні','["r = (a+b) mod 2⁸"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c05','13','["Қосынды269.","269 mod256=13."]','Бекітілген разрядтағы арифметикада үлкен тасымал жоғалуы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c06','number-systems','C',6,'Екілік көбейту','1101₂ × 101₂ нәтижесін екілік түрде жазыңыз.','13×5','Екілік нәтиже','["n = 13×5; екілікке түрлендіру"]','код','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c06','1000001','["1101₂=13;101₂=5.","Көбейтінді65=64+1.","Жазуы1000001."]','Көбейту нәтижесінің разряд саны бастапқы сандардан артуы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c07','number-systems','C',7,'Биттік маска','0xB6 AND 0x6D нәтижесін ондықпен табыңыз.','a=10110110;b=01101101','r₁₀','["rᵢ = aᵢ AND bᵢ"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c07','36','["AND нәтижесі00100100.","32+4=36."]','Биттік AND әр позицияға жеке қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c08','number-systems','C',8,'Аралықтағы кодтар','Төрт таңбалы екілік жазудың бірінші цифры1 болуы керек. Онда дәл екі1 бар неше сан бар?','4 бит; жетекші1; барлығы2 бірлік','Сандар саны','["C(3,1)"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c08','3','["Бір1 жетекші орында бекітілген.","Қалған1 үш позицияның бірінде:1001,1010,1100."]','Жетекші битті қайта таңдауға болмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c09','number-systems','C',9,'Сегіздік бөлшек','17,4₈ санын ондыққа түрлендіріңіз.','n=17,4₈','n₁₀','["n = 1×8+7+4/8"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c09','15.5','["Бүтін15.","Бөлшек4/8=0,5.","Жалпы15,5."]','Сегіздік үтірден кейінгі бірінші разрядтың салмағы1/8.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('number-systems-c10','number-systems','C',10,'Биттер мен hex','0x3F80 санындағы1 биттер санын табыңыз.','Hex=3F80','popcount','["3=0011;F=1111;8=1000;0=0000"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('number-systems-c10','7','["Төрт цифрдағы бірлер:2,4,1,0.","Қосынды7."]','Әр hex цифр дәл4 биттік топқа сай келеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-b01','networks','B',1,'Топология кабелі','Жұлдыз топологиясында12 компьютер бір коммутаторға жеке қосылады. Компьютерлерді қосуға неше кабель керек?','n=12; әр компьютерден бір кабель','Кабель саны','["E = n"]','кабель','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-b01','12','["Әр компьютер коммутаторға жеке арнамен қосылады.","12 компьютерге12 кабель."]','Орталық коммутатор компьютер санына қосылмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-b02','networks','B',2,'Желі көлемі','Бір ғимараттағы24 компьютер ортақ жергілікті желіге қосылған. LAN, MAN, WAN ішінен желі түрін жазыңыз.','Ауқым:бір ғимарат','Желі түрі','["Бір ұйым/шағын аумақ → LAN"]','атау','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-b02','LAN','["Ғимарат ішіндегі байланыс жергілікті ауқымда.","Бұл LAN, кең географиялық WAN емес."]','Желі түрі тек компьютер санына емес, қамту аумағына тәуелді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c01','networks','C',1,'Толық тор байланысы','8 маршрутизатор толық mesh топологиясында әр жұбы бір кабельмен жалғанған. Екі кабель істен шыққаннан кейін неше кабель қалады?','n=8; үзілген=2','Eқалған','["E = n(n−1)/2 − 2"]','кабель','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c01','26','["Бастапқы байланыстар8×7/2=28.","28−2=26 кабель қалады."]','Екі бағытты бір кабельді екі рет санамаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c02','networks','C',2,'Сақинадағы маршрут','10 түйін0–9 болып сақинада ретімен орналасқан. Екі бағытта жіберуге болады. 1-түйіннен7-түйінге ең қысқа маршрут неше қабырға?','n=10; a=1; b=7','d','["d = min(|a−b|, n−|a−b|)"]','қабырға','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c02','4','["Бір бағытта6 қабырға.","Кері бағытта10−6=4.","Қысқасы4."]','Бірбағытты сақина болса бұл таңдау болмайды; шартта екі бағыт рұқсат.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c03','networks','C',3,'Store-and-forward','1500 байт пакет үш100 Мбит/с арнадан өтеді. Әр арнада propagation0,2 мс, router processing жоқ. Толық пакет қабылданбайынша келесі арнаға өтпейді. Жалпы мс?','L=12000 бит;R=10⁸;h=3;d=0,2 мс','T, мс','["T = h×(L/R×1000+d)"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c03','0.96','["Бір арна serialization:0,12 мс.","Әр арна0,12+0,2=0,32 мс.","Үш арна0,96 мс."]','Store-and-forward әр түйінде бүкіл пакетті күтеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c04','networks','C',4,'Пакеттер конвейері','Тең5 пакет үш бірдей арнадан store-and-forward арқылы өтеді. Бір пакетті бір арнамен жіберу2 мс, өзге кідіріс жоқ. Соңғы пакет неше мс-та жетеді?','n=5;h=3;t=2 мс','T, мс','["T = (n+h−1)×t"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c04','14','["Бірінші пакет3×2=6 мс-та жетеді.","Қалған4 пакет әр2 мс сайын:6+8=14 мс."]','Пакеттер желіде бір мезгілде әртүрлі арнада бола алады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c05','networks','C',5,'Сенімді арналар','Екі тәуелсіз резерв арнаның әрқайсысы99% ықтималдықпен жұмыс істейді. Кемінде біреуі жұмыс істейтін ықтималдық пайызбен?','p₁=p₂=0,99','P, %','["P = (1 − (1−p₁)(1−p₂))×100"]','%','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c05','99.99','["Екеуі бірдей істемейді:0,01×0,01=0,0001.","Кемінде бірі жұмыс істейді:0,9999=99,99%."]','Резерв арналары үшін екі арнаның да істен шығу ықтималдығын алып тастаймыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c06','networks','C',6,'Broadcast домендері','Коммутаторда VLAN10,20,30 бар. Екі router арқылы internet бар, VLAN-дар біріктірілмеген. Осы LAN ішінде неше broadcast domain бар?','VLAN саны3; L3 маршруттау','Broadcast domain саны','["Әр VLAN → бір broadcast domain"]','домен','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c06','3','["Әр VLAN broadcast кадрларын өз ішінде ұстайды.","Үш VLAN —3 broadcast domain."]','Router broadcast-ты әдетте L2 сияқты еркін таратпайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c07','networks','C',7,'Желі масштабы','6 бөлімнің әрқайсысында14 компьютер. Әр коммутаторда24 порт, бөлім ішінде бір коммутатор, оның1 порты uplink. Бөлімдерге ең аз неше access switch қажет?','Бөлім=6; клиент=14; пайдалы порт=23','Switch саны','["N = бөлім саны×ceil(клиент/23)"]','коммутатор','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c07','6','["Бір бөлімге14≤23, бір switch жеткілікті.","Бөлімдер бөлек болғандықтан6 switch керек."]','Бөлім шекарасын алып тастап84/23 деп бөлу шартқа сай емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c08','networks','C',8,'MTU және тақырыпша','MTU1500 байт, IP тақырыпша20, TCP тақырыпша20. 10 000 байт қолданбалық дерек ең аз неше TCP сегментке бөлінеді?','MTU=1500;headers=40;payload=10000','n','["MSS = MTU−40; n=ceil(data/MSS)"]','сегмент','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c08','7','["MSS=1460 байт.","6 сегмент8760 байт;1340 байт қалады.","Барлығы7 сегмент."]','MTU ішінде транспорт/желілік тақырыпша да бар.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c09','networks','C',9,'Кідіріс бюджеті','Жүйенің RTT шегі50 мс. Forward жолы12 мс, return жолы17 мс, екі шеттегі өңдеу әрқайсысы4 мс. Қосымша queueing-ге қанша мс қалады?','RTTmax=50;12,17,4,4 мс','Qmax','["Qmax = RTTmax−Σкідіріс"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c09','13','["Негізгі кідіріс12+17+4+4=37.","50−37=13 мс."]','RTT — екі бағыт пен берілген өңдеу кідірістерінің қосындысы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('networks-c10','networks','C',10,'Ең арзан маршрут','Салмақтары AB=4,AC=2,CB=1,BD=5,CD=8 болатын бағытталмаған желіде A-дан D-ға ең қысқа қашықтықты табыңыз.','Қырлар:AB4 AC2 CB1 BD5 CD8','d(A,D)','["d(v)=min(d(u)+w(u,v))"]','бірлік','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('networks-c10','8','["A→B→D=9;A→C→D=10.","A→C→B→D=2+1+5=8.","Ең аз мән8."]','Ең қысқа жол міндетті түрде ең аз түйін арқылы өтпейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-b01','bandwidth','B',1,'Файл жіберу','20 MB файл80 Мбит/с идеал арнамен жіберіледі. 1 MB=10⁶ байт. Уақытты табыңыз.','V=20×10⁶ байт;R=80×10⁶ бит/с','t, с','["t = 8V/R"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-b01','2','["Файл160 Мбит.","160/80=2 с."]','Байттағы көлем бит/с жылдамдықпен тікелей бөлінбейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-b02','bandwidth','B',2,'Алынған көлем','12 Мбит/с арна15 секундта неше MB дерек береді? Арна толық пайдалы.','R=12×10⁶; t=15','V, MB','["V = Rt/(8×10⁶)"]','MB','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-b02','22.5','["12×15=180 Мбит.","180/8=22,5 MB."]','MB ондық бірлік, МиБ емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c01','bandwidth','C',1,'Пайдалы тиімділік','300 МиБ файл100 Мбит/с арнамен жіберіледі, тиімділік75%. Ең аз уақыт неше секунд?','V=300×2²⁰;R=100×10⁶;η=0,75','t, с','["t = 8V/(Rη)"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c01','33.554432','["Пайдалы жылдамдық75 000 000 бит/с.","Көлем2 516 582 400 бит.","Бөлінді33,554432 с."]','Екілік файл көлемі мен ондық арна жылдамдығы бірге есептеледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c02','bandwidth','C',2,'Тар орын','Бір бағыттағы тізбекті арналар100,40,80 Мбит/с. Ұзақ тасымалдау тұрақталған соң800 Мбит деректі жіберудің теориялық уақытын табыңыз. Басқа кідірістер жоқ.','R=100,40,80;V=800 Мбит','t, с','["Rpath=min(Rᵢ); t=V/Rpath"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c02','20','["Тар орын40 Мбит/с.","800/40=20 с."]','Тізбекті арналардың өткізу қабілеттері қосылмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c03','bandwidth','C',3,'Ортақ арна','120 Мбит/с пайдалы арна5 оқушыға тең бөлінеді. Әрқайсысы90 MB файл жүктейді. Бір файл неше секундта бітеді?','R=120; n=5; V=90 MB','t, с','["t = 8Vn/R"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c03','30','["Әр оқушы24 Мбит/с алады.","90 MB=720 Мбит;720/24=30 с."]','Тең бөлінетін пайдалы арна деп берілген.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c04','bandwidth','C',4,'Қайта жіберу','10 000 пакеттің әрқайсысы1200 байт. Оның5%-ы дәл бір рет қайта жіберіледі. Пайдалы арна84 Мбит/с. Барлығын жіберу уақыты?','N=10000;L=1200;retry=500','t, с','["t = (N+Nretry)L×8/R"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c04','1.2','["Пакеттер10500; көлем100 800 000 бит.","100 800 000/84 000 000=1,2 с."]','Қайта жіберілген пакет бастапқы тасымалға қосымша саналады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c05','bandwidth','C',5,'Бейнеағын қоры','Бір бейнеағын6 Мбит/с. 100 Мбит/с арнаның20%-ы бос қалуы тиіс. Ең көп неше толық ағын?','R=100;reserve=20%;r=6','n','["n=floor(R×0,8/r)"]','ағын','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c05','13','["Қолданылатын жылдамдық80 Мбит/с.","floor(80/6)=13."]','14 ағын84 Мбит/с болып резерв шартын бұзады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c06','bandwidth','C',6,'Екі кезеңді жүктеу','Файлдың алғашқы60 MB бөлігі24 Мбит/с, келесі40 MB бөлігі40 Мбит/с жылдамдықпен келеді. Жалпы уақыт?','V₁=60;R₁=24;V₂=40;R₂=40','t, с','["t = 8V₁/R₁ + 8V₂/R₂"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c06','28','["Бірінші кезең480/24=20 с.","Екінші320/40=8 с.","Барлығы28 с."]','Жылдамдықтың жай арифметикалық орташа мәнін қолдану дұрыс емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c07','bandwidth','C',7,'Жылдамдық өсімі','80 MB файл бұрын16 с, енді10 с-та жүктеледі. Пайдалы жылдамдық қанша пайызға өсті?','V=640 Мбит;t₁=16;t₂=10','Өсім, %','["g = ((V/t₂)/(V/t₁)−1)×100"]','%','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c07','60','["Бұрын40 Мбит/с, қазір64 Мбит/с.","(64−40)/40×100=60%."]','Уақыт37,5%-ға азайса да жылдамдық60%-ға өседі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c08','bandwidth','C',8,'Көлем және тақырыпша','Әр пакетте1000 байт пайдалы дерек пен40 байт header бар. 10 MB пайдалы дерек104 Мбит/с шикі арнамен жіберіледі. Неше секунд?','payload=1000;h=40;V=10⁷ байт','t, с','["n=V/1000; t=n×1040×8/R"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c08','0.8','["10 000 пакет, толық көлем10 400 000 байт.","83 200 000/104 000 000=0,8 с."]','Пайдалы дерек пен арнаға берілетін толық көлем бөлек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c09','bandwidth','C',9,'Bandwidth-delay product','200 Мбит/с арна, RTT40 мс. Арнаны бос ұстамау үшін ең аз терезе көлемін ондық kB-пен табыңыз.','R=200×10⁶;RTT=0,04 с','W, kB','["W=R×RTT/(8×1000)"]','kB','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c09','1000','["Жолдағы биттер8 000 000.","1 000 000 байт=1000 kB."]','Бұл RTT бойы жіберілетін дерек көлемі; протокол үстемесін есептемейміз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('bandwidth-c10','bandwidth','C',10,'Қысу пайдалы ма','120 MB файлды қысу4 с алады, көлемі50%-ға азаяды. Арна40 Мбит/с. Қысумен және қысусыз уақыт айырмасы қанша секунд?','V=120 MB;k=0,5;tcomp=4;R=40','Үнем, с','["Δt=8V/R−(tcomp+8Vk/R)"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('bandwidth-c10','8','["Қысусыз960/40=24 с.","Қысумен4+480/40=16 с.","Үнем8 с."]','Қысудың есептеу уақыты да жалпы кідіріске кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-b01','ip','B',1,'IPv4 желі адресі','192.168.14.77/24 адресінің желі адресін жазыңыз.','IP=192.168.14.77;prefix=/24','Network address','["Network = IP AND mask"]','IPv4','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-b01','192.168.14.0','["/24 алғашқы3 октетті сақтайды.","Хост бөлігі0:192.168.14.0."]','Желі адресінде хост биттерінің бәрі0.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-b02','ip','B',2,'Хост саны','Кәдімгі IPv4 /27 ішкі желісінде желі мен broadcast-ты алып тастағанда неше хост адресі бар?','prefix=27; /31,/32 жағдайы емес','H','["H=2^(32−p)−2"]','хост','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-b02','30','["Хост биті5, адрес32.","32−2=30."]','/31 мен /32 үшін арнайы ережелер бар, бұл есеп кәдімгі LAN туралы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c01','ip','C',1,'Маска және AND','172.19.83.201 адресі255.255.240.0 маскасымен берілген. Желі адресі?','IP=172.19.83.201; mask=/20','Network','["83 AND240 = 80"]','IPv4','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c01','172.19.80.0','["Үшінші октет83=01010011, mask240=11110000.","AND=01010000=80; соңғы октет0."]','Маска октетінің шекарасы міндетті түрде255 не0 болмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c02','ip','C',2,'Broadcast','10.24.37.18/22 желісінің broadcast адресін табыңыз.','IP=10.24.37.18;/22','Broadcast','["Broadcast = Network OR inverted_mask"]','IPv4','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c02','10.24.39.255','["/22 үшін үшінші октет қадамы4:36–39.","Желі10.24.36.0; соңғы адрес10.24.39.255."]','Broadcast адресінде хост биттері1 болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c03','ip','C',3,'Соңғы хост','192.168.5.150/26 желісінің соңғы қолданылатын хост адресін жазыңыз.','/26; блок64','Last usable','["Last = broadcast − 1"]','IPv4','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c03','192.168.5.190','["150 саны128–191 блогында.","Broadcast191, соңғы хост190."]','Желі адресі128 және broadcast191 хостқа берілмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c04','ip','C',4,'VLSM бөлу','/24 блоктан алдымен60 хостқа, кейін30 хостқа, кейін12 хостқа жеткілікті ең кіші блоктар бөлінді. Жалпы неше адрес резервтеледі?','Host қажеттілігі60,30,12','Бөлінген толық адрес саны','["B=Σ2^ceil(log₂(H+2))"]','адрес','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c04','112','["60 хостқа64 адрес;30-ға32;12-ге16.","64+32+16=112."]','Блок көлеміне желі және broadcast адрестері де кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c05','ip','C',5,'Екі желіні салыстыру','192.168.10.63 және192.168.10.64 адресі /26 маскасымен бір желіде ме? Иә/жоқ.','/26; қадам64','Шешім','["Same ⇔ (IP₁ AND M)=(IP₂ AND M)"]','жауап','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c05','жоқ','["63 бірінші0–63 блокта.","64 келесі64–127 блокта."]','Бірінің broadcast не network болуы да оларды бір желіге біріктірмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c06','ip','C',6,'Subnet саны','10.0.0.0/16 блогы /21 желілерге бөлінді. Неше ішкі желі шығады?','pold=16;pnew=21','Nsub','["Nsub=2^(pnew−pold)"]','желі','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c06','32','["Қосымша5 бит желіге бөлінеді.","2⁵=32."]','Subnet саны хост битінен емес, prefix айырмасынан табылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c07','ip','C',7,'Агрегация','192.168.32.0/24-тен192.168.39.0/24-ке дейінгі8 тізбектес желіні бір дәл CIDR блокпен жабыңыз.','32–39; сегіз /24; шекара тураланған','CIDR','["p=24−log₂8"]','CIDR','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c07','192.168.32.0/21','["8 желіге3 бит керек, prefix21.","32 саны8-ге еселік, блок32–39."]','Тізбектестікпен бірге басталу шекарасы да дұрыс болуы тиіс.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c08','ip','C',8,'Алғашқы хост индексі','172.16.8.0/23 желісінде хосттар желіден кейін1-ден саналады. 300-ші қолданылатын хосттың адресі?','base=172.16.8.0;index=300','IPv4','["Host = network + index"]','IPv4','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c08','172.16.9.44','["300=256+44.","Үшінші октет8+1=9, соңғы44."]','/23 хост кеңістігі келесі октетке тасымалдауға мүмкіндік береді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c09','ip','C',9,'Минималды префикс','Кәдімгі ішкі желіге500 хост қажет. Адрес шығыны ең аз IPv4 prefix ұзындығын табыңыз.','H=500','p','["h=ceil(log₂(H+2)); p=32−h"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c09','23','["256−2 аз;512−2=510 жеткілікті.","h=9, prefix32−9=23."]','Ең ұзын жеткілікті prefix ең кіші блокты береді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ip-c10','ip','C',10,'IPv6 қысқарту','2001:0db8:0000:0000:0020:0000:0000:0001 адресін RFC5952 қағидасымен қысқартыңыз: тең ұзын нөлдер тізбегінде сол жақтағысы алынады.','Екі ұзындығы2 нөл тізбегі','Қысқартылған IPv6','["Жетекші0-дерді жою; ең ұзын тізбек → ::"]','IPv6','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ip-c10','2001:db8::20:0:0:1','["Әр топтың жетекші0-лері жойылады.","Алғашқы екі0 тобы :: болады.",":: адрес ішінде тек бір рет қолданылады."]','Тең ұзын тізбекте сол жақтағысы таңдалады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-b01','dns','B',1,'DNS рөлі','Браузер www.example.test атауына IP іздейді. DNS, DHCP, FTP ішінен осы қызметті жазыңыз.','Домен→IP сәйкестігі','Қызмет','["Атау → ресурс жазбасы"]','атау','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-b01','DNS','["DNS атауларға қатысты ресурс жазбаларын береді.","DHCP адрес конфигурациясын, FTP файл тасымалын атқарады."]','DNS бір ғана IP емес, әртүрлі жазба түрлерін басқарады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-b02','dns','B',2,'TTL қалдығы','DNS жауабы t=100 с кезінде TTL=600 с болып кэшке түсті. t=460 с кезінде қалған TTL қанша?','t₀=100;TTL=600;t=460','TTLқалған, с','["remaining=max(0,TTL−(t−t₀))"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-b02','240','["Өткен уақыт460−100=360 с.","600−360=240 с."]','TTL кэшке салынған сәттен есептеледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c01','dns','C',1,'Alias арқылы IPv6','www.test CNAME app.test; app.test CNAME edge.test; edge.test A 192.0.2.5 және AAAA 2001:db8::5 жазбалары бар. IPv6 сұрауының соңғы адресін жазыңыз.','Екі CNAME; бір A және бір AAAA','Ақырғы IPv6 адресі','["CNAME тізбегін ашу → AAAA таңдау"]','IPv6','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c01','2001:db8::5','["www.test→app.test→edge.test.","IPv6 үшін A емес AAAA алынады.","Ақырғы адрес2001:db8::5."]','Alias атауы мен адрес жазбасының түрін бөлек талдаймыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c02','dns','C',2,'Итеративті кідіріс','Кэш бос. Resolver root,TLD,authoritative серверлеріне ретімен сұрау жібереді; әр RTT20 мс. Клиент-resolver RTT6 мс. Өңдеу0. Клиентке жалпы уақыт?','3 тәуелді сұрау×20; клиент6 мс','T, мс','["T = RTTclient + ΣRTTlookup"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c02','66','["Үш іздеу3×20=60 мс.","Клиент round trip-пен66 мс."]','Сұраулар ретімен орындалады, сондықтан RTT-лер қосылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c03','dns','C',3,'Кэш тиімділігі','1000 DNS сұрауының80%-ы кэште2 мс, қалғаны сыртқы іздеумен52 мс-та орындалады. Орташа жауап уақыты?','hit=0,8;tH=2;tM=52','E[T], мс','["E[T]=pH×tH+(1−pH)×tM"]','мс','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c03','12','["0,8×2=1,6.","0,2×52=10,4;қосынды12 мс."]','Miss уақыты52 мс толық берілген, оған2 мс-ті қайта қоспаймыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c04','dns','C',4,'CNAME тізбегі','a.test → b.test CNAME TTL300; b.test A TTL120. Екі жазба бір сәтте алынды. Сол жауапты жаңа A сұраусыз ең көп неше секунд қолдануға болады?','TTLc=300;TTLa=120','Қауіпсіз мерзім','["TTLchain=min(TTLᵢ)"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c04','120','["Адрес жазбасы120 с-та ескіреді.","CNAME300 с тұрса да адреске120 с шек қойылады."]','Тізбектің бір буыны ескірсе, оған сүйенген толық жауапты жаңарту қажет.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c05','dns','C',5,'DNS атауының шегі','Қысусыз wire атау ең көбі255 байт. Бес label ұзындықтары63,63,63,3,x; әр label алдында1 байт ұзындық, соңында1 байт түбір бар. Соңғы label-ға ең көп неше таңба сыяды? Әр таңба1 байт, label шегі63.','Ұзындықтар63,63,63,3,x; overhead6 байт','xmax','["xmax=min(63,255−Σknown_lengths−6)"]','таңба','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c05','57','["Белгілі таңбалар63×3+3=192 байт.","Бес ұзындық пен түбір6 байт.","255−192−6=57;63 шегінен аспайды."]','Толық атау шегі мен жеке label шегінің екеуі де орындалуы керек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c06','dns','C',6,'MX және қолжетімділік','MX:mail1 preference10 қолжетімсіз;mail2 preference20 қолжетімді;mail3 preference5 қолжетімсіз;mail4 preference10 қолжетімді. Қолжетімсіз серверлерге әрекеттері біткеннен кейін қай сервер таңдалады?','Алдымен төмен preference;екі сервер қолжетімсіз','Таңдалған сервер','["Қолжетімді жиыннан min(preference)"]','атау','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c06','mail4','["Ең жоғары басымдықmail3,бірақ қолжетімсіз.","Preference10 ішінен mail1 қолжетімсіз,mail4 қолжетімді.","mail4 mail2-ден бұрын таңдалады."]','Кіші preference басым,бірақ жеткізу үшін сервердің қолжетімділігі де қажет.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c07','dns','C',7,'Negative caching','Домен жоқ деген жауап TTL180 с-пенt=0-де алынды. Доменt=60-та жасалды. Осы кэшке сүйенген клиент ең ерте қай секундта жаңадан сұрауы тиіс?','NXDOMAIN TTL180; өзгерісt60','t, с','["expiry = cached_at + TTL"]','с','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c07','180','["Клиенттің кэші өзгерісті бірден білмейді.","Кэш t=180-де ескіреді."]','DNS өзгерісі барлық кэшке бір мезетте тарамайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c08','dns','C',8,'DNS wire өлшемі','www.school.test атауы DNS wire форматында әр label алдындағы1 байт ұзындықпен және соңғы0 байтпен жазылады. Қысусыз атау неше байт?','Label ұзындықтары3,6,4','V, байт','["V=Σ(1+Lᵢ)+1"]','байт','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c08','17','["(1+3)+(1+6)+(1+4)=16.","Түбірдің0 байтын қосқанда17."]','Мәтіндегі нүктелер wire форматында label ұзындықтарымен ауысады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c09','dns','C',9,'Кэш жүктемесі','Бір доменге әр секундта100 сұрау келеді. TTL60 с. Кэште алғаш жоқ, тұрақты сұрау үздіксіз келеді. t=0-денt=179-ға дейін authoritative-ке неше жаңарту кетеді?','TTL=60;t∈[0,179]','Жаңарту саны','["Қайта іздеу t=0,TTL,2TTL,…"]','сұрау','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c09','3','["Жаңарту сәттері0,60,120.","180 берілген аралыққа кірмейді.","Барлығы3."]','Кэш әр клиент сұрауына сыртқы сұрау жібермейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('dns-c10','dns','C',10,'DNSSEC шекарасы','DNSSEC қолтаңбасы жарамды болғанда DNS жауабының құпиялылығы автоматты қамтамасыз етіле ме? Иә/жоқ.','Қолтаңба тексерілген; шифрлау бөлек көрсетілмеген','Құпиялылық туралы шешім','["Signature → түпнұсқалық/тұтастық; encryption → құпиялылық"]','жауап','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('dns-c10','жоқ','["DNSSEC деректің түпнұсқалығы мен тұтастығын тексереді.","Жауапты шифрлау оның жеке міндеті емес."]','Жарамды қолтаңба желідегі бақылаушыдан сұрау мазмұнын жасыруға тең емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-b01','logic','B',1,'Құрама өрнек','A=1,B=0,C=1 болса, (A AND NOT B) OR (B AND C) мәнін табыңыз.','A1;B0;C1','F','["F=(A∧¬B)∨(B∧C)"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-b01','1','["NOT B=1;A AND1=1.","B AND C=0;1 OR0=1."]','NOT алдымен, содан кейінAND, ең соңындаOR есептеледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-b02','logic','B',2,'Ақиқат кесте көлемі','5 тәуелсіз екілік айнымалының толық ақиқат кестесінде неше жол бар?','n=5','Жол саны','["N=2ⁿ"]','жол','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-b02','32','["Әр айнымалының2 мүмкіндігі бар.","2⁵=32 комбинация."]','Кестеге тек бірліктер емес, барлық комбинациялар кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c01','logic','C',1,'Ақиқат жолдары','Үш айнымалы үшін (A XOR B) AND C өрнегі неше комбинацияда1 болады?','A,B,C∈{0,1}','1 болатын жол саны','["A XOR B=1 ⇔ A≠B"]','жол','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c01','2','["C міндетті1.","A,B үшін01 және10 ғана.","Барлығы2 жол."]','OR мен XOR бірдей емес:11 жағдайында XOR0.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c02','logic','C',2,'Де Морган','NOT(A OR B) AND C өрнегіне тең өрнекті қысқа сөздермен жазыңыз: NOT A AND NOT B AND C немесе NOT A OR NOT B OR C.','Терістелген дизъюнкция','Тең өрнек','["¬(A∨B)=¬A∧¬B"]','өрнек','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c02','NOT A AND NOT B AND C','["ТерістеуOR-дыAND-қа ауыстырады.","Екі операнд та терістеледі;C өзгермейді."]','Де Морган түрлендіруінде операция да, операндтардың терістелуі де өзгереді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c03','logic','C',3,'Минимизация','F=(A AND B) OR (A AND NOT B). Тек A, B, 0, 1 жауаптарының бірін беріңіз.','F=AB+A¬B','Қарапайым F','["F=A(B∨¬B)"]','өрнек','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c03','A','["B OR NOT B=1.","A AND1=A."]','Қарама-қарсы B мәндерінің толықтығы B-ге тәуелділікті жояды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c04','logic','C',4,'Majority қақпасы','F=(A AND B) OR (A AND C) OR (B AND C) үш кірісті функциясы неше ақиқат жолда1?','n=3; кемінде екі кіріс1','Жол саны','["C(3,2)+C(3,3)"]','жол','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c04','4','["Дәл екі1 бар3 жол.","Үш1 бар1 жол.","Қосынды4."]','Бұл көпшілік дауысы функциясы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c05','logic','C',5,'NAND желісі','X=NAND(A,B);Y=NAND(A,X);Z=NAND(B,X);F=NAND(Y,Z). A=B=1 кезінде F мәнін табыңыз.','A=B=1; төрт NAND','F','["NAND(u,v)=NOT(u AND v)"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c05','0','["X=0;Y=NAND(1,0)=1;Z=1.","F=NAND(1,1)=0."]','Бұл желі XOR іске асырады, сондықтан тең кірістерде0.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c06','logic','C',6,'Блок-схема циклі','s=0,i=1. i≤10 болса s=s+i, i=i+2, шартқа оралады. Соңында s неге тең?','i:1,3,5,…≤10','s','["s=1+3+5+7+9"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c06','25','["Қосылатын сандар1,3,5,7,9.","Қосынды25; келесі i=11, цикл бітеді."]','Шарт әр қайталанудың алдында тексеріледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c07','logic','C',7,'Цикл тармағы','x=4,y=1. x>0 болғанша: x жұп болса y=y×2, тақ болса y=y+3; әр айналым соңында x=x−1. Соңғы y?','x=4;y=1','y','["Тармақ → жаңарту → x азайту"]','сан','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c07','13','["x4:y2; x3:y5.","x2:y10; x1:y13.","Тізбекті мұқият есептеу нәтижесі13."]','Әр тармақ соңғы y мәніне қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c08','logic','C',8,'Эквиваленция саны','Төрт айнымалы үшін (A↔B) AND (C XOR D) неше жолда1 болады?','A,B,C,D∈{0,1}','Жол саны','["N=тең жұп саны×әртүрлі жұп саны"]','жол','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c08','4','["A,B:00 не11 —2 жағдай.","C,D:01 не10 —2 жағдай.","2×2=4."]','Тәуелсіз айнымалы жұптарының мүмкіндіктері көбейеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c09','logic','C',9,'Импликация','A→B импликациясы0 болатын A B жұбын бос орынмен жазыңыз.','A,B екілік','A B','["A→B = NOT A OR B"]','жұп','','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c09','1 0','["Импликация тек шарт ақиқат, нәтиже жалған кезде жалған.","СондықтанA1,B0."]','00,01,11 жолдарының бәрінде импликация1.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('logic-c10','logic','C',10,'Ақиқат векторы','F=(NOT A AND B) OR (A AND NOT C). Жолдар ABC=000,001,…,111 ретімен. Нәтиженің8 биттік векторын жазыңыз.','Рет:000–111','F векторы','["F=¬A·B + A·¬C"]','код','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('logic-c10','00111010','["A0 кезіндеF=B:0,0,1,1.","A1 кезіндеF=NOT C:1,0,1,0.","Біріктірсек00111010."]','Кесте жолдарының ретін ауыстыру векторды өзгертеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-b01','spreadsheets','B',1,'Арифметикалық формула','A1=12,B1=5. C1 формуласындағы нәтиже?','A1=12;B1=5','C1','["Алдымен жақша, кейін көбейту/бөлу"]','сан','= (A1+B1)*2','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-b01','34','["12+5=17.","17×2=34."]','Формула = таңбасынан басталады; ұяшық адресі оның мәнін береді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-b02','spreadsheets','B',2,'Салыстырмалы сілтеме','C2 ұяшығында =A2+B2. Формула C3-ке бір жол төмен көшірілді. A3=8,B3=11 болса жаңа нәтиже?','Көшіру:(0,+1); A3=8;B3=11','C3','["Салыстырмалы жол адресі ығысумен өзгереді"]','сан','=A2+B2','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-b02','19','["A2→A3, B2→B3.","8+11=19."]','$ белгісі жоқ жолдар көшіру кезінде ығысады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c01','spreadsheets','C',1,'Абсолютті коэффициент','C2-де =A2*$B$1. Оны C5-ке көшірді. A5=240,B1=0,15. C5 мәні?','A5=240;B1=0,15;Δrow=3','C5','["Салыстырмалы A2→A5; $B$1 бекітілген"]','сан','=A2*$B$1','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c01','36','["Формула=A5*$B$1.","240×0,15=36."]','$ бағанды да жолды да бекітіп, коэффициентті ортақ сақтайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c02','spreadsheets','C',2,'Аралас сілтеме','C3-те =$A3*B$1 формуласын E5-ке көшірді. A5=7,D1=9. Жаңа ұяшықтың мәні?','Δcol=2;Δrow=2;A5=7;D1=9','E5','["Бекітілмеген координата ғана ығысады"]','сан','=$A3*B$1','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c02','63','["$A3→$A5:баған бекітілген.","B$1→D$1:жол бекітілген.","7×9=63."]','Аралас сілтеменің баған/жол бөліктерін жеке талдаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c03','spreadsheets','C',3,'Диапазон және қосынды','A1:A5 мәндері4,7,−2,9,6. B1=SUM(A1:A5)−MAX(A1:A5). Нәтиже?','A=[4,7,−2,9,6]','B1','["SUM барлық санды, MAX ең үлкенін алады"]','сан','=SUM(A1:A5)-MAX(A1:A5)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c03','15','["SUM=24;MAX=9.","24−9=15."]','Теріс мән де қосындыға өз таңбасымен кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c04','spreadsheets','C',4,'Шартты санау','A1:A8 мәндері40,75,90,75,60,100,55,80. =COUNTIF(A1:A8,">=75")−COUNTIF(A1:A8,">90") нәтижесі?','8 балл;75 кіреді,90 екінші шартқа кірмейді','Нәтиже','["COUNTIF(range, criterion)"]','сан','=COUNTIF(A1:A8,">=75")-COUNTIF(A1:A8,">90")','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c04','4','["≥75:75,90,75,100,80 —5.",">90:100 —1.","5−1=4."]','Шарттағы ≥ мен > шекарасын ажыратыңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c05','spreadsheets','C',5,'Шартты қосынды','A1:A5 — A,B,A,C,A; B1:B5 —10,20,30,40,50. =SUMIF(A1:A5,"A",B1:B5)/COUNTIF(A1:A5,"A") мәні?','Санаттар мен сомалар қатарлас','A санатының орташа мәні','["Mean = SUMIF / COUNTIF"]','сан','=SUMIF(A1:A5,"A",B1:B5)/COUNTIF(A1:A5,"A")','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c05','30','["A қатарлары10,30,50.","Қосынды90,саны3.","90/3=30."]','SUMIF шарты бір диапазонда, қосылатын мәндері басқа диапазонда болуы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c06','spreadsheets','C',6,'Тармақталған баға','A2=82,B2=3. =IF(AND(A2>=80,B2<=2),"A",IF(A2>=60,"B","C")) қандай мәтін қайтарады?','score82;absence3','Баға','["IF(condition,true,false); AND екі шартты да талап етеді"]','мәтін','=IF(AND(A2>=80,B2<=2),"A",IF(A2>=60,"B","C"))','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c06','B','["Бірінші AND:ақиқат AND жалған→жалған.","Ішкі82≥60 ақиқат: B."]','Ұпай жоғары болса да қосымша қатысу шарты бірінші тармақты жояды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c07','spreadsheets','C',7,'Іздеу және көбейту','A1:B3 кестесі:101→12,102→15,103→20. D1=102,E1=4. =VLOOKUP(D1,A1:B3,2,FALSE)*E1 нәтижесі?','D1=102;E1=4;exact lookup','Нәтиже','["VLOOKUP(key,table,column,FALSE)"]','сан','=VLOOKUP(D1,A1:B3,2,FALSE)*E1','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c07','60','["Нақты102 кодының бағасы15.","15×4=60."]','FALSE жуық интервал емес, кілттің дәл сәйкестігін іздейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c08','spreadsheets','C',8,'Сан мен мәтін','A1:A5 ұяшықтары:10; бос; мәтін түріндегі20; =5+5; "жоқ" мәтіні. COUNTA(A1:A5)−COUNT(A1:A5) неге тең?','Шын бос ұяшық біреу;20 мәтін ретінде сақталған','Айырма','["COUNTA:бос емес;COUNT:сан"]','сан','=COUNTA(A1:A5)-COUNT(A1:A5)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c08','2','["Бос емес4 ұяшық.","Сан екеу:10 және формула нәтижесі10.","4−2=2."]','Мәтін болып сақталған сан COUNT арқылы сан болып есептелмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c09','spreadsheets','C',9,'Пайыздық пішім','A1 мәні0,125. Custom number format0.00% қолданылды. Ағылшын locale-де ұяшықта қандай мәтін көрінеді?','Value0.125;format0.00%;decimal point','Көрінетін мәтін','["Display = value×100 және % таңбасы"]','мәтін','0.00%','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c09','12.50%','["0,125×100=12,5.","Екі ондық таңбамен12.50%."]','Пішім сақтау мәнін өзгертпейді; формулалар әлі0,125-пен есептейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('spreadsheets-c10','spreadsheets','C',10,'Көшірілетін жиынтық','C2-де =SUM($A$2:A2). C5-ке көшірілді. A2:A5=3,5,7,9. Нәтиже?','Басы абсолютті;соңы салыстырмалы','C5','["Жинақталған сумма:Σ A2…A5"]','сан','=SUM($A$2:A2)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('spreadsheets-c10','24','["Диапазон$A$2:A5 болады.","3+5+7+9=24."]','Аралас бекіту көшірген сайын өсетін диапазон құруға мүмкіндік береді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-b01','python','B',1,'Сызықтық есеп','Python3 кодының жалғыз шығарылымын жазыңыз.','a=17;b=5','stdout','["// бүтін бөлік; % қалдық"]','сан','a, b = 17, 5
print((a // b) * 10 + a % b)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-b01','32','["17//5=3;17%5=2.","3×10+2=32."]','Бүтін бөлу мен қалдық бір бөлу амалының екі нәтижесі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-b02','python','B',2,'Тармақ реті','Код не шығарады?','x=12; if/elif','stdout','["if/elif:алғашқы ақиқат тармақ"]','мәтін','x = 12
if x % 2 == 0:
    print("even")
elif x % 3 == 0:
    print("three")
else:
    print("other")','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-b02','even','["12 жұп,бірінші шарт ақиқат.","elif орындалмайды,even шығады."]','Бірнеше шарт дұрыс болса да if/elif тізбегі бір тармақты орындайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c01','python','C',1,'Қос цикл','Кодта s неге тең болады?','range1…4;ішкіj<i','stdout','["ΣᵢΣⱼ(i+j)"]','сан','s = 0
for i in range(1, 5):
    for j in range(1, i):
        s += i + j
print(s)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c01','30','["i1:0; i2:3; i3:4+5=9.","i4:5+6+7=18.","Барлығы0+3+9+18=30."]','range тоқтау шегін қоспайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c02','python','C',2,'Тізім alias','Код соңындағы a элементтерін бос орынмен жазыңыз.','b=a ортақ объект; c=a[:] көшірме','a тізімі','["alias ортақ; slice жаңа тізім"]','тізбек','a = [1, 2, 3]
b = a
c = a[:]
b[1] = 8
c.append(9)
print(*a)','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c02','1 8 3','["b[1] a-ны да өзгертеді.","c.append тек көшірмені өзгертеді.","a=[1,8,3]."]','Айнымалыны меншіктеу объектінің өзін міндетті түрде көшірмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c03','python','C',3,'Кесінді','Код қандай тізбек шығарады?','a=0…9;теріс қадам','stdout','["slice(start,stop,step),stop кірмейді"]','тізбек','a = list(range(10))
print(*a[8:2:-2])','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c03','8 6 4','["8-ден2-ге дейін кері2 қадам.","8,6,4;2 шекке кірмейді."]','Теріс қадамда индекс төмендейді, stop бәрібір алынбайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c04','python','C',4,'Bubble swap','Көрсетілген сұрыптау алгоритмі неше swap жасайды?','a=[4,1,3,2]','swaps','["Әр swap бір инверсияны жояды"]','сан','a = [4, 1, 3, 2]
swaps = 0
for end in range(len(a)-1, 0, -1):
    for j in range(end):
        if a[j] > a[j+1]:
            a[j], a[j+1] = a[j+1], a[j]
            swaps += 1
print(swaps)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c04','4','["4 санынан кейін1,3,2:үш инверсия.","3 пен2 тағыбір инверсия.","Барлығы4 swap."]','Bubble sort-та көршілес орын ауыстыру саны бастапқы инверсия санына тең.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c05','python','C',5,'Тұрақты сұрыптау','sorted операциясынан кейінгі аттарды бос орынмен жазыңыз.','Бағалары70,90,70;score бойынша','Аттар реті','["Python sorted тұрақты:тең кілт бастапқы ретті сақтайды"]','тізбек','a = [("Ali", 70), ("Bota", 90), ("Dana", 70)]
print(*(name for name, score in sorted(a, key=lambda p: p[1])))','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c05','Ali Dana Bota','["70 балл Ali мен Dana бастапқы ретін сақтайды.","90 балл Bota соңына өтеді."]','Кілт тең болғанда атау бойынша қосымша сұрыптау берілмеген.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c06','python','C',6,'Тізім құрастыру','Кодтың тізбек нәтижесін жазыңыз.','x=1…6;жұптарға−x','stdout','["expression if condition else expression"]','тізбек','print(*[x*x if x % 2 else -x for x in range(1, 7)])','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c06','1 -2 9 -4 25 -6','["Тақ мәндер квадратталады:1,9,25.","Жұп мәндер терістеледі:−2,−4,−6."]','Бұл шарт элементтерді сүзбейді, әр элемент үшін екі өрнектің бірін таңдайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c07','python','C',7,'Break және else','Код қандай мәтін шығарады?','a=[2,4,7,8];алғашқы тақ','stdout','["for else тек break болмаса орындалады"]','мәтін','for x in [2, 4, 7, 8]:
    if x % 2:
        print(x)
        break
else:
    print("none")','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c07','7','["2,4 өткізіледі;7 тақ болғанда print жәнеbreak.","else тармағы орындалмайды."]','Циклдегі else — if-тің else тармағы емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c08','python','C',8,'Цифрларды талдау','Кодта k мәнін табыңыз.','n=50740;әр цифр тексеріледі','stdout','["digit=n%10; n//=10"]','сан','n, k = 50740, 0
while n > 0:
    if n % 10 >= 4:
        k += 1
    n //= 10
print(k)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c08','3','["Соңынан цифрлар0,4,7,0,5.","Шартқа4,7,5 сай:барлығы3."]','Нөл цифры while-ді тоқтатпайды; n бүтін бөлігі ғана шартқа кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c09','python','C',9,'Матрица диагоналі','Кодтың нәтижесін табыңыз.','3×3 матрица;негізгі мен қосалқы диагональ','stdout','["Σ a[i][i] − Σ a[i][n−1−i]"]','сан','a = [[1,2,3],[4,5,6],[7,8,9]]
print(sum(a[i][i] for i in range(3)) - sum(a[i][2-i] for i in range(3)))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c09','0','["Негізгі диагональ1+5+9=15.","Қосалқы3+5+7=15.","Айырма0."]','Орталық элемент екі қосындыда да бар және айырмада жойылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('python-c10','python','C',10,'Екі көрсеткіш','Код не шығарады?','Өсу ретімен тізім;target10','stdout','["Екі шеттен:қосындыға қарай көрсеткішті жылжыту"]','сан','a = [1, 2, 3, 7, 9]
l, r, k = 0, len(a)-1, 0
while l < r:
    s = a[l] + a[r]
    if s == 10:
        k += 1
        l += 1
        r -= 1
    elif s < 10:
        l += 1
    else:
        r -= 1
print(k)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('python-c10','2','["1+9=10:бір жұп.","2+7=9:сол жақ өседі;3+7=10:екінші жұп.","Барлығы2."]','Бұл алгоритм индекстерді әр жұптан кейін ішке жылжытады; барлық қайталанатын жұптарды санайтын жалпы алгоритм емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-b01','functions','B',1,'Return мәні','Код не шығарады?','f(a,b)=a²−b','stdout','["Функция нәтижесі аргументтерге тәуелді"]','сан','def f(a, b):
    return a*a - b
print(f(4, 3))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-b01','13','["f(4,3)=16−3=13.","return мәнді шақыру орнына береді."]','print пен return бірдей амал емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-b02','functions','B',2,'Процедура нәтижесі','Кодтың екі шығарылымын бір жолға бос орынмен жазыңыз.','show ішінде return жоқ','stdout','["Айқын return жоқ → None"]','тізбек','def show(x):
    print(x * 2)
y = show(3)
print(y)','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-b02','6 None','["show(3) алдымен6 шығарады.","Функция None қайтарады;сыртқы print None шығарады."]','Процедура деп қолданылған Python функциясы да None мәнін қайтарады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c01','functions','C',1,'Евклид рекурсиясы','f(84,30) нәтижесі?','Рекурсивті gcd','stdout','["gcd(a,b)=gcd(b,a%b)"]','сан','def f(a, b):
    return a if b == 0 else f(b, a % b)
print(f(84, 30))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c01','6','["84%30=24;30%24=6.","24%6=0, базалық жағдай6."]','Әр рекурсивті қадам екінші аргументті кішірейтеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c02','functions','C',2,'Рекурсия шақыру саны','Кодта f неше рет шақырылады?','f(4);екі тармақ;база n≤1','stdout','["C(n)=1+C(n−1)+C(n−2)"]','рет','calls = 0
def f(n):
    global calls
    calls += 1
    if n <= 1:
        return n
    return f(n-1) + f(n-2)
f(4)
print(calls)','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c02','9','["C0=C1=1;C2=3;C3=5.","C4=1+5+3=9."]','Базалық шақырулар да есепке кіреді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c03','functions','C',3,'Әдепкі mutable аргумент','Код шығаратын екі санды жазыңыз.','Бір default list бірнеше шақыруда сақталады','stdout','["Default аргумент функция анықталғанда бір рет жасалады"]','тізбек','def f(x, a=[]):
    a.append(x)
    return len(a)
print(f(1), f(2))','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c03','1 2','["Бірінші f тізімге1 қосады:ұзындығы1.","Екінші сол тізімге2 қосады:ұзындығы2."]','Қажет болса None default-пен әр шақыруда жаңа list жасаңыз.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c04','functions','C',4,'Жергілікті айнымалы','Код не шығарады?','global x10;local x7','stdout','["Local мен global бөлек атау кеңістігі"]','тізбек','x = 10
def f():
    x = 7
    return x * 2
print(f(), x)','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c04','14 10','["Функция ішіндегіx=7;return14.","Сыртқыx әлі10."]','global жарияланбаған local меншіктеу сыртқы айнымалыны өзгертпейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c05','functions','C',5,'Тізімді өзгерту','Кодтан кейін a қандай?','append ортақ объект;қайта binding жергілікті','stdout','["Mutation объектіні, меншіктеу атау сілтемесін өзгертеді"]','тізбек','def f(a):
    a.append(3)
    a = [9]
a = [1, 2]
f(a)
print(*a)','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c05','1 2 3','["append бастапқы тізімді[1,2,3] етеді.","a=[9] тек жергілікті атауды өзгертеді."]','Аргументтің объектісін өзгерту мен аргумент атауын қайта меншіктеу бөлек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c06','functions','C',6,'Keyword аргумент','Функция шақыруының мәні?','a міндетті;b2;c3 әдепкі','stdout','["Атаулы аргумент позициясына қарамастан өз параметріне беріледі"]','сан','def f(a, b=2, c=3):
    return 100*a + 10*b + c
print(f(1, c=5, b=4))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c06','145','["a=1,b=4,c=5.","100+40+5=145."]','Көрсетілмеген default қана қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c07','functions','C',7,'Nonlocal жинақтау','Код екі шақыруда не шығарады?','Closure ортақ s0;өсім3,5','stdout','["nonlocal сыртқы функция айнымалысын өзгертеді"]','тізбек','def make():
    s = 0
    def add(x):
        nonlocal s
        s += x
        return s
    return add
f = make()
print(f(3), f(5))','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c07','3 8','["Алғашқы қадамs=0+3=3.","Екінші сол s-ке5 қосылады:8."]','Closure функция аяқталғаннан кейін де күйді сақтайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c08','functions','C',8,'Lambda late binding','Кодтың нәтижесін жазыңыз.','Үш lambda ортақ i атауын қарайды','stdout','["Closure мәнді емес, атауға сілтемені сақтайды"]','тізбек','fs = [lambda: i for i in range(3)]
print(*(f() for f in fs))','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c08','2 2 2','["Цикл соңындаi=2.","Барлықlambda шақырылғанда осы2-ні оқиды."]','Әр i-ді бекіту үшін lambda i=i: i сияқты default қолдануға болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c09','functions','C',9,'Рекурсивті цифр қосындысы','f(4729) нәтижесі?','База:n<10;қалған цифрларға рекурсия','stdout','["sumdigits(n)=n%10+sumdigits(n//10)"]','сан','def f(n):
    if n < 10:
        return n
    return n % 10 + f(n // 10)
print(f(4729))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c09','22','["9+2+7+4=22.","База4 болғанда рекурсия тоқтайды."]','Әр қадам бір ондық цифрды бөліп алады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('functions-c10','functions','C',10,'Ерте return','Код қандай сан қайтарады?','n=12;алғашқы бөлгіш','stdout','["Алғашқы return функцияның қалған бөлігін тоқтатады"]','сан','def first_divisor(n):
    for d in range(2, n):
        if n % d == 0:
            return d
    return n
print(first_divisor(12))','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('functions-c10','2','["range2…11 ішінде алғашқы2 бөлгіш.","return2 орындалады;кейінгі цикл жалғаспайды."]','return тек циклден емес, бүкіл функциядан шығады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-b01','html-css','B',1,'HTML құрылымы','Берілген HTML-де неше li элементі бар?','ul ішінде li','Элемент саны','["DOM бойынша тегтерді санау"]','элемент','<ul><li>Python</li><li>SQL</li><li>HTML</li></ul>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-b01','3','["li тегтеріҮш:Python,SQL,HTML.","ul —контейнер,ол li санына кірмейді."]','Ашушы және жабушы тег бір элементтің екі шекарасы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-b02','html-css','B',2,'CSS font-size','Негізгі элемент font-size20px. Оның баласы font-size1.5em. Баланың font-size мәні px-пен?','parent20px;child1.5em','font-size, px','["child_size = parent_size × em"]','px','<div style="font-size:20px"><span style="font-size:1.5em">X</span></div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-b02','30','["1em ата-ананың20px өлшеміне тең.","1,5×20=30px."]','font-size үшін em ата-ананың есептелген қаріп өлшеміне сүйенеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c01','html-css','C',1,'Content-box ені','div үшін width200px,padding10px екі жақтан,border2px екі жақтан,margin0,box-sizing:content-box. Сыртқы border-box ені?','w200;p10;b2','Ені, px','["W = content + 2padding + 2border"]','px','<div style="box-sizing:content-box;width:200px;padding:10px;border:2px solid">X</div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c01','224','["Padding20px, border4px.","200+20+4=224px."]','content-box width тек контенттің енін береді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c02','html-css','C',2,'Border-box контенті','div border-box width240px,padding15px,border3px. Контент ені қанша?','W240;p15;b3','Content width','["content = width−2padding−2border"]','px','<div style="box-sizing:border-box;width:240px;padding:15px;border:3px solid">X</div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c02','204','["240−30−6=204px.","Жалпы border-box240 болып қалады."]','border-box padding пен border-ді берілген width ішіне қосады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c03','html-css','C',3,'Бала селекторы','Кодта .box > p селекторы неше элементті таңдайды?','Тек тікелей бала p','Match count','["> тікелей бала; бос орын барлық ұрпақ"]','элемент','<div class="box"><p>бір</p><section><p>екі</p></section><p>үш</p></div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c03','2','["Тікелей p:бір жәнеүш.","section ішіндегіекі тікелей бала емес."]','Селектор ұрпақ тереңдігін ескереді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c04','html-css','C',4,'Nth-child сүзгісі','ul > li:nth-child(2n+1) селекторы7 li тізімінің неше элементін таңдайды?','Жеті қатар;индекс1-ден','Match count','["2n+1 = 1,3,5,…"]','элемент','<ul><li>1</li><li>2</li><li>3</li><li>4</li><li>5</li><li>6</li><li>7</li></ul>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c04','4','["Позициялар1,3,5,7.","Барлығы4."]','nth-child индексі0-ден емес1-ден саналады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c05','html-css','C',5,'Specificity','Төмендегі кодта p түсінің CSS атауы қандай болады? Inline/important жоқ.','p.blue және#x','color','["ID specificity > class > type"]','түс','<style>#x{color:red} p.blue{color:blue}</style><p id="x" class="blue">X</p>','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c05','red','["#x ID селекторы p.blue-дан басым.","Сондықтан red."]','Кейін жазылған ереже тек басымдықтары тең болғанда шешуші болады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c06','html-css','C',6,'Important каскады','p элементінің түсі қандай?','inline blue;stylesheet important green','color','["Бір author origin-де important әдеттегі inline-нан басым"]','түс','<style>p{color:green !important}</style><p style="color:blue">X</p>','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c06','green','["green ережесі !important.","Кәдімгі inline blue оны баса алмайды."]','Маңыздылық деңгейі specificity-ден бұрын салыстырылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c07','html-css','C',7,'Rem және em','html font-size16px;section font-size20px. Баланың padding-left2rem және margin-left1.5em. Осы екі аралықтың қосындысы px-пен?','root16;local20;2rem+1.5em','Қосынды, px','["2×root + 1,5×local"]','px','<style>html{font-size:16px} section{font-size:20px} p{padding-left:2rem;margin-left:1.5em}</style><section><p>X</p></section>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c07','62','["2rem=32px.","1,5em=30px;қосынды62px."]','rem түбірге, бұл margin em элементтің өзінің font-size мәніне сүйенеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c08','html-css','C',8,'Flex gap','Ені500px flex контейнерде ені100px үш бала бар. justify-content:space-between, gap20px. Іргелес балалар арасындағы нақты бос аралық неше px?','W500;items3×100;gap20','Аралық, px','["Жалпы бос орын = W−Σitem; екі аралыққа бөлінеді"]','px','<div style="display:flex;width:500px;justify-content:space-between;gap:20px"><i style="width:100px"></i><i style="width:100px"></i><i style="width:100px"></i></div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c08','100','["Бос орын500−300=200px.","Gap міндетті40px алған соң160px екіаралыққа80px-ден қосылады.","Нақты аралық20+80=100px."]','gap пен space-between екеуін бір-біріне тәуелсіз толық бос орын ретінде екі рет қоспау керек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c09','html-css','C',9,'Grid бағаны','Ені620px grid контейнерде grid-template-columns:repeat(3,1fr);gap10px. Әр бағанның ені? Балалардың min-width0, padding жоқ.','W620;columns3;gaps2×10','Column width, px','["col=(W−(n−1)gap)/n"]','px','<div style="display:grid;width:620px;grid-template-columns:repeat(3,1fr);gap:10px"><i></i><i></i><i></i></div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c09','200','["Gap жалпы20px.","(620−20)/3=200px."]','fr тек gap алынғаннан кейінгі бос кеңістікті бөледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('html-css-c10','html-css','C',10,'Media шарт','Viewport ені800 CSS px. Қарапайым cascade бойынша div width қандай px болады?','Негізгі200;min-width700→300;min-width900→400','Width, px','["Тек шарты true media ережелері қолданылады"]','px','<style>div{width:200px}@media(min-width:700px){div{width:300px}}@media(min-width:900px){div{width:400px}}</style><div>X</div>','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('html-css-c10','300','["800≥700,екінші ереже іске қосылады.","800<900,үшінші ереже қолданылмайды.","Ені300px."]','Media шарт құрылғының физикалық пикселіне емес CSS viewport өлшеміне сүйенеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-b01','sql','B',1,'WHERE сүзгісі','Сұрау қайтаратын санды табыңыз.','learners кестесі4 жол','COUNT','["COUNT(*) сүзгіден өткен жолдарды санайды"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners WHERE klass=10;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-b01','2','["10-сыныптаAli менDana.","Олардың саны2."]','WHERE топтаудан бұрын жеке жолдарды сүзеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-b02','sql','B',2,'NULL және AVG','Сұраудағы AVG мәні?','score:80,90,60,90,NULL','AVG','["AVG = SUM(non-null)/COUNT(non-null)"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT AVG(score) FROM results;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-b02','80','["Сандық балл қосындысы320.","NULL кірмейді:320/4=80."]','SQL AVG бос мәнді0 деп қоспайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c01','sql','C',1,'JOIN жолдарының саны','Сұрау нәтижесін табыңыз.','learners PK;results FK логикалық байланыс','COUNT','["INNER JOIN әр сәйкес жұпты береді"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l JOIN results r ON l.id=r.student_id;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c01','5','["Ali үшін2,Bota1,Dana2 сәйкестік бар.","Erke-де нәтиже жоқ.","2+1+2=5."]','Бір оқушыға бірнеше нәтиже болса JOIN оны бірнеше жолмен көрсетеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c02','sql','C',2,'LEFT JOIN санау','Сұраудың санын табыңыз.','Erke-де results жоқ','COUNT(*)','["LEFT JOIN сол жақ жолды сақтайды"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l LEFT JOIN results r ON l.id=r.student_id;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c02','6','["Бар5 нәтиже сәйкестігі сақталады.","Erke үшін NULL-мен толықтырылған1 жол қосылады.","Барлығы6."]','COUNT(*) NULL өрістер болса да жолды санайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c03','sql','C',3,'Бос нәтижелер','Сұрау қанша оқушы табады?','Erke-де нәтиже жоқ;Dana-да бірNULL score бар','COUNT','["r.student_id IS NULL — сәйкестік болмауын тексеру"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l LEFT JOIN results r ON l.id=r.student_id WHERE r.student_id IS NULL;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c03','1','["Dana-ның NULL баллында student_id=3 бар.","ТекErke-де join сәйкестігі жоқ.","Саны1."]','NULL score мен мүлде нәтиже жолының болмауы бөлек жағдай.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c04','sql','C',4,'HAVING топтары','Сұрауда сыртқы COUNT неге тең?','Әр оқушының non-null орташа ұпайы','COUNT топтар','["GROUP BY → AVG → HAVING"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM (SELECT student_id FROM results GROUP BY student_id HAVING AVG(score)>=85) q;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c04','2','["Ali орташа85;Bota60;Dana90.","85-тен кем емес топтарAli,Dana.","Саны2."]','HAVING жеке баллды емес, топтың агрегат нәтижесін сүзеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c05','sql','C',5,'Біріктірілген қосынды','Сұраудың SUM мәнін табыңыз.','10-сынып:Ali,Dana','SUM','["JOIN → WHERE → SUM"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(r.score) FROM learners l JOIN results r ON l.id=r.student_id WHERE l.klass=10;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c05','260','["Ali балдары80+90=170.","Dana-ның сандық баллы90.","170+90=260."]','NULL қосындыға0 ретінде емес, есепке алынбай қатысады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c06','sql','C',6,'Үшмәнді логика','Сұрауда COUNT неге тең?','score80,90,60,90,NULL','COUNT','["NULL<>80 → UNKNOWN, WHERE алмайды"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM results WHERE score<>80;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c06','3','["80 жолы алынбайды.","90,60,90 алынады;NULL белгісіз болып өтпейді.","Саны3."]','NULL-мен салыстыру үшін IS NULL/IS NOT NULL қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c07','sql','C',7,'DISTINCT ұғымы','Сұрау неше бірегей student_id санайды?','python нәтижелері:1,2,3','COUNT DISTINCT','["Қайталанбайтын, NULL емес кілттер"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(DISTINCT student_id) FROM results WHERE topic=''python'';','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c07','3','["Python жолдарыAli,Bota,Dana-ға тиесілі.","БаллNULL болса да student_id=3 саналады."]','COUNT(DISTINCT student_id) score бағаныныңNULL-ын тексермейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c08','sql','C',8,'ORDER BY tie-break','Сұраудың жалғыз student_id мәнін табыңыз.','Ең жоғары балл90 екі оқушыда','student_id','["score DESC;теңде student_id ASC"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT student_id FROM results WHERE score IS NOT NULL ORDER BY score DESC, student_id ASC LIMIT 1;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c08','1','["Ең жоғары90:Ali id1,Dana id3.","Екінші кілт кішіid1-ді алдына қояды."]','LIMIT алдында детерминделген tie-break керек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c09','sql','C',9,'NOT EXISTS','Сұрау неше жол береді?','SQL нәтижесіAli менDana-да бар','COUNT','["NOT EXISTS байланысқан ішкі сұраудың бос болуын тексереді"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l WHERE NOT EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id AND r.topic=''sql'');','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c09','2','["SQL жолы жоқ оқушыларBota жәнеErke.","Барлығы2."]','Корреляция әр оқушыныңid-сі үшін бөлек тексеріледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('sql-c10','sql','C',10,'CASE агрегаты','Сұраудағы санды табыңыз.','Өткен балл≥80;NULL өтпейді','SUM CASE','["CASE WHEN true THEN1 ELSE0"]','сан','CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(CASE WHEN score>=80 THEN 1 ELSE 0 END) FROM results;','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('sql-c10','3','["80,90,90 —үш өткен нәтиже.","60 жәнеNULL ELSE0 береді."]','ELSE0 агрегатқа сандық0 береді, ал шарттыңNULL мәні true емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-b01','ai','B',1,'Оқыту түрі','Әр хат spam/normal белгісімен берілген; модель жаңа хаттың осы екі санатын үйренеді. Supervised, unsupervised, reinforcement ішінен түрін жазыңыз.','Кіріс хат;белгі spam/normal','Түр','["Белгіленген мысал → supervised learning"]','түр','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-b01','supervised','["Деректерде дұрыс санат белгілері бар.","Модель кірістен белгіге сәйкестікті үйренеді."]','Кластерлеуде алдын ала дұрыс белгі берілмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-b02','ai','B',2,'Train бөлігі','2000 жазба80% train,10% validation,10% test болып бөлінеді. Train жазба саны?','N=2000;p=0,8','Ntrain','["Ntrain=Np"]','жазба','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-b02','1600','["2000×0,8=1600.","Қалған400 жазба validation/test-ке бөлінеді."]','Test жиыны соңғы тәуелсіз бағалауға сақталады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c01','ai','C',1,'Precision','TP=36,FP=12,FN=9,TN=43. Precision пайызбен?','TP36;FP12;FN9;TN43','Precision, %','["Precision=TP/(TP+FP)×100"]','%','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c01','75','["Оң болжам48.","36/48×100=75%."]','Precision оң деп болжанғандардың қаншасы дұрыс екенін көрсетеді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c02','ai','C',2,'Recall','TP=42,FP=8,FN=14,TN=36. Recall пайызбен?','TP42;FN14','Recall, %','["Recall=TP/(TP+FN)×100"]','%','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c02','75','["Нақты оңдар56.","42/56=0,75."]','Recall табылмай қалғанFN-ді есепке алады,FP-ді емес.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c03','ai','C',3,'F1 теңгерімі','Precision=0,8,Recall=0,5. F1-ді төрт ондық таңбаға дейін дөңгелектеңіз.','P=0,8;R=0,5','F1','["F1=2PR/(P+R)"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c03','0.6154','["2×0,8×0,5=0,8.","0,8/1,3=0,615384…","Төрт таңбамен0,6154."]','F1 — жай орта емес, гармониялық орта.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c04','ai','C',4,'Min-max масштаб','Train минимум10, максимум50. Validation ішіндегі30 мәнін тек train параметрлерімен0–1 шкаласына айналдырыңыз.','min10;max50;x30','xscaled','["xscaled=(x−min)/(max−min)"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c04','0.5','["Ауқым40;ығысу20.","20/40=0,5."]','Validation/test деректерімен min/max қайта үйрету ақпараттың ағуына әкелуі мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c05','ai','C',5,'Z-score','Train орташа60, стандартты ауытқу8. x=76 үшін z-score?','μ60;σ8;x76','z','["z=(x−μ)/σ"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c05','2','["76−60=16.","16/8=2."]','Бұл мән ортадан2 стандартты ауытқуға жоғары.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c06','ai','C',6,'k-NN көпшілік','Жаңа нүктеге ең жақын5 көршінің арақашықтық/санаттары:1:A,2:B,3:B,4:A,5:B. Салмақсыз k=3 болса, санат?','Алғашқы3 көрші;теңдік жоқ','Санат','["Кіші k арақашықтықтағы көпшілік"]','санат','','text');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c06','B','["Алғашқы3:A,B,B.","B екі дауыс алады."]','k=3 болғанда төртінші жәнебесінші көрші шешімге кірмейді.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c07','ai','C',7,'Сызықтық регрессия','Модель ŷ=2x+3. x=1,2,3 үшін нақты y=4,8,8. MSE табыңыз.','ŷ5,7,9;y4,8,8','MSE','["MSE=Σ(ŷ−y)²/n"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c07','1','["Қателер1,−1,1.","Квадраттар1+1+1=3.","MSE3/3=1."]','Квадраттау таңбаларды жояды және үлкен қатені күштірек жазалайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c08','ai','C',8,'Теңгерімсіз жиын','1000 мысалдың950-і normal,50-і spam. Барлығын normal дейтін модельдің accuracy пайызы және spam recall пайызы қандай? Екі санды жазыңыз.','950 normal;50 spam;барлықболжамnormal','accuracy recall','["Accuracy=(TP+TN)/N;Recall=TP/(TP+FN)"]','пайыздар','','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c08','95 0','["Дұрыс950/1000=95%.","Spam TP0,FN50:recall0%."]','Жоғары accuracy сирек оң санатты мүлде таппайтын модельде де болуы мүмкін.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c09','ai','C',9,'Қате құны','A моделіндеFP=20,FN=5;B моделіндеFP=8,FN=9. FP құны1,FN құны4. A жалпы шығыны B-дан қаншаға аз?','costFP1;costFN4','CostB−CostA','["Cost=FP×cFP+FN×cFN"]','бірлік','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c09','4','["A:20+5×4=40.","B:8+9×4=44.","Айырма4."]','Модель таңдауда қателердің нақты құнын ескеру пайдалы.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('ai-c10','ai','C',10,'Information gain','8 жазбаның4-і A,4-і B. Split солға4 A,оңға4 B бөледі. log₂ қолданыңыз. Ақпарат өсімі неше бит?','Түбір теңгерімді;екі таза бала','IG','["H=−Σp log₂p; IG=Hparent−Σweight×Hchild"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('ai-c10','1','["Түбір энтропиясы1 бит.","Таза баланың энтропиясы0.","IG=1−0=1."]','Таза топта санат белгісіздігі жоқ;0log0 шегі0 деп алынады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-b01','neural-networks','B',1,'Нейронның сызықтық бөлігі','x=[2,−1],w=[3,4],b=1. z мәнін табыңыз.','Екі кіріс;bias1','z','["z=Σwᵢxᵢ+b"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-b01','3','["3×2+4×(−1)+1=3.","Bias қосындыға бір рет қосылады."]','Салмақ белгісі кірістің әсер бағытын анықтайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-b02','neural-networks','B',2,'ReLU','z=−2,5 үшін ReLU(z) мәні?','z=−2,5','a','["ReLU(z)=max(0,z)"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-b02','0','["−2,5<0.","ReLU теріс кірісті0 етеді."]','ReLU теріс бөлікте0,оң бөліктеөз мәнін қайтарады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c01','neural-networks','C',1,'Екі қабат','x=[2,1]. Жасырын h1=ReLU(x1−2x2+1),h2=ReLU(−x1+3x2). Шығыс y=2h1−h2+1. y?','x1=2;x2=1','y','["Әр қабатта z→ReLU, кейіншығыс"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c01','2','["h1=ReLU(2−2+1)=1.","h2=ReLU(−2+3)=1.","y=2−1+1=2."]','Қабат аралық activation-ды өткізіп кетуге болмайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c02','neural-networks','C',2,'Dense параметрлері','4 кіріс→6 жасырын→3 шығыс fully-connected желі. Әр нейрондаbias бар. Барлық үйретілетін параметр саны?','4→6→3;bias әр non-input нейронда','P','["P=(in+1)out әр қабатқа"]','параметр','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c02','51','["Бірінші қабат(4+1)×6=30.","Екінші(6+1)×3=21.","Барлығы51."]','Кіріс түйінінің өз bias-ы болмайды; әр келесі нейрондікі саналады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c03','neural-networks','C',3,'Convolution параметрлері','RGB кіріс үшін3×3 өлшемді8 фильтр,әр фильтрдеbias1. Параметр саны?','kernel3×3;channels3;filters8','P','["P=(kh×kw×Cin+1)×Cout"]','параметр','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c03','224','["Бір фильтр3×3×3=27 салмақ+bias1.","28×8=224."]','Фильтр салмақтары кескін позициялары арасында ортақ қолданылады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c04','neural-networks','C',4,'Convolution шығыс өлшемі','Кіріс32×32,filter5×5,stride1,padding0. Бір шығыс картасының ені?','N32;K5;S1;P0','Wout','["Wout=floor((N+2P−K)/S)+1"]','пиксель','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c04','28','["(32−5)/1+1=28.","Filter ең соңғы жарамдыпозицияда тоқтайды."]','Valid convolution padding қоспайды.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c05','neural-networks','C',5,'Gradient descent','Бір үлгі үшінŷ=wx,x=2,y=5,w=1. L=(ŷ−y)². Learning rate0,1. Бір жаңартудан кейін w?','x2;y5;w1;η0,1','wnew','["dL/dw=2(wx−y)x;wnew=w−ηgrad"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c05','2.2','["ŷ=2;қате−3.","Gradient2×(−3)×2=−12.","wnew=1−0,1×(−12)=2,2."]','Бұл loss-та1/2 коэффициенті жоқ;градиентте2 қалады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c06','neural-networks','C',6,'Sigmoid ортасы','z=0 үшінsigmoid мәні және0,5 шегімен p≥0,5 кезінде берілетін санат қандай? Екі сан жазыңыз.','σ(z)=1/(1+e^(−z));threshold0,5','p class','["σ(0)=1/2"]','тізбек','','sequence');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c06','0.5 1','["e⁰=1,σ0=0,5.","p≥0,5 болғандықтансанат1."]','Шекке теңдік қай сыныпқа жататыны шартта анық көрсетілуі керек.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c07','neural-networks','C',7,'Softmax ықтималдығы','Екіlogit z1=2,z2=2. Бірінші санаттыңsoftmax ықтималдығы?','z1=z2','p1','["p1=e^z1/(e^z1+e^z2)"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c07','0.5','["Екіэкспонентабірдей.","a/(a+a)=0,5."]','Softmax барлықсанаттар үшінбір нормалау қосындысын қолданады.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c08','neural-networks','C',8,'Cross-entropy','Нақтысанатқа берілген ықтималдық0,125. log₂ қолданылған cross-entropy неше бит?','ptrue=1/8','L','["L=−log₂(ptrue)"]','бит','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c08','3','["0,125=2⁻³.","−log₂(2⁻³)=3."]','Табиғи логарифм қолданылса бірлікnatболареді;шарттабит берілген.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c09','neural-networks','C',9,'Dropout scaling','Inverted dropout кезіндеpdrop=0,25. Сақталғанactivation6 үйрету кезінде қандаймәнге масштабталады?','keep=0,75;a=6','ascaled','["ascaled=a/(1−pdrop)"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c09','8','["Keep ықтималдығы0,75.","6/0,75=8."]','Масштабтау математикалық күтімді сақтайды;inference-деdropout өшіріледі.');
insert into public.unt_tasks(id,topic_id,level,position,title,prompt,given_data,find_value,formulas,unit,code,answer_format) values('neural-networks-c10','neural-networks','C',10,'Мини-батч градиенті','Төртүлгінің бірпараметрге градиенттері2,−1,3,0. Batch loss орташаалынған. w=0,8,η=0,2 болса жаңамән?','g=[2,−1,3,0];w0,8;η0,2','wnew','["gmean=Σg/n;wnew=w−ηgmean"]','мән','','number');
insert into unt_private.answer_keys(task_id,answer,steps,explanation) values('neural-networks-c10','0.6','["Орташаградиент(2−1+3+0)/4=1.","0,8−0,2×1=0,6."]','Loss sum болса басқа градиентшығады;мұндаmeanнақтыберілген.');


-- SOURCE: 202610180005_quality_review.sql
-- Quality audit revision: safe new columns; no user/account deletion.

alter table public.unt_tasks add column revision integer not null default 1;
alter table public.unt_attempts add column task_revision integer not null default 1;
alter table public.unt_attempts add column task_snapshot jsonb;
update public.unt_attempts a set task_snapshot=to_jsonb(t) from public.unt_tasks t where a.task_id=t.id;
alter table unt_private.answer_keys add column error_feedback text not null default '';
alter table unt_private.answer_keys add column mistakes jsonb not null default '{}'::jsonb;
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
 insert into public.unt_attempts(student_id, task_id, submitted_answer, correct,task_revision,task_snapshot)
 values(actor, task.id, cleaned, is_correct,task.revision,to_jsonb(task)) returning id into attempt_id;
 return jsonb_build_object('attempt_id', attempt_id, 'correct', is_correct,
  'answer', key.answer, 'unit', task.unit, 'steps', key.steps, 'explanation', key.explanation, 'feedback', case when is_correct then null else coalesce(key.mistakes ->> cleaned,key.error_feedback) end);
end;
$$;

create or replace function public.unt_workspace() returns jsonb
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
    from (select distinct on(student_id, task_id, task_revision) student_id, task_id, task_revision, correct
     from public.unt_attempts where student_id = actor or (teacher and exists(
       select 1 from public.unt_enrollments e where e.teacher_id = actor and e.student_id = unt_attempts.student_id))
     order by student_id, task_id, task_revision, id) a
    join public.unt_tasks t on t.id = a.task_id group by a.student_id, t.topic_id, t.level
  ) s), '[]'::jsonb),
  'roster', case when teacher then coalesce((select jsonb_agg(jsonb_build_object(
    'id', p.id, 'username', p.username, 'full_name', p.full_name, 'class_name', p.class_name))
    from public.profiles p join public.unt_enrollments e on e.student_id = p.id where e.teacher_id = actor), '[]'::jsonb) else '[]'::jsonb end
 ) into result;
 return result;
end;
$$;

update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Үлкен бірліктен кішіге өткенде көбейтеміз; МиБ пен КиБ қатынасы1024.',mistakes='{}' where task_id='measure-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қосындыға дейін әр бөлікті бірдей байт бірлігіне келтіреміз.',mistakes='{}' where task_id='measure-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кіші бөліктегі жарты КиБ-ті жоғалтпау үшін аралық мәнді дөңгелектемейміз.',mistakes='{}' where task_id='measure-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Символдың16 бит салмағы кодтау шартымен берілген, барлық мәтінге әмбебап емес.',mistakes='{}' where task_id='measure-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бос қор сақталатын жалпы көлемнен алынады, тек толық файлдар саналады.',mistakes='{}' where task_id='measure-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қысу коэффициенті қалған үлесті береді; тақырыпша әр файлға бөлек қосылады.',mistakes='{}' where task_id='measure-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр файл жеке кластермен сақталады, сондықтан дөңгелектеу де жеке жасалады.',mistakes='{}' where task_id='measure-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы дерек бөлігі толтырылмайды, бірақ оның да тақырыпшасы бар.',mistakes='{}' where task_id='measure-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Толық база мен барлық инкременттер екі данаға бірдей көбейтіледі.',mistakes='{}' where task_id='measure-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қысылмаған PCM моделі жиілік, разряд, арна саны және уақытты көбейтеді.',mistakes='{}' where task_id='measure-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Туралау әр жолға қолданылады; пиксельдердің жалпы санына бір рет дөңгелектеу қате.',mistakes='{}' where task_id='measure-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ондық GB пен екілік ГиБ-ты байтқа айналдырғаннан кейін ғана бөлеміз.',mistakes='{}' where task_id='measure-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жиілік пен бір такттағы жұмыс көлемі бірге ескеріледі.',mistakes='{}' where task_id='hardware-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: SSD-нің энергияға тәуелсіздігі оны RAM-нан ажыратады.',mistakes='{}' where task_id='hardware-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: CPI — бір нұсқауға кететін орташа такт; оны IPC-пен шатастырмаңыз.',mistakes='{}' where task_id='hardware-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тізбекті бөлік ядро көбейгенде де қысқармайды.',mistakes='{}' where task_id='hardware-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тасымал саны жиіліктен бөлек көбейткіш болады.',mistakes='{}' where task_id='hardware-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бұл есептік төменгі шек; нақты блокты стандартты қуаттардан жоғары таңдайды.',mistakes='{}' where task_id='hardware-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Түстердің разрядтылығы мен буфер саны бөлек ескеріледі.',mistakes='{}' where task_id='hardware-c05';
update public.unt_tasks set revision=revision+1,title='Дискке бірнеше сұрау',prompt='Диск 7500 айн/мин. Әр сұраудың seek уақыты 3 мс, орташа айналу кідірісі жарты айналым, 1 MB дерек 250 MB/с жылдамдықпен оқылады. Кэшсіз 8 тәуелсіз сұрау ретімен орындалса, жалпы уақыт қанша мс?',given_data='7500 айн/мин;seek3;V1 MB;R250 MB/с;n8',find_value='T, мс',formulas='["T=n×(seek+30000/rpm+1000V/R)"]',unit='мс',code='',answer_format='number' where id='hardware-c06';
update unt_private.answer_keys set answer='88',steps='["Айналу кідірісі 30000/7500=4 мс.","Дерек оқу 1000×1/250=4 мс.","Бір сұрау 3+4+4=11 мс.","8×11=88 мс."]',explanation='Seek, айналу және тасымалдау — бөлек кідірістер. Әр тәуелсіз сұрауда үшеуі де қайта есептеледі.' where task_id='hardware-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Seek, айналу және тасымалдау — бөлек кідірістер. Әр тәуелсіз сұрауда үшеуі де қайта есептеледі.',mistakes='{}' where task_id='hardware-c06';
update public.unt_tasks set revision=revision+1,title='Резерв және ортақ компонент',prompt='Екі тәуелсіз дискінің әрқайсысы 0,95 ықтималдықпен жұмыс істейді. Кемінде бір диск керек. Ортақ контроллердің жұмыс ықтималдығы 0,98; ол дискілерден тәуелсіз. Жүйенің жұмыс ықтималдығын пайызбен табыңыз.',given_data='pdisc=0,95;pcontroller=0,98',find_value='P, %',formulas='["P=pc×(1−(1−pd)²)×100"]',unit='%',code='',answer_format='number' where id='hardware-c07';
update unt_private.answer_keys set answer='97.755',steps='["Екі дискінің де істен шығуы 0,05²=0,0025.","Кемінде бірі жұмыс істейді:0,9975.","Контроллер де керек:0,98×0,9975=0,97755.","Пайызбен 97,755%."]',explanation='Параллель резервтің тиімділігі ортақ контроллердің істен шығуын жоймайды.' where task_id='hardware-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Параллель резервтің тиімділігі ортақ контроллердің істен шығуын жоймайды.',mistakes='{}' where task_id='hardware-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қуаты жоғары құрылғы жылдам аяқтаса, жалпы энергиясы аз болуы мүмкін.',mistakes='{}' where task_id='hardware-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Шикі жылдамдықтың бәрі пайдалы дерекке жұмсалмайды.',mistakes='{}' where task_id='hardware-c09';
update public.unt_tasks set revision=revision+1,title='Кадр бюджеті',prompt='Монитор 120 Гц. Бір кадрға CPU2,5 мс, одан кейін GPU4 мс кетеді, қабаттасу жоқ. Қалған уақыттың 20%-ы резервке қалуы тиіс. Бір кадрға қосымша постөңдеудің ең үлкен уақытын мс-пен үш ондыққа дөңгелектеңіз.',given_data='120 Гц;CPU2,5;GPU4; қалған қордың 20%-ы бос',find_value='tpost, мс',formulas='["Tframe=1000/f; tpost=(Tframe−tCPU−tGPU)×0,8"]',unit='мс',code='',answer_format='number' where id='hardware-c10';
update unt_private.answer_keys set answer='1.467',steps='["Кадр бюджеті 1000/120=8,333333… мс.","CPU+GPU=6,5 мс; қалғаны 1,833333… мс.","Қолдануға 80%:1,466666… мс.","Үш ондықпен 1,467."]',explanation='20% резерв бүкіл кадрдан емес, CPU/GPU-дан кейін қалған уақыттан алынады.' where task_id='hardware-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: 20% резерв бүкіл кадрдан емес, CPU/GPU-дан кейін қалған уақыттан алынады.',mistakes='{}' where task_id='hardware-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Драйвер — жүйелік программалық жасақтаманың бөлігі.',mistakes='{}' where task_id='software-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Лицензияның шартын орындау тегін көшірме жасаумен алмастырылмайды.',mistakes='{}' where task_id='software-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Абсолютті жол түбірден басталады; .. тізбегін солдан оңға өңдейміз.',mistakes='{}' where task_id='software-c01';
update public.unt_tasks set revision=revision+1,title='Келу уақыты бар FCFS',prompt='FCFS-та A: келуі 0,CPU7; B: келуі 2,CPU4; C: келуі 3,CPU2; D: келуі 15,CPU3 мс. Context switch жоқ. Төрт процестің орташа күту уақытын табыңыз.',given_data='(arrival,burst):A(0,7),B(2,4),C(3,2),D(15,3)',find_value='Wорта, мс',formulas='["start=max(arrival,previous_finish);wait=start−arrival"]',unit='мс',code='',answer_format='number' where id='software-c02';
update unt_private.answer_keys set answer='3.25',steps='["A:0–7, күту 0.","B:7–11, күту 7−2=5.","C:11–13, күту 11−3=8;CPU13–15 бос.","D:15–18, күту 0; орташа(0+5+8+0)/4=3,25."]',explanation='Күту — басталу сәті минус келу сәті; CPU бос аралықты жұмысқа қосуға болмайды.' where task_id='software-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Күту — басталу сәті минус келу сәті; CPU бос аралықты жұмысқа қосуға болмайды.',mistakes='{}' where task_id='software-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Квант біткенде аяқталмаған процесс кезектің соңына өтеді.',mistakes='{}' where task_id='software-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жергілікті желі трафигі бұл есепке кірмейді.',mistakes='{}' where task_id='software-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Umask рұқсатты қосатын арифметика емес,сұралған mode-тың биттерін өшіретін маска.',mistakes='{}' where task_id='software-c05';
update public.unt_tasks set revision=revision+1,title='Орнатудың critical path-ы',prompt='A пакеті B және C біткен соң орнатылады; B-ге D керек, C-ге D және E керек. D3 мин,E5 мин қатарt=0-де басталады. B4 мин,C2 мин,A1 мин. Параллельдік шектеусіз. A ең ерте қай минутта бітеді?',given_data='D3,E5,B4,C2,A1;dependencies берілген',find_value='Аяқталу сәті',formulas='["finish(v)=duration(v)+max(finish(dependency))"]',unit='мин',code='',answer_format='number' where id='software-c06';
update unt_private.answer_keys set answer='8',steps='["D3,E5 минутта бітеді.","B D-дан кейін:3+4=7.","C екеуін күтеді:max(3,5)+2=7.","A:max(7,7)+1=8."]',explanation='Тәуелді параллель жұмыста уақыттар түгел қосылмайды; ең ұзақ тәуелді жол шешеді.' where task_id='software-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тәуелді параллель жұмыста уақыттар түгел қосылмайды; ең ұзақ тәуелді жол шешеді.',mistakes='{}' where task_id='software-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Операциялық жүйе жадын босату программаның ресурсты дұрыс қайтаруын алмастырмайды.',mistakes='{}' where task_id='software-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Delta сақтау қалпына келтіру үшін базаның да сақталуын талап етеді.',mistakes='{}' where task_id='software-c08';
update public.unt_tasks set revision=revision+1,title='Жаңартуды қабылдау саясаты',prompt='Пакет тек hash сәйкес, қолтаңба сенімді және version≥5 болса қабылданады. A:(иә, иә,5),B:(жоқ, иә,6),C:(иә, жоқ,7),D:(иә, иә,4),E:(иә, иә,6). Қабылданған нұсқалар көлемі A120 MB,E180 MB. Қабылданғандарды 30 MB/с-пен жүктеп, әрқайсын 2 с тексерсек, жалпы уақыт?',given_data='Үш шарттың бәрі қажет; тізбекті жүктеу/тексеру',find_value='T, с',formulas='["eligible=hash∧signature∧version;T=ΣV/R+2n"]',unit='с',code='',answer_format='number' where id='software-c09';
update unt_private.answer_keys set answer='14',steps='["A және E ғана үш шарттан өтеді;B hash,C signature,D version-нан өтпейді.","Көлем 120+180=300 MB; жүктеу 300/30=10 с.","Екі пакетке 2×2=4 с тексеру.","Барлығы 14 с."]',explanation='Бір ғана hash не қолтаңба жеткіліксіз; саясаттағы барлық шартты алдымен сүзу керек.' where task_id='software-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бір ғана hash не қолтаңба жеткіліксіз; саясаттағы барлық шартты алдымен сүзу керек.',mistakes='{}' where task_id='software-c09';
update public.unt_tasks set revision=revision+1,title='Толқындар және rollback',prompt='53 компьютер ең көбі 6-дан жаңартылады. Әр толқын 7 мин; алдыңғысы толық біткен соң келесі басталады. Соңында сәтсіз 5 компьютерді ең көбі 2-ден топтап, әр топқа 4 мин rollback керек. Жалпы уақыт?',given_data='53/6;7 мин;rollback5/2;4 мин',find_value='T, мин',formulas='["T=ceil(53/6)×7+ceil(5/2)×4"]',unit='мин',code='',answer_format='number' where id='software-c10';
update unt_private.answer_keys set answer='75',steps='["Жаңарту толқыныceil(53/6)=9:63 мин.","Rollback тобыceil(5/2)=3:12 мин.","63+12=75 мин."]',explanation='Соңғы толық емес топ та толық операция уақытын алады; жаңарту мен rollback екі бөлек кезең.' where task_id='software-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы толық емес топ та толық операция уақытын алады; жаңарту мен rollback екі бөлек кезең.',mistakes='{}' where task_id='software-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Адрес биттері санын дерек ұяшығының разрядтылығымен шатастырмаңыз.',mistakes='{}' where task_id='memory-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ұяшық саны мен әр ұяшықтағы бит бірге есептеледі.',mistakes='{}' where task_id='memory-b02';
update public.unt_tasks set revision=revision+1,title='Екі деңгейлі кэш',prompt='L1 қарау 1 нс,miss rate0,1. L1 miss болғанда қосымша L2 қарау 5 нс; оның local miss rate0,2. L2 miss болса тағы 80 нс RAM керек. AMAT табыңыз.',given_data='L1=1,m1=0,1;L2=5,m2=0,2;RAM80',find_value='AMAT, нс',formulas='["AMAT=t1+m1×(t2+m2×RAM)"]',unit='нс',code='',answer_format='number' where id='memory-c01';
update unt_private.answer_keys set answer='3.1',steps='["L1 miss жағдайының орташа қосымшасы 5+0,2×80=21 нс.","Бұл жағдай сұраулардың 0,1 бөлігінде.","AMAT=1+0,1×21=3,1 нс."]',explanation='L2 miss rate барлық сұрауға емес, тек L1 miss болған сұрауларға қатысты.' where task_id='memory-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: L2 miss rate барлық сұрауға емес, тек L1 miss болған сұрауларға қатысты.',mistakes='{}' where task_id='memory-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кэштің direct-mapped болуы индекс санын анықтайды.',mistakes='{}' where task_id='memory-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Мақсатты ұйым 2²⁰×16, жалпы көлемі2 МиБ; ұяшық пен байтты ажыратыңыз.',mistakes='{}' where task_id='memory-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бет offset-і бет кестесіне индекс ретінде қолданылмайды.',mistakes='{}' where task_id='memory-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: FIFO hit кезінде беттің кезектегі жасын жаңартпайды.',mistakes='{}' where task_id='memory-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: LRU соңғы қолданылу уақытын, FIFO жүктелу ретін бақылайды.',mistakes='{}' where task_id='memory-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы өңдеу де саналады, ал оқу/өңдеудің ұзын кезеңі конвейерді шектейді.',mistakes='{}' where task_id='memory-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Өрістер өлшемдерінің қосындысы padding-ті қамтымайды.',mistakes='{}' where task_id='memory-c08';
update public.unt_tasks set revision=revision+1,title='Матрица адресі мен туралау',prompt='Row-major A[20][30] матрицасының элементі 4 байт. Әр жол 32 байтқа тураланып жеке сақталады. Base4096; индекстер 0-ден. A[7][18] бірінші байтының адресі?',given_data='20×30;4 байт;row alignment32;base4096',find_value='Address',formulas='["stride=32ceil(30×4/32);addr=base+row×stride+col×4"]',unit='адрес',code='',answer_format='number' where id='memory-c09';
update unt_private.answer_keys set answer='5064',steps='["Жол дерегі 30×4=120 байт.","Stride=32×ceil(120/32)=128 байт.","7-жол ығысуы 7×128=896;18-баған 72.","4096+896+72=5064."]',explanation='Матрицадағы жол padding-ін елемей 30×4 stride алу қате.' where task_id='memory-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Матрицадағы жол padding-ін елемей 30×4 stride алу қате.',mistakes='{}' where task_id='memory-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: MT/s берілсе, DDR коэффициентін екінші рет көбейтпеңіз.',mistakes='{}' where task_id='memory-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тең ұзын код және екінің дәрежесі берілген.',mistakes='{}' where task_id='alphabet-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Символ саны мен алфавит қуаттылығы әртүрлі шамалар.',mistakes='{}' where task_id='alphabet-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тұрақты код ұзындығы бүтін бит; log₂70-ті тікелей қолдануға болмайды.',mistakes='{}' where task_id='alphabet-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Көлемнен символ салмағын, одан алфавитті табамыз.',mistakes='{}' where task_id='alphabet-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр мәтіннің өзіндік символ салмағы бар.',mistakes='{}' where task_id='alphabet-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Дөңгелектеу әр идентификаторға бөлек жасалады.',mistakes='{}' where task_id='alphabet-c04';
update public.unt_tasks set revision=revision+1,title='Алфавит пен жазба резерві',prompt='1024 символдық әр хабар бұрын 32 таңбалы, енді 80 таңбалы алфавитпен тұрақты кодталады. Әр хабар жеке байтқа оралып,12 байт header алады. 50 жаңа хабар бұрынғы 50 хабардан қанша байт артық?',given_data='K1024;Nold32;Nnew80;h12;n50',find_value='ΔV, байт',formulas='["ΔV=n×(ceil(Kinew/8)−ceil(Kiold/8))"]',unit='байт',code='',answer_format='number' where id='alphabet-c05';
update unt_private.answer_keys set answer='12800',steps='["Бұрынi=5, ендіceil(log₂80)=7 бит.","Бір хабар 640 байттан 896 байтқа өседі.","Header екі нұсқада да 12, айырмада жойылады.","50×(896−640)=12800 байт."]',explanation='Алфавиттің сандық өсуін көлемге тікелей көбейтпеңіз; бүтін код ұзындығы анықтайды.' where task_id='alphabet-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алфавиттің сандық өсуін көлемге тікелей көбейтпеңіз; бүтін код ұзындығы анықтайды.',mistakes='{}' where task_id='alphabet-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Толық символ ғана саналады.',mistakes='{}' where task_id='alphabet-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тақырыпша әр хабарға қосылады.',mistakes='{}' where task_id='alphabet-c07';
update public.unt_tasks set revision=revision+1,title='Жарамды кодтар қоры',prompt='8 биттік өрістің 32 коды қызметтікке бөлінген. Қалған кодтарға 150 символдық алфавит орналастырылды. Осы форматта алфавитті тағы неше символға кеңейтуге болады?',given_data='w8;reserved32;used150',find_value='Қосымша символ саны',formulas='["free=2ʷ−reserved−used"]',unit='символ',code='',answer_format='number' where id='alphabet-c08';
update unt_private.answer_keys set answer='74',steps='["8 бит 256 код береді.","Қолданбаға 256−32=224 код қалады.","224−150=74 қосымша символ."]',explanation='Қызметтік кодтарды бос алфавит коды деп санауға болмайды.' where task_id='alphabet-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қызметтік кодтарды бос алфавит коды деп санауға болмайды.',mistakes='{}' where task_id='alphabet-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Барлық позицияға бір ортақ код емес, шарттағы екі бөлек код қолданылады.',mistakes='{}' where task_id='alphabet-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Биттегі бет көлемін байтқа айналдыруды ұмытпаңыз.',mistakes='{}' where task_id='alphabet-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Негізгі ASCII —7 биттік128 код; кеңейтілген8 биттік кестелер бөлек.',mistakes='{}' where task_id='encoding-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Код нүктелерінің саны байт санына тең емес.',mistakes='{}' where task_id='encoding-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: UTF-16-да U+FFFF-тен үлкен код нүктесіне екі16 биттік бірлік керек.',mistakes='{}' where task_id='encoding-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: UTF-32 тұрақты ұзын, UTF-8 айнымалы ұзын кодтау.',mistakes='{}' where task_id='encoding-c02';
update public.unt_tasks set revision=revision+1,title='Таңбалы қосу және overflow',prompt='8 биттік two’s complement-та 01100100 және 00111100 қосылады. Сыртқы тасымал тасталады. Нәтижені таңбалы ондық сан ретінде жазыңыз.',given_data='8 бит;100+60; таңбалы интерпретация',find_value='Signed result',formulas='["r=(unsigned_a+unsigned_b) mod256; signed=r−256 егер r≥128"]',unit='сан',code='',answer_format='number' where id='encoding-c03';
update unt_private.answer_keys set answer='-96',steps='["Сандар 100 және 60; қосынды 160.","8 биттік сөз 10100000.","Үлкен бит 1 болғандықтан 160−256=−96.","Екі оң санның нәтижесі теріс: таңбалы overflow."]',explanation='Таңбалы диапазон−128…127;160 математикалық қосындысы бұл диапазоннан тыс.' where task_id='encoding-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Таңбалы диапазон−128…127;160 математикалық қосындысы бұл диапазоннан тыс.',mistakes='{}' where task_id='encoding-c03';
update public.unt_tasks set revision=revision+1,title='Таңбалы сөзді жылжыту',prompt='8 биттік 11101010 сөзін алдымен таңбалы ондыққа айналдырыңыз. Сол мәнге 3 қосып, нәтижені 8 биттік two’s complement-та жазыңыз.',given_data='word11101010;increment3',find_value='8 биттік нәтиже',formulas='["signed=unsigned−256;code=(signed+3) mod256"]',unit='код',code='',answer_format='text' where id='encoding-c04';
update unt_private.answer_keys set answer='11101101',steps='["11101010₂=234; таңбалы 234−256=−22.","−22+3=−19.","Код 256−19=237=11101101₂."]',explanation='Бірінші таңбалы интерпретация, кейін арифметика, соңында қайта кодтау жасалады.' where task_id='encoding-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бірінші таңбалы интерпретация, кейін арифметика, соңында қайта кодтау жасалады.',mistakes='{}' where task_id='encoding-c04';
update public.unt_tasks set revision=revision+1,title='Little-endian арифметика',prompt='Екі 16 биттік сан өсетін адрес бойынша A:[F0 12],B:[30 01] little-endian байттарымен сақталған. Қосынды mod65536. Нәтижені low high hex байттары түрінде жазыңыз.',given_data='A=F0 12;B=30 01;16 бит',find_value='Нәтиже байттары',formulas='["A=high×256+low;S=(A+B)mod65536"]',unit='байттар',code='',answer_format='sequence' where id='encoding-c05';
update unt_private.answer_keys set answer='20 14',steps='["A=0x12F0;B=0x0130.","0x12F0+0x0130=0x1420; кіші байтта тасымал бар.","Little-endian реті 20 14."]',explanation='Байттарды жад ретімен сан деп қосу қате; алдымен мәнді қалпына келтіріңіз.' where task_id='encoding-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Байттарды жад ретімен сан деп қосу қате; алдымен мәнді қалпына келтіріңіз.',mistakes='{}' where task_id='encoding-c05';
update public.unt_tasks set revision=revision+1,title='Хэмминг және parity',prompt='A=10110100,B=10001101. Олардың Хэмминг аралығын табыңыз; әрі әр сөздің соңына even-parity битін қосқанда 9 биттік сөздер арасындағы аралықты табыңыз. Екі сан жазыңыз.',given_data='A,B8 бит;parity жалпы 1 санын жұп етеді',find_value='d8 d9',formulas='["d8=popcount(A XOR B);d9=d8+(parityA XOR parityB)"]',unit='тізбек',code='',answer_format='sequence' where id='encoding-c06';
update unt_private.answer_keys set answer='4 4',steps='["XOR00111001, онда 4 бірлік:d8=4.","A-да 4,B-де 4 бірлік; екеуінің parity биті 0.","Қосымша биттер тең, сондықтанd9=4."]',explanation='Even parity жұп санды бит ауысуын анықтамауы мүмкін; Хэмминг аралығы мен parity әртүрлі өлшемдер.' where task_id='encoding-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Even parity жұп санды бит ауысуын анықтамауы мүмкін; Хэмминг аралығы мен parity әртүрлі өлшемдер.',mistakes='{}' where task_id='encoding-c06';
update public.unt_tasks set revision=revision+1,title='Екі XOR кілті',prompt='Сервер байтқа алдымен 0xC3, кейін 0x0F кілтін XOR қолданды; соңғы байт 0x96. Бастапқы байтты екі hex таңбамен жазыңыз.',given_data='C=96;K1=C3;K2=0F',find_value='Бастапқы hex',formulas='["P=C XOR K2 XOR K1"]',unit='hex',code='',answer_format='text' where id='encoding-c07';
update unt_private.answer_keys set answer='5A',steps='["XOR кері амалы өзіне тең.","0x96 XOR0x0F=0x99.","0x99 XOR0xC3=0x5A."]',explanation='Кілттерді қосу/азайту емес, әр битке XOR қолдану керек.' where task_id='encoding-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кілттерді қосу/азайту емес, әр битке XOR қолдану керек.',mistakes='{}' where task_id='encoding-c07';
update public.unt_tasks set revision=revision+1,title='Base64 және жол тасымалы',prompt='1025 байт Base64-пен padding қосылып кодталады. Нәтиже 76 таңбадан жолдарға бөлінеді; соңғы жолдан басқа әр жолдан кейінCRLF2 байт. Алдында 20 байт header бар. Жалпы көлем?',given_data='n1025;line76;CRLF2;header20',find_value='V, байт',formulas='["L=4ceil(n/3);V=L+2(ceil(L/76)−1)+20"]',unit='байт',code='',answer_format='number' where id='encoding-c08';
update unt_private.answer_keys set answer='1422',steps='["Base64 ұзындығы 4×ceil(1025/3)=1368.","Жол саны 1368/76=18.","Жол арасы 17×2=34 байт.","1368+34+20=1422."]',explanation='Соңғы жолдан кейін CRLF жоқ; таңба саны мен тасымал байттарын бөлек есептеңіз.' where task_id='encoding-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы жолдан кейін CRLF жоқ; таңба саны мен тасымал байттарын бөлек есептеңіз.',mistakes='{}' where task_id='encoding-c08';
update public.unt_tasks set revision=revision+1,title='RLE шекті сериясы',prompt='A таңбасы 600 рет, артынан B3 рет келеді. RLE-де бір жазба 1 байт таңба+1 байт count, count1…255. Header4 байт. Бастапқы 603 байтпен салыстырғанда қанша байт үнемделеді?',given_data='A600,B3;countmax255;record2;header4',find_value='Үнем, байт',formulas='["records=ceil(600/255)+ceil(3/255);saving=603−(2records+4)"]',unit='байт',code='',answer_format='number' where id='encoding-c09';
update unt_private.answer_keys set answer='591',steps='["A600 үш жазба:255,255,90.","B3 бір жазба; барлығы 4×2=8 байт.","Header-мен 12 байт.","603−12=591 байт үнем."]',explanation='Бір count байты 600 мәнін сақтай алмайды; ұзын серияны бөлу қажет.' where task_id='encoding-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бір count байты 600 мәнін сақтай алмайды; ұзын серияны бөлу қажет.',mistakes='{}' where task_id='encoding-c09';
update public.unt_tasks set revision=revision+1,title='Префикстік код пен салмақ',prompt='A=0,B=10,C=110,D=111. 0101101110 ағынын ашыңыз. A1,B2,C3,D4 салмақтарымен декодталған хабардың салмақ қосындысын табыңыз.',given_data='Ағын 10 бит; төрт префикстік код; салмақ 1,2,3,4',find_value='Салмақ қосындысы',formulas='["Decode → символдарға салмақ беру → Σweight"]',unit='сан',code='',answer_format='number' where id='encoding-c10';
update unt_private.answer_keys set answer='11',steps='["Ағын 0|10|110|111|0→ABCDA.","Салмақтар 1,2,3,4,1.","Қосынды 11."]',explanation='Алдымен бірмәнді префикстік шекаралармен ашыңыз; екілік ағынды ондық сан ретінде оқымаңыз.' where task_id='encoding-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен бірмәнді префикстік шекаралармен ашыңыз; екілік ағынды ондық сан ретінде оқымаңыз.',mistakes='{}' where task_id='encoding-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр цифр өз позициясының2 дәрежесіне көбейтіледі.',mistakes='{}' where task_id='number-systems-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Hex цифрлары10–15 үшін A–F болады.',mistakes='{}' where task_id='number-systems-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әртүрлі негіздегі цифр жазуларын тікелей қоспаңыз.',mistakes='{}' where task_id='number-systems-c01';
update public.unt_tasks set revision=revision+1,title='Аралас бөлшек арифметика',prompt='101,101₂ + 7,4₈ − A,8₁₆ өрнегін ондықпен табыңыз.',given_data='Екілік, сегіздік,hex бөлшектер',find_value='Нәтиже₁₀',formulas='["Σdᵢbⁱ;барлығын бір негізге келтіру"]',unit='сан',code='',answer_format='number' where id='number-systems-c02';
update unt_private.answer_keys set answer='2.625',steps='["101,101₂=5,625.","7,4₈=7,5;A,8₁₆=10,5.","5,625+7,5−10,5=2,625."]',explanation='Бөлшектегі салмақтар тиісінше 1/2,1/8,1/16 негіздерімен есептеледі.' where task_id='number-systems-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бөлшектегі салмақтар тиісінше 1/2,1/8,1/16 негіздерімен есептеледі.',mistakes='{}' where task_id='number-systems-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Теріс түбір позициялық негіз болмайды.',mistakes='{}' where task_id='number-systems-c03';
update public.unt_tasks set revision=revision+1,title='Hex бит өрісі',prompt='24 биттік сөздің үлкен 4 биті A₁₆, ортаңғы 12 биті FFF₁₆, кіші 8 биті 00₁₆. Сөзді 8 бит оңға ығыстырып,0x0FFF маскасын қолданыңыз. Нәтижені ондықпен табыңыз.',given_data='Word=0xAFFF00;shift8;mask0x0FFF',find_value='Нәтиже₁₀',formulas='["r=(word>>8) AND0x0FFF"]',unit='сан',code='',answer_format='number' where id='number-systems-c04';
update unt_private.answer_keys set answer='4095',steps='["Бит өрістері бірігіп 0xAFFF00 болады.","Оңға 8:0xAFFF.","AND0x0FFF→0x0FFF=4095."]',explanation='Ығысу мен маска әртүрлі әрекет: ығысу өрісті төменге әкеледі, маска артық битті өшіреді.' where task_id='number-systems-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ығысу мен маска әртүрлі әрекет: ығысу өрісті төменге әкеледі, маска артық битті өшіреді.',mistakes='{}' where task_id='number-systems-c04';
update public.unt_tasks set revision=revision+1,title='Екі кезеңді регистр',prompt='8 биттік unsigned регистр бастапқыда 250. Оған 19 қосылады, кейін нәтиже 3-ке көбейтіледі; әр амалдан кейін mod256. Соңғы мәнді екі hex таңбамен жазыңыз.',given_data='r0=250;+19;×3;8 бит',find_value='Hex нәтиже',formulas='["r1=(250+19)mod256;r2=(3r1)mod256"]',unit='hex',code='',answer_format='text' where id='number-systems-c05';
update unt_private.answer_keys set answer='27',steps='["250+19=269→13.","13×3=39, бұл 8 битке сыяды.","39₁₀=27₁₆."]',explanation='Соңғы негіз hex болғандықтан 39 деп енгізу қате.' where task_id='number-systems-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы негіз hex болғандықтан 39 деп енгізу қате.',mistakes='{}' where task_id='number-systems-c05';
update public.unt_tasks set revision=revision+1,title='Көбейту және тасымал',prompt='1101₂×101₂ + 37₈ өрнегін 8 биттік екілік сөзбен жазыңыз.',given_data='13×5 және 37₈;8 бит',find_value='Екілік нәтиже',formulas='["Әр операнд→ондық;арифметика;8 битке кодтау"]',unit='код',code='',answer_format='text' where id='number-systems-c06';
update unt_private.answer_keys set answer='01100000',steps='["1101₂×101₂=13×5=65.","37₈=3×8+7=31; қосынды 96.","96=64+32→01100000."]',explanation='Бастапқы нөл 8 биттік жауап форматы үшін міндетті.' where task_id='number-systems-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бастапқы нөл 8 биттік жауап форматы үшін міндетті.',mistakes='{}' where task_id='number-systems-c06';
update public.unt_tasks set revision=revision+1,title='Маска мен циклдік емес ығысу',prompt='8 биттік 0xB6 алдымен 0x6D-пен AND жасалады. Нәтиже 2 бит солға ығысып,8 битпен шектеледі; соңында 0x0F-пен OR. Соңғы ондық мән?',given_data='B6 AND6D;<<2;AND FF;OR0F',find_value='r₁₀',formulas='["r=(((B6 AND6D)<<2) AND FF) OR0F"]',unit='сан',code='',answer_format='number' where id='number-systems-c07';
update unt_private.answer_keys set answer='159',steps='["B6 AND6D=0x24=36.","36<<2=144=0x90;8 битке сыяды.","0x90 OR0x0F=0x9F=159."]',explanation='Биттік OR арифметикалық қосуға жалпы жағдайда тең емес.' where task_id='number-systems-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Биттік OR арифметикалық қосуға жалпы жағдайда тең емес.',mistakes='{}' where task_id='number-systems-c07';
update public.unt_tasks set revision=revision+1,title='Шартты бинарлық санау',prompt='8 биттік сөздің бірінші биті 1, соңғысы 0. Барлығы дәл 4 бірлік бит бар және ортаңғы 6 биттің алғашқыекеуі бірдей болмауы тиіс. Неше сөз бар?',given_data='Бекітілген 1…0;middle6 ішінде 3 бірлік;middle[0]≠middle[1]',find_value='Сөз саны',formulas='["N=2×C(4,2)"]',unit='сөз',code='',answer_format='number' where id='number-systems-c08';
update unt_private.answer_keys set answer='12',steps='["Жетекші 1 алынғанда ортада 3 бірлік қалуы керек.","Алғашқы екі орта бит 01 не 10:2 мүмкіндік.","Қалған 4 орында 2 бірлік:C(4,2)=6.","2×6=12."]',explanation='Жетекші және соңғы биттерді еркін комбинацияға қайта қоспаңыз.' where task_id='number-systems-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жетекші және соңғы биттерді еркін комбинацияға қайта қоспаңыз.',mistakes='{}' where task_id='number-systems-c08';
update public.unt_tasks set revision=revision+1,title='Екі бөлшек пен көбейту',prompt='17,4₈ санынан 11,01₂ санын азайтып, нәтижені 2-ге көбейтіңіз. Ондық жауап беріңіз.',given_data='17,4₈;11,01₂;factor2',find_value='Нәтиже',formulas='["r=2×(octal−binary)"]',unit='сан',code='',answer_format='number' where id='number-systems-c09';
update unt_private.answer_keys set answer='24.5',steps='["17,4₈=15,5.","11,01₂=3,25.","2×(15,5−3,25)=24,5."]',explanation='Бөлшек разрядтарды әр негізбен жеке есептеңіз.' where task_id='number-systems-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бөлшек разрядтарды әр негізбен жеке есептеңіз.',mistakes='{}' where task_id='number-systems-c09';
update public.unt_tasks set revision=revision+1,title='Бит санының өзгерісі',prompt='16 биттік 0x3F80 сөзі 0x0FF0-пен XOR жасалады. Содан соң төменгі 8 бит қана қалдырылады. Қалған сөздегі 1 биттер саны?',given_data='x3F80;key0FF0;mask00FF',find_value='popcount',formulas='["r=(x XOR key) AND00FF;N=popcount(r)"]',unit='бит',code='',answer_format='number' where id='number-systems-c10';
update unt_private.answer_keys set answer='3',steps='["0x3F80 XOR0x0FF0=0x3070.","Төменгі 8 бит 0x70=01110000.","Бірлер саны 3."]',explanation='Бастапқы сөздің popcount-ын емес, барлық түрлендіруден кейінгі сөзді санаңыз.' where task_id='number-systems-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бастапқы сөздің popcount-ын емес, барлық түрлендіруден кейінгі сөзді санаңыз.',mistakes='{}' where task_id='number-systems-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Орталық коммутатор компьютер санына қосылмайды.',mistakes='{}' where task_id='networks-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Желі түрі тек компьютер санына емес, қамту аумағына тәуелді.',mistakes='{}' where task_id='networks-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Екі бағытты бір кабельді екі рет санамаңыз.',mistakes='{}' where task_id='networks-c01';
update public.unt_tasks set revision=revision+1,title='Сақинадағы үзілген байланыс',prompt='0–9 түйіндері екібағытты сақинада. 8–9 қабырғасы істен шықты. 1-ден 7-ге ең қысқа жарамды маршруттың әр қабырғасы 2 мс, әр аралық түйінде 0,5 мс өңдеу бар. Жалпы уақыт?',given_data='10 түйін;edge8–9 жоқ;1→7;edge2ms;intermediate0,5ms',find_value='T, мс',formulas='["T=2×edge_count+0,5×(edge_count−1)"]',unit='мс',code='',answer_format='number' where id='networks-c02';
update unt_private.answer_keys set answer='14.5',steps='["Қысқа кері 1→0→9→8→7 жолы 8–9 үзілуінен жарамсыз.","Жарамды 1→2→3→4→5→6→7:6 қабырға.","Аралық түйін 5:6×2+5×0,5=14,5 мс."]',explanation='Үзілген жолды қысқа болғаны үшін таңдау мүмкін емес; өңдеу тек аралық түйіндерде.' where task_id='networks-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Үзілген жолды қысқа болғаны үшін таңдау мүмкін емес; өңдеу тек аралық түйіндерде.',mistakes='{}' where task_id='networks-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Store-and-forward әр түйінде бүкіл пакетті күтеді.',mistakes='{}' where task_id='networks-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Пакеттер желіде бір мезгілде әртүрлі арнада бола алады.',mistakes='{}' where task_id='networks-c04';
update public.unt_tasks set revision=revision+1,title='Резерв және ортақ router',prompt='Екі тәуелсіз арна 0,99 жұмыс ықтималдығымен параллель резервте. Ортақ router0,98 ықтималдықпен жұмыс істейді, ол арналардан тәуелсіз. Бір арна жәнеrouter жеткілікті. Жүйе ықтималдығын пайызбен төрт ондыққа жазыңыз.',given_data='pchannel0,99;prouter0,98',find_value='P, %',formulas='["P=prouter×(1−(1−pchannel)²)×100"]',unit='%',code='',answer_format='number' where id='networks-c05';
update unt_private.answer_keys set answer='97.9902',steps='["Арналардың біреуі жұмыс істейді:1−0,01²=0,9999.","Router де қажет:0,98×0,9999=0,979902.","Пайызбен 97,9902."]',explanation='Тәуелсіздік шарты көбейтуге мүмкіндік береді; ортақrouter резервтен тыс қалады.' where task_id='networks-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тәуелсіздік шарты көбейтуге мүмкіндік береді; ортақrouter резервтен тыс қалады.',mistakes='{}' where task_id='networks-c05';
update public.unt_tasks set revision=revision+1,title='VLAN және құрылғы саны',prompt='Бір switch ішіндеVLAN10-да 18,VLAN20-да 12,VLAN30-да 10 клиент бар. Router VLAN-дарды L3-пен байланыстырады,bridge жасамайды. Бір клиенттің broadcast кадры өзін есептемегендеVLAN10 ішінде неше клиентке тарайды?',given_data='VLAN10:18;VLAN20:12;VLAN30:10;routerL3',find_value='Қабылдайтын клиент саны',formulas='["Receivers=source_VLAN_clients−1"]',unit='клиент',code='',answer_format='number' where id='networks-c06';
update unt_private.answer_keys set answer='17',steps='["VLAN-дар бөлек broadcast domain: басқа 22 клиентке тарамайды.","VLAN10-дағы 18-дің бірі жіберуші.","18−1=17 қабылдаушы."]',explanation='Барлықswitch портын санамай, кадрдыңVLAN шекарасын жәнежіберушіні алып тастауды ескеріңіз.' where task_id='networks-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Барлықswitch портын санамай, кадрдыңVLAN шекарасын жәнежіберушіні алып тастауды ескеріңіз.',mistakes='{}' where task_id='networks-c06';
update public.unt_tasks set revision=revision+1,title='Uplink порттарының бағасы',prompt='6 бөлімнің әрқайсысында 47 компьютер. Әр 24 порттықaccess switch-тің 2 порты резерв/uplink үшін бөлінген. Әр бөлім бөлек switch-терді қолданады. Core switch әрaccess switch-ке бір порт береді. Core-таaccess үшін ең аз неше порт керек?',given_data='6 бөлім;47 клиент/бөлім;24−2=22clientпорт',find_value='Core port саны',formulas='["N=6×ceil(47/(24−2))"]',unit='порт',code='',answer_format='number' where id='networks-c07';
update unt_private.answer_keys set answer='18',steps='["Access switch22 клиентті қосады.","Әр бөлімгеceil(47/22)=3 switch.","6×3=18 access switch,core-та 18 порт."]',explanation='Бөлімдер арасында қалғанclientпортты ортақ пайдалануға шарт рұқсат етпейді.' where task_id='networks-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бөлімдер арасында қалғанclientпортты ортақ пайдалануға шарт рұқсат етпейді.',mistakes='{}' where task_id='networks-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: MTU ішінде транспорт/желілік тақырыпша да бар.',mistakes='{}' where task_id='networks-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: RTT — екі бағыт пен берілген өңдеу кідірістерінің қосындысы.',mistakes='{}' where task_id='networks-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ең қысқа жол міндетті түрде ең аз түйін арқылы өтпейді.',mistakes='{}' where task_id='networks-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Байттағы көлем бит/с жылдамдықпен тікелей бөлінбейді.',mistakes='{}' where task_id='bandwidth-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: MB ондық бірлік, МиБ емес.',mistakes='{}' where task_id='bandwidth-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Екілік файл көлемі мен ондық арна жылдамдығы бірге есептеледі.',mistakes='{}' where task_id='bandwidth-c01';
update public.unt_tasks set revision=revision+1,title='Тар орын және RTT',prompt='Маршруттың үш арнасы 100,40,80 Мбит/с. Пайдалы дерек 800 Мбит;header/coding толық тасымалды 25%-ға арттырады. Ағын басталғанға дейін 0,5 с handshake бар. Пайплайн тұрақталған, басқа кідіріс жоқ. Жалпы уақыт?',given_data='R100/40/80;V800Mbit;overhead25%;startup0,5 с',find_value='T, с',formulas='["T=startup+V×1,25/min(R)"]',unit='с',code='',answer_format='number' where id='bandwidth-c02';
update unt_private.answer_keys set answer='25.5',steps='["Тар орын 40 Мбит/с.","Арнаға берілетіні 800×1,25=1000 Мбит.","1000/40=25 с;handshake-пен 25,5."]',explanation='25% overhead пайдалы көлемге қосылады; оны 75% тиімділікпен шатастырмаңыз.' where task_id='bandwidth-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: 25% overhead пайдалы көлемге қосылады; оны 75% тиімділікпен шатастырмаңыз.',mistakes='{}' where task_id='bandwidth-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тең бөлінетін пайдалы арна деп берілген.',mistakes='{}' where task_id='bandwidth-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қайта жіберілген пакет бастапқы тасымалға қосымша саналады.',mistakes='{}' where task_id='bandwidth-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: 14 ағын84 Мбит/с болып резерв шартын бұзады.',mistakes='{}' where task_id='bandwidth-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жылдамдықтың жай арифметикалық орташа мәнін қолдану дұрыс емес.',mistakes='{}' where task_id='bandwidth-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Уақыт37,5%-ға азайса да жылдамдық60%-ға өседі.',mistakes='{}' where task_id='bandwidth-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Пайдалы дерек пен арнаға берілетін толық көлем бөлек.',mistakes='{}' where task_id='bandwidth-c08';
update public.unt_tasks set revision=revision+1,title='Терезені блокпен бөлу',prompt='200 Мбит/с арнадаRTT40 мс. Терезе буфері 64 КиБ блоктармен бөлінеді. BDP-дан кем емес ең кіші буфер көлемін КиБ-пен табыңыз.',given_data='R200e6;RTT0,04;block64KiB',find_value='Buffer, КиБ',formulas='["W=R×RTT/8;blocks=ceil(W/65536)"]',unit='КиБ',code='',answer_format='number' where id='bandwidth-c09';
update unt_private.answer_keys set answer='1024',steps='["BDP=200e6×0,04/8=1000000 байт.","ceil(1000000/65536)=16 блок.","16×64=1024 КиБ."]',explanation='БайттағыBDP-ны 64 КиБ блок шекарасына жоғары дөңгелектеу қажет.' where task_id='bandwidth-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: БайттағыBDP-ны 64 КиБ блок шекарасына жоғары дөңгелектеу қажет.',mistakes='{}' where task_id='bandwidth-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қысудың есептеу уақыты да жалпы кідіріске кіреді.',mistakes='{}' where task_id='bandwidth-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Желі адресінде хост биттерінің бәрі0.',mistakes='{}' where task_id='ip-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: /31 мен /32 үшін арнайы ережелер бар, бұл есеп кәдімгі LAN туралы.',mistakes='{}' where task_id='ip-b02';
update public.unt_tasks set revision=revision+1,title='Бөлінген subnet-тен кейін',prompt='172.19.80.0/20 блогынан алдымен 700 хостқа ең кіші subnet, одан кейін 300 хостқа ең кіші subnet өсу ретімен, бос орынсыз бөлінеді. Екінші subnet желі адресін CIDR-мен жазыңыз.',given_data='Parent172.19.80.0/20;H1=700;H2=300',find_value='Екінші network/CIDR',formulas='["block=2^ceil(log₂(H+2));next=base+first_block"]',unit='CIDR',code='',answer_format='text' where id='ip-c01';
update unt_private.answer_keys set answer='172.19.84.0/23',steps='["700+2≤1024→/22, бірінші 172.19.80.0/22,80–83.","Келесі шекара 172.19.84.0.","300+2≤512→/23; адрес 172.19.84.0/23."]',explanation='Біріншіsubnet-тіңтолық 1024 адресін өткізу керек; тек 700 хостты қосу туралауды бұзады.' where task_id='ip-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Біріншіsubnet-тіңтолық 1024 адресін өткізу керек; тек 700 хостты қосу туралауды бұзады.',mistakes='{}' where task_id='ip-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Broadcast адресінде хост биттері1 болады.',mistakes='{}' where task_id='ip-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Желі адресі128 және broadcast191 хостқа берілмейді.',mistakes='{}' where task_id='ip-c03';
update public.unt_tasks set revision=revision+1,title='VLSM толық орналастыру',prompt='10.42.8.0/23 блогынан 134,62,28 және 2 хосттық төрт желіге ең кішіsubnet-тер үлкенінен кішісіне қарай, ең төмен бос адрестен бөлінеді. /31 қолданылмайды. Соңғы 2-хосттық желінің соңғы қолданылатын адресі?',given_data='Parent10.42.8.0/23;hosts134,62,28,2',find_value='Соңғы link last usable',formulas='["B=2^ceil(log₂(H+2));aligned_allocate;last=broadcast−1"]',unit='IPv4',code='',answer_format='text' where id='ip-c04';
update unt_private.answer_keys set answer='10.42.9.98',steps='["134 хостқа 134+2=136 адрес керек: ең кіші блок 256, яғни /24. Ол 10.42.8.0–10.42.8.255 аралығын алады.","62 хостқа 64 адрес: 10.42.9.0/26, аралығы 10.42.9.0–10.42.9.63.","28 хостқа 32 адрес: 10.42.9.64/27, аралығы 10.42.9.64–10.42.9.95.","2 хостқа 4 адрес: 10.42.9.96/30. Желі адресі .96, broadcast .99, хосттар .97 және .98.","Соңғы қолданылатын адрес: 10.42.9.98."]',explanation='Әр subnet үшін алдымен network пен broadcast адрестерін қосып, ең кіші екі дәрежелік блок таңдалады. Содан кейін блоктарды ретімен туралап орналастырып, соңғы желінің broadcast адресінен бірді аламыз.' where task_id='ip-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр subnet үшін алдымен network пен broadcast адрестерін қосып, ең кіші екі дәрежелік блок таңдалады. Содан кейін блоктарды ретімен туралап орналастырып, соңғы желінің broadcast адресінен бірді аламыз.',mistakes='{"10.42.9.99":"Бұл соңғы subnet-тің broadcast адресі. Хостқа арналған соңғы адрес одан1 кем."}' where task_id='ip-c04';
update public.unt_tasks set revision=revision+1,title='Субнеттерді жіктеу',prompt='192.168.10.0/24 ішінде адрес тізімі 3,62,63,64,100,127,128,190,191,192 соңғы октеттерімен берілген. /26 маскасымен network/broadcast адрестерін алып тастағанда неше жарамды хост бар?',given_data='Октеттер 3,62,63,64,100,127,128,190,191,192; /26',find_value='Жарамды адрес саны',formulas='["Block64;network=0,64,128,192;broadcast=63,127,191,255"]',unit='адрес',code='',answer_format='number' where id='ip-c05';
update unt_private.answer_keys set answer='4',steps='["Network адрестер 64,128,192 жарамсыз.","Broadcast63,127,191 жарамсыз.","Қалған 3,62,100,190 —4 хост."]',explanation='Адрес subnet шекарасының бір жағында жатқаны жеткіліксіз;network/broadcast болуы да тексеріледі.' where task_id='ip-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Адрес subnet шекарасының бір жағында жатқаны жеткіліксіз;network/broadcast болуы да тексеріледі.',mistakes='{}' where task_id='ip-c05';
update public.unt_tasks set revision=revision+1,title='Subnet және резерв',prompt='10.0.0.0/16 блогы /21-лерге бөлінеді. Алғашқы 2 subnet инфрақұрылымға бөлінген. Әр қалғанsubnet-те 10 статикалықадрес резервтеледі. Барлық қалған subnet-терге DHCP арқылы ең көп неше хост беріледі?',given_data='/16→/21;reserved_subnets2;static10/subnet',find_value='DHCP host саны',formulas='["N=(2^(21−16)−2)×(2^(32−21)−2−10)"]',unit='хост',code='',answer_format='number' where id='ip-c06';
update unt_private.answer_keys set answer='61080',steps='["Subnet саны 32, клиенттік 32−2=30.","Бір/21-де 2048−2=2046 қолданылатынадрес.","DHCP-қа 2046−10=2036.","30×2036=61080."]',explanation='Екіreservedsubnet-ті хост деңгейіндегі 10 адреспен шатастырмаңыз.' where task_id='ip-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Екіreservedsubnet-ті хост деңгейіндегі 10 адреспен шатастырмаңыз.',mistakes='{}' where task_id='ip-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тізбектестікпен бірге басталу шекарасы да дұрыс болуы тиіс.',mistakes='{}' where task_id='ip-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: /23 хост кеңістігі келесі октетке тасымалдауға мүмкіндік береді.',mistakes='{}' where task_id='ip-c08';
update public.unt_tasks set revision=revision+1,title='Өсуі бар адрес жоспары',prompt='410 жұмыс орны 25% өседі деп жоспарланған; өскенсан жоғары бүтінге дөңгелектеледі. Бұған 12 сервер және 1gateway қосылады. Network/broadcast бөлек. Ең кішіжеткіліктіsubnet-тің prefix ұзындығы?',given_data='410×1,25→ceil;server12;gateway1',find_value='prefix',formulas='["H=ceil(410×1,25)+13;prefix=32−ceil(log₂(H+2))"]',unit='бит',code='',answer_format='number' where id='ip-c09';
update unt_private.answer_keys set answer='22',steps='["Жұмысорынceil(512,5)=513.","Жалпы 513+12+1=526 хост.","512 адрес−2=510 жеткіліксіз;1024−2=1022 жетеді.","Hostbit10,prefix22."]',explanation='Өсу қорын, қосымша құрылғыны жәнеnetwork/broadcast-ты бөлек есептеңіз.' where task_id='ip-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Өсу қорын, қосымша құрылғыны жәнеnetwork/broadcast-ты бөлек есептеңіз.',mistakes='{}' where task_id='ip-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тең ұзын тізбекте сол жақтағысы таңдалады.',mistakes='{}' where task_id='ip-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: DNS бір ғана IP емес, әртүрлі жазба түрлерін басқарады.',mistakes='{}' where task_id='dns-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: TTL кэшке салынған сәттен есептеледі.',mistakes='{}' where task_id='dns-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Alias атауы мен адрес жазбасының түрін бөлек талдаймыз.',mistakes='{}' where task_id='dns-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Сұраулар ретімен орындалады, сондықтан RTT-лер қосылады.',mistakes='{}' where task_id='dns-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Miss уақыты52 мс толық берілген, оған2 мс-ті қайта қоспаймыз.',mistakes='{}' where task_id='dns-c03';
update public.unt_tasks set revision=revision+1,title='Әртүрлі жастағы кэш',prompt='CNAME TTL300 t=0-де, оның target A жазбасыTTL120 t=80-де кэшке түсті. t=150 кезінде екіжазбаға сүйенген жауапты сыртқа сұраусыз тағы неше секунд қолдануға болады?',given_data='CNAME expiry300;A expiry200;now150',find_value='Remaining, с',formulas='["remaining=min(t₁+TTL₁,t₂+TTL₂)−now"]',unit='с',code='',answer_format='number' where id='dns-c04';
update unt_private.answer_keys set answer='50',steps='["CNAME t300-ге дейінжарамды.","A t80+120=200-ге дейін.","Ертеexpiry200;200−150=50 с."]',explanation='TTL-дерді өзара ғана салыстырмай, әрқайсысының кэшке түскен уақытын ескеріңіз.' where task_id='dns-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: TTL-дерді өзара ғана салыстырмай, әрқайсысының кэшке түскен уақытын ескеріңіз.',mistakes='{}' where task_id='dns-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Толық атау шегі мен жеке label шегінің екеуі де орындалуы керек.',mistakes='{}' where task_id='dns-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кіші preference басым,бірақ жеткізу үшін сервердің қолжетімділігі де қажет.',mistakes='{}' where task_id='dns-c06';
update public.unt_tasks set revision=revision+1,title='Екі negative кэш',prompt='ResolverA t0-деNXDOMAIN TTL180,ResolverB t40-таNXDOMAIN TTL90 алды. Доменt60-та жасалды. Кэштер expiry-ге дейінжаңартылмайды. Екеуі де жаңа жазбаны алаалатын еңерте сәт жәнедомен жасалғаннан кейінгі күту қанша? Екісанжазыңыз.',given_data='A expiry180;B expiry130;create60',find_value='t wait',formulas='["t=max(expiryA,expiryB);wait=t−create"]',unit='тізбек',code='',answer_format='sequence' where id='dns-c07';
update unt_private.answer_keys set answer='180 120',steps='["A0+180=180-де,B40+90=130-да босайды.","Екеуі де жаңартаалатынсәтmax(180,130)=180.","Жасалғаннанкейін 180−60=120 с."]',explanation='Барлықклиентке қолжетімділікүшін еңкешескіретін кэш ескеріледі.' where task_id='dns-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Барлықклиентке қолжетімділікүшін еңкешескіретін кэш ескеріледі.',mistakes='{}' where task_id='dns-c07';
update public.unt_tasks set revision=revision+1,title='DNS атауын қысу',prompt='Қысусызwww.school.test аты 17 байт. Бірпакеттеалдыменосыаты толық, соданmail.school.test атыжазылады. Екіншіатта school.test бөлігі 2 байтcompression pointer-менберілген. Осыекіатқа жалпы қаншабайт?',given_data='www=3;mail=4;school.test suffix pointer2 байт',find_value='Екіname wire bytes',formulas='["V=first_full+(1+mail_length)+pointer"]',unit='байт',code='',answer_format='number' where id='dns-c08';
update unt_private.answer_keys set answer='24',steps='["Біріншіат(1+3)+(1+6)+(1+4)+1=17 байт.","Екіншіаттыңmail бөлігі 1+4=5 байт.","Suffix pointer2 байт, түбірдіқайтақоспаймыз.","17+5+2=24 байт."]',explanation='Pointer толықsuffix-ті, оныңтүбірінқоса алмастырады.' where task_id='dns-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Pointer толықsuffix-ті, оныңтүбірінқоса алмастырады.',mistakes='{}' where task_id='dns-c08';
update public.unt_tasks set revision=revision+1,title='Екі resolver жүктемесі',prompt='Екітәуелсізresolver-де бірдомен бастапқыдажоқ. A TTL60,B TTL45 с қолданады. Әрсекундтаәрқайсына сұрау келеді; жаңартукэшескіргенсәтте. t0…179 аралығында authoritative-ке жалпы нешежаңартусұрауы?',given_data='A TTL60;B TTL45;interval0…179',find_value='N',formulas='["N=Σ(1+floor(179/TTL))"]',unit='сұрау',code='',answer_format='number' where id='dns-c09';
update unt_private.answer_keys set answer='7',steps='["A:0,60,120→3.","B:0,45,90,135→4.","Тәуелсізкэштер болғандықтан 3+4=7."]',explanation='Әрresolver-діңөзTTLкестесі бар; клиентсұрауларыныңбәрісыртқаөтпейді.' where task_id='dns-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әрresolver-діңөзTTLкестесі бар; клиентсұрауларыныңбәрісыртқаөтпейді.',mistakes='{}' where task_id='dns-c09';
update public.unt_tasks set revision=revision+1,title='DNSSEC қабылдау сүзгісі',prompt='Жауап текқолтаңбадұрыс,signer сенімдіжәнемерзімжарамдыболса қолданылады. Төртжауап:(иә, иә, иә),(иә, жоқ, иә),(иә, иә, жоқ),(иә, иә, иә). Қабылданғанәржауапта 2 A жазбасыбар. ҚолданылатынAжазбаларыныңжалпысаны?',given_data='4 үштік;ANDүшшарт;2A/жауап',find_value='A саны',formulas='["Accepted=signature∧trust∧valid_time;records=2×count(accepted)"]',unit='жазба',code='',answer_format='number' where id='dns-c10';
update unt_private.answer_keys set answer='4',steps='["1 және 4 жауапүшшарттанөтеді.","2-деtrust,3-темерзімжоқ.","Қабылданған 2 жауап×2A=4 жазба."]',explanation='Қолтаңбаныңматематикалықдұрыстығысенімменмерзімдіөздігіненрастамайды.' where task_id='dns-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қолтаңбаныңматематикалықдұрыстығысенімменмерзімдіөздігіненрастамайды.',mistakes='{}' where task_id='dns-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: NOT алдымен, содан кейінAND, ең соңындаOR есептеледі.',mistakes='{}' where task_id='logic-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кестеге тек бірліктер емес, барлық комбинациялар кіреді.',mistakes='{}' where task_id='logic-b02';
update public.unt_tasks set revision=revision+1,title='Төрт кірісті сүзгі',prompt='F=((A XOR B) AND(C OR D)) OR(A AND B AND NOT C AND NOT D). ABCD0000…1111 толықкестесіндеFнешежолда 1?',given_data='4 екіліккіріс; екіORтармақ',find_value='Жолсаны',formulas='["Бірінші жәнеекінші тармақтыңүйлесімдері қиылыспайды"]',unit='жол',code='',answer_format='number' where id='logic-c01';
update unt_private.answer_keys set answer='7',steps='["A≠B:2 жұп;C OR Dүшін 3 жұп→6 жол.","ЕкіншітармақтекA=B=1,C=D=0→1 жол.","Тармақтарқиылыспайды:6+1=7."]',explanation='ЕкіORтармаққиылыссаекіретсанамаукерек; мұндаA≠BжәнеA=Bөзарабөлек.' where task_id='logic-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: ЕкіORтармаққиылыссаекіретсанамаукерек; мұндаA≠BжәнеA=Bөзарабөлек.',mistakes='{}' where task_id='logic-c01';
update public.unt_tasks set revision=revision+1,title='Эквивалент өрнек пен шектеу',prompt='F=NOT(A OR B) AND(C OR D). ТекC≠DжолдарынқарастырғандаF=1 болатынкомбинациясаны?',given_data='A,B,C,D;C XOR D=1',find_value='Count',formulas='["F=¬A∧¬B∧(C∨D);C≠D"]',unit='жол',code='',answer_format='number' where id='logic-c02';
update unt_private.answer_keys set answer='2',steps='["ДеМорган:NOT(A OR B)=NOT A AND NOT B.","A=B=0 ғана;C,Dүшін 01 не 10.","ӘржұптаC OR D=1, сондықтан 2 жол."]',explanation='Теңөрнектітабу—біріншіқадам; оданкейінқосымшашектеуге сайжолдарсаналады.' where task_id='logic-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Теңөрнектітабу—біріншіқадам; оданкейінқосымшашектеуге сайжолдарсаналады.',mistakes='{}' where task_id='logic-c02';
update public.unt_tasks set revision=revision+1,title='Қысқарту және санақ',prompt='F=(A AND B) OR(A AND NOT B) OR(NOT A AND C). ТөртайнымалыABCDүшінF=1 жәнеD=Aболатынжолсаны?',given_data='Fқысқарту;D=A',find_value='Count',formulas='["AB∨A¬B=A;A∨¬AC=A∨C"]',unit='жол',code='',answer_format='number' where id='logic-c03';
update unt_private.answer_keys set answer='6',steps='["АлғашқыекітармақA-ғатең.","ЖұтузаңыменF=A OR C.","A,Cүшін 01,10,11:3 жұп;Bеркін 2 мән.","DәрAүшінбекітілген:3×2=6."]',explanation='Dшектеуіжаңаеркінкөбейткішбермейді, алBқысқарғаннанкейінеркінқалады.' where task_id='logic-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Dшектеуіжаңаеркінкөбейткішбермейді, алBқысқарғаннанкейінеркінқалады.',mistakes='{}' where task_id='logic-c03';
update public.unt_tasks set revision=revision+1,title='Көпшілік және бекітілген кіріс',prompt='Бес кірісті majority функциясы кемінде үш кіріс 1 болса, 1 береді. A=0 бекітілген. B,C,D,E комбинацияларының нешеуі F=1 береді?',given_data='5 кіріс;A0; кемінде 3 бірлік',find_value='Count',formulas='["C(4,3)+C(4,4)"]',unit='жол',code='',answer_format='number' where id='logic-c04';
update unt_private.answer_keys set answer='5',steps='["Aбірлікбермейді, төртқалғанкірістекемінде 3 бірліккерек.","Дәл 3 бірлік:C(4,3)=4.","Төртеуідебірлік:1; барлығы 5."]',explanation='A=0 болғандықтан, қалған төрт кірістің кемінде үшеуі 1 болуы керек. Шектеулі кестеге толық кестенің симметриясын тікелей қолданбаңыз.' where task_id='logic-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: A=0 болғандықтан, қалған төрт кірістің кемінде үшеуі 1 болуы керек. Шектеулі кестеге толық кестенің симметриясын тікелей қолданбаңыз.',mistakes='{}' where task_id='logic-c04';
update public.unt_tasks set revision=revision+1,title='NAND толық векторы',prompt='NAND желісін AB=00,01,10,11 ретімен есептеңіз. Алдымен төрт биттік F векторын, одан кейін ондағы бірліктер санын бос орынмен жазыңыз. Желінің теңдеулері берілгені өрісінде көрсетілген.',given_data='X=NAND(A,B); Y=NAND(A,X); Z=NAND(B,X); F=NAND(Y,Z). AB реті: 00,01,10,11.',find_value='vector ones',formulas='["ӘржолдаX→Y,Z→F"]',unit='тізбек',code='',answer_format='sequence' where id='logic-c05';
update unt_private.answer_keys set answer='0110 2',steps='["00:X1,Y1,Z1,F0.","01:X1,Y1,Z0,F1;10:X1,Y0,Z1,F1.","11:X0,Y1,Z1,F0.","Вектор 0110, бірліктер 2."]',explanation='Әр кіріс жұбында X, содан кейін Y мен Z, соңында F есептеледі. Бір жұпты ғана есептеу толық функцияны анықтамайды.' where task_id='logic-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр кіріс жұбында X, содан кейін Y мен Z, соңында F есептеледі. Бір жұпты ғана есептеу толық функцияны анықтамайды.',mistakes='{}' where task_id='logic-c05';
update public.unt_tasks set revision=revision+1,title='Күйге тәуелді блок-схема',prompt='s=0, i=1. i≤6 болғанша: s жұп болса s=s+i, әйтпесе s=2s−i; содан кейін i=i+1. Цикл соңындағы s мәнін табыңыз.',given_data='Бастапқыs0,i1; шартs-тіңескіпаритетімен',find_value='s',formulas='["Әрайналым:шарт→біртармақ→i++"]',unit='сан',code='',answer_format='number' where id='logic-c06';
update unt_private.answer_keys set answer='8',steps='["i1:s0 жұп→1;i2:s1 тақ→0.","i3:s0 жұп→3;i4:s3 тақ→2.","i5:s2 жұп→7;i6:s7 тақ→8.","Соңғыs=8."]',explanation='Тармақ i-ге емес, әр айналымның басындағы s мәнінің жұптығына тәуелді. Айнымалыларды жазылған ретпен жаңартыңыз.' where task_id='logic-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тармақ i-ге емес, әр айналымның басындағы s мәнінің жұптығына тәуелді. Айнымалыларды жазылған ретпен жаңартыңыз.',mistakes='{}' where task_id='logic-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр тармақ соңғы y мәніне қолданылады.',mistakes='{}' where task_id='logic-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Тәуелсіз айнымалы жұптарының мүмкіндіктері көбейеді.',mistakes='{}' where task_id='logic-c08';
update public.unt_tasks set revision=revision+1,title='Импликациялар жүйесі',prompt='ТөртайнымалыүшінF=(A→B) AND(B→C) AND(A OR D). F=1 жәнедәлекіайнымалы 1 болатыннешежолбар?',given_data='4 бит; екіимпликация;popcount2',find_value='Count',formulas='["A→B=¬A∨B;B→C=¬B∨C"]',unit='жол',code='',answer_format='number' where id='logic-c09';
update unt_private.answer_keys set answer='1',steps='["A=1 болсаB=C=1 талапетіледі: кемінде 3 бірлік, жарамсыз.","A=0 болғандаA OR DүшінD=1 керек.","ДәлекіншібірлікB,Cарасында:01 жарамды,10B→C-нібұзады.","Жалғыз 0011 жолы, саны 1."]',explanation='Импликациятерістеуіндұрысталдап, дәлекібірлікшектеуінқатарорындаңыз.' where task_id='logic-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Импликациятерістеуіндұрысталдап, дәлекібірлікшектеуінқатарорындаңыз.',mistakes='{}' where task_id='logic-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кесте жолдарының ретін ауыстыру векторды өзгертеді.',mistakes='{}' where task_id='logic-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Формула = таңбасынан басталады; ұяшық адресі оның мәнін береді.',mistakes='{}' where task_id='spreadsheets-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: $ белгісі жоқ жолдар көшіру кезінде ығысады.',mistakes='{}' where task_id='spreadsheets-b02';
update public.unt_tasks set revision=revision+1,title='Көшірілген жеңілдік',prompt='C2 ұяшығындағы көрсетілген формула C5-ке көшірілді. A5=240, B1=0.15, D1=200. C5 ұяшығының сандық нәтижесін табыңыз.',given_data='A5=240;B1=0.15;D1=200;Δrow3',find_value='C5',formulas='["Relative A2→A5;absolute B1,D1бекітілген;IF"]',unit='сан',code='=IF(A2>=$D$1,A2*(1-$B$1),A2)',answer_format='number' where id='spreadsheets-c01';
update unt_private.answer_keys set answer='204',steps='["Формула=IF(A5>=$D$1,A5*(1-$B$1),A5).","240≥200 ақиқат.","240×0.85=204."]',explanation='Алдымен салыстырмалы сілтемені көшіріңіз, содан кейін шартты таңдаңыз және тек орындалатын тармақта жеңілдікті есептеңіз.' where task_id='spreadsheets-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен салыстырмалы сілтемені көшіріңіз, содан кейін шартты таңдаңыз және тек орындалатын тармақта жеңілдікті есептеңіз.',mistakes='{}' where task_id='spreadsheets-c01';
update public.unt_tasks set revision=revision+1,title='Аралас сілтеме және SUM',prompt='C3 ұяшығындағы көрсетілген формула E5-ке көшірілді. A5:D5 мәндері 2,4,6,8; E1=3 және F2=5. E5 мәнін табыңыз.',given_data='Δcol2,Δrow2;A5:D5;E1,F2',find_value='E5',formulas='["Координатаныбекіту→жаңаrange→SUM×factor+constant"]',unit='сан',code='=SUM($A3:B3)*C$1+$F$2',answer_format='number' where id='spreadsheets-c02';
update unt_private.answer_keys set answer='65',steps='["C3-тен E5-ке ығысу: екі баған оңға, екі жол төмен.","Сілтемелер: $A3→$A5; B3→D5; C$1→E$1; $F$2 өзгермейді.","Жаңа формула: =SUM($A5:D5)*E$1+$F$2. Диапазон қосындысы 2+4+6+8=20.","E5=20×3+5=65."]',explanation='Бекітілмеген жол мен баған екеуі де жылжиды. $A бағаны орнында қалғандықтан, жаңа диапазон A5:D5 болады.' where task_id='spreadsheets-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бекітілмеген жол мен баған екеуі де жылжиды. $A бағаны орнында қалғандықтан, жаңа диапазон A5:D5 болады.',mistakes='{"47":"Диапазонның сол жақ бағаны $A арқылы бекітілген. E5-ке көшіргенде диапазон A5:D5 болады."}' where task_id='spreadsheets-c02';
update public.unt_tasks set revision=revision+1,title='Агрегат пен шартты түзету',prompt='A1:A6 мәндері 4,7,−2,9,6,12. Көрсетілген IF, COUNTIF, SUM және MAX формуласының сандық нәтижесін есептеңіз.',given_data='6 сан; терісбар-жоқшарты',find_value='Value',formulas='["COUNTIF→IFтармағы→SUM−2MAX"]',unit='сан',code='=IF(COUNTIF(A1:A6,"<0")>0,SUM(A1:A6)-MAX(A1:A6)*2,AVERAGE(A1:A6))',answer_format='number' where id='spreadsheets-c03';
update unt_private.answer_keys set answer='12',steps='["Теріссанбіреу, біріншітармақалынған.","SUM=36;MAX=12.","36−2×12=12."]',explanation='Алдымен теріс мәннің барын тексеріңіз. Орташа мән тармағы орындалмаса, оны нәтижеге қоспаңыз.' where task_id='spreadsheets-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен теріс мәннің барын тексеріңіз. Орташа мән тармағы орындалмаса, оны нәтижеге қоспаңыз.',mistakes='{}' where task_id='spreadsheets-c03';
update public.unt_tasks set revision=revision+1,title='Екі шартты жиын',prompt='A1:A8 мәндері 40,75,90,75,60,100,55,80. Код өрісіндегі үш COUNTIF біріктірілген формуланың нәтижесін табыңыз.',given_data='8 балл; үшсүзгі',find_value='Value',formulas='["ӘрCOUNTIFжеке;көбейтуқосуданбұрын"]',unit='сан',code='=COUNTIF(A1:A8,">=75")-COUNTIF(A1:A8,">90")+COUNTIF(A1:A8,"<60")*2',answer_format='number' where id='spreadsheets-c04';
update unt_private.answer_keys set answer='8',steps='["≥75 бесмән;>90 бірмән.","<60 мәндері 40,55: екеу.","5−1+2×2=8."]',explanation='Әр сүзгінің жиынын бөлек санаңыз. 75 бірінші шартқа кіреді, 90 екінші шартқа кірмейді; көбейту соңғы қосудан бұрын орындалады.' where task_id='spreadsheets-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр сүзгінің жиынын бөлек санаңыз. 75 бірінші шартқа кіреді, 90 екінші шартқа кірмейді; көбейту соңғы қосудан бұрын орындалады.',mistakes='{}' where task_id='spreadsheets-c04';
update public.unt_tasks set revision=revision+1,title='SUMIFS арқылы орташа',prompt='A1:A6 санаттары A,B,A,A,B,A; B1:B6 мәндері 10,20,30,40,50,60; C1:C6 белгілері 1,1,0,1,1,1. Кодтағы SUMIFS/COUNTIFS нәтижесін төрт ондық таңбаға дейін дөңгелектеңіз.',given_data='СанатAжәнеflag1 бірге',find_value='Mean',formulas='["ANDсүзгі→қосынды/сан"]',unit='сан',code='=SUMIFS(B1:B6,A1:A6,"A",C1:C6,1)/COUNTIFS(A1:A6,"A",C1:C6,1)',answer_format='number' where id='spreadsheets-c05';
update unt_private.answer_keys set answer='36.6667',steps='["Екішартқа 1,4,6 қатарларсай:10,40,60.","Қосынды 110, саны 3.","110/3=36.666666…; төртондықпен 36.6667."]',explanation='Санат A және белгі 1 шарттарының екеуі де бір қатарда орындалуы керек. Қосынды мен санға бірдей сүзгіні қолданыңыз.' where task_id='spreadsheets-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Санат A және белгі 1 шарттарының екеуі де бір қатарда орындалуы керек. Қосынды мен санға бірдей сүзгіні қолданыңыз.',mistakes='{}' where task_id='spreadsheets-c05';
update public.unt_tasks set revision=revision+1,title='Көшірілген nested IF',prompt='Көрсетілген C2 формуласы C4-ке көшірілді. A4=82, B4=3; F1=80, F2=2, F3=10. C4 мәнін есептеңіз.',given_data='Δrow2;A482,B43;F80,2,10',find_value='C4',formulas='["Адрестері→AND→ішкіIF"]',unit='сан',code='=IF(AND(A2>=$F$1,B2<=$F$2),A2+$F$3,IF(A2>=60,A2-5,0))',answer_format='number' where id='spreadsheets-c06';
update unt_private.answer_keys set answer='77',steps='["ЖаңаformulaA4,B4-тіалады,Fбекітілген.","82≥80true,3≤2false:ANDfalse.","Ішкі 82≥60true:82−5=77."]',explanation='AND шартында бір бөлік жалған болса, бірінші нәтиже алынбайды. $F сілтемелерін көшіру кезінде өзгертпеңіз.' where task_id='spreadsheets-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: AND шартында бір бөлік жалған болса, бірінші нәтиже алынбайды. $F сілтемелерін көшіру кезінде өзгертпеңіз.',mistakes='{}' where task_id='spreadsheets-c06';
update public.unt_tasks set revision=revision+1,title='Іздеу және көлемдік жеңілдік',prompt='A1:B3 кестесі 101→12, 102→15, 103→20. D2=102, E2=8, F1=0.10. Көрсетілген VLOOKUP және IF формуласы қандай жалпы құн береді?',given_data='Код 102; саны 8;5-тенбастап 10%жеңілдік',find_value='Total',formulas='["Exactlookup→quantity→discount"]',unit='сан',code='=VLOOKUP(D2,$A$1:$B$3,2,FALSE)*E2*IF(E2>=5,1-$F$1,1)',answer_format='number' where id='spreadsheets-c07';
update unt_private.answer_keys set answer='108',steps='["102 кодыныңбағасы 15.","8 дананыңбағасы 120.","8≥5:120×0.9=108."]',explanation='Алдымен нақты код бойынша бағаны іздеңіз, кейін санға көбейтіп, көлемдік жеңілдіктің қолданылуын тексеріңіз.' where task_id='spreadsheets-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен нақты код бойынша бағаны іздеңіз, кейін санға көбейтіп, көлемдік жеңілдіктің қолданылуын тексеріңіз.',mistakes='{}' where task_id='spreadsheets-c07';
update public.unt_tasks set revision=revision+1,title='Бос мән мен бос жол',prompt='A1=10; A2 шынымен бос; A3 мәтін түріндегі 20; A4 формуласы =5+5; A5 формуласы =""; A6 мәтіні «жоқ». Кодтағы COUNTA, COUNT және LEN формуласының нәтижесін табыңыз.',given_data='6 ұяшық; формулақайтарғанбосжол≠шынбос',find_value='Value',formulas='["COUNTA мен COUNT бөлек; LEN бос жолға 0 береді"]',unit='сан',code='=COUNTA(A1:A6)*10-COUNT(A1:A6)-IF(LEN(A5)=0,2,0)',answer_format='number' where id='spreadsheets-c08';
update unt_private.answer_keys set answer='46',steps='["COUNTA: шынбосA2-денбасқасы 5.","COUNT: сандықA1,A4→2.","LEN(A5)=0 ақиқат, сондықтан IF 2 қайтарады.","5×10−2−2=46."]',explanation='Формула қайтарған бос жол COUNTA үшін бос емес ұяшық, бірақ оның мәтін ұзындығы 0. Сан мен санға ұқсас мәтінді бөлек есептеңіз.' where task_id='spreadsheets-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Формула қайтарған бос жол COUNTA үшін бос емес ұяшық, бірақ оның мәтін ұзындығы 0. Сан мен санға ұқсас мәтінді бөлек есептеңіз.',mistakes='{}' where task_id='spreadsheets-c08';
update public.unt_tasks set revision=revision+1,title='Пайыздық көрініс пен мән',prompt='A1=0.125, A2=0.075. B1 формуласы =SUM(A1:A2)*1.5. B1 үшін 0.00% пішімі мен ағылшын locale қолданылған. Экрандағы мәтінді жазыңыз.',given_data='Сақталғанмәндер 0.125,0.075;×1.5',find_value='Display',formulas='["Сандықформула→пайызкөрінісі×100→2decimal"]',unit='мәтін',code='=SUM(A1:A2)*1.5',answer_format='text' where id='spreadsheets-c09';
update unt_private.answer_keys set answer='30.00%',steps='["Қосынды 0.2.","B1=0.2×1.5=0.3.","Пішімі 0.00%→30.00%."]',explanation='Формула сақталған ондық мәнмен есептеледі. Пайыздық пішім тек соңғы көріністі 100-ге көбейтіп көрсетеді.' where task_id='spreadsheets-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Формула сақталған ондық мәнмен есептеледі. Пайыздық пішім тек соңғы көріністі 100-ге көбейтіп көрсетеді.',mistakes='{}' where task_id='spreadsheets-c09';
update public.unt_tasks set revision=revision+1,title='Жинақталған диапазонды көшіру',prompt='C2 ұяшығындағы көрсетілген формула D5-ке көшірілді. A2:C5 қатарлары: (3,1,2), (5,2,4), (7,3,6), (9,4,8). D5 сандық нәтижесін табыңыз.',given_data='Δcol1,Δrow3;4 қатар 3 баған',find_value='D5',formulas='["Фиксацияланғанбасы;салыстырмалысоңыжол/бағанбойыншаығысады"]',unit='сан',code='=SUM($A$2:A2)-SUM($B$2:B2)',answer_format='number' where id='spreadsheets-c10';
update unt_private.answer_keys set answer='4',steps='["Біріншіrange$A$2:B5, екінші$B$2:C5.","БіріншіSUM=(Aсум 24)+(Bсум 10)=34.","ЕкіншіSUM=10+20=30.","Айырма 34−30=4."]',explanation='Бір баған оңға және үш жол төмен көшіру диапазондардың енін де өзгертеді. Екі жаңа диапазондағы ортақ B бағаны айырмада жойылады.' where task_id='spreadsheets-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бір баған оңға және үш жол төмен көшіру диапазондардың енін де өзгертеді. Екі жаңа диапазондағы ортақ B бағаны айырмада жойылады.',mistakes='{}' where task_id='spreadsheets-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бүтін бөлу мен қалдық бір бөлу амалының екі нәтижесі.',mistakes='{}' where task_id='python-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бірнеше шарт дұрыс болса да if/elif тізбегі бір тармақты орындайды.',mistakes='{}' where task_id='python-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: range тоқтау шегін қоспайды.',mistakes='{}' where task_id='python-c01';
update public.unt_tasks set revision=revision+1,title='Nested list және көшірме',prompt='Python3 кодын талдаңыз. a, b және c тізімдерінің қосындыларын дәл print ретімен, бос орынмен бөліп жазыңыз.',given_data='bүстірткөшірме;cжолдардыжекекөшіреді',find_value='stdout',formulas='["Ортақішкіобъект→append;жолдықайтаб байланыстыру→Σ"]',unit='тізбек',code='a = [[1, 2], [3, 4]]
b = a[:]
c = [row[:] for row in a]
b[0].append(5)
b[1] = [9]
c[0][1] = 7
print(sum(map(sum, a)), sum(map(sum, b)), sum(map(sum, c)))',answer_format='sequence' where id='python-c02';
update unt_private.answer_keys set answer='15 17 15',steps='["b=a[:] жаңа сыртқы тізім жасайды, бірақ a мен b ішкі жолдары ортақ. c ішкі жолдарды да бөлек көшіреді.","b[0].append(5) a[0]-ді де [1,2,5] етеді. b[1]=[9] тек b-нің екінші жол сілтемесін ауыстырады.","c[0][1]=7 тек c-ге әсер етеді. a=[[1,2,5],[3,4]], b=[[1,2,5],[9]], c=[[1,7],[3,4]].","Қосындылар: a=15, b=17, c=15. Шығарылым: 15 17 15."]',explanation='b сыртқы тізімнің үстірт көшірмесі: ішкі жолдар a-мен ортақ. c ішкі жолдарды да жеке көшірген. Жолды қайта меншіктеу мен ортақ жолға append жасау бөлек әсер етеді.' where task_id='python-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: b сыртқы тізімнің үстірт көшірмесі: ішкі жолдар a-мен ортақ. c ішкі жолдарды да жеке көшірген. Жолды қайта меншіктеу мен ортақ жолға append жасау бөлек әсер етеді.',mistakes='{"10 17 15":"a-ның бірінші ішкі тізімі b-мен ортақ. b[0].append(5) a-ға да әсер етеді.","17 17 15":"b[1]=[9] сыртқы b тізімінің сілтемесін ғана өзгертеді; a[1] әлі [3,4]."}' where task_id='python-c02';
update public.unt_tasks set revision=revision+1,title='Slice assignment және кері кесінді',prompt='Python3 кодындағы slice assignment пен кері кесіндіні талдаңыз. print шығаратын барлық сандарды ретімен жазыңыз.',given_data='a0…9;extendedsliceassignment; керікесінді',find_value='stdout',formulas='["Бірдейпозицияларғаменшіктеу→керіиндекстер→қосынды"]',unit='тізбек',code='a = list(range(10))
a[2:7:2] = [20, 40, 60]
b = a[8:1:-2]
print(sum(b), *a[3:8])',answer_format='sequence' where id='python-c03';
update unt_private.answer_keys set answer='128 3 40 5 60 7',steps='["a[2:7:2]индекстері 2,4,6:20,40,60 қойылады.","a[8:1:-2]индекстері 8,6,4,2→8,60,40,20; қосынды 128.","a[3:8]→3,40,5,60,7."]',explanation='Қадамды кесіндіге меншіктеу тек таңдалған позицияларды ауыстырады. Кері кесіндідегі stop шегі алынбайды.' where task_id='python-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қадамды кесіндіге меншіктеу тек таңдалған позицияларды ауыстырады. Кері кесіндідегі stop шегі алынбайды.',mistakes='{}' where task_id='python-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Bubble sort-та көршілес орын ауыстыру саны бастапқы инверсия санына тең.',mistakes='{}' where task_id='python-c04';
update public.unt_tasks set revision=revision+1,title='Екі тұрақты сұрыптау',prompt='Екі тұрақты sorted операциясы орындалғаннан кейінгі аттардың ретін жазыңыз. Алдымен балл, кейін сынып бойынша сұрыпталады.',given_data='Алдыменбаллкемуі, сосынсыныпөсуі',find_value='stdout',formulas='["Соңғыstable sortтеңкілттебұрынғыреттісақтайды"]',unit='тізбек',code='a = [("Ali",10,80),("Bota",11,70),("Dana",10,90),("Erke",11,90)]
b = sorted(a, key=lambda p: p[2], reverse=True)
c = sorted(b, key=lambda p: p[1])
print(*(p[0] for p in c))',answer_format='sequence' where id='python-c05';
update unt_private.answer_keys set answer='Dana Ali Erke Bota',steps='["Біріншіscoreкемуі:Dana90,Erke90,Ali80,Bota70.","Екіншіclassөсуі 10 сыныптыалдынақояды.","10:Dana,Ali;11:Erke,Bota→Dana Ali Erke Bota."]',explanation='Соңғы сұрыптау басты топтауды анықтайды. Сол кілт бойынша тең элементтерде алдыңғы сұрыптаудың реті сақталады.' where task_id='python-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Соңғы сұрыптау басты топтауды анықтайды. Сол кілт бойынша тең элементтерде алдыңғы сұрыптаудың реті сақталады.',mistakes='{}' where task_id='python-c05';
update public.unt_tasks set revision=revision+1,title='Ішкі comprehension және сүзгі',prompt='Матрица, enumerate және ішкі comprehension кодын талдаңыз. Алынған тізім мен оның қосындысын print ретімен жазыңыз.',given_data='Үшжолдыматрица; әриндексішіндеөзгереді',find_value='stdout',formulas='["Қатариндексі→сүзгі→өрнек→sum"]',unit='тізбек',code='a = [[1,2,3],[4,5,6],[7,8]]
b = [x*x+i for i, row in enumerate(a) for x in row if x % 2 == 0]
print(*b, sum(b))',answer_format='sequence' where id='python-c06';
update unt_private.answer_keys set answer='4 17 37 66 124',steps='["i0: жұп 2→2²+0=4.","i1:4→16+1=17;6→36+1=37.","i2:8→64+2=66.","Тізбек 4,17,37,66; қосынды 124."]',explanation='i әр жол үшін бөлек мән алады. Сүзгі санның жұптығын тексереді, ал өрнек оның квадратына жол индексін қосады.' where task_id='python-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: i әр жол үшін бөлек мән алады. Сүзгі санның жұптығын тексереді, ал өрнек оның квадратына жол индексін қосады.',mistakes='{}' where task_id='python-c06';
update public.unt_tasks set revision=revision+1,title='Nested break және for-else',prompt='Ішкі циклдің break және else тармақтарын ескеріп, кодтың соңғы s мәнін есептеңіз.',given_data='Әржолдаалғашқытеріссанғадейін;breakболмасаelse',find_value='stdout',formulas='["Ішкіbreak→осыциклдіңelse-сінболдырмау"]',unit='сан',code='s = 0
for row in [[2,3,-1,9],[4,5],[-2,7]]:
    for x in row:
        if x < 0:
            break
        s += x
    else:
        s += 100
print(s)',answer_format='number' where id='python-c07';
update unt_private.answer_keys set answer='114',steps='["1-жол 2,3 қосылады,−1-деbreak:5;elseжоқ.","2-жол 4,5 қосылады:14;breakжоқ→100 қосылады:114.","3-жолалғашқы−2-деbreak; соңғыс 114."]',explanation='Ішкі break сыртқы циклді тоқтатпайды. else тек сол жол теріс сансыз толық қаралған жағдайда орындалады.' where task_id='python-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ішкі break сыртқы циклді тоқтатпайды. else тек сол жол теріс сансыз толық қаралған жағдайда орындалады.',mistakes='{}' where task_id='python-c07';
update public.unt_tasks set revision=revision+1,title='Цифрлар және позиция',prompt='Кодтағы цифр позициялары мен нөлдерді санауды талдаңыз. Соңғы s және z мәндерін бос орынмен жазыңыз.',given_data='n50740; оңнанпозиция 0; тақпозицияцифрларықосылады',find_value='stdout',formulas='["digit=n%10;позициябойыншасүзу;нөлсанау"]',unit='тізбек',code='n, p, s, z = 50740, 0, 0, 0
while n > 0:
    d = n % 10
    if p % 2 == 1:
        s += d
    if d == 0:
        z += 1
    n //= 10
    p += 1
print(s, z)',answer_format='sequence' where id='python-c08';
update unt_private.answer_keys set answer='4 2',steps='["Оңнанцифрлар 0,4,7,0,5.","Тақпозициялар 1,3:4+0=4.","Нөлцифрларекі,z=2."]',explanation='Позициялар оңнан 0-ден басталады. Цифрдың мәнін оның позициясының жұптығымен шатастырмаңыз; нөл цифры бөлек саналады.' where task_id='python-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Позициялар оңнан 0-ден басталады. Цифрдың мәнін оның позициясының жұптығымен шатастырмаңыз; нөл цифры бөлек саналады.',mistakes='{}' where task_id='python-c08';
update public.unt_tasks set revision=revision+1,title='Матрица жаңартуы және диагональ',prompt='Матрица құру және элементтерін жаңарту кодын орындап шығыңыз. Диагональдар қосындыларының соңғы айырмасын табыңыз.',given_data='Жолдаржекежасалған; әржолдыңбірэлементіөзгереді',find_value='stdout',formulas='["Матрицажасау→индекстікжаңарту→екідиагональайырмасы"]',unit='сан',code='a = [[3*i+j for j in range(3)] for i in range(3)]
for i in range(3):
    a[i][(i+1)%3] += 2*i
print(sum(a[i][i] for i in range(3)) - sum(a[i][2-i] for i in range(3)))',answer_format='number' where id='python-c09';
update unt_private.answer_keys set answer='-4',steps='["Бастапқыжолдар[0,1,2],[3,4,5],[6,7,8].","a[0][1]+=0;a[1][2]+=2;a[2][0]+=4→10.","Негізгі 0+4+8=12; қосалқы 2+4+10=16.","Айырма−4."]',explanation='Алдымен барлық индекстік жаңартуды аяқтаңыз. Диагональ қосындылары бастапқы емес, өзгертілген матрицадан алынады.' where task_id='python-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен барлық индекстік жаңартуды аяқтаңыз. Диагональ қосындылары бастапқы емес, өзгертілген матрицадан алынады.',mistakes='{}' where task_id='python-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бұл алгоритм индекстерді әр жұптан кейін ішке жылжытады; барлық қайталанатын жұптарды санайтын жалпы алгоритм емес.',mistakes='{}' where task_id='python-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: print пен return бірдей амал емес.',mistakes='{}' where task_id='functions-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Процедура деп қолданылған Python функциясы да None мәнін қайтарады.',mistakes='{}' where task_id='functions-b02';
update public.unt_tasks set revision=revision+1,title='Рекурсия мәні мен саны',prompt='Рекурсивті Евклид алгоритмін талдаңыз. print шығаратын gcd нәтижесі мен шақырулар санын жазыңыз.',given_data='gcd(84,30); әршақырусаналады',find_value='stdout',formulas='["Евклидтізбегі;базалықшақырудасаналады"]',unit='тізбек',code='calls = 0
def f(a,b):
    global calls
    calls += 1
    return a if b == 0 else f(b, a % b)
g = f(84,30)
print(g, calls)',answer_format='sequence' where id='functions-c01';
update unt_private.answer_keys set answer='6 4',steps='["(84,30)→(30,24)→(24,6)→(6,0).","Базалықмән 6.","Төртжұп=4 шақыру; шығарылым 6 4."]',explanation='Базалық шақыру да саналады. Өтулер санын функцияның жалпы шақырылу санымен шатастырмаңыз.' where task_id='functions-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Базалық шақыру да саналады. Өтулер санын функцияның жалпы шақырылу санымен шатастырмаңыз.',mistakes='{}' where task_id='functions-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Базалық шақырулар да есепке кіреді.',mistakes='{}' where task_id='functions-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қажет болса None default-пен әр шақыруда жаңа list жасаңыз.',mistakes='{}' where task_id='functions-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: global жарияланбаған local меншіктеу сыртқы айнымалыны өзгертпейді.',mistakes='{}' where task_id='functions-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Аргументтің объектісін өзгерту мен аргумент атауын қайта меншіктеу бөлек.',mistakes='{}' where task_id='functions-c05';
update public.unt_tasks set revision=revision+1,title='Variadic және keyword аргументтер',prompt='Позициялық, *args және атаулы аргументтері бар функцияның сандық нәтижесін есептеңіз.',given_data='a1;args2,3;scale3;bonus4',find_value='stdout',formulas='["Аргументтердіжіктеу→sum→көбейту→bonus"]',unit='сан',code='def f(a,*args,scale=2,**kw):
    return (a+sum(args))*scale+kw.get("bonus",0)
print(f(1,2,3,bonus=4,scale=3))',answer_format='number' where id='functions-c06';
update unt_private.answer_keys set answer='22',steps='["a=1,args=(2,3),scale=3,kw={bonus:4}.","(1+2+3)×3+4=22.","scaleжәнеbonusargsқұрамынакірмейді."]',explanation='Артық позициялық мәндер *args-қа жиналады; scale жеке параметр, bonus **kw ішінде. Оларды бір тізбекке араластырмаңыз.' where task_id='functions-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Артық позициялық мәндер *args-қа жиналады; scale жеке параметр, bonus **kw ішінде. Оларды бір тізбекке араластырмаңыз.',mistakes='{}' where task_id='functions-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Closure функция аяқталғаннан кейін де күйді сақтайды.',mistakes='{}' where task_id='functions-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр i-ді бекіту үшін lambda i=i: i сияқты default қолдануға болады.',mistakes='{}' where task_id='functions-c08';
update public.unt_tasks set revision=revision+1,title='Салмақталған рекурсивті цифрлар',prompt='Позиция салмағын арттыратын f(4729) рекурсивті шақыруының нәтижесін табыңыз.',given_data='Оңнанбасталғанцифрсалмағы 1,2,3,4',find_value='stdout',formulas='["f(n,p)=p(n%10)+f(n//10,p+1)"]',unit='сан',code='def f(n,p=1):
    if n == 0:
        return 0
    return p*(n%10)+f(n//10,p+1)
print(f(4729))',answer_format='number' where id='functions-c09';
update unt_private.answer_keys set answer='50',steps='["Оңнан 9×1+2×2+7×3+4×4.","9+4+21+16=50.","n0 болғандарекурсия 0 қайтарады."]',explanation='Оң жақ цифрдың салмағы 1, одан солға қарай әр шақыруда 1-ге өседі. Бұл кәдімгі цифрлар қосындысы емес.' where task_id='functions-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Оң жақ цифрдың салмағы 1, одан солға қарай әр шақыруда 1-ге өседі. Бұл кәдімгі цифрлар қосындысы емес.',mistakes='{}' where task_id='functions-c09';
update public.unt_tasks set revision=revision+1,title='Ерте return және сыртқы цикл',prompt='Факторларды қайталай табатын функция мен сыртқы while циклін талдаңыз. Барлық print мәндерін ретімен жазыңыз.',given_data='Алғашқыбөлгіштіәрқадамдаалу',find_value='stdout',formulas='["first_divisor→n-дібөлу→жинақтау"]',unit='тізбек',code='def first_divisor(n):
    for d in range(2,n):
        if n%d == 0:
            return d
    return n
n, a = 84, []
while n > 1:
    d = first_divisor(n)
    a.append(d)
    n //= d
print(*a, sum(a))',answer_format='sequence' where id='functions-c10';
update unt_private.answer_keys set answer='2 2 3 7 14',steps='["84-тіңалғашқыбөлгіші 2;n42.","42→2;n21. 21→3;n7.","7 жайсан→7;n1.","Факторлар 2,2,3,7; қосынды 14."]',explanation='Жай сан үшін first_divisor циклден бөлгіш таппай, санның өзін қайтарады. Сыртқы цикл әр табылған бөлгіштен кейін n-ді азайтады.' where task_id='functions-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жай сан үшін first_divisor циклден бөлгіш таппай, санның өзін қайтарады. Сыртқы цикл әр табылған бөлгіштен кейін n-ді азайтады.',mistakes='{}' where task_id='functions-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ашушы және жабушы тег бір элементтің екі шекарасы.',mistakes='{}' where task_id='html-css-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: font-size үшін em ата-ананың есептелген қаріп өлшеміне сүйенеді.',mistakes='{}' where task_id='html-css-b02';
update public.unt_tasks set revision=revision+1,title='Пайыз, calc және content-box',prompt='Parent ені 500px. Child үшін width:calc(60% - 20px), content-box, екі жақтан padding 10px және border 2px. Child border-box ені қанша?',given_data='Parent500;60%−20;pad10;border2',find_value='Width',formulas='["Content=0.6parent−20;box=content+2pad+2border"]',unit='px',code='<section style="width:500px"><div style="width:calc(60% - 20px);box-sizing:content-box;padding:10px;border:2px solid">X</div></section>',answer_format='number' where id='html-css-c01';
update unt_private.answer_keys set answer='304',steps='["60%×500=300px.","Content300−20=280px.","Padding20,border4 қосылады:304px."]',explanation='Пайыз parent енінен есептеледі. Одан кейін calc азайтуы орындалып, content-box өлшеміне padding пен border қосылады.' where task_id='html-css-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Пайыз parent енінен есептеледі. Одан кейін calc азайтуы орындалып, content-box өлшеміне padding пен border қосылады.',mistakes='{}' where task_id='html-css-c01';
update public.unt_tasks set revision=revision+1,title='Пайыздық border-box контенті',prompt='Parent ені 400px. Child ені 75%, box-sizing:border-box, екі жақтан padding 15px және border 3px. Контент ені қанша?',given_data='Parent400;width75%;pad15;border3',find_value='Content width',formulas='["BorderBox=parent×0.75;content=box−2pad−2border"]',unit='px',code='<section style="width:400px"><div style="width:75%;box-sizing:border-box;padding:15px;border:3px solid">X</div></section>',answer_format='number' where id='html-css-c02';
update unt_private.answer_keys set answer='264',steps='["Border-box400×0.75=300px.","Padding30,border6 байланысты.","Content300−30−6=264px."]',explanation='Пайыздық width border-box енін береді. Контентті табу үшін екі жақтағы padding пен border осы еннен алынады.' where task_id='html-css-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Пайыздық width border-box енін береді. Контентті табу үшін екі жақтағы padding пен border осы еннен алынады.',mistakes='{}' where task_id='html-css-c02';
update public.unt_tasks set revision=revision+1,title='Күрделі selector',prompt='Берілген HTML ағашында .box > p.note:not([hidden]) селекторы неше элементті таңдайды? Үш сүзгінің бәрін ескеріңіз.',given_data='Class, тікелейбала, атрибутжоқтығыбірге',find_value='Count',formulas='["parent>child;class;:not([hidden])"]',unit='элемент',code='<div class="box"><p class="note">A</p><p class="note" hidden>B</p><p>C</p><section><p class="note">nested</p></section><p class="note">D</p></div>',answer_format='number' where id='html-css-c03';
update unt_private.answer_keys set answer='2',steps='["Тікелейpтөртеу:noteA,notehiddenB,plainC,noteD.","A,Dnoteжәнеhiddenжоқ.","Ішкіsection/pтікелейбалаемес: нәтиже 2."]',explanation='Алдымен тікелей баланы, кейін note класын және hidden атрибутының жоқтығын тексеріңіз. Ішкі section ішіндегі p тікелей бала емес.' where task_id='html-css-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен тікелей баланы, кейін note класын және hidden атрибутының жоқтығын тексеріңіз. Ішкі section ішіндегі p тікелей бала емес.',mistakes='{}' where task_id='html-css-c03';
update public.unt_tasks set revision=revision+1,title='Nth-child және жоққа шығару',prompt='Берілген сегіз li элементіне li:nth-child(2n+1):not(.skip) селекторы қолданылады. Неше сәйкестік қалады?',given_data='Тақпозиция;skipкласыалынады',find_value='Count',formulas='["Тақпозицияларжиыны−skipқиылысы"]',unit='элемент',code='<ul><li>1</li><li>2</li><li class="skip">3</li><li>4</li><li>5</li><li>6</li><li class="skip">7</li><li>8</li></ul>',answer_format='number' where id='html-css-c04';
update unt_private.answer_keys set answer='2',steps='["Тақпозициялар 1,3,5,7.","3 және 7-деskipбар.","Қалған 1,5→2 элемент."]',explanation='nth-child барлық элемент бауырлардың 1-ден басталған позициясын санайды. Одан кейін skip класы бар сәйкестіктер алынады.' where task_id='html-css-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: nth-child барлық элемент бауырлардың 1-ден басталған позициясын санайды. Одан кейін skip класы бар сәйкестіктер алынады.',mistakes='{}' where task_id='html-css-c04';
update public.unt_tasks set revision=revision+1,title='Specificity tuple',prompt='Кодтағы p элементінің color мәнін CSS түс атауымен жазыңыз. Ережелер бір author origin-де, cascade layer жоқ.',given_data='ЕкіIDvsбірID+class',find_value='Color',formulas='["Specificity:(ID,class,type)лексикографиялық"]',unit='түс',code='<style>#wrap #x{color:red} #x.blue{color:blue}</style><div id="wrap"><p id="x" class="blue">X</p></div>',answer_format='text' where id='html-css-c05';
update unt_private.answer_keys set answer='red',steps='["#wrap #x:2ID→(2,0,0).","#x.blue:1ID+class→(1,1,0).","Алғашқыtupleүлкен,red; кейінжазылуоныөзгертпейді."]',explanation='Specificity үштігі ID, class, type ретімен салыстырылады. ID санын class санымен жай қосуға болмайды.' where task_id='html-css-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Specificity үштігі ID, class, type ретімен салыстырылады. ID санын class санымен жай қосуға болмайды.',mistakes='{}' where task_id='html-css-c05';
update public.unt_tasks set revision=revision+1,title='Layer important ретін талдау',prompt='Кодтағы p түсін CSS атауымен жазыңыз. Үш ереже де author !important; layer ретін ескеріңіз.',given_data='layerbase,theme;unlayeredID',find_value='Color',formulas='["Importantкезінделayerретікері;layeredimportantunlayered-тенжоғары"]',unit='түс',code='<style>@layer base,theme;@layer base{p{color:green !important}}@layer theme{#x{color:red !important}}#x{color:blue !important}</style><p id="x">X</p>',answer_format='text' where id='html-css-c06';
update unt_private.answer_keys set answer='green',steps='["Layerретіbase,theme.","!importantкезіндеалғашқыbaseсоңғыtheme-денбасым.","Layeredimportantunlayeredimportant-тендеозады→green."]',explanation='!important кезінде layer реті кері қолданылады: алғашқы layer кейінгі layer-ден басым. Layered important unlayered important-тан да жоғары.' where task_id='html-css-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: !important кезінде layer реті кері қолданылады: алғашқы layer кейінгі layer-ден басым. Layered important unlayered important-тан да жоғары.',mistakes='{}' where task_id='html-css-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: rem түбірге, бұл margin em элементтің өзінің font-size мәніне сүйенеді.',mistakes='{}' where task_id='html-css-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: gap пен space-between екеуін бір-біріне тәуелсіз толық бос орын ретінде екі рет қоспау керек.',mistakes='{}' where task_id='html-css-c08';
update public.unt_tasks set revision=revision+1,title='Calc ішіндегі Grid',prompt='Parent ені 800px. Grid ені calc(75% - 20px), үш тең 1fr баған және gap 20px. Балалардың min-width:0, padding жоқ. Бір баған ені қанша?',given_data='Parent800;grid75%−20;3cols;gap20',find_value='Column width',formulas='["Wgrid=0.75parent−20;column=(Wgrid−2gap)/3"]',unit='px',code='<section style="width:800px"><div style="display:grid;width:calc(75% - 20px);grid-template-columns:repeat(3,1fr);gap:20px"><i></i><i></i><i></i></div></section>',answer_format='number' where id='html-css-c09';
update unt_private.answer_keys set answer='180',steps='["Grid800×0.75−20=580px.","Екіgap40pxалыптасталады.","(580−40)/3=180px."]',explanation='Алдымен grid-тің нақты енін табыңыз, екі gap-ті алып тастаңыз, қалған кеңістікті үш fr бағанына бөліңіз.' where task_id='html-css-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен grid-тің нақты енін табыңыз, екі gap-ті алып тастаңыз, қалған кеңістікті үш fr бағанына бөліңіз.',mistakes='{}' where task_id='html-css-c09';
update public.unt_tasks set revision=revision+1,title='Media, пайыз және calc',prompt='Viewport ені 800 CSS px, parent ені 500px. Media ережелері мен calc қолданылған кодта child ені неше px? Padding пен border жоқ.',given_data='Viewport800;parent500;min-width700/900',find_value='Width',formulas='["Mediaтаңдау→parentpercentage→calc"]',unit='px',code='<style>.parent{width:500px}.child{width:200px}@media(min-width:700px){.child{width:calc(80% - 100px)}}@media(min-width:900px){.child{width:400px}}</style><div class="parent"><div class="child">X</div></div>',answer_format='number' where id='html-css-c10';
update unt_private.answer_keys set answer='300',steps='["800≥700, бірақ 800<900→ортаңғыереже.","80%parent500=400px.","calc(400−100)=300px."]',explanation='Media viewport еніне қарай таңдалады, бірақ width ішіндегі пайыз parent енінен алынады. Бұл екі өлшемді алмастырмаңыз.' where task_id='html-css-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Media viewport еніне қарай таңдалады, бірақ width ішіндегі пайыз parent енінен алынады. Бұл екі өлшемді алмастырмаңыз.',mistakes='{}' where task_id='html-css-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: WHERE топтаудан бұрын жеке жолдарды сүзеді.',mistakes='{}' where task_id='sql-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: SQL AVG бос мәнді0 деп қоспайды.',mistakes='{}' where task_id='sql-b02';
update public.unt_tasks set revision=revision+1,title='JOIN және HAVING',prompt='JOIN, WHERE және HAVING кезеңдерінен кейін сыртқы COUNT қандай мән қайтарады? Кестелер кодта толық берілген.',given_data='learners PK;results FK логикалық байланыс',find_value='COUNT',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM (SELECT l.id FROM learners l JOIN results r ON l.id=r.student_id WHERE r.score>=70 GROUP BY l.id HAVING COUNT(*)>=2) q;',answer_format='number' where id='sql-c01';
update unt_private.answer_keys set answer='1',steps='["WHERE>=70Ali80,90 жәнеDana90-дысақтайды.","ТоптарAli2,Dana1.","HAVING>=2 текAli: сыртқыCOUNT1."]',explanation='JOIN жолдарын бірден оқушы саны деп есептемеңіз. Алдымен балл бойынша сүзгі, кейін оқушы бойынша топтау орындалады.' where task_id='sql-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: JOIN жолдарын бірден оқушы саны деп есептемеңіз. Алдымен балл бойынша сүзгі, кейін оқушы бойынша топтау орындалады.',mistakes='{}' where task_id='sql-c01';
update public.unt_tasks set revision=revision+1,title='LEFT JOIN және COALESCE',prompt='LEFT JOIN нәтижесінде әр оқушы үшін есептелген v мәндері қосылады. Сұраудың соңғы SUM нәтижесін табыңыз.',given_data='Erke-де results жоқ',find_value='COUNT(*)',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(v) FROM (SELECT l.id,COALESCE(SUM(r.score),0)+COUNT(*) AS v FROM learners l LEFT JOIN results r ON l.id=r.student_id GROUP BY l.id) q;',answer_format='number' where id='sql-c02';
update unt_private.answer_keys set answer='326',steps='["Ali:170+2=172;Bota60+1=61.","Dana90+2=92;ErkeCOALESCE0+1=1.","172+61+92+1=326."]',explanation='LEFT JOIN бос сәйкестікте бір жасанды жол сақтайды. COUNT(*) оны санайды; COALESCE бос SUM-ды 0 етеді.' where task_id='sql-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: LEFT JOIN бос сәйкестікте бір жасанды жол сақтайды. COUNT(*) оны санайды; COALESCE бос SUM-ды 0 етеді.',mistakes='{}' where task_id='sql-c02';
update public.unt_tasks set revision=revision+1,title='Барлық талапты орындау',prompt='Python және SQL тақырыптарының әрқайсысынан кемінде 80 балл алған оқушыларды сұрау санайды. Нәтижені табыңыз.',given_data='Erke-де нәтиже жоқ;Dana-да бірNULL score бар',find_value='COUNT',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l WHERE EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id AND r.topic=''python'' AND r.score>=80) AND EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id AND r.topic=''sql'' AND r.score>=80);',answer_format='number' where id='sql-c03';
update unt_private.answer_keys set answer='1',steps='["AliPython80,SQL90: екіталаптанөтеді.","BotaPython60,SQLжоқ;DanaSQL90,PythonNULL.","Erke-денәтижелержоқ; қалғаныAliғана→1."]',explanation='Екі EXISTS бөлек тақырыпты тексереді. Бір жоғары балл екінші тақырыптың жоқ не NULL нәтижесін алмастырмайды.' where task_id='sql-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Екі EXISTS бөлек тақырыпты тексереді. Бір жоғары балл екінші тақырыптың жоқ не NULL нәтижесін алмастырмайды.',mistakes='{}' where task_id='sql-c03';
update public.unt_tasks set revision=revision+1,title='Топтау және сынып шарты',prompt='Сынып бойынша топтау, бірегей оқушылар саны және орташа балл шектеулері орындалғанда сыртқы COUNT не береді?',given_data='Әр оқушының non-null орташа ұпайы',find_value='COUNT топтар',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM (SELECT l.klass,AVG(r.score) AS m FROM learners l JOIN results r ON r.student_id=l.id GROUP BY l.klass HAVING COUNT(DISTINCT l.id)>=2 AND AVG(r.score)>=80) q;',answer_format='number' where id='sql-c04';
update unt_private.answer_keys set answer='1',steps='["10 сыныптаAli,Dana→2 оқушы, балдар 80,90,90; орташа 86,666… .","11 сыныптаJOIN-нанBotaғана, орташа 60.","Екішарттан 10 сыныпөтеді:1 топ."]',explanation='AVG NULL емес JOIN баллдарынан есептеледі. Оқушы санын табуда бір оқушының бірнеше нәтижесін DISTINCT арқылы бір рет санаңыз.' where task_id='sql-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: AVG NULL емес JOIN баллдарынан есептеледі. Оқушы санын табуда бір оқушының бірнеше нәтижесін DISTINCT арқылы бір рет санаңыз.',mistakes='{}' where task_id='sql-c04';
update public.unt_tasks set revision=revision+1,title='Қос көбейтуді болдырмау',prompt='Алдын ала агрегатталған нәтижелерге сынып және total шектеуі қолданылған. Сұраудың соңғы SUM мәнін есептеңіз.',given_data='10-сынып:Ali,Dana',find_value='SUM',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(p.total) FROM learners l JOIN (SELECT student_id,SUM(score) AS total FROM results GROUP BY student_id) p ON p.student_id=l.id WHERE l.klass=10 AND p.total>=100;',answer_format='number' where id='sql-c05';
update unt_private.answer_keys set answer='170',steps='["АлдыналатоптарAli170,Bota60,Dana90.","10 сыныпAli,Dana;total>=100 текAli.","СыртқыSUM170."]',explanation='Әр оқушының total мәні ішкі сұрауда есептеледі. Содан кейін сынып пен total шарты бірдей орындалған жолдар ғана қосылады.' where task_id='sql-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр оқушының total мәні ішкі сұрауда есептеледі. Содан кейін сынып пен total шарты бірдей орындалған жолдар ғана қосылады.',mistakes='{}' where task_id='sql-c05';
update public.unt_tasks set revision=revision+1,title='NULL және correlated average',prompt='Әр нәтиже өз оқушысының орташа баллымен салыстырылады. Корреляцияланған сұраудың COUNT нәтижесі қанша?',given_data='score80,90,60,90,NULL',find_value='COUNT',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM results r WHERE r.score>(SELECT AVG(s.score) FROM results s WHERE s.student_id=r.student_id);',answer_format='number' where id='sql-c06';
update unt_private.answer_keys set answer='1',steps='["Aliорташа 85:90 ғанаоданүлкен.","Botaорташа 60: өзіненүлкенемес.","Danaорташа 90:90 тең,NULLсалыстыруыUNKNOWN.","Саны 1."]',explanation='Ішкі AVG барлық оқушыға ортақ емес. NULL салыстыруы TRUE болмайды; орташаға тең балл да > шартынан өтпейді.' where task_id='sql-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Ішкі AVG барлық оқушыға ортақ емес. NULL салыстыруы TRUE болмайды; орташаға тең балл да > шартынан өтпейді.',mistakes='{}' where task_id='sql-c06';
update public.unt_tasks set revision=revision+1,title='UNION және DISTINCT',prompt='UNION арқылы алынған екі жиындағы бірегей student_id саны қанша болады? NULL шарты мен нәтижесі жоқ оқушыларды ажыратыңыз.',given_data='python нәтижелері:1,2,3',find_value='COUNT DISTINCT',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM (SELECT student_id FROM results WHERE topic=''python'' AND score>=60 UNION SELECT l.id FROM learners l WHERE NOT EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id)) q;',answer_format='number' where id='sql-c07';
update unt_private.answer_keys set answer='3',steps='["Python>=60Ali1,Bota2;DanaNULLөтпейді.","МүлденәтижесіжоқErke4.","UNIONбірегей 1,2,4→3."]',explanation='UNION қайталануды жояды. Нәтиже жолы бар, бірақ score NULL болған оқушыны мүлде нәтиже жолы жоқ оқушымен шатастырмаңыз.' where task_id='sql-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: UNION қайталануды жояды. Нәтиже жолы бар, бірақ score NULL болған оқушыны мүлде нәтиже жолы жоқ оқушымен шатастырмаңыз.',mistakes='{}' where task_id='sql-c07';
update public.unt_tasks set revision=revision+1,title='Әр оқушының үздік нәтижесі',prompt='ROW_NUMBER әр оқушының үздік нәтижесін таңдайды. Сыртқы SUM қайтаратын мәнді табыңыз.',given_data='Ең жоғары балл 90 екі оқушыда',find_value='student_id',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(score) FROM (SELECT student_id,score,ROW_NUMBER() OVER(PARTITION BY student_id ORDER BY score DESC,topic ASC) AS rn FROM results WHERE score IS NOT NULL) q WHERE rn=1;',answer_format='number' where id='sql-c08';
update unt_private.answer_keys set answer='240',steps='["Aliүздігі 90;Bota60;Dana90.","NULLалдыналасүзілген;Erkeнәтижесіжоқ.","90+60+90=240."]',explanation='PARTITION BY әр оқушыға бөлек реттік нөмір береді. Бұл бүкіл кестеден жалғыз ең жоғары баллды алу емес.' where task_id='sql-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: PARTITION BY әр оқушыға бөлек реттік нөмір береді. Бұл бүкіл кестеден жалғыз ең жоғары баллды алу емес.',mistakes='{}' where task_id='sql-c08';
update public.unt_tasks set revision=revision+1,title='Anti-join және threshold',prompt='Барлық нәтижесі кемінде 80 және кемінде бір нәтижесі бар оқушыларды сұрау санайды. COUNT нәтижесін табыңыз.',given_data='SQL нәтижесіAli менDana-да бар',find_value='COUNT',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT COUNT(*) FROM learners l WHERE NOT EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id AND (r.score<80 OR r.score IS NULL)) AND EXISTS(SELECT 1 FROM results r WHERE r.student_id=l.id);',answer_format='number' where id='sql-c09';
update unt_private.answer_keys set answer='1',steps='["Ali-діңбарлықбалдары>=80.","Bota60 үшін,DanaNULLүшіналынады.","Erke-демүлдерезултатжоқ: екіншіEXISTSөтпейді.","ТекAli→1."]',explanation='Бос жиын үшін NOT EXISTS ақиқат болуы мүмкін. Екінші EXISTS нәтижесі жоқ оқушыны алып тастайды; NULL жеке тексеріледі.' where task_id='sql-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бос жиын үшін NOT EXISTS ақиқат болуы мүмкін. Екінші EXISTS нәтижесі жоқ оқушыны алып тастайды; NULL жеке тексеріледі.',mistakes='{}' where task_id='sql-c09';
update public.unt_tasks set revision=revision+1,title='Шартты агрегат және GROUP',prompt='LEFT JOIN, екі CASE және GROUP BY қолданылған. Сұраудың сыртқы SUM нәтижесін табыңыз.',given_data='Өткен балл≥80;NULL өтпейді',find_value='SUM CASE',formulas='["JOIN/сүзгі→GROUP/aggregate→сыртқысұрау"]',unit='сан',code='CREATE TABLE learners(id INTEGER PRIMARY KEY, name TEXT, klass INTEGER);
INSERT INTO learners VALUES(1,''Ali'',10),(2,''Bota'',11),(3,''Dana'',10),(4,''Erke'',11);
CREATE TABLE results(student_id INTEGER, topic TEXT, score INTEGER);
INSERT INTO results VALUES(1,''python'',80),(1,''sql'',90),(2,''python'',60),(3,''sql'',90),(3,''python'',NULL);
-- Query
SELECT SUM(passed*10+missing) FROM (SELECT l.id,SUM(CASE WHEN r.score>=80 THEN 1 ELSE 0 END) AS passed,SUM(CASE WHEN r.student_id IS NOT NULL AND r.score IS NULL THEN 1 ELSE 0 END) AS missing FROM learners l LEFT JOIN results r ON l.id=r.student_id GROUP BY l.id) q;',answer_format='number' where id='sql-c10';
update unt_private.answer_keys set answer='31',steps='["Ali:passed2,missing0→20.","Bota0,0→0;Dana1,1→11.","Erke-ніңжасандыNULLжолыr.student_idISNULLболғандықтанmissingемес.","20+0+11+0=31."]',explanation='Нәтиже жолындағы NULL балл мен LEFT JOIN жасанды жолындағы NULL бірдей есептелмейді: student_id арқылы ажыратыңыз.' where task_id='sql-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Нәтиже жолындағы NULL балл мен LEFT JOIN жасанды жолындағы NULL бірдей есептелмейді: student_id арқылы ажыратыңыз.',mistakes='{}' where task_id='sql-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кластерлеуде алдын ала дұрыс белгі берілмейді.',mistakes='{}' where task_id='ai-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Test жиыны соңғы тәуелсіз бағалауға сақталады.',mistakes='{}' where task_id='ai-b02';
update public.unt_tasks set revision=revision+1,title='Массивтен precision',prompt='Нақты санаттар [1,0,1,1,0,0,1,0], болжамдар [1,1,0,1,0,1,1,0]. Жұптарды салыстырып, оң санат 1 үшін precision пайызын табыңыз.',given_data='8 сәйкесжұп; оң 1',find_value='Precision, %',formulas='["TP=count(y=1,p=1);FP=count(y=0,p=1);P=TP/(TP+FP)"]',unit='%',code='',answer_format='number' where id='ai-c01';
update unt_private.answer_keys set answer='60',steps='["TPпозициялар 1,4,7:3.","FPпозициялар 2,6:2;FNпозиция 3:1.","Precision3/(3+2)×100=60%."]',explanation='Алдымен TP мен FP-ді жеке санаңыз. Precision бөлімінде барлық нақты оңдар емес, барлық оң болжамдар тұрады.' where task_id='ai-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен TP мен FP-ді жеке санаңыз. Precision бөлімінде барлық нақты оңдар емес, барлық оң болжамдар тұрады.',mistakes='{}' where task_id='ai-c01';
update public.unt_tasks set revision=revision+1,title='Шектен кейін recall',prompt='Нақты санаттар [1,1,0,1,0,1], ықтималдықтар [0.9,0.6,0.8,0.4,0.2,0.7]. p≥0.7 болса модель 1 дейді. Recall пайызын табыңыз.',given_data='6 үлгі;threshold0.7 теңдікпен',find_value='Recall, %',formulas='["Шек→болжам;TP,FN;R=TP/(TP+FN)"]',unit='%',code='',answer_format='number' where id='ai-c02';
update unt_private.answer_keys set answer='50',steps='["Болжам 1 позициялар 1,3,6.","Нақтыоң 1,2,4,6:TP1,6→2;FN2,4→2.","Recall2/(2+2)×100=50%."]',explanation='0.7-ге тең ықтималдық та оң болжам болады. Recall нақты оңдардың қаншасы табылғанын өлшейді; FP оның бөліміне кірмейді.' where task_id='ai-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: 0.7-ге тең ықтималдық та оң болжам болады. Recall нақты оңдардың қаншасы табылғанын өлшейді; FP оның бөліміне кірмейді.',mistakes='{}' where task_id='ai-c02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: F1 — жай орта емес, гармониялық орта.',mistakes='{}' where task_id='ai-c03';
update public.unt_tasks set revision=revision+1,title='Train scaler және арақашықтық',prompt='Train min=[10,0], max=[50,20]. x=[30,15] және c=[20,5] нүктелерін сол параметрлермен min-max масштабтап, Манхэттен арақашықтығын табыңыз. Clipping жоқ.',given_data='Екібелгі; бірscaler',find_value='Distance',formulas='["x′=(x−min)/(max−min);d=Σ|x′−c′|"]',unit='мән',code='',answer_format='number' where id='ai-c04';
update unt_private.answer_keys set answer='0.75',steps='["x′=[0.5,0.75].","c′=[0.25,0.25].","d=|0.5−0.25|+|0.75−0.25|=0.75."]',explanation='Әр координата өз train ауқымымен масштабталады. Арақашықтық бастапқы емес, масштабталған нүктелер арасында есептеледі.' where task_id='ai-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр координата өз train ауқымымен масштабталады. Арақашықтық бастапқы емес, масштабталған нүктелер арасында есептеледі.',mistakes='{}' where task_id='ai-c04';
update public.unt_tasks set revision=revision+1,title='Стандартталған модель',prompt='Train μ=[60,100], σ=[8,20]. x=[76,70] үшін екі z-score есептеп, s=2z1−z2+0.5 мәнін табыңыз.',given_data='μ60,100;σ8,20;x76,70',find_value='s',formulas='["zᵢ=(xᵢ−μᵢ)/σᵢ;s=2z1−z2+0.5"]',unit='мән',code='',answer_format='number' where id='ai-c05';
update unt_private.answer_keys set answer='6',steps='["z1=(76−60)/8=2.","z2=(70−100)/20=−1.5.","s=4−(−1.5)+0.5=6."]',explanation='Әр белгі үшін бөлек орташа мен стандартты ауытқу қолданылады. Теріс z2-ні азайту оның модулін қосады.' where task_id='ai-c05';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Әр белгі үшін бөлек орташа мен стандартты ауытқу қолданылады. Теріс z2-ні азайту оның модулін қосады.',mistakes='{}' where task_id='ai-c05';
update public.unt_tasks set revision=revision+1,title='Координатадан k-NN',prompt='Сұрау нүктесі (0,0). Үйрету нүктелері (1,1):A, (2,0):B, (0,3):B, (4,0):A, (3,3):A. Euclidean метрикасы, k=3, салмақсыз дауыс. Санатты табыңыз.',given_data='5 нүкте; еңжақын 3; теңқашықтықжоқ',find_value='Class',formulas='["d²=x²+y²;еңкішік→көпшілік"]',unit='санат',code='',answer_format='text' where id='ai-c06';
update unt_private.answer_keys set answer='B',steps='["Арақашықтықквадраттары 2,4,9,16,18.","ҮшжақыныA,B,B.","Bекідауыс: санатB."]',explanation='Алдымен координаталардан қашықтықтарды есептеңіз. Ең жақын үш көршіні таңдағаннан кейін ғана көпшілік дауысты алыңыз.' where task_id='ai-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен координаталардан қашықтықтарды есептеңіз. Ең жақын үш көршіні таңдағаннан кейін ғана көпшілік дауысты алыңыз.',mistakes='{}' where task_id='ai-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Квадраттау таңбаларды жояды және үлкен қатені күштірек жазалайды.',mistakes='{}' where task_id='ai-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Жоғары accuracy сирек оң санатты мүлде таппайтын модельде де болуы мүмкін.',mistakes='{}' where task_id='ai-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Модель таңдауда қателердің нақты құнын ескеру пайдалы.',mistakes='{}' where task_id='ai-c09';
update public.unt_tasks set revision=revision+1,title='Таза емес split',prompt='Түбірдегі 8 жазба: 4 A, 4 B. Сол балада 3 A,1 B; оң балада 1 A,3 B. log₂ арқылы information gain есептеп, алты ондық таңбаға дөңгелектеңіз.',given_data='Parent4/4;children3/1 және 1/3',find_value='IG',formulas='["H=−Σp log₂p;IG=Hparent−Σweight×Hchild"]',unit='бит',code='',answer_format='number' where id='ai-c10';
update unt_private.answer_keys set answer='0.188722',steps='["ТүбірH=1.","ӘрбаланыңH=−0.75log₂0.75−0.25log₂0.25≈0.8112781245.","Салмақтар 0.5,0.5;weightedHсол 0.8112781245.","IG≈0.1887218755→0.188722."]',explanation='Балалар таза емес, сондықтан олардың энтропиясы 0 емес. Екі баланың салмақталған энтропиясын түбірден азайтыңыз.' where task_id='ai-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Балалар таза емес, сондықтан олардың энтропиясы 0 емес. Екі баланың салмақталған энтропиясын түбірден азайтыңыз.',mistakes='{}' where task_id='ai-c10';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Салмақ белгісі кірістің әсер бағытын анықтайды.',mistakes='{}' where task_id='neural-networks-b01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: ReLU теріс бөлікте0,оң бөліктеөз мәнін қайтарады.',mistakes='{}' where task_id='neural-networks-b02';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Қабат аралық activation-ды өткізіп кетуге болмайды.',mistakes='{}' where task_id='neural-networks-c01';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Кіріс түйінінің өз bias-ы болмайды; әр келесі нейрондікі саналады.',mistakes='{}' where task_id='neural-networks-c02';
update public.unt_tasks set revision=revision+1,title='Convolution және dense параметр',prompt='RGB 8×8 кіріске 3×3 valid convolution, stride 1, төрт фильтр және bias қолданылады. Flatten шығысы bias бар үш нейронды dense қабатқа беріледі. Барлық параметр саны қанша?',given_data='Input8×8×3;conv3×3×4;dense3',find_value='Parameters',formulas='["Wout=8−3+1;Pconv=(3×3×3+1)4;Pdense=(Wout²×4+1)3"]',unit='параметр',code='',answer_format='number' where id='neural-networks-c03';
update unt_private.answer_keys set answer='547',steps='["Convбірфильтр 27 салмақ+1bias, төртеуі 112.","Шығыс 6×6×4=144 белгі.","Dense(144+1)×3=435.","112+435=547."]',explanation='Convolution салмақтары позициялар арасында ортақ. Бірақ шығыс картасының барлық элементі келесі dense қабатқа жеке кіріс болады.' where task_id='neural-networks-c03';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Convolution салмақтары позициялар арасында ортақ. Бірақ шығыс картасының барлық элементі келесі dense қабатқа жеке кіріс болады.',mistakes='{}' where task_id='neural-networks-c03';
update public.unt_tasks set revision=revision+1,title='Conv-pool-flatten',prompt='32×32 кіріс → 5×5 convolution, stride 2, padding 1, сегіз фильтр → 2×2 max-pool, stride 2, padding 0. Flatten өлшемін табыңыз.',given_data='N32;convK5,S2,P1,C8;poolK2,S2',find_value='Flatten units',formulas='["Nconv=floor((N+2P−K)/S)+1;Npool=floor((Nconv−2)/2)+1"]',unit='бірлік',code='',answer_format='number' where id='neural-networks-c04';
update unt_private.answer_keys set answer='392',steps='["Convөлшеміfloor((32+2−5)/2)+1=15.","Poolfloor((15−2)/2)+1=7.","Flatten7×7×8=392."]',explanation='Екі қабаттың әрқайсысында floor бөлек қолданылады. Pool кеңістіктік өлшемді азайтады, бірақ сегіз арнаны сақтайды.' where task_id='neural-networks-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Екі қабаттың әрқайсысында floor бөлек қолданылады. Pool кеңістіктік өлшемді азайтады, бірақ сегіз арнаны сақтайды.',mistakes='{}' where task_id='neural-networks-c04';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Бұл loss-та1/2 коэффициенті жоқ;градиентте2 қалады.',mistakes='{}' where task_id='neural-networks-c05';
update public.unt_tasks set revision=revision+1,title='Hidden қабаттан sigmoid',prompt='x=[2,1]; h1=ReLU(x1−2x2+1), h2=ReLU(−x1+3x2). z=2h1−h2−1, p=sigmoid(z). p≥0.5 болса class 1. p мен class мәндерін жазыңыз.',given_data='x2,1; екіReLU;outputbias−1',find_value='p class',formulas='["Forwardhidden→z→sigmoid→threshold"]',unit='тізбек',code='',answer_format='sequence' where id='neural-networks-c06';
update unt_private.answer_keys set answer='0.5 1',steps='["h1=ReLU1=1;h2=ReLU1=1.","z=2−1−1=0.","sigmoid0=0.5, теңдікclass1 береді."]',explanation='Алдымен жасырын қабат, кейін output z есептеледі. Sigmoid бастапқы x-ке емес, осы z-ке қолданылады; шек теңдігі де шартқа сай алынады.' where task_id='neural-networks-c06';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен жасырын қабат, кейін output z есептеледі. Sigmoid бастапқы x-ке емес, осы z-ке қолданылады; шек теңдігі де шартқа сай алынады.',mistakes='{}' where task_id='neural-networks-c06';
update public.unt_tasks set revision=revision+1,title='Әртүрлі softmax logits',prompt='Logit мәндері [ln 2, ln 3, 0]. Үш санаттың softmax ықтималдықтарын қысқартылған жай бөлшектермен, бос орынмен бөліп жазыңыз.',given_data='e^ln2=2;e^ln3=3;e⁰=1',find_value='p1 p2 p3',formulas='["pᵢ=e^zᵢ/Σe^z"]',unit='тізбек',code='',answer_format='sequence' where id='neural-networks-c07';
update unt_private.answer_keys set answer='1/3 1/2 1/6',steps='["Экспоненталар 2,3,1.","Нормалауқосындысы 6.","2/6=1/3;3/6=1/2;1/6."]',explanation='Logit-терді тікелей қоспаңыз. Әуелі олардың экспоненталарын алып, ортақ қосындысына бөліңіз.' where task_id='neural-networks-c07';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Logit-терді тікелей қоспаңыз. Әуелі олардың экспоненталарын алып, ортақ қосындысына бөліңіз.',mistakes='{}' where task_id='neural-networks-c07';
update public.unt_tasks set revision=revision+1,title='Batch cross-entropy',prompt='Үш үлгінің өз нақты санатына берілген ықтималдықтары 0.5, 0.25, 0.125. log₂ cross-entropy үшін орташа batch loss табыңыз.',given_data='ptrue=[1/2,1/4,1/8];meanreduction',find_value='Mean loss',formulas='["Lmean=−Σlog₂(ptrue)/3"]',unit='бит',code='',answer_format='number' where id='neural-networks-c08';
update unt_private.answer_keys set answer='2',steps='["Жекелосстар 1,2,3 бит.","Қосынды 6.","Mean6/3=2 бит."]',explanation='Алдымен әр үлгінің логарифмдік шығыны есептеледі. Орташа ықтималдықтың логарифмі орташа loss-пен бірдей емес.' where task_id='neural-networks-c08';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен әр үлгінің логарифмдік шығыны есептеледі. Орташа ықтималдықтың логарифмі орташа loss-пен бірдей емес.',mistakes='{}' where task_id='neural-networks-c08';
update public.unt_tasks set revision=revision+1,title='Mask-пен inverted dropout',prompt='Activation [2,4,6], mask [1,0,1], pdrop=0.25. Келесі қабат w=[1,2,−1], bias=2. Inverted dropout-тен кейінгі сызықтық шығысты алты ондық таңбаға дөңгелектеңіз.',given_data='a2,4,6;mask1,0,1;keep0.75;w1,2,−1;b2',find_value='y',formulas='["a′=a×mask/keep;y=w·a′+b"]',unit='мән',code='',answer_format='number' where id='neural-networks-c09';
update unt_private.answer_keys set answer='-3.333333',steps='["Dropout-тенкейін[2/0.75,0,6/0.75]=[8/3,0,8].","Weightedқосынды 8/3−8=−16/3.","Bias2 қосқанда−10/3≈−3.333333."]',explanation='Алдымен mask қолданылады, сақталған activation keep ықтималдығына бөлінеді. Bias dropout коэффициентімен масштабталмайды.' where task_id='neural-networks-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Алдымен mask қолданылады, сақталған activation keep ықтималдығына бөлінеді. Bias dropout коэффициентімен масштабталмайды.',mistakes='{}' where task_id='neural-networks-c09';
update unt_private.answer_keys set error_feedback='Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: Loss sum болса басқа градиентшығады;мұндаmeanнақтыберілген.',mistakes='{}' where task_id='neural-networks-c10';


-- SOURCE: 202610260006_vercel_management.sql
-- Vercel/Supabase management, access revocation and profile hardening.
-- PREPARED ONLY: do not execute on Production without a separate release authorization.

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

notify pgrst, 'reload schema';
commit;
