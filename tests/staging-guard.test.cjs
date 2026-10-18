const {test}=require('node:test');const assert=require('node:assert/strict');
const {config,runStaging}=require('../scripts/staging-check.cjs');
const env={STAGING_SUPABASE_URL:'https://separate-staging.supabase.co',STAGING_SUPABASE_PUBLISHABLE_KEY:'fake-key',STAGING_PREVIEW_URL:'https://project-preview.vercel.app',STAGING_TEACHER_EMAIL:'teacher@example.test',STAGING_TEACHER_PASSWORD:'fake-password'};
test('staging acceptance refuses missing configuration before any request',async()=>{
 let calls=0;await assert.rejects(()=>runStaging({},async()=>{calls++;}),/Missing protected/);assert.equal(calls,0);
});
test('staging acceptance refuses known Production, configured Production and Production website',()=>{
 assert.throws(()=>config({...env,STAGING_SUPABASE_URL:'https://kbnwfuvfnspanoomusmu.supabase.co'}),/separate/);
 assert.throws(()=>config({...env,SUPABASE_URL:env.STAGING_SUPABASE_URL}),/separate/);
 assert.throws(()=>config({...env,STAGING_PREVIEW_URL:'https://ustaz-bilimai.vercel.app'}),/Production/);
});
test('staging acceptance rejects a Preview attached to another database before Auth or mutation',async()=>{
 const calls=[];await assert.rejects(()=>runStaging(env,async(url,options)=>{calls.push({url,options});return {ok:true,status:200,json:async()=>({url:'https://kbnwfuvfnspanoomusmu.supabase.co',publishableKey:'fake-key'})};},()=>{}),/not connected/);
 assert.equal(calls.length,1);assert.equal(calls[0].options.method,'GET');
});
test('staging acceptance rejects URLs containing credentials, paths or query parameters',()=>{
 for(const value of ['https://user:pass@separate-staging.supabase.co','https://separate-staging.supabase.co/rest/v1','https://separate-staging.supabase.co/?token=secret'])assert.throws(()=>config({...env,STAGING_SUPABASE_URL:value}),/clean/);
});
test('staging acceptance restores visibility and revokes test sessions when a check fails',async()=>{
 const accounts=new Map(),attempts=[],visibility=[],logs=[];let active=true,logout=0;
 const response=(data,status=200)=>({ok:status>=200&&status<300,status,json:async()=>data});
 const who=options=>(options.headers.Authorization||'').replace('Bearer ','');
 const fake=async(url,options)=>{
  const path=new URL(url).pathname,body=options.body?JSON.parse(options.body):null,actor=who(options);
  if(path==='/api/config')return response({url:env.STAGING_SUPABASE_URL,publishableKey:'public-placeholder-can-differ'});
  if(path.startsWith('/scripts/')||path.startsWith('/supabase/')||path.startsWith('/tests/')||['/.env','/app.py','/api/_lib/supabase.cjs'].includes(path))return response({},404);
  if(path==='/auth/v1/token'){
   const email=body.email,id=email===env.STAGING_TEACHER_EMAIL?'teacher':accounts.get(email)?.id;
   assert.ok(id);return response({access_token:id,user:{id}});
  }
  if(path==='/auth/v1/logout'){logout++;return response({});}
  if(path==='/api/students'){
   const email=body.username+'@students.ustaz-bilimai.example.com';accounts.set(email,{id:body.username});return response({enrolled:true},201);
  }
  if(path==='/rest/v1/unt_attempts'&&options.method==='GET')return response(attempts.filter(a=>a.student_id===actor));
  if(path.startsWith('/rest/v1/'))return response({},403);
  if(path==='/api/learning'&&options.method==='GET'){
   if(!actor)return response({},401);
   const rows=attempts.filter(a=>actor==='teacher'||a.student_id===actor);
   return response({role:actor==='teacher'?'teacher':'student',topics:Array(19).fill({}),tasks:Array.from({length:12},(_,i)=>({id:i===0?'measure-b01':'task-'+i,level:i<2?'B':'C',active})),
    roster:[...accounts.values()],attempts:rows,summary:rows.length?[{attempted:1,first_wrong:1,first_correct:0}]:[]});
  }
  if(path==='/api/learning'&&body.action==='grade'){
   const correct=body.answer!=='0';attempts.push({student_id:actor});return response({correct,steps:['step']});
  }
  if(path==='/api/learning'&&body.action==='set_active'){active=body.active;visibility.push(active);return response({ok:true});}
  throw Error('Unexpected fake request');
 };
 // Fixture intentionally continues to expose a hidden task: acceptance must fail and restore it.
 await assert.rejects(()=>runStaging(env,fake,s=>logs.push(s)),/Hidden task is visible/);
 assert.deepEqual(visibility,[false,true]);assert.equal(active,true);assert.equal(logout,4);
 assert.ok(logs.every(s=>!s.includes(env.STAGING_TEACHER_PASSWORD)));
});
