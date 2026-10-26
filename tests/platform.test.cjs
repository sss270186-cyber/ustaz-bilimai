const {test,before,after}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{execFileSync}=require('node:child_process');
const {openDatabase}=require('../platform/test-db.cjs'),{tasks}=require('../scripts/curriculum.cjs');
let worker,tmp;const origin='https://platform.test',ownerEmail='owner@platform.test';
before(async()=>{tmp=fs.mkdtempSync(path.join(os.tmpdir(),'bilimai-platform-'));execFileSync(process.execPath,['platform/build.cjs',tmp]);worker=await import('data:text/javascript;base64,'+fs.readFileSync(path.join(tmp,'worker/index.js')).toString('base64'));});
after(()=>fs.rmSync(tmp,{recursive:true,force:true}));
function client(db){const env={DB:db,BILIMAI_OWNER_EMAIL:ownerEmail};return async(p,{body,cookie,owner=false,origin:requestOrigin=origin,method=body?'POST':'GET'}={})=>{
 const r=await worker.default.fetch(new Request(origin+p,{method,headers:{...(cookie?{Cookie:cookie}:{}),...(body?{Origin:requestOrigin,'Content-Type':'application/json'}:{}),...(owner?{'oai-authenticated-user-id':'trusted-owner-id','oai-authenticated-user-email':ownerEmail}:{})},body:body?JSON.stringify(body):undefined}),env);
 return {status:r.status,data:await r.json().catch(()=>null),cookie:r.headers.get('set-cookie')?.split(';')[0],response:r};
};}
async function setup(filename){const db=openDatabase(filename);const call=client(db);const o=await call('/api/owner-login',{owner:true,body:{}});assert.equal(o.status,200);return {db,call,owner:o.cookie,ownerUser:o.data.user};}
async function add(call,owner,name='student01'){const password='Student-Test-2026';const r=await call('/api/students',{cookie:owner,body:{action:'create',username:name,full_name:'Synthetic '+name,class_name:'11',password,role:'teacher'}});assert.equal(r.status,201);
 const logged=await call('/api/login',{body:{email:name+'@students.ustaz-bilimai.example.com',password}});assert.equal(logged.status,200);return {cookie:logged.cookie,user:logged.data.user,password};}
test('platform denies anonymous access, forged owner authority, cross-origin mutations and client role promotion',async()=>{
 const {db,call,owner}=await setup();try{
  for(const p of ['/api/learning','/api/students','/api/task-edit?id=measure-b01'])assert.equal((await call(p)).status,401);
  assert.equal((await call('/api/owner-login',{body:{role:'teacher',email:ownerEmail}})).status,401);
  const a=await add(call,owner);assert.equal(a.user.role,'student');
  for(const p of ['/api/students','/api/task-edit'])assert.equal((await call(p,{cookie:a.cookie,body:{role:'teacher',task_id:'measure-b01'}})).status,403);
  assert.equal((await call('/api/results.csv',{cookie:a.cookie})).status,403);
  assert.equal((await call('/api/students',{cookie:owner,origin:'https://other.test',body:{action:'create'}})).status,403);
 }finally{db.close();}
});
test('platform server checks all 228 correct/wrong answers and exact decimal normalization',()=>{
 for(const t of tasks){assert.equal(worker.checkAnswer(t,String(t.answer)).correct,true,t.id);const r=worker.checkAnswer(t,t.answer_format==='number'?'999999999999':'wrong-answer');assert.equal(r.correct,false,t.id);assert.ok(r.steps.length);assert.ok(r.feedback);}
 assert.equal(worker.checkAnswer(tasks.find(t=>t.id==='measure-b01'),'001 792,000').correct,true);
});
test('platform saves server-owned results, excludes private keys and isolates two students',async()=>{
 const {db,call,owner}=await setup();try{
  const a=await add(call,owner),b=await add(call,owner,'student02');let ws=await call('/api/learning',{cookie:a.cookie});assert.equal(ws.data.tasks.length,228);assert.equal(ws.data.topics.length,19);
  for(const t of ws.data.tasks)for(const key of ['answer','steps','explanation','mistakes','error_feedback'])assert.equal(key in t,false);
  let r=await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'ip-c04',answer:'10.42.9.99',student_id:b.user.id,correct:true}});assert.equal(r.data.correct,false);assert.match(r.data.feedback,/broadcast/);
  r=await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1792'}});assert.equal(r.data.correct,true);
  ws=await call('/api/learning',{cookie:a.cookie});assert.equal(ws.data.attempts.length,2);assert.ok(ws.data.attempts.every(x=>x.student_id===a.user.id));assert.equal((await call('/api/learning',{cookie:b.cookie})).data.attempts.length,0);
  assert.equal((await call('/api/learning',{cookie:owner})).data.attempts.length,2);
  const invalid=await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1 MB'}});assert.equal(invalid.status,400);assert.equal('steps' in invalid.data,false);
 }finally{db.close();}
});
test('task editor versions updates without changing old results, and visibility is enforced server-side',async()=>{
 const {db,call,owner}=await setup();try{
  const a=await add(call,owner);await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1792'}});
  const old=(await call('/api/task-edit?id=measure-b01',{cookie:owner})).data.task;
  assert.equal((await call('/api/task-edit?id=measure-b01',{cookie:a.cookie})).status,403);
  const edit={...old,task_id:old.id,title:'Жаңа өлшем есебі',prompt:'1800 байттың көлемін байтпен жазыңыз.',given_data:'V = 1800 байт',find_value:'V, байт',formulas:['V = 1800 байт'],answer:'1800',steps:['Берілген көлем 1800 байт.','Бірлік байт, сондықтан жауап 1800.'],explanation:'Бұл тест нұсқаларды сақтауды тексереді.'};
  assert.equal((await call('/api/task-edit',{cookie:owner,body:edit})).status,200);
  assert.equal((await call('/api/task-edit',{cookie:owner,body:edit})).status,409);
  assert.equal((await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1800'}})).data.correct,true);
  const snapshots=db.sqlite.prepare('SELECT task_revision,task_snapshot,correct FROM attempts ORDER BY created_at').all();assert.equal(snapshots[0].correct,1);assert.equal(JSON.parse(snapshots[0].task_snapshot).title,old.title);assert.equal(snapshots[1].task_revision,old.revision+1);assert.equal('answer' in JSON.parse(snapshots[1].task_snapshot),false);
  await call('/api/learning',{cookie:owner,body:{action:'set_active',task_id:'measure-b01',active:false}});
  assert.equal((await call('/api/learning',{cookie:a.cookie})).data.tasks.some(t=>t.id==='measure-b01'),false);
  assert.equal((await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1800'}})).status,400);
 }finally{db.close();}
});
test('student password change and teacher reset revoke previous sessions without deleting accounts/results',async()=>{
 const {db,call,owner}=await setup();try{
  const a=await add(call,owner);const bad=await call('/api/password',{cookie:a.cookie,body:{current:'incorrect',password:'Changed-Test-2026'}});assert.equal(bad.status,400);
  const changed=await call('/api/password',{cookie:a.cookie,body:{current:a.password,password:'Changed-Test-2026'}});assert.equal(changed.status,200);assert.equal((await call('/api/account',{cookie:a.cookie})).status,401);assert.equal((await call('/api/account',{cookie:changed.cookie})).status,200);
  const reset=await call('/api/students',{cookie:owner,body:{action:'reset_password',student_id:a.user.id,password:'Reset-Student-2026'}});assert.equal(reset.status,200);assert.equal((await call('/api/account',{cookie:changed.cookie})).status,401);
  assert.equal((await call('/api/login',{body:{email:'student01',password:'Reset-Student-2026'}})).status,200);
  const row=db.sqlite.prepare('SELECT password_hash,password_salt FROM users WHERE id=?').get(a.user.id);assert.equal(row.password_hash.length,64);assert.ok(row.password_salt);assert.notEqual(row.password_hash,'Reset-Student-2026');
 }finally{db.close();}
});
test('accounts and results survive database close/reopen; login throttling is persistent',async()=>{
 const filename=path.join(tmp,'durable.sqlite');let {db,call,owner}=await setup(filename);const a=await add(call,owner);
 await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1792'}});db.close();db=openDatabase(filename,false);call=client(db);
 try{const ws=await call('/api/learning',{cookie:a.cookie});assert.equal(ws.data.attempts.length,1);assert.equal(ws.data.attempts[0].correct,true);
  for(let i=0;i<8;i++)await call('/api/login',{body:{email:'missinguser',password:'wrong'}});
  assert.equal((await call('/api/login',{body:{email:'missinguser',password:'wrong'}})).status,429);
 }finally{db.close();}
});
test('concurrent grading cannot exceed the server limit and expired sessions cannot read results',async()=>{
 const {db,call,owner}=await setup();try{
  const a=await add(call,owner);const results=await Promise.all(Array.from({length:21},()=>call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'measure-b01',answer:'1792'}})));
  assert.equal(results.filter(r=>r.status===200).length,20);assert.equal(results.filter(r=>r.status===429).length,1);
  assert.equal(db.sqlite.prepare('SELECT count(*) AS n FROM attempts WHERE student_id=?').get(a.user.id).n,20);
  db.sqlite.prepare('UPDATE sessions SET expires_at=0 WHERE user_id=?').run(a.user.id);
  assert.equal((await call('/api/learning',{cookie:a.cookie})).status,401);
 }finally{db.close();}
});
test('CSV neutralizes formula cells, cookies are protected, and public assets exclude private source',async()=>{
 const {db,call,owner}=await setup();try{
  const a=await add(call,owner);db.sqlite.prepare('UPDATE users SET full_name=? WHERE id=?').run('=SUM(1,1)',a.user.id);
  await call('/api/learning',{cookie:a.cookie,body:{action:'grade',task_id:'ip-c04',answer:'=HYPERLINK(test)'}});
  const exported=await worker.default.fetch(new Request(origin+'/api/results.csv',{headers:{cookie:owner}}),{DB:db});assert.equal(exported.status,200);const csv=await exported.text();assert.ok(csv.includes('"\'=SUM(1,1)"'));assert.match(csv,/"'=hyperlink\(test\)"/i);
  const logged=await call('/api/login',{body:{email:'student01',password:a.password}});const cookie=logged.response.headers.get('set-cookie');assert.match(cookie,/HttpOnly/);assert.match(cookie,/Secure/);assert.match(cookie,/SameSite=Lax/);
  for(const p of ['/platform/worker.mjs','/db/schema.ts','/drizzle/0000_eager_victor_mancha.sql','/.env','/api/preview/catalog'])assert.equal((await worker.default.fetch(new Request(origin+p),{DB:db})).status,p.startsWith('/api/')?401:404);
 }finally{db.close();}
});
test('hosted geographic secret binding authorizes only the configured teacher identity',async()=>{
 const db=openDatabase();let reads=0;const env={DB:db,SECRET_BILIMAI_OWNER_EMAIL:{async get(){reads++;return ownerEmail;}}};
 const login=email=>worker.default.fetch(new Request(origin+'/api/owner-login',{method:'POST',headers:{origin,'Content-Type':'application/json','oai-authenticated-user-id':'secret-owner','oai-authenticated-user-email':email},body:'{}'}),env);
 try{assert.equal((await login('other@platform.test')).status,403);assert.equal((await login(ownerEmail)).status,200);assert.equal(reads,2);assert.equal(db.sqlite.prepare('SELECT count(*) AS n FROM users').get().n,1);}finally{db.close();}
});
