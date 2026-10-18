const {test,before,after}=require('node:test');const assert=require('node:assert/strict');
const {PGlite}=require('@electric-sql/pglite');const fs=require('node:fs');
const db=new PGlite();
const T='00000000-0000-0000-0000-000000000001',T2='00000000-0000-0000-0000-000000000002';
const S='00000000-0000-0000-0000-000000000003',S2='00000000-0000-0000-0000-000000000004',S3='00000000-0000-0000-0000-000000000005';
async function actor(id,fn,role='authenticated'){
 await db.exec(`set role ${role};`);await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id||'']);
 try{return await fn();}finally{await db.exec('reset role');}
}
async function grade(id,answer){return (await db.query('select public.unt_submit_answer($1,$2) as data',[id,answer])).rows[0].data;}
async function workspace(){return (await db.query('select public.unt_workspace() as data')).rows[0].data;}
before(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon,service_role;
 create table public.profiles(id uuid primary key references auth.users(id),role text,username text,full_name text,class_name text,created_at timestamptz default now());
 create table public.legacy_lesson(id int primary key, content text);insert into public.legacy_lesson values(1,'ҚМЖ сақталуы керек');`);
 for(const [id,role,username] of [[T,'teacher','teacher1'],[T2,'teacher','teacher2'],[S,'student','student1'],[S2,'student','student2'],[S3,'student','student3']]){
  await db.query('insert into auth.users values($1)',[id]);await db.query('insert into public.profiles(id,role,username,full_name,class_name) values($1,$2,$3,$3,$4)',[id,role,username,'11']);
 }
 await db.exec(fs.readFileSync('supabase/migrations/202610180001_learning.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610180002_measurement_seed.sql','utf8'));
 await db.query('insert into public.unt_enrollments values($1,$2),($3,$4)',[T,S,T2,S2]);
});
after(async()=>await db.close());
test('additive migrations preserve all original profiles and lesson data',async()=>{
 assert.equal((await db.query('select count(*)::int as n from public.profiles')).rows[0].n,5);
 assert.equal((await db.query('select content from public.legacy_lesson')).rows[0].content,'ҚМЖ сақталуы керек');
 assert.equal((await db.query('select count(*)::int as n from public.unt_topics')).rows[0].n,19);
});
test('anonymous users cannot read questions or call grading functions',async()=>{
 await actor(null,async()=>{
  await assert.rejects(()=>db.query('select * from public.unt_tasks'),/permission denied/);
  await assert.rejects(()=>grade('measure-b01','1792'),/permission denied/);
 },'anon');
 await actor(null,async()=>await assert.rejects(()=>workspace(),/insufficient_privilege|insufficient privilege/i));
});
test('students cannot read private keys or forge attempts and teacher status',async()=>{
 await actor(S,async()=>{
  await assert.rejects(()=>db.query('select * from unt_private.answer_keys'),/permission denied/);
  await assert.rejects(()=>db.query('insert into public.unt_attempts(student_id,task_id,submitted_answer,correct) values($1,$2,$3,true)',[S,'measure-b01','bad']),/permission denied/);
  await assert.rejects(()=>db.query('insert into public.unt_teachers(user_id) values($1)',[S]),/permission denied/);
  await assert.rejects(()=>db.query('select public.unt_set_task_active($1,false)',['measure-b01']),/insufficient_privilege|insufficient privilege/i);
  const data=await workspace();assert.equal(data.role,'student');assert.equal(data.tasks.length,12);
  for(const task of data.tasks){assert.equal(task.answer,undefined);assert.equal(task.steps,undefined);}
 });
});
test('server checks and persists a wrong answer and accepts numeric formatting',async()=>{
 await actor(S,async()=>{
  const wrong=await grade('measure-b01','1');assert.equal(wrong.correct,false);assert.equal(wrong.answer,'1792');assert.ok(wrong.steps.length);
  const right=await grade('measure-b01','1 792,00');assert.equal(right.correct,true);
  const ws=await workspace();assert.equal(ws.attempts.length,2);assert.equal(ws.summary[0].attempted,1);assert.equal(ws.summary[0].first_correct,0);assert.equal(ws.summary[0].first_wrong,1);
 });
});
test('invalid input cannot create attempts; exact decimal answers work',async()=>{
 await actor(S,async()=>{
  for(const answer of ['', '1e3','NaN','Infinity','1792 КиБ','1,2,3','9'.repeat(65)])await assert.rejects(()=>grade('measure-b01',answer));
  assert.equal((await workspace()).attempts.length,2);
  assert.equal((await grade('measure-c01','4352,500')).correct,true);
  assert.equal((await grade('measure-c08','20.599365234375')).correct,true);
 });
});
test('students and teachers only see their authorized result rows',async()=>{
 await actor(S2,async()=>{assert.equal((await workspace()).attempts.length,0);await grade('measure-b02','3084');});
 await actor(S,async()=>assert.equal((await db.query('select * from public.unt_attempts')).rows.some(a=>a.student_id===S2),false));
 await actor(T,async()=>{const ws=await workspace();assert.equal(ws.roster.length,1);assert.equal(ws.roster[0].id,S);assert.ok(ws.attempts.every(a=>a.student_id===S));assert.equal((await db.query('select * from public.unt_attempts')).rows.some(a=>a.student_id===S2),false);});
 await actor(T2,async()=>{const ws=await workspace();assert.ok(ws.attempts.every(a=>a.student_id===S2));});
});
test('teacher can hide a task; history stays readable and grading is blocked',async()=>{
 await actor(T,async()=>await db.query('select public.unt_set_task_active($1,false)',['measure-b01']));
 await actor(S,async()=>{const ws=await workspace();assert.equal(ws.tasks.length,11);assert.ok(ws.attempts.length);await assert.rejects(()=>grade('measure-b01','1792'),/қолжетімсіз/);});
 await actor(T,async()=>await db.query('select public.unt_set_task_active($1,true)',['measure-b01']));
});
test('changes to old profile roles cannot promote a new learning teacher',async()=>{
 await db.query("update public.profiles set role='teacher' where id=$1",[S3]);
 await actor(S3,async()=>assert.equal((await db.query('select public.unt_is_teacher() as teacher')).rows[0].teacher,false));
 await db.query("update public.profiles set role='student' where id=$1",[S3]);
});
test('per-user rate limit caps writes at 20 per minute',async()=>{
 await actor(S3,async()=>{for(let i=0;i<20;i++)await grade('measure-b02','3084');await assert.rejects(()=>grade('measure-b02','3084'),/шектелді/);assert.equal((await workspace()).attempts.length,20);});
});
