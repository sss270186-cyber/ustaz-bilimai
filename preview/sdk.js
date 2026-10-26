// Demo identity/results are browser-local. Only grading goes to the private Preview server.
// Never load real Supabase credentials or contact a Production service.
(()=>{
 const nativeFetch=window.fetch.bind(window),KEY='bilimai_preview_v1';
 let data;try{data=JSON.parse(localStorage.getItem(KEY)||'null');}catch{}
 if(!data||!Array.isArray(data.accounts)||!Array.isArray(data.attempts))data={accounts:[
  {id:'preview-teacher',username:'teacher',email:'teacher@preview.test',full_name:'Сынақ мұғалімі',role:'teacher',class_name:'11'},
  {id:'preview-student01',username:'student01',email:'student01@students.ustaz-bilimai.example.com',full_name:'Сынақ оқушысы 1',role:'student',class_name:'11'},
  {id:'preview-student02',username:'student02',email:'student02@students.ustaz-bilimai.example.com',full_name:'Сынақ оқушысы 2',role:'student',class_name:'11'}
 ],attempts:[],hidden:[],current:'preview-student01'};
 let memoryOnly=false;const save=()=>{try{localStorage.setItem(KEY,JSON.stringify(data));}catch{memoryOnly=true;}};save();
 const user=()=>data.accounts.find(a=>a.id===data.current),session=()=>user()?{access_token:'demo:'+user().id,user:{id:user().id,email:user().email}}:null;
 const hash=async password=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(password)))].map(b=>b.toString(16).padStart(2,'0')).join('');
 const catalog=nativeFetch('/api/preview/catalog').then(async r=>{if(!r.ok)throw Error('Тапсырмалар жүктелмеді.');return r.json();});
 let callback=()=>{};
 window.supabase={createClient(){return {auth:{
  onAuthStateChange(fn){callback=fn;return {data:{subscription:{unsubscribe(){}}}};},
  async getSession(){return {data:{session:session()}};},
  async signInWithPassword({email,password}){const account=data.accounts.find(a=>a.email===email);if(!account||(account.passwordHash?account.passwordHash!==await hash(password):password!=='Preview-Only-2026'))return {data:{},error:{message:'Қате сынақ логині'}};
   data.current=account.id;save();callback('SIGNED_IN',session());return {data:{session:session()},error:null};},
  async signOut(){data.current=null;save();callback('SIGNED_OUT',null);return {error:null};}
 },from(){return {select(){return {eq(){return {async single(){return {data:user(),error:user()?null:{message:'Сынақ аккаунтын таңдаңыз'}};}};}};}};}};}};
 function workspace(c){
  const a=user(),teacher=a.role==='teacher',attempts=data.attempts.filter(x=>teacher||x.student_id===a.id),first=new Map(),summary=new Map();
  for(const attempt of attempts){const key=attempt.student_id+':'+attempt.task_id+':'+attempt.task_revision;if(!first.has(key))first.set(key,attempt);}
  for(const row of first.values()){const t=c.tasks.find(t=>t.id===row.task_id);if(!t)continue;const key=row.student_id+':'+t.topic_id+':'+t.level;
   const s=summary.get(key)||{student_id:row.student_id,topic_id:t.topic_id,level:t.level,attempted:0,first_correct:0,first_wrong:0};s.attempted++;s[row.correct?'first_correct':'first_wrong']++;summary.set(key,s);}
  return {role:a.role,topics:c.topics,tasks:c.tasks.map(t=>({...t,active:!data.hidden.includes(t.id)})).filter(t=>teacher||t.active),
   attempts:attempts.slice(-200).reverse(),summary:[...summary.values()],roster:teacher?data.accounts.filter(a=>a.role==='student').map(({passwordHash,...p})=>p):[]};
 }
 const reply=(d,status=200)=>new Response(JSON.stringify(d),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}});
 window.fetch=async(input,options={})=>{
  const path=new URL(typeof input==='string'?input:input.url,location.origin).pathname;
  if(!['/api/learning','/api/students'].includes(path))return nativeFetch(input,options);
  if(!user())return reply({error:'Сынақ аккаунтын таңдаңыз.'},401);
  const c=await catalog,a=user(),body=options.body?JSON.parse(options.body):{};
  if(path==='/api/learning'){
   if(!options.method||options.method==='GET')return reply(workspace(c));
   if(body.action==='set_active'){if(a.role!=='teacher')return reply({error:'Мұғалім режимін таңдаңыз.'},403);
    data.hidden=data.hidden.filter(id=>id!==body.task_id);if(!body.active)data.hidden.push(body.task_id);save();return reply({ok:true});}
   if(body.action==='grade'){
    if(data.hidden.includes(body.task_id))return reply({error:'Тапсырма жасырылған.'},400);
    const response=await nativeFetch('/api/preview/grade',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({task_id:body.task_id,answer:body.answer})});
    if(!response.ok)return response;
    const result=await response.json(),task=c.tasks.find(t=>t.id===body.task_id);
    data.attempts.push({id:crypto.randomUUID(),student_id:a.id,task_id:body.task_id,task_revision:task.revision,submitted_answer:result.submitted_answer,correct:result.correct,created_at:new Date().toISOString()});save();return reply(result);
   }
  }
  if(path==='/api/students'){
   if(a.role!=='teacher')return reply({error:'Мұғалім режимін таңдаңыз.'},403);
   if(!options.method||options.method==='GET')return reply({students:data.accounts.filter(a=>a.role==='student').map(({passwordHash,...p})=>p)});
   if(body.action==='enroll')return reply({ok:true});
   if(!/^[a-z][a-z0-9_]{2,23}$/.test(body.username||'')||typeof body.password!=='string'||body.password.length<12||typeof body.full_name!=='string'||body.full_name.trim().length<2||!['9','10','11'].includes(body.class_name))return reply({error:'Сынақ деректерін тексеріңіз.'},400);
   if(data.accounts.some(a=>a.username===body.username))return reply({error:'Бұл сынақ логині бос емес.'},409);
   data.accounts.push({id:crypto.randomUUID(),username:body.username,email:body.username+'@students.ustaz-bilimai.example.com',full_name:body.full_name.trim(),class_name:body.class_name,role:'student',passwordHash:await hash(body.password)});save();return reply({ok:true,enrolled:true},201);
  }
  return reply({error:'Әрекет табылмады.'},400);
 };
 document.addEventListener('DOMContentLoaded',()=>{
  for(const button of document.querySelectorAll('[data-demo-account]'))button.addEventListener('click',async()=>{
   const account=data.accounts.find(a=>a.username===button.dataset.demoAccount);data.current=account.id;save();
   clearAccount();await restoreAccount(session());if(account.role==='teacher')showView('results');else showView('practice');
  });
  new MutationObserver(()=>{
   const status=document.getElementById('workspaceStatus');if(status?.textContent==='Жеке кабинет қосылды. Әр жауап тексерілгенде нәтиже дерекқорға сақталады.')status.textContent=memoryOnly?'Сынақ режимі: браузер сақтауына рұқсат жоқ. Нәтиже тек осы бет ашық тұрғанда сақталады.':'Сынақ режимі: жауап серверде тексеріледі, нәтижелер осы браузерде сақталады.';
  }).observe(document.getElementById('workspaceStatus'),{childList:true,subtree:true});
 });
})();
