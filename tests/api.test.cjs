const {test,afterEach,after}=require('node:test');const assert=require('node:assert/strict');
const learning=require('../api/learning.js'),students=require('../api/students.js'),config=require('../api/config.js'),tasksApi=require('../api/tasks.js'),passwordApi=require('../api/password.js'),resultsApi=require('../api/results.js');
const saved=Object.fromEntries(['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_SERVICE_ROLE_KEY','VERCEL_ENV','BILIMAI_STAGING_SUPABASE_URL'].map(k=>[k,process.env[k]]));
const originalFetch=global.fetch;
const response=(data,status=200)=>({ok:status>=200&&status<300,status,json:async()=>data});
function run(handler,{method='GET',token='fake-user-token',body,query}={}){
 const req={method,headers:token?{authorization:`Bearer ${token}`}:{},body,query};
 const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.code=s;return this;},json(data){this.data=data;return this;},send(data){this.data=data;return this;}};
 return Promise.resolve(handler(req,res)).then(()=>res);
}
function setup(responses){
 delete process.env.VERCEL_ENV;delete process.env.BILIMAI_STAGING_SUPABASE_URL;
 process.env.SUPABASE_URL='https://test.supabase.co';process.env.SUPABASE_PUBLISHABLE_KEY='fake-public';process.env.SUPABASE_SERVICE_ROLE_KEY='fake-admin';
 const calls=[];global.fetch=async(url,options)=>{calls.push({url,options});const r=responses.shift();if(r instanceof Error)throw r;if(!r)throw Error('Unexpected request');return r;};return calls;
}
afterEach(()=>{global.fetch=originalFetch;for(const [k,v]of Object.entries(saved)){if(v===undefined)delete process.env[k];else process.env[k]=v;}});
after(()=>{global.fetch=originalFetch;});
test('learning API rejects unauthenticated and expired sessions',async()=>{
 setup([]);assert.equal((await run(learning,{token:null})).code,401);
 setup([response({},401)]);assert.equal((await run(learning)).code,401);
});
test('workspace uses caller JWT, never the admin key',async()=>{
 const calls=setup([response({id:'student-id'}),response({role:'student',tasks:[]})]);
 const result=await run(learning);assert.equal(result.code,200);assert.equal(result.headers['Cache-Control'],'no-store');
 assert.ok(calls[1].url.endsWith('/rpc/unt_workspace'));assert.equal(calls[1].options.headers.Authorization,'Bearer fake-user-token');
 assert.equal(calls.some(c=>c.options.headers.apikey==='fake-admin'),false);
});
test('grade API validates input and binds identity to JWT instead of supplied user id',async()=>{
 setup([response({id:'student-id'})]);assert.equal((await run(learning,{method:'POST',body:{action:'grade',task_id:'measure-b01',answer:123}})).code,400);
 const calls=setup([response({id:'student-id'}),response({correct:false,answer:'1792',steps:['solution']})]);
 const result=await run(learning,{method:'POST',body:{action:'grade',task_id:'measure-b01',answer:'1',student_id:'victim-id',correct:true}});
 assert.equal(result.code,200);assert.deepEqual(JSON.parse(calls[1].options.body),{p_task_id:'measure-b01',p_answer:'1'});
});
test('missing migration and forbidden teacher actions fail clearly',async()=>{
 setup([response({id:'student-id'}),response({code:'PGRST202'},404)]);assert.equal((await run(learning)).code,503);
 setup([response({id:'student-id'}),response({code:'42501'},403)]);
 assert.equal((await run(learning,{method:'POST',body:{action:'set_active',task_id:'measure-b01',active:false}})).code,403);
});
test('network errors do not leak internal details',async()=>{
 setup([Error('sensitive upstream diagnostic')]);const r=await run(learning);assert.equal(r.code,502);assert.equal(JSON.stringify(r.data).includes('sensitive'),false);
});
test('student admin denies non-teachers before any data access',async()=>{
 const calls=setup([response({id:'student-id'}),response({code:'42501'},403)]);const r=await run(students);assert.equal(r.code,403);assert.equal(calls.length,2);
});
test('profile failure after Auth creation never deletes an account',async()=>{
 const calls=setup([response({id:'teacher-id'}),response({teacher:true}),response([]),response({id:'new-id'}),response({},500)]);
 const r=await run(students,{method:'POST',body:{username:'student99',full_name:'Test Student',class_name:'11',password:'test-password-123'}});
 assert.equal(r.code,502);assert.equal(calls.some(c=>c.options.method==='DELETE'),false);assert.match(r.data.error,/Auth аккаунты жасалды/);
});
test('new account enrollment failure preserves the account and reports partial completion',async()=>{
 setup([response({id:'teacher-id'}),response({teacher:true}),response([]),response({id:'new-id'}),response(null,201),response({},503)]);
 const r=await run(students,{method:'POST',body:{username:'student99',full_name:'Test Student',class_name:'11',password:'test-password-123'}});
 assert.equal(r.code,201);assert.equal(r.data.enrolled,false);assert.ok(r.data.warning);
});
test('missing management migration fails closed before admin access',async()=>{
 const calls=setup([response({id:'teacher-id'}),response({code:'PGRST202'},404)]);const r=await run(students);assert.equal(r.code,503);assert.equal(calls.length,2);
});
test('config endpoint only returns public configuration',async()=>{
 setup([]);const r=await run(config);assert.deepEqual(r.data,{url:'https://test.supabase.co',publishableKey:'fake-public'});assert.equal(JSON.stringify(r.data).includes('fake-admin'),false);
});
test('misconfigured Vercel Preview blocks all APIs before any Supabase network request',async()=>{
 const cases=[
  {SUPABASE_URL:'https://kbnwfuvfnspanoomusmu.supabase.co',BILIMAI_STAGING_SUPABASE_URL:'https://kbnwfuvfnspanoomusmu.supabase.co'},
  {SUPABASE_URL:'https://test.supabase.co'},
  {SUPABASE_URL:'https://other.supabase.co',BILIMAI_STAGING_SUPABASE_URL:'https://test.supabase.co'},
  {SUPABASE_URL:'https://test.supabase.co',BILIMAI_STAGING_SUPABASE_URL:'https://test.supabase.co/path'},
  {SUPABASE_URL:'http://test.supabase.co',BILIMAI_STAGING_SUPABASE_URL:'http://test.supabase.co'}
 ];
 for(const values of cases){
  const calls=setup([]);Object.assign(process.env,{VERCEL_ENV:'preview'},values);
  for(const handler of [config,learning,students,tasksApi,passwordApi,resultsApi]){
   const result=await run(handler,{method:handler===passwordApi?'POST':'GET'});assert.equal(result.code,503);assert.equal(JSON.stringify(result.data).includes('fake-admin'),false);
  }
  assert.equal(calls.length,0);
 }
});
test('explicit separate staging Preview works with the caller JWT and public-only configuration',async()=>{
 const calls=setup([response({id:'student-id'}),response({role:'student',tasks:[]})]);
 Object.assign(process.env,{VERCEL_ENV:'preview',BILIMAI_STAGING_SUPABASE_URL:'https://test.supabase.co/'});
 assert.equal((await run(config)).code,200);assert.equal((await run(learning)).code,200);
 assert.equal(calls.length,2);assert.equal(calls[1].options.headers.Authorization,'Bearer fake-user-token');
});
test('unauthenticated or student callers cannot create accounts by forging a teacher payload',async()=>{
 let calls=setup([]);assert.equal((await run(students,{method:'POST',token:null,body:{role:'teacher'}})).code,401);assert.equal(calls.length,0);
 calls=setup([response({id:'student-id'}),response({teacher:false})]);
 assert.equal((await run(students,{method:'POST',body:{role:'teacher',username:'forged',password:'not-a-real-password'}})).code,403);
 assert.equal(calls.length,2);assert.equal(calls.some(c=>c.url.includes('/auth/v1/admin/')),false);
});
test('task editor binds teacher authority to JWT and excludes forged topic/level/user fields',async()=>{
 let calls=setup([response({id:'student-id'}),response({code:'42501'},403)]);assert.equal((await run(tasksApi,{query:{id:'ip-c04'}})).code,403);
 calls=setup([response({id:'teacher-id'}),response({ok:true,revision:3})]);
 const r=await run(tasksApi,{method:'POST',body:{task_id:'ip-c04',revision:2,title:'Edited',topic_id:'sql',level:'B',teacher_id:'forged',answer:'10.42.9.98'}});assert.equal(r.code,200);
 const body=JSON.parse(calls[1].options.body);assert.equal(body.p_task_id,'ip-c04');assert.equal('topic_id' in body.p_data,false);assert.equal('teacher_id' in body.p_data,false);assert.equal(calls[1].options.headers.Authorization,'Bearer fake-user-token');
});
test('password reset authorizes a roster target before sending a server-only password update',async()=>{
 let calls=setup([response({id:'teacher-id'}),response({teacher:true}),response({code:'42501'},403)]);
 let r=await run(students,{method:'POST',body:{action:'reset_password',username:'other_student',password:'New-Password-2026'}});assert.equal(r.code,403);assert.equal(calls.some(c=>c.url.includes('/admin/users/')),false);
 calls=setup([response({id:'teacher-id'}),response({teacher:true}),response('owned-student'),response({}),response({ok:true})]);
 r=await run(students,{method:'POST',body:{action:'reset_password',username:'student01',password:'New-Password-2026',user_id:'victim'}});assert.equal(r.code,200);assert.ok(calls[3].url.endsWith('/admin/users/owned-student'));assert.deepEqual(JSON.parse(calls[3].options.body),{password:'New-Password-2026'});assert.equal(calls[3].options.headers.apikey,'fake-admin');assert.equal(JSON.stringify(r.data).includes('New-Password'),false);
});
test('self password change verifies the current password for the authenticated email and invalidates app sessions',async()=>{
 let calls=setup([response({id:'self',email:'self@example.test'}),response({teacher:false}),response({},400)]);
 let r=await run(passwordApi,{method:'POST',body:{current:'wrong',password:'New-Password-2026',email:'victim@example.test'}});assert.equal(r.code,400);assert.equal(JSON.parse(calls[2].options.body).email,'self@example.test');assert.equal(calls.some(c=>c.options.method==='PUT'),false);
 calls=setup([response({id:'self',email:'self@example.test'}),response({teacher:false}),response({access_token:'verification-token',user:{id:'self'}}),response({}),response({ok:true}),response({})]);
 r=await run(passwordApi,{method:'POST',body:{current:'Old-Password-2026',password:'New-Password-2026'}});assert.equal(r.code,200);assert.equal(r.data.reauthenticate,true);assert.ok(calls[4].url.endsWith('/rpc/unt_revoke_access'));assert.ok(calls[5].url.endsWith('/logout?scope=global'));assert.equal(calls.some(c=>c.options.headers.apikey==='fake-admin'),false);assert.equal(JSON.stringify(r.data).includes('verification-token'),false);
});
test('CSV endpoint uses teacher RPC, denies students and neutralizes spreadsheet formulas',async()=>{
 let calls=setup([response({id:'student-id'}),response({code:'42501'},403)]);assert.equal((await run(resultsApi)).code,403);
 calls=setup([response({id:'teacher-id'}),response([{username:'student01',full_name:'=SUM(1,1)',task_id:'ip-c04',task_revision:2,submitted_answer:' @command',correct:false,created_at:'2026-10-26'}])]);const r=await run(resultsApi);assert.equal(r.code,200);assert.match(r.headers['Content-Type'],/text\/csv/);assert.ok(r.data.includes('"\'=SUM(1,1)"'));assert.ok(r.data.includes('"\' @command"'));assert.equal(calls[1].options.headers.Authorization,'Bearer fake-user-token');
});
test('Vercel package contains six usable Node entrypoints and no private authored source or Sites runtime',()=>{
 const fs=require('node:fs'),path=require('node:path'),{build}=require('../scripts/build-vercel.cjs');const {out,functions}=build();assert.equal(functions.length,6);
 for(const f of functions)assert.equal(typeof require(path.join(out,'api',f)),'function');
 for(const forbidden of ['platform','preview','supabase','scripts','ops','tests','.env','app.py'])assert.equal(fs.existsSync(path.join(out,forbidden)),false,forbidden);
 const html=fs.readFileSync(path.join(out,'index.html'),'utf8');assert.equal(/lessonForm|data-view="lesson"|signin-with-chatgpt|ҚМЖ/.test(html),false);
 const config=JSON.parse(fs.readFileSync(path.join(out,'vercel.json')));assert.equal(config.git.deploymentEnabled['codex/stage1-information-measurement'],false);
});
