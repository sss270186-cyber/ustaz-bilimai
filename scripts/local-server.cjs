// Isolated localhost learning sandbox. No Production environment variable or remote API is read.
const http=require('node:http'),fs=require('node:fs'),path=require('node:path');
const {randomUUID,randomBytes,scryptSync,timingSafeEqual}=require('node:crypto');const {PGlite}=require('@electric-sql/pglite');
const root=path.resolve(__dirname,'..'),PASSWORD='LocalDemo-Only-2026';
const sdk=String.raw`window.supabase={createClient(){let callback=()=>{};let session=null;
 const saved=()=>{try{return JSON.parse(localStorage.getItem('bilimai_local_session')||'null')}catch{return null}};
 async function request(path,body){const r=await fetch(path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json',...(session?{Authorization:'Bearer '+session.access_token}:{})},body:body?JSON.stringify(body):undefined});return {r,data:await r.json()};}
 return {auth:{onAuthStateChange(fn){callback=fn;return {data:{subscription:{unsubscribe(){}}}}},async getSession(){session=saved();if(session){const {r}=await request('/__local/session');if(!r.ok){session=null;localStorage.removeItem('bilimai_local_session')}}return {data:{session}}},
 async signInWithPassword(body){const {r,data}=await request('/__local/login',body);if(!r.ok)return {data:{},error:{message:'Local login failed'}};session=data.session;localStorage.setItem('bilimai_local_session',JSON.stringify(session));callback('SIGNED_IN',session);return {data:{session},error:null}},
 async signOut(){if(session)await request('/__local/logout',{});session=null;localStorage.removeItem('bilimai_local_session');callback('SIGNED_OUT',null);return {error:null}}},
 from(){return {select(){return {eq(){return {async single(){const {r,data}=await request('/__local/profile');return {data:r.ok?data:null,error:r.ok?null:{message:'Local profile missing'}}}}}}}}}}}};`;
async function startLocal({port=0,log=()=>{}}={}) {
 const db=new PGlite(),accounts=new Map(),tokens=new Map();let queue=Promise.resolve();
 const serial=fn=>{const result=queue.then(fn);queue=result.catch(()=>{});return result;};
 const addAccount=async(username,full_name,role,password,id=randomUUID(),class_name='11')=>{
  const email=role==='teacher'?'teacher@local.test':username+'@students.ustaz-bilimai.example.com';
  const salt=randomBytes(16),hash=scryptSync(password,salt,32);
  await db.query('insert into auth.users values($1)',[id]);await db.query('insert into public.profiles(id,username,full_name,role,class_name) values($1,$2,$3,$4,$5)',[id,username,full_name,role,class_name]);
  accounts.set(email,{id,email,username,full_name,role,class_name,salt,hash});return accounts.get(email);
 };
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;
 create schema auth;create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth to authenticated,anon,service_role;
 create table public.profiles(id uuid primary key references auth.users(id),username text unique,full_name text,role text,class_name text,created_at timestamptz default now());`);
 const teacher=await addAccount('teacher','Жергілікті сынақ мұғалімі','teacher',PASSWORD);
 await addAccount('student01','Жергілікті сынақ оқушысы','student',PASSWORD);
 for(const file of ['202610180001_learning.sql','202610180002_measurement_seed.sql','202610180003_answer_formats.sql','202610180004_full_curriculum.sql'])await db.exec(fs.readFileSync(path.join(root,'supabase/migrations',file),'utf8'));
 const asUser=async(account,fn)=>{
  await db.exec('set role authenticated');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[account.id]);try{return await fn();}finally{await db.exec('reset role');}
 };
 const callRpc=async(account,name,args=[])=>asUser(account,async()=>{
  const allowed={unt_workspace:'select public.unt_workspace() as data',unt_submit_answer:'select public.unt_submit_answer($1,$2) as data',unt_set_task_active:'select public.unt_set_task_active($1,$2) as data'};
  return (await db.query(allowed[name],args)).rows[0].data;
 });
 let origin;
 const server=http.createServer((req,res)=>serial(async()=>{
  const send=(data,status=200)=>{res.statusCode=status;res.setHeader('Content-Type','application/json; charset=utf-8');res.end(JSON.stringify(data));};
  res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
  for(const h of JSON.parse(fs.readFileSync(path.join(root,'vercel.json'))).headers[0].headers)res.setHeader(h.key,h.value);
  const pathname=new URL(req.url,origin).pathname;
  if(!['GET','POST'].includes(req.method))return send({error:'Method not allowed'},405);
  let body;
  if(req.method==='POST'){
   if(req.headers.origin&&req.headers.origin!==origin)return send({error:'Origin denied'},403);
   if(!req.headers['content-type']?.startsWith('application/json'))return send({error:'JSON required'},415);
   let data='';for await(const chunk of req){data+=chunk;if(data.length>8192)return send({error:'Request too large'},413);}
   try{body=JSON.parse(data);}catch{return send({error:'Invalid JSON'},400);}
   if(!body||typeof body!=='object'||Array.isArray(body))return send({error:'Invalid body'},400);
  }
  const token=(req.headers.authorization||'').replace(/^Bearer /,''),account=tokens.get(token);
  if(pathname==='/__local/auth.js'&&req.method==='GET'){res.setHeader('Content-Type','application/javascript');return res.end(sdk);}
  if(pathname==='/api/config'&&req.method==='GET')return send({url:origin,publishableKey:'local-only',mode:'local-demo'});
  if(pathname==='/__local/login'&&req.method==='POST'){
   const a=accounts.get(body.email);if(!a||typeof body.password!=='string'||body.password.length>128||!timingSafeEqual(a.hash,scryptSync(body.password,a.salt,32)))return send({error:'Қате логин'},401);
   const access_token=randomBytes(32).toString('hex');tokens.set(access_token,a);return send({session:{access_token,user:{id:a.id,email:a.email}}});
  }
  if(pathname.startsWith('/api/')||pathname.startsWith('/__local/')){
   if(!account)return send({error:'Жүйеге кіріңіз'},401);
   if(pathname==='/__local/session')return send({ok:true});
   if(pathname==='/__local/logout'&&req.method==='POST'){tokens.delete(token);return send({ok:true});}
   if(pathname==='/__local/profile')return send({full_name:account.full_name,class_name:account.class_name,role:account.role});
   if(pathname==='/api/learning'){
    if(req.method==='GET')return send(await callRpc(account,'unt_workspace'));
    if(body.action==='grade'&&typeof body.task_id==='string'&&typeof body.answer==='string'&&body.answer.length<=256)return send(await callRpc(account,'unt_submit_answer',[body.task_id,body.answer]));
    if(body.action==='set_active'&&typeof body.task_id==='string'&&typeof body.active==='boolean')return send(await callRpc(account,'unt_set_task_active',[body.task_id,body.active]));
    return send({error:'Invalid action'},400);
   }
   if(pathname==='/api/students'){
    if(account.role!=='teacher')return send({error:'Тек мұғалімге'},403);
    if(req.method==='GET')return send({students:[...accounts.values()].filter(a=>a.role==='student').map(a=>({username:a.username,full_name:a.full_name,class_name:a.class_name}))});
    if(body.action==='enroll'){
     const a=[...accounts.values()].find(a=>a.username===body.username&&a.role==='student');if(!a)return send({error:'Оқушы жоқ'},404);
     await db.query('insert into public.unt_enrollments values($1,$2) on conflict do nothing',[account.id,a.id]);return send({ok:true});
    }
    if(!/^[a-z][a-z0-9_]{2,23}$/.test(body.username||'')||typeof body.password!=='string'||body.password.length<12||body.password.length>128||typeof body.full_name!=='string'||body.full_name.trim().length<2||body.full_name.length>120||!['9','10','11'].includes(body.class_name))return send({error:'Тіркеу мәліметтерін тексеріңіз'},400);
    if([...accounts.values()].some(a=>a.username===body.username))return send({error:'Логин бос емес'},409);
    const a=await addAccount(body.username,body.full_name.trim(),'student',body.password,undefined,body.class_name);await db.query('insert into public.unt_enrollments values($1,$2)',[account.id,a.id]);return send({ok:true,enrolled:true},201);
   }
   return send({error:'Not found'},404);
  }
  if(req.method!=='GET')return send({error:'Not found'},404);
  const files={'/':'index.html','/index.html':'index.html','/assets/style.css':'assets/style.css','/assets/lessons.js':'assets/lessons.js','/assets/app.js':'assets/app.js','/student.js':'student.js'};
  if(!files[pathname])return send({error:'Not found'},404);
  let data=fs.readFileSync(path.join(root,files[pathname]),'utf8');
  if(files[pathname]==='index.html')data=data.replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js','/__local/auth.js').replace('<header class="topbar">','<div class="local-banner">ЖЕРГІЛІКТІ СЫНАҚ · Оқшауланған PostgreSQL, сынақ аккаунттары. Нақты Supabase емес. Қайта іске қосқанда деректер тазарады.</div><header class="topbar">');
  res.setHeader('Content-Type',files[pathname].endsWith('.js')?'application/javascript':files[pathname].endsWith('.css')?'text/css':'text/html; charset=utf-8');res.end(data);
 }).catch(error=>{if(!res.headersSent){res.statusCode=error.code==='42501'?403:400;res.setHeader('Content-Type','application/json');res.end(JSON.stringify({error:error.code==='P0001'?error.message:'Жергілікті сұрау орындалмады'}));}else res.end();}));
 await new Promise(resolve=>server.listen(port,'127.0.0.1',resolve));origin=`http://127.0.0.1:${server.address().port}`;
 log(`Local sandbox: ${origin}\nTeacher: teacher@local.test\nStudent: student01\nDemo-only password: ${PASSWORD}\nMemory-only data. No remote APIs are used.`);
 return {origin,close:async()=>{await new Promise(resolve=>server.close(resolve));await queue;await db.close();}};
}
module.exports={startLocal,PASSWORD};
if(require.main===module)startLocal({port:Number(process.env.LOCAL_PORT||4173),log:console.log}).then(app=>{let stopping=false;for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{if(stopping)return;stopping=true;await app.close();process.exit(0);});}).catch(()=>{console.error('Local sandbox could not start.');process.exitCode=1;});
