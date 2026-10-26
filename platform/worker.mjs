// Standalone hosted platform. Its database is separate from the legacy Supabase project.
/*__DATA__*/
const security={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'same-origin',
 'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'"};
const json=(body,status=200,extra={})=>new Response(JSON.stringify(body),{status,headers:{...security,'Content-Type':'application/json; charset=utf-8',...extra}});
const fail=(message,status=400)=>{throw Object.assign(Error(message),{status});};
const now=()=>new Date().toISOString(),seconds=()=>Math.floor(Date.now()/1000);
const bytesToHex=bytes=>[...new Uint8Array(bytes)].map(b=>b.toString(16).padStart(2,'0')).join('');
const random=()=>bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
const digest=async s=>bytesToHex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
async function passwordHash(password,salt){const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(password),'PBKDF2',false,['deriveBits']);return bytesToHex(await crypto.subtle.deriveBits({name:'PBKDF2',hash:'SHA-256',salt:new TextEncoder().encode(salt),iterations:100000},key,256));}
function equal(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let diff=0;for(let i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0;}
const publicUser=u=>({id:u.id,username:u.username,email:u.email,full_name:u.full_name,class_name:u.class_name,role:u.role,active:Boolean(u.active)});
const publicTask=t=>Object.fromEntries(['id','topic_id','level','position','title','prompt','given_data','find_value','formulas','unit','code','answer_format','revision','active'].map(k=>[k,t[k]]));
async function all(db,sql,...params){return (await db.prepare(sql).bind(...params).all()).results;}
const first=(db,sql,...params)=>db.prepare(sql).bind(...params).first();
const run=(db,sql,...params)=>db.prepare(sql).bind(...params).run();
async function log(db,actor,action,subject){await run(db,'INSERT INTO audit_log(id,actor_id,action,subject_id,created_at) VALUES(?,?,?,?,?)',crypto.randomUUID(),actor,action,subject,now());}
function cookie(request,token,maxAge=604800){return `bilimai_session=${token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=${maxAge}`+(new URL(request.url).protocol==='https:'?'; Secure':'');}
async function createSession(db,user,request){const token=random();await run(db,'INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)',await digest(token),user.id,seconds()+604800);return cookie(request,token);}
async function actor(db,request){const token=request.headers.get('cookie')?.match(/(?:^|;\s*)bilimai_session=([a-f0-9]{64})(?:;|$)/)?.[1];if(!token)fail('Жүйеге кіріңіз.',401);
 const u=await first(db,'SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.token_hash=? AND s.revoked=0 AND s.expires_at>? AND u.active=1',await digest(token),seconds());if(!u)fail('Сеанс аяқталды. Қайта кіріңіз.',401);return u;}
const teacher=u=>{if(u.role!=='teacher')fail('Тек мұғалімге рұқсат.',403);};
const teacherId=u=>u.role==='teacher'?u.id:u.teacher_id;
async function tasksFor(db,u){
 const versions=await all(db,'SELECT task_id,revision,content FROM task_versions WHERE teacher_id=? ORDER BY revision DESC',teacherId(u)),overrides=new Map();
 for(const row of versions)if(!overrides.has(row.task_id))overrides.set(row.task_id,{...JSON.parse(row.content),revision:row.revision});
 const states=new Map((await all(db,'SELECT task_id,active FROM task_state WHERE teacher_id=?',teacherId(u))).map(x=>[x.task_id,Boolean(x.active)]));
 return baseTasks.map(t=>({...t,...overrides.get(t.id),active:states.has(t.id)?states.get(t.id):true}));
}
export function normalize(value,format){
 if(format==='number'){if(value.length>64)fail('Сандық жауап тым ұзын.');const s=value.trim().replace(/[ \u00a0]/g,'').replaceAll(',','.');if(!/^[+-]?\d+(\.\d+)?$/.test(s))fail('Тек сан енгізіңіз. Өлшем бірлігін жазбаңыз.');let [w,d='']=s.replace(/^[+-]/,'').split('.');w=w.replace(/^0+(?=\d)/,'');d=d.replace(/0+$/,'');return (s.startsWith('-')&&(w!=='0'||d)?'-':'')+w+(d?'.'+d:'');}
 return value.trim().toLowerCase().replace(format==='sequence'?/[,;\s]+/g:/\s+/g,' ');
}
export function checkAnswer(task,answer){if(typeof answer!=='string'||!answer.trim()||answer.length>256)fail('Жауап енгізіңіз (256 таңбаға дейін).');const clean=normalize(answer,task.answer_format),correct=clean===normalize(String(task.answer),task.answer_format);
 return {correct,answer:String(task.answer),unit:task.unit,steps:task.steps,explanation:task.explanation,feedback:correct?null:task.mistakes?.[clean]||task.error_feedback||'Берілген шамаларды және формуладағы өлшем бірліктерін қайта тексеріңіз.',submitted_answer:clean};}
async function boundedBody(request){if(!request.headers.get('content-type')?.startsWith('application/json'))fail('JSON сұрауы қажет.',415);const reader=request.body?.getReader();if(!reader)fail('Сұрау бос.');let length=0;const parts=[];while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>65536){await reader.cancel();fail('Сұрау тым ұзын.',413);}parts.push(value);}const bytes=new Uint8Array(length);let offset=0;for(const p of parts){bytes.set(p,offset);offset+=p.length;}try{const value=JSON.parse(new TextDecoder().decode(bytes));if(!value||typeof value!=='object'||Array.isArray(value))fail('Сұрау пішімі дұрыс емес.');return value;}catch{fail('Сұрау пішімі дұрыс емес.');}}
async function limit(db,bucket,max=8){const row=await first(db,'INSERT INTO login_events(id,bucket,created_at) SELECT ?,?,? WHERE (SELECT count(*) FROM login_events WHERE bucket=? AND created_at>?)<? RETURNING id',crypto.randomUUID(),bucket,seconds(),bucket,seconds()-900,max);if(!row)fail('Әрекет саны шектелді. 15 минуттан кейін қайталаңыз.',429);}
async function workspace(db,u){
 const visible=u.role==='teacher'?'(student_id=? OR student_id IN (SELECT id FROM users WHERE teacher_id=?))':'student_id=?';
 const params=u.role==='teacher'?[u.id,u.id]:[u.id];
 const rows=await all(db,`SELECT id,student_id,task_id,task_revision,submitted_answer,correct,created_at FROM attempts WHERE ${visible} ORDER BY rowid DESC LIMIT 200`,...params);
 const summary=await all(db,`WITH ranked AS (SELECT student_id,task_id,task_revision,correct,task_snapshot,ROW_NUMBER() OVER(PARTITION BY student_id,task_id,task_revision ORDER BY rowid) AS n FROM attempts WHERE ${visible}) SELECT student_id,json_extract(task_snapshot,'$.topic_id') AS topic_id,json_extract(task_snapshot,'$.level') AS level,count(*) AS attempted,sum(correct) AS first_correct,sum(1-correct) AS first_wrong FROM ranked WHERE n=1 GROUP BY student_id,topic_id,level`,...params);
 const tasks=await tasksFor(db,u),roster=u.role==='teacher'?(await all(db,'SELECT * FROM users WHERE teacher_id=? ORDER BY created_at',u.id)).map(publicUser):[];
 return {role:u.role,topics,tasks:tasks.filter(t=>t.active||u.role==='teacher').map(publicTask),attempts:rows.map(a=>({...a,correct:Boolean(a.correct)})),summary,roster};
}
function validateTask(body,old){
 const t={...old};for(const key of ['title','prompt','given_data','find_value','unit','answer','explanation','code']){
  if(typeof body[key]!=='string'||body[key].length>(key==='code'?20000:5000)||(key!=='code'&&!body[key].trim()))fail('Тапсырманың барлық міндетті өрістерін толтырыңыз.');t[key]=body[key].trim();}
 if(!['number','text','sequence'].includes(body.answer_format))fail('Жауап түрі дұрыс емес.');t.answer_format=body.answer_format;
 for(const key of ['formulas','steps']){if(!Array.isArray(body[key])||body[key].length>(key==='steps'?20:10)||body[key].length<(key==='steps'?(old.level==='C'?3:2):1)||body[key].some(s=>typeof s!=='string'||!s.trim()||s.length>4000))fail('Формула мен шешу қадамдарын толық жазыңыз.');t[key]=body[key].map(s=>s.trim());}
 if(t.answer.length>256)fail('Дұрыс жауап 256 таңбадан аспауы керек.');normalize(t.answer,t.answer_format);t.mistakes={};t.error_feedback='Шешіміңізді мына түсіндірмемен салыстырыңыз: '+t.explanation;return t;
}
export default {async fetch(request,env){
 const url=new URL(request.url),path=url.pathname;
 if(request.method==='GET'&&assets[path])return new Response(assets[path].body,{headers:{...security,'Content-Type':assets[path].type}});
 if(path==='/api/config'&&request.method==='GET')return json({url:url.origin,publishableKey:'server-session',mode:'platform'});
 if(!path.startsWith('/api/'))return json({error:'Бет табылмады.'},404);
 if(!env.DB)return json({error:'Тұрақты сақтау қызметі дайын емес. Кейінірек қайталаңыз.'},503);
 try{
  if(path==='/api/health'&&request.method==='GET'){await first(env.DB,'SELECT id FROM users LIMIT 1');return json({status:'ready',topics:19,tasks:228});}
  let body={};if(request.method==='POST'){if(request.headers.get('origin')!==url.origin)fail('Сұрау осы сайттан жіберілуі керек.',403);body=await boundedBody(request);}else if(request.method!=='GET')fail('Бұл сұрау түрі қолдау таппайды.',405);
  const db=env.DB;
  if(path==='/api/owner-login'&&request.method==='POST'){
   const id=request.headers.get('oai-authenticated-user-id'),email=request.headers.get('oai-authenticated-user-email')?.toLowerCase();
   if(!id||!email)fail('Мұғалім ChatGPT аккаунты арқылы кіреді.',401);
   const ownerEmail=env.SECRET_BILIMAI_OWNER_EMAIL?.get?await env.SECRET_BILIMAI_OWNER_EMAIL.get():env.BILIMAI_OWNER_EMAIL;
   if(typeof ownerEmail!=='string'||email!==ownerEmail.toLowerCase())fail('Бұл аккаунт мұғалім ретінде тіркелмеген.',403);
   let u=await first(db,'SELECT * FROM users WHERE sites_id=?',id);
   if(!u){await run(db,'INSERT OR IGNORE INTO users(id,username,email,sites_id,full_name,class_name,role,created_at) VALUES(?,?,?,?,?,?,?,?)',crypto.randomUUID(),'teacher',email,id,'Мұғалім','11','teacher',now());u=await first(db,'SELECT * FROM users WHERE sites_id=?',id);}
   if(!u||u.role!=='teacher'||!u.active)fail('Мұғалім кабинеті қолжетімсіз.',403);
   return json({user:publicUser(u)},200,{'Set-Cookie':await createSession(db,u,request)});
  }
  if(path==='/api/login'&&request.method==='POST'){
   if(typeof body.email!=='string'||typeof body.password!=='string'||body.password.length>128)fail('Логин мен құпиясөзді енгізіңіз.');
   const username=body.email.split('@')[0].toLowerCase();if(!/^[a-z][a-z0-9_]{2,23}$/.test(username))fail('Логин немесе құпиясөз дұрыс емес.',401);
   const ip=request.headers.get('CF-Connecting-IP')||'unknown';await limit(db,'ip:'+await digest(ip),40);const bucket=await digest(ip+':'+username);await limit(db,bucket);
   const u=await first(db,'SELECT * FROM users WHERE username=? AND role=? AND active=1',username,'student');
   const hash=await passwordHash(body.password,u?.password_salt||'missing-account-salt');
   if(!u||!equal(hash,u.password_hash))fail('Логин немесе құпиясөз дұрыс емес.',401);
   return json({user:publicUser(u)},200,{'Set-Cookie':await createSession(db,u,request)});
  }
  const u=await actor(db,request);
  if(path==='/api/account'&&request.method==='GET')return json({user:publicUser(u)});
  if(path==='/api/logout'&&request.method==='POST'){const token=request.headers.get('cookie')?.match(/bilimai_session=([a-f0-9]{64})/)?.[1];if(token)await run(db,'UPDATE sessions SET revoked=1 WHERE token_hash=?',await digest(token));return json({ok:true},200,{'Set-Cookie':cookie(request,'',0)});}
  if(path==='/api/learning'){
   if(request.method==='GET')return json(await workspace(db,u));
   const tasks=await tasksFor(db,u),task=tasks.find(t=>t.id===body.task_id);if(!task)fail('Тапсырма табылмады.',404);
   if(body.action==='grade'){
    if(!task.active)fail('Тапсырма уақытша жасырылған.');const result=checkAnswer(task,body.answer),id=crypto.randomUUID();
    const row=await first(db,'INSERT INTO attempts(id,student_id,task_id,task_revision,submitted_answer,correct,created_at,task_snapshot) SELECT ?,?,?,?,?,?,?,? WHERE (SELECT count(*) FROM attempts WHERE student_id=? AND created_at>?)<20 RETURNING id',id,u.id,task.id,task.revision,result.submitted_answer,result.correct?1:0,now(),JSON.stringify(publicTask(task)),u.id,new Date(Date.now()-60000).toISOString());
    if(!row)fail('Бір минуттағы тексеру саны шектелді. Сәл күтіңіз.',429);return json({...result,attempt_id:id});
   }
   if(body.action==='set_active'){teacher(u);if(typeof body.active!=='boolean')fail('Қолжетімділік мәні дұрыс емес.');await run(db,'INSERT INTO task_state(teacher_id,task_id,active) VALUES(?,?,?) ON CONFLICT(teacher_id,task_id) DO UPDATE SET active=excluded.active',u.id,task.id,body.active?1:0);await log(db,u.id,'task_visibility',task.id);return json({ok:true});}
   fail('Белгісіз әрекет.');
  }
  if(path==='/api/students'){
   teacher(u);if(request.method==='GET')return json({students:(await all(db,'SELECT * FROM users WHERE teacher_id=? ORDER BY created_at',u.id)).map(publicUser)});
   if(body.action==='reset_password'){
    const student=await first(db,'SELECT * FROM users WHERE id=? AND teacher_id=? AND role=?',body.student_id,u.id,'student');if(!student)fail('Оқушы табылмады.',404);
    if(typeof body.password!=='string'||body.password.length<12||body.password.length>128)fail('Құпиясөз 12–128 таңба болсын.');await limit(db,'reset:'+u.id,20);const salt=random();
    const hash=await passwordHash(body.password,salt);await db.batch([db.prepare('UPDATE users SET password_hash=?,password_salt=? WHERE id=?').bind(hash,salt,student.id),db.prepare('UPDATE sessions SET revoked=1 WHERE user_id=?').bind(student.id)]);await log(db,u.id,'password_reset',student.id);return json({ok:true});
   }
   if(body.action==='enroll')fail('Бұл сайтта оқушыны тек тіркеген мұғалім басқарады.');
   if(body.action&&body.action!=='create')fail('Белгісіз әрекет.');
   if(typeof body.username!=='string'||!/^[a-z][a-z0-9_]{2,23}$/.test(body.username)||body.username==='teacher'||typeof body.full_name!=='string'||body.full_name.trim().length<2||body.full_name.length>120||!['9','10','11'].includes(body.class_name)||typeof body.password!=='string'||body.password.length<12||body.password.length>128)fail('Аты-жөнін, логинді, сыныпты және кемінде 12 таңбалы құпиясөзді тексеріңіз.');
   if(await first(db,'SELECT id FROM users WHERE username=?',body.username))fail('Бұл логин бос емес.',409);await limit(db,'create:'+u.id,30);
   const id=crypto.randomUUID(),salt=random();await run(db,'INSERT INTO users(id,username,full_name,class_name,role,teacher_id,password_hash,password_salt,created_at) VALUES(?,?,?,?,?,?,?,?,?)',id,body.username,body.full_name.trim(),body.class_name,'student',u.id,await passwordHash(body.password,salt),salt,now());await log(db,u.id,'student_created',id);return json({ok:true,enrolled:true,username:body.username},201);
  }
  if(path==='/api/task-edit'){
   teacher(u);const tasks=await tasksFor(db,u),task=tasks.find(t=>t.id===(request.method==='GET'?url.searchParams.get('id'):body.task_id));if(!task)fail('Тапсырма табылмады.',404);
   if(request.method==='GET')return json({task});if(body.revision!==task.revision)fail('Тапсырма басқа бетте өзгерген. Қайта ашыңыз.',409);
   const updated=validateTask(body,task),revision=task.revision+1;await run(db,'INSERT INTO task_versions(teacher_id,task_id,revision,content,created_at) VALUES(?,?,?,?,?)',u.id,task.id,revision,JSON.stringify({...updated,revision}),now());await log(db,u.id,'task_edited',task.id);return json({ok:true,revision});
  }
  if(path==='/api/password'&&request.method==='POST'){
   if(u.role!=='student')fail('Мұғалім ChatGPT аккаунты арқылы кіреді.');if(typeof body.current!=='string'||typeof body.password!=='string'||body.password.length<12||body.password.length>128||body.current.length>128)fail('Қазіргі және жаңа құпиясөзді енгізіңіз.');await limit(db,'password:'+u.id);
   if(!equal(await passwordHash(body.current,u.password_salt),u.password_hash))fail('Қазіргі құпиясөз дұрыс емес.');const salt=random();const hash=await passwordHash(body.password,salt);
   await db.batch([db.prepare('UPDATE users SET password_hash=?,password_salt=? WHERE id=?').bind(hash,salt,u.id),db.prepare('UPDATE sessions SET revoked=1 WHERE user_id=?').bind(u.id)]);await log(db,u.id,'password_changed',u.id);return json({ok:true},200,{'Set-Cookie':await createSession(db,u,request)});
  }
  if(path==='/api/results.csv'&&request.method==='GET'){
   teacher(u);const rows=await all(db,'SELECT u.username,u.full_name,a.task_id,a.task_revision,a.submitted_answer,a.correct,a.created_at FROM attempts a JOIN users u ON u.id=a.student_id WHERE u.teacher_id=? ORDER BY a.created_at DESC LIMIT 10000',u.id);
   const cell=value=>'"'+String(value??'').replace(/^[=+\-@]/,"'$&").replaceAll('"','""')+'"';
   const csv='\ufeff'+[['Логин','Оқушы','Есеп','Нұсқа','Жауап','Дұрыс','Уақыты'],...rows.map(r=>[r.username,r.full_name,r.task_id,r.task_revision,r.submitted_answer,r.correct,r.created_at])].map(row=>row.map(cell).join(',')).join('\r\n');
   return new Response(csv,{headers:{...security,'Content-Type':'text/csv; charset=utf-8','Content-Disposition':'attachment; filename="bilimai-results.csv"'}});
  }
  return json({error:'Сұрау табылмады.'},404);
 }catch(error){return json({error:error.status?error.message:'Сұрау орындалмады. Қайта көріңіз.'},error.status||500);}
}};
