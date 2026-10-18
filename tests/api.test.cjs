const {test,afterEach,after}=require('node:test');const assert=require('node:assert/strict');
const learning=require('../api/learning.js'),students=require('../api/students.js'),config=require('../api/config.js');
const saved=Object.fromEntries(['SUPABASE_URL','SUPABASE_PUBLISHABLE_KEY','SUPABASE_SERVICE_ROLE_KEY'].map(k=>[k,process.env[k]]));
const originalFetch=global.fetch;
const response=(data,status=200)=>({ok:status>=200&&status<300,status,json:async()=>data});
function run(handler,{method='GET',token='fake-user-token',body}={}){
 const req={method,headers:token?{authorization:`Bearer ${token}`}:{},body};
 const res={headers:{},setHeader(k,v){this.headers[k]=v;},status(s){this.code=s;return this;},json(data){this.data=data;return this;}};
 return Promise.resolve(handler(req,res)).then(()=>res);
}
function setup(responses){
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
 const calls=setup([response({id:'student-id'}),response([])]);const r=await run(students);assert.equal(r.code,403);assert.equal(calls.length,2);
});
test('profile failure after Auth creation never deletes an account',async()=>{
 const calls=setup([response({id:'teacher-id'}),response([{user_id:'teacher-id'}]),response([]),response({id:'new-id'}),response({},500)]);
 const r=await run(students,{method:'POST',body:{username:'student99',full_name:'Test Student',class_name:'11',password:'test-password-123'}});
 assert.equal(r.code,502);assert.equal(calls.some(c=>c.options.method==='DELETE'),false);assert.match(r.data.error,/Auth аккаунты жасалды/);
});
test('new account enrollment failure preserves the account and reports partial completion',async()=>{
 setup([response({id:'teacher-id'}),response([{user_id:'teacher-id'}]),response([]),response({id:'new-id'}),response(null,201),response({},503)]);
 const r=await run(students,{method:'POST',body:{username:'student99',full_name:'Test Student',class_name:'11',password:'test-password-123'}});
 assert.equal(r.code,201);assert.equal(r.data.enrolled,false);assert.ok(r.data.warning);
});
test('existing administration remains available before migration',async()=>{
 setup([response({id:'teacher-id'}),response({code:'PGRST205'},404),response([{role:'teacher'}]),response([{username:'student01'}])]);
 const r=await run(students);assert.equal(r.code,200);assert.equal(r.data.students.length,1);
});
test('config endpoint only returns public configuration',async()=>{
 setup([]);const r=await run(config);assert.deepEqual(r.data,{url:'https://test.supabase.co',publishableKey:'fake-public'});assert.equal(JSON.stringify(r.data).includes('fake-admin'),false);
});
