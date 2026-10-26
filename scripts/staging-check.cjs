// Real staging acceptance. Creates synthetic students and attempts; never targets Production.
const {randomBytes}=require('node:crypto');
const PROD_HOST='kbnwfuvfnspanoomusmu.supabase.co';
function config(env) {
 const required=['STAGING_SUPABASE_URL','STAGING_SUPABASE_PUBLISHABLE_KEY','STAGING_PREVIEW_URL','STAGING_TEACHER_EMAIL','STAGING_TEACHER_PASSWORD'];
 for(const key of required)if(!env[key])throw Error(`Missing protected environment variable: ${key}`);
 const db=new URL(env.STAGING_SUPABASE_URL),site=new URL(env.STAGING_PREVIEW_URL);
 const prod=env.SUPABASE_URL?new URL(env.SUPABASE_URL).hostname:PROD_HOST;
 if(db.protocol!=='https:'||!db.hostname.endsWith('.supabase.co')||[PROD_HOST,prod].includes(db.hostname))throw Error('Staging must use a separate hosted Supabase project');
 if(site.protocol!=='https:'||!site.hostname.endsWith('.vercel.app')||site.hostname==='ustaz-bilimai.vercel.app')throw Error('Use a Vercel Preview URL, never the Production URL');
 if(db.username||db.password||site.username||site.password||db.search||site.search||db.hash||site.hash||db.pathname!=='/'||site.pathname!=='/')throw Error('Use clean project and Preview origins without credentials, paths or query strings');
 return {db:db.origin,site:site.origin,key:env.STAGING_SUPABASE_PUBLISHABLE_KEY,email:env.STAGING_TEACHER_EMAIL,password:env.STAGING_TEACHER_PASSWORD};
}
async function runStaging(env=process.env,fetchImpl=fetch,report=console.log) {
 const c=config(env),sessions=[];let teacher;
 const assert=(condition,label)=>{if(!condition)throw Error(label);};
 const call=async(base,path,{token,body,headers={},method='GET'}={})=>{
  const response=await fetchImpl(base+path,{method,headers:{...(base===c.db?{apikey:c.key}:{}),...(token?{Authorization:`Bearer ${token}`}:(base===c.db?{Authorization:`Bearer ${c.key}`}:{})),'Content-Type':'application/json',...headers},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000),redirect:'error'});
  const data=await response.json().catch(()=>null);return {ok:response.ok,status:response.status,data,headers:response.headers};
 };
 const site=(path,options)=>call(c.site,path,options);
 const rpc=(session,name,body={})=>call(c.db,'/rest/v1/rpc/'+name,{method:'POST',token:session.access_token,body});
 const workspace=async session=>{const r=await site('/api/learning',{token:session.access_token});assert(r.ok,'Workspace request failed');return r.data;};
 const login=async(email,password)=>{
  const r=await call(c.db,'/auth/v1/token?grant_type=password',{method:'POST',body:{email,password}});
  assert(r.ok&&r.data?.access_token&&r.data?.user?.id,'Staging Auth login failed');sessions.push(r.data);return r.data;
 };
 // Validate the deployed project's database BEFORE authenticating or creating accounts.
 const deployed=await site('/api/config');assert(deployed.ok&&deployed.data?.url,'Preview configuration is unavailable');
 assert(new URL(deployed.data.url).origin===c.db,'Preview is not connected to the staging database; no mutations were made');
 assert(typeof deployed.data.publishableKey==='string'&&deployed.data.publishableKey.length>0,'Preview public configuration is incomplete');
 report('PASS: Preview is connected to a separate staging project');
 for(const path of ['/scripts/measurement.cjs','/supabase/migrations/202610180002_measurement_seed.sql','/api/_lib/supabase.cjs','/app.py','/tests/database.test.cjs','/.env']){
  const r=await site(path);assert([403,404].includes(r.status),'Private source exclusion failed');
 }
 const publicWorkspace=await site('/api/learning');assert(publicWorkspace.status===401,'Anonymous workspace must be denied');
 report('PASS: private source paths and anonymous API access are blocked');
 try {
  teacher=await login(c.email,c.password);const initial=await workspace(teacher);assert(initial.role==='teacher','Staging account is not a registered learning teacher');
  assert(initial.topics.length===19,'Expected 19 topics');assert(initial.tasks.length===228&&initial.tasks.every(t=>t.active),'Expected 228 active staging tasks');
  const prefix='qa_'+randomBytes(6).toString('hex'),students=[];
  for(const suffix of ['a','b']){
   const username=prefix+suffix,password=randomBytes(24).toString('base64url');
   const created=await site('/api/students',{method:'POST',token:teacher.access_token,body:{action:'create',username,password,full_name:'Staging acceptance '+suffix,class_name:'11'}});
   assert(created.status===201&&created.data?.enrolled===true,'Staging account creation/enrollment failed; check the roster before retrying');
   const session=await login(username+'@students.ustaz-bilimai.example.com',password);students.push({session,username,password});
  }
  report('PASS: teacher registration and real student Auth login');
  const [a,b]=students;let ws=await workspace(a.session);assert(ws.role==='student','Expected student role');
  assert(ws.tasks.filter(t=>t.topic_id==='measurement'&&t.level==='B').length===2&&ws.tasks.filter(t=>t.topic_id==='measurement'&&t.level==='C').length===10,'Task level counts differ');
  assert(ws.tasks.every(t=>!('answer'in t)&&!('steps'in t)),'Workspace leaked answer keys');
  const grade=async(session,answer,task='measure-b01')=>site('/api/learning',{method:'POST',token:session.access_token,body:{action:'grade',task_id:task,answer}});
  let result=await grade(a.session,'0');assert(result.ok&&result.data.correct===false&&result.data.steps.length>0,'Wrong-answer grading failed');
  result=await grade(a.session,'1 792,00');assert(result.ok&&result.data.correct===true,'Correct-answer grading failed');
  result=await grade(b.session,'3084','measure-b02');assert(result.ok&&result.data.correct===true,'Second student grading failed');
  const refreshed=await login(a.username+'@students.ustaz-bilimai.example.com',a.password);ws=await workspace(refreshed);
  assert(ws.attempts.length===2&&ws.attempts.every(x=>x.student_id===refreshed.user.id),'Attempts were not persisted or another student is visible');
  assert(ws.summary[0]?.attempted===1&&ws.summary[0].first_wrong===1&&ws.summary[0].first_correct===0,'First-attempt statistics are incorrect');
  const rows=await call(c.db,'/rest/v1/unt_attempts?select=student_id',{token:refreshed.access_token});
  assert(rows.ok&&rows.data.length===2&&rows.data.every(x=>x.student_id===refreshed.user.id),'Direct REST result isolation failed');
  report('PASS: correct/wrong grading, persisted history and cross-student isolation');
  const forbidden=[
   await call(c.db,'/rest/v1/answer_keys?select=*',{token:refreshed.access_token,headers:{'Accept-Profile':'unt_private'}}),
   await call(c.db,'/rest/v1/unt_attempts',{method:'POST',token:refreshed.access_token,body:{student_id:refreshed.user.id,task_id:'measure-b01',submitted_answer:'fake',correct:true}}),
   await call(c.db,'/rest/v1/unt_teachers',{method:'POST',token:refreshed.access_token,body:{user_id:refreshed.user.id}}),
   await rpc(refreshed,'unt_set_task_active',{p_task_id:'measure-b01',p_active:false})
  ];
  assert(forbidden.every(r=>[401,403,404,406].includes(r.status)),'RLS or teacher-role boundary failed');
  const tw=await workspace(teacher);assert(students.every(s=>tw.roster.some(p=>p.id===s.session.user.id)),'Teacher roster is incomplete');
  assert(students.every(s=>tw.attempts.some(p=>p.student_id===s.session.user.id)),'Teacher cannot read enrolled results');
  report('PASS: answer-key protection, write denial, teacher authority and enrolled results');
  try {
   const hidden=await site('/api/learning',{method:'POST',token:teacher.access_token,body:{action:'set_active',task_id:'measure-b01',active:false}});
   assert(hidden.ok,'Teacher could not hide a task');
   assert(!(await workspace(refreshed)).tasks.some(t=>t.id==='measure-b01'),'Hidden task is visible to a student');
   assert((await grade(refreshed,'1792')).status===400,'Hidden task grading must be rejected');
  } finally {
   const restored=await site('/api/learning',{method:'POST',token:teacher.access_token,body:{action:'set_active',task_id:'measure-b01',active:true}});
   assert(restored.ok,'Task visibility restore failed; restore measure-b01 in staging before retrying');
  }
  report('PASS: teacher visibility controls restore the task and preserve history');
  report('Staging acceptance passed. Synthetic QA accounts/attempts are retained; no production data was changed.');
 } finally {
  for(const session of sessions){try{const r=await call(c.db,'/auth/v1/logout?scope=local',{method:'POST',token:session.access_token});if(!r.ok)report('NOTICE: a synthetic test session could not be revoked');}catch{report('NOTICE: a synthetic test session could not be revoked');}}
 }
}
module.exports={config,runStaging};
if(require.main===module)runStaging().catch(()=>{console.error('Staging acceptance stopped. Check protected configuration, Preview access and the last PASS step. Secrets and upstream payloads are not printed.');process.exitCode=1;});
