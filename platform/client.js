// Real server sessions and durable records; no browser-owned roles or result history.
(()=>{
 let callback=()=>{};
 const call=async(path,body)=>{const r=await fetch(path,{method:body?'POST':'GET',credentials:'same-origin',cache:'no-store',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});const data=await r.json().catch(()=>({}));return {r,data};};
 const session=user=>user?{access_token:'http-only-session',user:{id:user.id,email:user.email||user.username}}:null;
 window.supabase={createClient(){return {auth:{
  onAuthStateChange(fn){callback=fn;return {data:{subscription:{unsubscribe(){}}}};},
  async getSession(){try{const {r,data}=await call('/api/account');return {data:{session:r.ok?session(data.user):null},error:null};}catch{return {data:{session:null},error:{message:'Байланыс үзілді.'}};}},
  async signInWithPassword({email,password}){const {r,data}=await call('/api/login',{email,password});if(!r.ok)return {data:{},error:{message:data.error}};const s=session(data.user);callback('SIGNED_IN',s);return {data:{session:s},error:null};},
  async signOut(){const {r,data}=await call('/api/logout',{});if(!r.ok)return {error:{message:data.error}};callback('SIGNED_OUT',null);return {error:null};}
 },from(){return {select(){return {eq(){return {async single(){const {r,data}=await call('/api/account');return {data:r.ok?data.user:null,error:r.ok?null:{message:data.error}};}};}};}};}};}};
 document.addEventListener('DOMContentLoaded',()=>{
  const ownerLink=document.getElementById('ownerLogin'),passwordButton=document.getElementById('changePassword'),download=document.getElementById('downloadResults');
  const update=()=>{ownerLink.hidden=Boolean(state.user);passwordButton.hidden=state.profile?.role!=='student';download.hidden=state.profile?.role!=='teacher';};
  const originalUpdate=updateAccount;updateAccount=function(){originalUpdate();update();};update();
  if(new URL(location.href).searchParams.get('teacher')==='1'){
   history.replaceState(null,'',location.pathname);
   call('/api/owner-login',{}).then(async({r,data})=>{if(!r.ok)throw Error(data.error);clearAccount();await restoreAccount(session(data.user));showView('students');}).catch(e=>notice(e.message,true));
  }
  const originalLoad=loadStudents;
  loadStudents=async function(){
   if(state.profile?.role!=='teacher')return;try{const {students}=await api('/api/students');el('studentsTable').replaceChildren(renderTable(['Логин','Оқушы','Сынып','Құпиясөз'],students.map(s=>{
    const reset=node('button','Жаңарту','button secondary small');reset.type='button';reset.addEventListener('click',()=>openReset(s));return [s.username,s.full_name,s.class_name,reset];
   })));}catch(e){el('adminStatus').textContent=e.message;}
  };
  // The original listener captures the earlier function; replace its DOM button safely.
  const oldRefresh=el('refreshStudents'),fresh=oldRefresh.cloneNode(true);oldRefresh.replaceWith(fresh);fresh.addEventListener('click',()=>loadStudents());
  const originalAdmin=renderTaskAdmin;
  renderTaskAdmin=function(){originalAdmin();if(state.profile?.role!=='teacher'||!state.workspace)return;
   const tasks=state.workspace.tasks.filter(t=>t.topic_id===state.topic);el('taskAdmin').querySelectorAll('.admin-task').forEach((row,i)=>{const edit=node('button','Өңдеу','button secondary small');edit.type='button';edit.addEventListener('click',()=>openTask(tasks[i].id));row.append(edit);});
  };
  const editor=el('taskEditor'),editorForm=el('taskEditorForm');let editing;
  const textKeys=['title','prompt','given_data','find_value','unit','answer','explanation','code'];
  async function openTask(id){el('editorStatus').textContent='Жүктелуде…';editor.showModal();try{const {task}=await api('/api/task-edit?id='+encodeURIComponent(id));editing=task;el('editorTaskId').textContent=task.id+' · v'+task.revision;
   for(const k of textKeys)el('edit-'+k).value=task[k]||'';for(const k of ['steps','formulas'])el('edit-'+k).value=task[k].join('\n');el('edit-answer_format').value=task.answer_format;el('editorStatus').textContent='Өзгеріс жаңа нұсқа ретінде сақталады. Бұрынғы нәтижелер өзгермейді.';
  }catch(e){el('editorStatus').textContent=e.message;}}
  el('closeEditor').addEventListener('click',()=>editor.close());
  editorForm.addEventListener('submit',async e=>{e.preventDefault();if(!editing)return;const button=el('saveTask');button.disabled=true;try{
   const body={task_id:editing.id,revision:editing.revision,answer_format:el('edit-answer_format').value};for(const k of textKeys)body[k]=el('edit-'+k).value;for(const k of ['steps','formulas'])body[k]=el('edit-'+k).value.split('\n').map(s=>s.trim()).filter(Boolean);
   const result=await api('/api/task-edit',{method:'POST',body:JSON.stringify(body)});await refreshWorkspace();editor.close();el('adminStatus').textContent='Тапсырманың v'+result.revision+' нұсқасы сақталды.';
  }catch(error){el('editorStatus').textContent=error.message;}finally{button.disabled=false;}});
  const passDialog=el('passwordDialog');let resetStudent=null;
  function openReset(student){resetStudent=student;el('passwordHeading').textContent=student.full_name+' — жаңа құпиясөз';el('currentPasswordRow').hidden=true;el('passwordStatus').textContent='Оқушы келесі кіруде жаңа құпиясөзді қолданады.';el('passwordForm').reset();passDialog.showModal();}
  passwordButton.addEventListener('click',()=>{resetStudent=null;el('passwordHeading').textContent='Құпиясөзді өзгерту';el('currentPasswordRow').hidden=false;el('passwordStatus').textContent='';el('passwordForm').reset();passDialog.showModal();});
  el('closePassword').addEventListener('click',()=>passDialog.close());
  el('passwordForm').addEventListener('submit',async e=>{e.preventDefault();const password=el('updatedPassword').value;if(password!==el('confirmPassword').value){el('passwordStatus').textContent='Жаңа құпиясөздер сәйкес келмеді.';return;}
   const button=el('savePassword');button.disabled=true;try{
    const path=resetStudent?'/api/students':'/api/password',body=resetStudent?{action:'reset_password',student_id:resetStudent.id,password}:{current:el('currentPassword').value,password};
    await api(path,{method:'POST',body:JSON.stringify(body)});passDialog.close();el('passwordForm').reset();notice('Құпиясөз жаңартылды.');
   }catch(error){el('passwordStatus').textContent=error.message;}finally{button.disabled=false;}
  });
  download.addEventListener('click',async()=>{download.disabled=true;try{const response=await fetch('/api/results.csv',{credentials:'same-origin',cache:'no-store'});if(!response.ok)throw Error('Нәтижелерді жүктеу орындалмады.');const url=URL.createObjectURL(await response.blob());const a=document.createElement('a');a.href=url;a.download='bilimai-results.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);}catch(e){notice(e.message,true);}finally{download.disabled=false;}});
 });
})();
