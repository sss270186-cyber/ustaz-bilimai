const {test,before,after}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');
const {PGlite}=require('@electric-sql/pglite');const {topics,tasks}=require('../scripts/curriculum.cjs');
const db=new PGlite();
const uid=i=>'10000000-0000-0000-0000-'+String(i).padStart(12,'0');
async function actor(id,fn){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);try{return await fn();}finally{await db.exec('reset role');}}
const grade=async(id,answer)=>(await db.query('select public.unt_submit_answer($1,$2) as data',[id,answer])).rows[0].data;
before(async()=>{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon,service_role;
 create table public.profiles(id uuid primary key references auth.users(id),role text,username text,full_name text,class_name text,created_at timestamptz default now());`);
 for(let i=1;i<=20;i++){await db.query('insert into auth.users values($1)',[uid(i)]);await db.query('insert into public.profiles(id,role,username,full_name,class_name) values($1,$2,$3,$3,$4)',[uid(i),i===20?'teacher':'student','qa'+i,'11']);}
 await db.exec(fs.readFileSync('supabase/migrations/202610180001_learning.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610180002_measurement_seed.sql','utf8'));
 await db.query("insert into public.unt_attempts(student_id,task_id,submitted_answer,correct) values($1,'measure-b01','0',false)",[uid(20)]);
 await db.exec(fs.readFileSync('supabase/migrations/202610180003_answer_formats.sql','utf8'));
 await db.exec(fs.readFileSync('supabase/migrations/202610180004_full_curriculum.sql','utf8'));
});
after(async()=>await db.close());
test('incremental curriculum migration preserves old users/results and adds 228 private keys',async()=>{
 assert.equal((await db.query('select count(*)::int as n from public.profiles')).rows[0].n,20);
 assert.equal((await db.query('select count(*)::int as n from public.unt_attempts')).rows[0].n,1);
 assert.equal((await db.query('select count(*)::int as n from public.unt_tasks')).rows[0].n,228);
 assert.equal((await db.query('select count(*)::int as n from unt_private.answer_keys')).rows[0].n,228);
});
for(const topic of topics)test(`all 12 ${topic.id} answers grade correctly, return explanation and persist`,async()=>{
 const id=uid(topic.position+1),a=tasks.filter(t=>t.topic_id===topic.id);
 await actor(id,async()=>{for(const t of a){const r=await grade(t.id,t.answer);assert.equal(r.correct,true,t.id);assert.ok(r.steps.length>=2);assert.ok(r.explanation.length>0);}
 const ws=(await db.query('select public.unt_workspace() as data')).rows[0].data;
 assert.equal(ws.attempts.length,12);assert.equal(ws.summary.reduce((s,x)=>s+x.first_correct,0),12);
 assert.equal(ws.tasks.length,228);for(const t of ws.tasks){assert.equal(t.answer,undefined);assert.equal(t.steps,undefined);assert.equal(t.explanation,undefined);}
 });
});
test('text and sequence normalization does not numerically erase leading bits',async()=>{
 await actor(uid(1),async()=>{
  assert.equal((await grade('encoding-c03','11011011')).correct,true);
  assert.equal((await grade('logic-c10','111010')).correct,false); // expected 00111010
  assert.equal((await grade('functions-b02',' 6; NONE ')).correct,true);
  assert.equal((await grade('ip-c02','10.24.39.255')).correct,true);
  assert.equal((await grade('ip-c02','10.24.39.254')).correct,false);
  await assert.rejects(()=>grade('measure-b01','1e3'));
  await assert.rejects(()=>db.query('select * from unt_private.answer_keys'),/permission denied/);
 });
});
