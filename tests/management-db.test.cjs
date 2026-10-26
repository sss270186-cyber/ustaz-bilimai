const {test,before,after}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{PGlite}=require('@electric-sql/pglite');
let db;const uid=n=>`10000000-0000-4000-8000-${String(n).padStart(12,'0')}`,sid=n=>`20000000-0000-4000-8000-${String(n).padStart(12,'0')}`;
before(async()=>{
 db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users,created_at timestamptz default now());create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;create table public.profiles(id uuid primary key references auth.users,username text unique,full_name text,role text,class_name text,created_at timestamptz default now());`);
 for(let n=1;n<=5;n++){await db.query('insert into auth.users values($1)',[uid(n)]);await db.query("insert into auth.sessions values($1,$2,now()-interval '1 hour')",[sid(n),uid(n)]);await db.query('insert into public.profiles(id,username,full_name,role,class_name) values($1,$2,$3,$4,$5)',[uid(n),'user'+n,'Synthetic '+n,n<=2?'teacher':'student','11']);}
 for(const file of fs.readdirSync('supabase/migrations').filter(f=>f.endsWith('.sql')&&!f.includes('006')).sort())await db.exec(fs.readFileSync('supabase/migrations/'+file,'utf8'));
 await db.query('insert into public.unt_enrollments values($1,$2),($3,$4)',[uid(1),uid(3),uid(2),uid(5)]);
 await db.exec('grant update(role) on public.profiles to authenticated;create policy old_permissive on public.profiles for all to authenticated using(true) with check(true);');
 await db.exec(fs.readFileSync('supabase/migrations/202610260006_vercel_management.sql','utf8'));
});
after(()=>db?.close());
async function asUser(n,fn,session=sid(n)){await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false),set_config('request.jwt.claims',$2,false)",[uid(n),JSON.stringify({sub:uid(n),session_id:session,iat:9999999999})]);try{return await fn();}finally{await db.exec('reset role');}}
const rpc=async(name,args=[])=>{const placeholders=args.map((_,i)=>'$'+(i+1)).join(',');return (await db.query('select public.'+name+'('+placeholders+') as data',args)).rows[0].data;};
test('Vercel migration preserves all original accounts, task counts and existing profile policies',async()=>{
 assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,5);assert.equal((await db.query('select count(*)::int n from profiles')).rows[0].n,5);assert.equal((await db.query('select count(*)::int n from unt_tasks')).rows[0].n,228);
 assert.equal((await db.query("select count(*)::int n from pg_policies where policyname='old_permissive'")).rows[0].n,1);
 assert.equal((await db.query("select has_column_privilege('authenticated','public.profiles','role','UPDATE') allowed")).rows[0].allowed,false);
});
test('even old permissive policies cannot expose other profiles or permit teacher self-promotion',async()=>{
 await asUser(3,async()=>{assert.equal((await db.query('select id from public.profiles')).rows.length,1);await assert.rejects(()=>db.query("update public.profiles set role='teacher'"),/(permission denied|insufficient_privilege)/);await assert.rejects(()=>rpc('unt_teacher_students'),/(permission denied|insufficient_privilege)/);await assert.rejects(()=>rpc('unt_task_for_edit',['measure-b01']),/(permission denied|insufficient_privilege)/);});
});
test('teacher roster and password targets are restricted to enrolled students, including direct RPC',async()=>{
 await asUser(1,async()=>{const rows=await rpc('unt_teacher_students');assert.deepEqual(rows.map(x=>x.id),[uid(3)]);assert.equal(await rpc('unt_student_target',['user3']),uid(3));await assert.rejects(()=>rpc('unt_student_target',['user5']),/(permission denied|insufficient_privilege)/);await assert.rejects(()=>rpc('unt_revoke_access',[uid(5)]),/(permission denied|insufficient_privilege)/);await assert.rejects(()=>rpc('unt_enroll_student',['user5']),/(permission denied|insufficient_privilege)/);await rpc('unt_enroll_student',['user4']);});
});
test('task edits are atomic, preserve the previous key/snapshot and cannot change topic or level',async()=>{
 await asUser(3,()=>rpc('unt_submit_answer',['measure-b01','1792']));
 await asUser(1,async()=>{const t=await rpc('unt_task_for_edit',['measure-b01']);const edited={...t,title:'Байтқа түрлендіру — жаңа нұсқа',topic_id:'sql',level:'C'};
  const result=await rpc('unt_edit_task',[t.id,t.revision,edited]);assert.equal(result.revision,t.revision+1);
  await assert.rejects(()=>rpc('unt_edit_task',[t.id,t.revision,edited]),/қайта ашыңыз/);
  const current=await rpc('unt_task_for_edit',[t.id]);assert.equal(current.topic_id,'measurement');assert.equal(current.level,'B');
 });
 assert.equal((await db.query("select count(*)::int n from unt_private.task_versions where task_id='measure-b01'")).rows[0].n,2);
 const old=(await db.query('select task_snapshot,correct from public.unt_attempts where student_id=$1 order by id limit 1',[uid(3)])).rows[0];assert.equal(old.correct,true);assert.equal('answer' in old.task_snapshot,false);assert.notEqual(old.task_snapshot.title,'Байтқа түрлендіру — жаңа нұсқа');
});
test('invalid edits and student callers cannot write keys, attempt rows or task history',async()=>{
 await asUser(1,async()=>{const t=await rpc('unt_task_for_edit',['ip-c04']);await assert.rejects(()=>rpc('unt_edit_task',[t.id,t.revision,{...t,steps:['Too short']}]),/қадамдары жеткіліксіз/);});
 await asUser(3,async()=>{for(const table of ['unt_private.answer_keys','unt_private.task_versions','unt_private.session_cutoffs'])await assert.rejects(()=>db.query('select * from '+table),/(permission denied|insufficient_privilege)/);await assert.rejects(()=>db.query("insert into unt_attempts(student_id,task_id,submitted_answer,correct) values($1,'measure-b01','fake',true)",[uid(3)]),/(permission denied|insufficient_privilege)/);});
});
test('CSV source data contains only teacher-owned results and no private solution fields',async()=>{
 await asUser(5,()=>rpc('unt_submit_answer',['measure-b02','3084']));
 await asUser(1,async()=>{const rows=await rpc('unt_results_export');assert.equal(rows.length,1);assert.equal(rows[0].username,'user3');assert.equal('answer' in rows[0],false);assert.equal('steps' in rows[0],false);});
});
test('password reset blocks old/refreshed sessions in RPC and direct REST policies; new login survives',async()=>{
 await asUser(1,()=>rpc('unt_revoke_access',[uid(3)]));
 await asUser(3,async()=>{assert.equal(await rpc('unt_session_valid'),false);await assert.rejects(()=>rpc('unt_workspace'),/(permission denied|insufficient_privilege)/);assert.equal((await db.query('select * from unt_attempts')).rows.length,0);assert.equal((await db.query('select * from profiles')).rows.length,0);});
 await db.query("insert into auth.sessions(id,user_id,created_at) values($1,$2,clock_timestamp()+interval '1 millisecond')",[sid(30),uid(3)]);
 await asUser(3,async()=>{assert.equal(await rpc('unt_session_valid'),true);const w=await rpc('unt_workspace');assert.equal(w.attempts.length,1);},sid(30));
 assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,5);
});
