// Ustaz BilimAI 2.1 - login + teacher-managed accounts
const studentEmail = login => `${login.toLowerCase()}@students.ustaz-bilimai.example.com`;
const studentMsg = text => document.getElementById('studentStatus').textContent=text;
async function restoreStudent(session){
  if(!session || !supabaseClient)return;
  const {data,error}=await supabaseClient.from('profiles').select('full_name,class_name,role').eq('id',session.user.id).single();
  if(error||data?.role!=='student'){studentMsg('Оқушы профилі табылмады.');return;}
  student={name:data.full_name,grade:data.class_name};
  document.getElementById('studentLogin').classList.remove('hide');
  studentMsg(`${data.full_name}, қош келдіңіз! Демо тестке кіре аласыз.`);
  renderQuiz();show('quiz');
}
async function loginStudent(){
  if(!supabaseClient){studentMsg('Supabase байланысы дайын емес. Бетті жаңартыңыз.');return;}
  const login=document.getElementById('studentUsername').value.trim().toLowerCase();
  const password=document.getElementById('studentPassword').value;
  if(!/^[a-z][a-z0-9_]{2,23}$/.test(login)||!password){studentMsg('Логин немесе құпиясөз дұрыс енгізілмеген.');return;}
  studentMsg('Тексерілуде...');
  const {data,error}=await supabaseClient.auth.signInWithPassword({email:studentEmail(login),password});
  document.getElementById('studentPassword').value='';
  if(error){studentMsg('Логин немесе құпиясөз дұрыс емес.');return;}
  await restoreStudent(data.session);
}
async function logoutStudent(){if(supabaseClient)await supabaseClient.auth.signOut();student=null;document.getElementById('quiz').classList.add('hide');studentMsg('Жүйеден шықтыңыз.');}
async function teacherRequest(method,body){
  const {data:{session}}=await supabaseClient.auth.getSession();
  if(!session)throw Error('Мұғалім ретінде қайта кіріңіз.');
  const res=await fetch('/api/students',{method,headers:{'Authorization':`Bearer ${session.access_token}`,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,cache:'no-store'});
  const data=await res.json().catch(()=>({}));
  if(!res.ok)throw Error(data.error||'Сервер қатесі');
  return data;
}
async function createStudentAccount(){
  const el=id=>document.getElementById(id);
  const username=el('newLogin').value.trim().toLowerCase(),full_name=el('newFullName').value.trim(),class_name=el('newGrade').value,password=el('newPassword').value;
  if(!/^[a-z][a-z0-9_]{2,23}$/.test(username)){el('adminStatus').textContent='Логин 3–24 таңба: латын әріптері, сандар, _. Бірінші таңба — әріп.';return;}
  if(full_name.length<2||password.length<12){el('adminStatus').textContent='Аты-жөнін және кемінде 12 таңбалы құпиясөзді енгізіңіз.';return;}
  el('adminStatus').textContent='Аккаунт жасалуда...';
  try{await teacherRequest('POST',{username,full_name,class_name,password});el('newPassword').value='';el('adminStatus').textContent='Аккаунт жасалды. Логин мен құпиясөзді оқушыға қауіпсіз түрде беріңіз.';await loadStudents();}
  catch(e){el('adminStatus').textContent='Қате: '+e.message;}
}
async function loadStudents(){
  const target=document.getElementById('studentsTable');
  if(!teacherSession)return;
  try{const {students}=await teacherRequest('GET');target.replaceChildren();
    const table=document.createElement('table');
    const header=document.createElement('tr');['Логин','Оқушы','Сынып'].forEach(s=>{const th=document.createElement('th');th.textContent=s;header.append(th)});table.append(header);
    students.forEach(item=>{const tr=document.createElement('tr');[item.username,item.full_name,item.class_name].forEach(s=>{const td=document.createElement('td');td.textContent=s||'';tr.append(td)});table.append(tr)});target.append(table);
  }catch(e){document.getElementById('adminStatus').textContent='Тізім: '+e.message;}
}
