const {test,before,after}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');
const {PGlite}=require('@electric-sql/pglite');const {topics,tasks}=require('../scripts/curriculum.cjs');
const db=new PGlite();
const uid=i=>'10000000-0000-0000-0000-'+String(i).padStart(12,'0');
async function actor(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn();}finally{await db.exec('reset role');}}
const grade=async(id,answer)=>(await db.query('select public.unt_submit_answer($1,$2) as data',[id,answer])).rows[0].data;
before(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid,created_at timestamptz);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon,service_role;
 create table public.profiles(id uuid primary key references auth.users(id),role text,username text,full_name text,class_name text,created_at timestamptz default now());`);
 for(let i=1;i<=20;i++){await db.query('insert into auth.users values($1)',[uid(i)]);await db.query('insert into public.profiles(id,role,username,full_name,class_name) values($1,$2,$3,$3,$4)',[uid(i),i===20?'teacher':'student','qa'+i,'11']);}
 await db.exec(fs.readFileSync('supabase/migrations/202610180001_learning.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610180002_measurement_seed.sql','utf8'));
 await db.query("insert into public.unt_attempts(student_id,task_id,submitted_answer,correct) values($1,'measure-b01','0',false)",[uid(20)]);
 await db.exec(fs.readFileSync('supabase/migrations/202610180003_answer_formats.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610180004_full_curriculum.sql','utf8'));
 await db.query("insert into public.unt_attempts(student_id,task_id,submitted_answer,correct) values($1,'python-c02','1 8 3',true)",[uid(20)]);
 await db.exec(fs.readFileSync('supabase/migrations/202610180005_quality_review.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610260006_vercel_management.sql','utf8'));
});
after(async()=>await db.close());
test('incremental curriculum migration preserves old users/results and adds 228 private keys',async()=>{
 assert.equal((await db.query('select count(*)::int as n from public.profiles')).rows[0].n,20);
 assert.equal((await db.query('select count(*)::int as n from public.unt_attempts')).rows[0].n,2);
 assert.equal((await db.query('select count(*)::int as n from public.unt_tasks')).rows[0].n,228);
 assert.equal((await db.query('select count(*)::int as n from unt_private.answer_keys')).rows[0].n,228);
});
for(const topic of topics)test(`all 12 ${topic.id} answers grade correctly, return explanation and persist`,async()=>{
 const id=uid(topic.position+1),a=tasks.filter(t=>t.topic_id===topic.id);
 await actor(id,async()=>{for(const t of a){const r=await grade(t.id,t.answer);assert.equal(r.correct,true,t.id);assert.ok(r.steps.length>=2);assert.ok(r.explanation.length>0);}
 const ws=(await db.query('select public.unt_workspace() as data')).rows[0].data;
 assert.equal(ws.attempts.length,12);assert.equal(ws.summary.reduce((s,x)=>s+x.first_correct,0),12);
 assert.equal(ws.tasks.length,228);for(const t of ws.tasks){assert.equal(t.answer,undefined);assert.equal(t.steps,undefined);assert.equal(t.explanation,undefined);assert.equal(t.error_feedback,undefined);assert.equal(t.mistakes,undefined);}
 });
});
test('text and sequence normalization does not numerically erase leading bits',async()=>{
 await actor(uid(1),async()=>{
  assert.equal((await grade('encoding-c04','11101101')).correct,true);
  assert.equal((await grade('logic-c10','111010')).correct,false); // expected 00111010
  assert.equal((await grade('functions-b02',' 6; NONE ')).correct,true);
  assert.equal((await grade('ip-c02','10.24.39.255')).correct,true);
  assert.equal((await grade('ip-c02','10.24.39.254')).correct,false);
  await assert.rejects(()=>grade('measure-b01','1e3'));
  await assert.rejects(()=>db.query('select * from unt_private.answer_keys'),/permission denied/);
 });
});

test('wrong answer diagnostics are task-specific, while invalid answers reveal no solution',async()=>{
 await actor(uid(2),async()=>{
 const wrong=await grade('ip-c04','10.42.9.99');assert.equal(wrong.correct,false);assert.match(wrong.feedback,/broadcast/);assert.ok(wrong.steps.length>=4);
 const correct=await grade('ip-c04','10.42.9.98');assert.equal(correct.correct,true);assert.equal(correct.feedback,null);
 const generic=await grade('memory-c01','0');assert.equal(generic.correct,false);assert.match(generic.feedback,/L2|L1/);
 await assert.rejects(()=>grade('measure-b01','not-a-number'));await assert.rejects(()=>grade('ip-c04',''));
 });
});
test('every one of the 228 tasks returns helpful feedback for a wrong submitted answer',async()=>{
 // Test-only clock aging permits a full independent batch without weakening production rate limits.
 await db.exec("update public.unt_attempts set created_at=now()-interval '2 minutes'");
 for(const topic of topics)await actor(uid(topic.position+1),async()=>{
  for(const task of tasks.filter(t=>t.topic_id===topic.id)){
   const wrong=task.answer_format==='number'?'999999999999':'__wrong__';const r=await grade(task.id,wrong);
   assert.equal(r.correct,false,task.id);assert.ok(r.feedback.length>50,task.id);assert.ok(r.steps.length>=2);assert.ok(r.explanation.length>0);
  }
 });
});

test('quality revision snapshots old completed tasks without exposing private keys',async()=>{
 const old=(await db.query("select * from public.unt_attempts where student_id=$1 and task_id='python-c02' order by id limit 1",[uid(20)])).rows[0];
 assert.equal(old.submitted_answer,'1 8 3');assert.equal(old.correct,true);assert.equal(old.task_revision,1);assert.equal(old.task_snapshot.title,'Тізім alias');assert.equal(old.task_snapshot.answer,undefined);assert.equal(old.task_snapshot.steps,undefined);
 const task=(await db.query("select revision from public.unt_tasks where id='python-c02'")).rows[0];assert.equal(task.revision,2);
 await actor(uid(20),async()=>{await grade('python-c02','15 17 15');const w=(await db.query('select public.unt_workspace() as data')).rows[0].data;const summary=w.summary.find(x=>x.topic_id==='python');assert.equal(summary.attempted,2);assert.equal(summary.first_correct,2);});
});
