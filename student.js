'use strict';
// Keep the existing account address format: all current student logins still work.
const studentEmail = login => `${login.toLowerCase()}@students.ustaz-bilimai.example.com`;
async function restoreAccount(session) {
  if(!session){clearAccount();return;}
  const epoch=++state.epoch;
  state.user=session.user;state.profile=null;state.workspace=null;updateAccount();
  el('studentsTable').replaceChildren();el('taskAdmin').replaceChildren();renderTasks();renderResults();
  try {
    const {data:profile,error}=await state.client.from('profiles').select('full_name,class_name,role').eq('id',session.user.id).single();
    if(epoch!==state.epoch)return;
    if(error||!profile||!['teacher','student'].includes(profile.role))throw Error('Аккаунт профилі табылмады. Мұғалімге хабарласыңыз.');
    state.profile=profile;updateAccount();el('loginDialog').close();el('loginStatus').textContent='';
    await refreshWorkspace();
  }catch(error){if(epoch===state.epoch){el('loginDialog').close();el('loginStatus').textContent='';notice(error.message,true);}}
}
async function setupSupabase() {
  try {
    const response=await fetch('/api/config',{cache:'no-store'});
    if(!response.ok)throw Error('Кіру конфигурациясы қолжетімсіз. Теорияны оқуға болады.');
    const config=await response.json();
    if(!config.url||!config.publishableKey||!window.supabase)throw Error('Кіру кітапханасы немесе баптауы дайын емес. Бетті жаңартыңыз.');
    state.client=window.supabase.createClient(config.url,config.publishableKey);
    state.client.auth.onAuthStateChange((event,session)=>{
      // Defer calls to Supabase outside its synchronous auth callback.
      if(event==='SIGNED_OUT')clearAccount();
      else if(event==='SIGNED_IN'&&session?.user.id!==state.user?.id)setTimeout(()=>restoreAccount(session),0);
    });
    const {data:{session}}=await state.client.auth.getSession();
    if(session)await restoreAccount(session);
  }catch(error){notice(error.message,true);}
}
el('loginForm').addEventListener('submit',async event=>{
  event.preventDefault();const button=el('loginSubmit');
  if(!state.client){el('loginStatus').textContent='Кіру жүйесі әлі дайын емес. Бетті жаңартыңыз.';return;}
  const teacher=el('loginRole').value==='teacher',login=el('loginName').value.trim().toLowerCase();
  if(!teacher&&!/^[a-z][a-z0-9_]{2,23}$/.test(login)){el('loginStatus').textContent='Мұғалім берген логинді енгізіңіз.';return;}
  button.disabled=true;el('loginStatus').textContent='Тексерілуде…';
  try {
    const {data,error}=await state.client.auth.signInWithPassword({email:teacher?login:studentEmail(login),password:el('loginPassword').value});
    if(error)throw Error('Логин немесе құпиясөз дұрыс емес.');
    // SIGNED_IN restores the session; explicitly handle same-user reauthentication.
    if(data.session&&state.user?.id===data.session.user.id)await restoreAccount(data.session);
  }catch(error){el('loginStatus').textContent=error.message;}
  finally{el('loginPassword').value='';button.disabled=false;}
});
el('loginRole').addEventListener('change',()=>{
  const input=el('loginName');el('loginLabel').firstChild.textContent=el('loginRole').value==='teacher'?'Электрондық пошта':'Логин';
  input.type=el('loginRole').value==='teacher'?'email':'text';input.value='';el('loginStatus').textContent='';
});
el('logout').addEventListener('click',async()=>{
  const client=state.client;clearAccount();
  try {const {error}=await client.auth.signOut();if(error){notice('Сеансты серверде жабу орындалмады. Қайта шығуды орындаңыз.',true);el('logout').hidden=false;}}
  catch{notice('Шығу кезінде байланыс қатесі болды. Қайта шығуды орындаңыз.',true);el('logout').hidden=false;}
});
async function loadStudents() {
  if(state.profile?.role!=='teacher')return;
  const epoch=state.epoch;
  try {
    const {students}=await api('/api/students');if(epoch!==state.epoch)return;
    const linked=new Set((state.workspace?.roster||[]).map(s=>s.username));
    el('studentsTable').replaceChildren(renderTable(['Логин','Оқушы','Сынып','Оқу тобы'],students.map(s=>{
      if(linked.has(s.username))return [s.username,s.full_name,s.class_name,'Топта'];
      const b=node('button','Топқа қосу','button secondary small');b.type='button';
      b.addEventListener('click',async()=>{b.disabled=true;try{await api('/api/students',{method:'POST',body:JSON.stringify({action:'enroll',username:s.username})});if(epoch!==state.epoch)return;await refreshWorkspace();await loadStudents();}catch(error){if(epoch===state.epoch)el('adminStatus').textContent=error.message;b.disabled=false;}});
      return [s.username,s.full_name,s.class_name,b];
    })));
  }catch(error){if(epoch===state.epoch)el('adminStatus').textContent=error.message;}
}
el('refreshStudents').addEventListener('click',loadStudents);
el('createStudentForm').addEventListener('submit',async event=>{
  event.preventDefault();if(state.profile?.role!=='teacher')return;
  const epoch=state.epoch,button=event.currentTarget.querySelector('button[type=submit]');button.disabled=true;
  el('adminStatus').textContent='Аккаунт жасалуда…';
  try {
    const result=await api('/api/students',{method:'POST',body:JSON.stringify({action:'create',username:el('newLogin').value.trim().toLowerCase(),full_name:el('newFullName').value.trim(),class_name:el('newGrade').value,password:el('newPassword').value})});
    if(epoch!==state.epoch)return;
    el('adminStatus').textContent=result.warning||'Аккаунт жасалды және оқу тобына қосылды. Логин мен құпиясөзді оқушыға қауіпсіз түрде беріңіз.';
    await refreshWorkspace();await loadStudents();
  }catch(error){if(epoch===state.epoch)el('adminStatus').textContent=error.message;}
  finally{el('newPassword').value='';button.disabled=false;}
});
setupSupabase();
