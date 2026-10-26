'use strict';
let editingTask=null,passwordStudent=null;
const editFields=['title','prompt','given_data','find_value','unit','code','answer','explanation'];
function resetManagement(){
 editingTask=null;passwordStudent=null;
 for(const id of ['taskEditor','passwordDialog'])if(el(id).open)el(id).close();
 el('taskEditorForm').reset();el('passwordForm').reset();el('editorTaskId').textContent='';el('editorStatus').textContent='';el('passwordStatus').textContent='';
}
async function openTaskEditor(id){
 const epoch=state.epoch;editingTask=null;el('taskEditorForm').reset();el('editorStatus').textContent='Жүктелуде…';el('taskEditor').showModal();
 try{const {task}=await api('/api/tasks?id='+encodeURIComponent(id));if(epoch!==state.epoch)return;editingTask=task;
  el('editorTaskId').textContent=task.id+' · v'+task.revision;for(const k of editFields)el('edit-'+k).value=task[k]||'';
  for(const k of ['steps','formulas'])el('edit-'+k).value=task[k].join('\n');el('edit-answer_format').value=task.answer_format;
  el('editorStatus').textContent='Өзгеріс жаңа нұсқа ретінде сақталады. Бұрынғы нәтижелер өзгермейді.';
 }catch(e){if(epoch===state.epoch)el('editorStatus').textContent=e.message;}
}
el('closeEditor').addEventListener('click',()=>{el('taskEditor').close();el('taskEditorForm').reset();editingTask=null;});
el('taskEditorForm').addEventListener('submit',async e=>{
 e.preventDefault();if(!editingTask)return;const epoch=state.epoch,button=el('saveTask');button.disabled=true;
 try{const body={task_id:editingTask.id,revision:editingTask.revision,answer_format:el('edit-answer_format').value};for(const k of editFields)body[k]=el('edit-'+k).value;
  for(const k of ['steps','formulas'])body[k]=el('edit-'+k).value.split('\n').map(x=>x.trim()).filter(Boolean);
  const r=await api('/api/tasks',{method:'POST',body:JSON.stringify(body)});if(epoch!==state.epoch)return;
  await refreshWorkspace();el('taskEditor').close();el('taskEditorForm').reset();editingTask=null;el('adminStatus').textContent='Тапсырманың v'+r.revision+' нұсқасы сақталды.';
 }catch(error){if(epoch===state.epoch)el('editorStatus').textContent=error.message;}finally{button.disabled=false;}
});
function resetStudentPassword(student){
 passwordStudent=student;el('passwordForm').reset();el('passwordHeading').textContent=student.full_name+' — жаңа құпиясөз';el('currentPasswordRow').hidden=true;el('passwordStatus').textContent='Оқушы жаңа құпиясөзбен қайта кіреді. Аккаунт пен нәтижелер сақталады.';el('passwordDialog').showModal();
}
el('changePassword').addEventListener('click',()=>{
 passwordStudent=null;el('passwordForm').reset();el('passwordHeading').textContent='Құпиясөзді өзгерту';el('currentPasswordRow').hidden=false;el('passwordStatus').textContent='Өзгерткеннен кейін қайта кіресіз.';el('passwordDialog').showModal();
});
el('closePassword').addEventListener('click',()=>{el('passwordDialog').close();el('passwordForm').reset();passwordStudent=null;});
el('passwordForm').addEventListener('submit',async e=>{
 e.preventDefault();const password=el('updatedPassword').value;if(password!==el('confirmPassword').value){el('passwordStatus').textContent='Жаңа құпиясөздер сәйкес келмеді.';return;}
 const epoch=state.epoch,student=passwordStudent,button=el('savePassword');button.disabled=true;
 try{const body=student?{action:'reset_password',username:student.username,password}:{current:el('currentPassword').value,password};
  await api(student?'/api/students':'/api/password',{method:'POST',body:JSON.stringify(body)});if(epoch!==state.epoch)return;
  el('passwordDialog').close();el('passwordForm').reset();passwordStudent=null;
  if(student)notice('Оқушының құпиясөзі жаңартылды.');else{
   try{await state.client.auth.signOut({scope:'global'});}catch{}clearAccount();notice('Құпиясөз жаңартылды. Жаңа құпиясөзбен қайта кіріңіз.');
  }
 }catch(error){if(epoch===state.epoch)el('passwordStatus').textContent=error.message;}finally{button.disabled=false;}
});
el('enrollStudentForm').addEventListener('submit',async e=>{
 e.preventDefault();const epoch=state.epoch,button=e.currentTarget.querySelector('button');button.disabled=true;
 try{await api('/api/students',{method:'POST',body:JSON.stringify({action:'enroll',username:el('enrollUsername').value.trim().toLowerCase()})});if(epoch!==state.epoch)return;await refreshWorkspace();await loadStudents();el('adminStatus').textContent='Оқушы оқу тобына қосылды.';}
 catch(error){if(epoch===state.epoch)el('adminStatus').textContent=error.message;}finally{button.disabled=false;}
});
el('downloadResults').addEventListener('click',async()=>{
 const epoch=state.epoch,button=el('downloadResults');button.disabled=true;
 try{const {data:{session}}=await state.client.auth.getSession();if(!session)throw Error('Жүйеге қайта кіріңіз.');
  const response=await fetch('/api/results',{headers:{Authorization:'Bearer '+session.access_token},cache:'no-store'});if(!response.ok)throw Error('Нәтижелер жүктелмеді. Қайта көріңіз.');const blob=await response.blob();if(epoch!==state.epoch)return;
  const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='bilimai-results.csv';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
 }catch(error){if(epoch===state.epoch)notice(error.message,true);}finally{button.disabled=false;}
});
