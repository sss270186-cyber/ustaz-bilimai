'use strict';
const el = id => document.getElementById(id);
const state = {client:null,user:null,profile:null,workspace:null,topic:'measurement',level:'B',view:'theory',epoch:0,loading:false};
const topicNames = ['Аппараттық жасақтама','Программалық жасақтама','Компьютер жады','Ақпаратты өлшеу','Ақпарат көлемін алфавиттік тәсілмен есептеу','Ақпаратты кодтау: екілік код, ASCII, Unicode','Санау жүйелері','Компьютерлік желілер','Желінің өткізу қабілеті','IP-адрестер және маска','DNS — домендік атаулар жүйесі','Логикалық элементтер, блок-схемалар, ақиқат кестелері','Электрондық кестелер: формулалар, форматтау және сілтемелер','Python: алгоритмдер, тізімдер, массивтер, сұрыптау','Python функциялары мен процедуралары','HTML және CSS','SQL дерекқорлары','Жасанды интеллект','Нейрондық желілер'];
const topicIds = ['hardware','software','memory','measurement','alphabet','encoding','number-systems','networks','bandwidth','ip','dns','logic','spreadsheets','python','functions','html-css','sql','ai','neural-networks'];
function node(tag,text,className) { const n=document.createElement(tag); if(text!==undefined)n.textContent=text; if(className)n.className=className; return n; }
function notice(text,error=false) { el('workspaceStatus').textContent=text;el('workspaceStatus').classList.toggle('error',error); }
function empty(target,text) {target.replaceChildren(node('p',text,'panel empty'));}
function selectedTopic(id) {
  state.topic=id;
  const index=topicIds.indexOf(id), ready=id==='measurement'||Boolean(window.LESSONS?.[id]);
  el('topicTitle').textContent=topicNames[index];el('crumb').textContent=topicNames[index];
  el('topicIndex').textContent=`${String(index).padStart(2,'0')} / 19 · ТАҚЫРЫП`;
  el('topicDescription').textContent=id==='measurement'?'Биттен гигабайтқа дейін. Өлшем бірліктерін түсініп, көпқадамды есептерді сенімді шығар.':window.LESSONS?.[id]?.summary||'Тақырып жүктелмеді.';
  document.querySelector('.hero-tags').hidden=!ready;
  document.querySelector('.bit-visual').hidden=id!=='measurement';
  renderTheory(id);
  document.querySelectorAll('.topic-button').forEach(b=>{const current=b.dataset.topic===id;b.classList.toggle('selected',current);current?b.setAttribute('aria-current','page'):b.removeAttribute('aria-current');});
  el('topicList').classList.remove('open');el('topicToggle').setAttribute('aria-expanded','false');
  showView('theory');
}
function renderTopics() {
  el('topicList').replaceChildren(...topicNames.map((title,index)=>{
    const b=node('button',undefined,'topic-button');b.type='button';b.dataset.topic=topicIds[index];
    b.append(node('span',String(index).padStart(2,'0'),'number'),node('span',title,'topic-name'));
    b.append(node('span','2B · 10C','soon'));
    b.addEventListener('click',()=>selectedTopic(topicIds[index]));return b;
  }));
}
function showView(view) {
  if(view==='students' && state.profile?.role!=='teacher')return;
  state.view=view;
  const pending=state.topic!=='measurement'&&!window.LESSONS?.[state.topic]&&['theory','practice'].includes(view);
  el('pending').hidden=!pending;
  document.querySelectorAll('.view').forEach(n=>n.hidden=pending||n.id!==view);
  document.querySelectorAll('[data-view]').forEach(b=>{b.classList.toggle('active',b.dataset.view===view);b.dataset.view===view?b.setAttribute('aria-current','page'):b.removeAttribute('aria-current');});
  if(view==='practice')renderTasks();
  if(view==='results')renderResults();
  if(view==='students'){loadStudents();renderTaskAdmin();}
}
async function api(path,options={}) {
  if(!state.client)throw Error('Кіру жүйесі әлі дайын емес');
  const {data:{session},error}=await state.client.auth.getSession();
  if(error||!session)throw Error('Жүйеге қайта кіріңіз');
  const response=await fetch(path,{...options,headers:{'Authorization':`Bearer ${session.access_token}`,'Content-Type':'application/json'},cache:'no-store'});
  const data=await response.json().catch(()=>({}));
  if(!response.ok)throw Error(data.error||'Сервер сұрауы орындалмады');
  return data;
}
async function refreshWorkspace() {
  if(!state.user)return;
  const epoch=state.epoch;
  notice('Тапсырмалар мен нәтижелер жүктелуде…');
  try {
    const data=await api('/api/learning');
    if(epoch!==state.epoch)return;
    state.workspace=data;
    // Server-owned role is authoritative for learning management.
    if(data.role!==state.profile?.role)state.profile={...state.profile,role:data.role};
    updateAccount();renderTasks();renderResults();renderTaskAdmin();
    notice('Жеке кабинет қосылды. Әр жауап тексерілгенде нәтиже дерекқорға сақталады.');
  } catch(error) {if(epoch===state.epoch){state.workspace=null;notice(error.message,true);renderTasks();renderResults();renderTaskAdmin();}}
}
function renderTasks() {
  const target=el('taskList');
  if(!state.user){empty(target,'Тапсырмаларды ашу үшін жеке логиніңізбен кіріңіз.');return;}
  if(!state.workspace){empty(target,'Тапсырмалар жүктелмеді. Жоғарыдағы хабарламаны тексеріп, нәтижелер бөліміндегі «Жаңарту» батырмасын басыңыз.');return;}
  const tasks=state.workspace.tasks.filter(t=>t.topic_id===state.topic&&t.level===state.level&&t.active);
  if(!tasks.length){empty(target,'Бұл деңгейдегі тапсырмалар уақытша жасырылған.');return;}
  target.replaceChildren(...tasks.map(t=>{
    const card=node('article',undefined,'panel task');
    const top=node('div',undefined,'task-top');top.append(node('span',`${t.level} ДЕҢГЕЙІ · ${String(t.position).padStart(2,'0')}`,'badge'),node('span',t.id,'task-id'));
    card.append(top,node('h3',t.title),node('p',t.prompt,'task-prompt'));
    if(t.code){const pre=node('pre',undefined,'code-block');pre.append(node('code',t.code));card.append(pre);}
    const info=node('div',undefined,'task-data');
    [['Берілгені',t.given_data],['Табу керек',t.find_value]].forEach(([label,value])=>{const n=node('div');n.append(node('strong',label),node('p',value));info.append(n);});
    card.append(info,node('strong','Формула / ереже'),node('div',t.formulas.join('\n'),'task-formulas'));
    const form=node('form',undefined,'answer-row'), label=node('label',t.answer_format==='number'?'Сандық жауап':'Жауап'), input=node('input');
    input.id=`answer-${t.id}`;input.name='answer';input.type='text';input.inputMode=t.answer_format==='number'?'decimal':'text';input.required=true;input.maxLength=t.answer_format==='number'?64:256;input.autocomplete='off';label.htmlFor=input.id;label.append(input);
    const unit=node('span',t.unit,'answer-unit'), button=node('button','Тексеру','button');button.type='submit';
    const feedback=node('div');feedback.id=`feedback-${t.id}`;feedback.setAttribute('role','status');input.setAttribute('aria-describedby',feedback.id);
    form.append(label,unit,button);card.append(form,feedback);
    const epoch=state.epoch;
    form.addEventListener('submit',async event=>{
      event.preventDefault();if(button.disabled)return;
      button.disabled=true;button.textContent='Тексерілуде…';feedback.replaceChildren();
      try {
        const result=await api('/api/learning',{method:'POST',body:JSON.stringify({action:'grade',task_id:t.id,answer:input.value})});
        if(epoch!==state.epoch)return;
        feedback.className=`feedback${result.correct?'':' incorrect'}`;
        feedback.append(node('p',result.correct?'Дұрыс! Нәтиже сақталды.':'Жауап сәйкес келмеді. Нәтиже сақталды.'),node('strong',`Дұрыс жауап: ${result.answer} ${result.unit}`));
        if(!result.correct&&result.feedback)feedback.append(node('h4','Қатені талдау'),node('p',result.feedback));
        feedback.append(node('h4','Шешуі'));
        const steps=node('ol');result.steps.forEach(s=>steps.append(node('li',s)));feedback.append(steps);
        if(result.explanation)feedback.append(node('h4','Түсіндірме'),node('p',result.explanation));
        // Refresh the cached statistics without replacing this task and its explanation.
        try {const workspace=await api('/api/learning');if(epoch===state.epoch){state.workspace=workspace;renderResults();}}catch{notice('Жауап сақталды. Статистиканы жаңарту үшін «Жаңарту» батырмасын басыңыз.',true);}
      }catch(error){if(epoch===state.epoch){feedback.className='feedback incorrect';feedback.append(node('p',error.message));}}
      finally{button.disabled=false;button.textContent='Тексеру';}
    });
    return card;
  }));
}
function renderTable(headers,rows) {
  const wrap=node('div',undefined,'table-scroll'),table=node('table'),thead=node('thead'),tr=node('tr'),tbody=node('tbody');
  headers.forEach(h=>{const th=node('th',h);th.scope='col';tr.append(th);});thead.append(tr);table.append(thead,tbody);
  rows.forEach(values=>{const row=node('tr');values.forEach(v=>{const td=node('td');v instanceof Node?td.append(v):td.textContent=String(v??'');row.append(td);});tbody.append(row);});
  wrap.append(table);return wrap;
}
function formatTime(date){return new Intl.DateTimeFormat('kk-KZ',{dateStyle:'short',timeStyle:'short',timeZone:'Asia/Qyzylorda'}).format(new Date(date));}
function renderResults() {
  const target=el('resultList'),summaryTarget=el('resultSummary');summaryTarget.replaceChildren();target.replaceChildren();
  const teacher=state.profile?.role==='teacher';el('resultsTitle').textContent=teacher?'Оқушылардың нәтижелері':'Менің нәтижелерім';
  if(!state.workspace){empty(target,state.user?'Нәтижелер әлі жүктелмеді. «Жаңарту» батырмасын басыңыз.':'Нәтижелерді көру үшін жүйеге кіріңіз.');renderLegacy();return;}
  const ws=state.workspace, roster=new Map(ws.roster.map(p=>[p.id,p]));
  const own=ws.summary.filter(s=>teacher?s.student_id!==state.user.id:s.student_id===state.user.id);
  const attempted=own.reduce((a,s)=>a+s.attempted,0), correct=own.reduce((a,s)=>a+s.first_correct,0);
  const stats=node('div',undefined,'stats');
  [[attempted,'Орындалған есеп'],[correct,'Алғашқыда дұрыс'],[attempted?Math.round(correct/attempted*100)+'%':'—','Алғашқы әрекет дәлдігі']].forEach(([value,label])=>{const n=node('div',undefined,'stat');n.append(node('b',String(value)),node('span',label));stats.append(n);});summaryTarget.append(stats);
  summaryTarget.append(node('p','Алғашқы әрекет әр есептің әр нұсқасына бір рет саналады. Қайталау кезінде шешім бұрын көрілген болуы мүмкін. Мұғалімнің өзінің сынақ әрекеттері оқушы есебіне қосылмайды.','muted'));
  if(teacher && ws.roster.length===0)target.append(node('p','Топта оқушы жоқ. «Оқушылар» бөлімінен бұрын тіркелген оқушыларды топқа қосыңыз.','panel'));
  if(own.length){
    const panel=node('article',undefined,'panel');panel.append(node('h3',teacher?'Қате кеткен тақырыптар':'Тақырып пен деңгей бойынша'));
    panel.append(renderTable(teacher?['Оқушы','Тақырып / деңгей','Орындалған','Алғашқы қате']:['Тақырып / деңгей','Орындалған','Алғашқы қате'],own.map(s=>{
      const values=[`${topicNames[topicIds.indexOf(s.topic_id)]||s.topic_id} · ${s.level}`,s.attempted,s.first_wrong];
      return teacher?[roster.get(s.student_id)?.full_name||'Оқушы',...values]:values;
    })));target.append(panel);
  }
  const attempts=ws.attempts.filter(a=>!teacher||a.student_id!==state.user.id);
  if(attempts.length){const panel=node('article',undefined,'panel');panel.append(node('h3','Соңғы әрекеттер'),node('p','Соңғы 200 әрекетке дейін көрсетіледі. Жоғарыдағы статистика бүкіл тарихтың алғашқы әрекеттерінен есептеледі. Уақыт: Қызылорда.','muted'));
    panel.append(renderTable(teacher?['Оқушы','Есеп','Жауап','Нәтиже','Уақыты']:['Есеп','Жауап','Нәтиже','Уақыты'],attempts.map(a=>{
      const values=[a.task_id+(a.task_revision?' · v'+a.task_revision:''),a.submitted_answer,a.correct?'Дұрыс':'Қате',formatTime(a.created_at)];return teacher?[roster.get(a.student_id)?.full_name||'Оқушы',...values]:values;
    })));target.append(panel);
  }else empty(target,'Әзірге орындалған тапсырма жоқ.');
  renderLegacy();
}
function renderLegacy() {
  const target=el('legacyResults');target.replaceChildren();
  if(state.profile?.role!=='teacher'){target.append(node('p','Жергілікті демо тарихы мұғалім кіргенде көрсетіледі.'));return;}
  try {const data=JSON.parse(localStorage.getItem('bilimai_results')||'[]');
    if(!Array.isArray(data)||!data.length){target.append(node('p','Бұл браузерде демо нәтижелер жоқ.'));return;}
    target.append(renderTable(['Оқушы','Сынып','Ұпай','Уақыты'],data.slice(-200).map(x=>[x.name,x.grade,`${x.score}/${x.total}`,x.date])));
  }catch{target.append(node('p','Бұрынғы деректерді оқу мүмкін болмады. Сақталған деректер өзгертілген жоқ.'));}
}
function renderTaskAdmin() {
  const target=el('taskAdmin');target.replaceChildren();
  if(state.profile?.role!=='teacher'||!state.workspace)return;
  state.workspace.tasks.filter(t=>t.topic_id===state.topic).forEach(t=>{
    const row=node('div',undefined,'admin-task'),button=node('button',t.active?'Жасыру':'Ашу','button secondary small');button.type='button';
    row.append(node('span',`${t.level}${t.position} · ${t.title}${t.active?'':' · жасырылған'}`),button);
    button.addEventListener('click',async()=>{button.disabled=true;try{await api('/api/learning',{method:'POST',body:JSON.stringify({action:'set_active',task_id:t.id,active:!t.active})});await refreshWorkspace();}catch(e){el('adminStatus').textContent=e.message;button.disabled=false;}});target.append(row);
  });
}
function updateAccount() {
  const logged=Boolean(state.user),teacher=state.profile?.role==='teacher';
  el('accountName').textContent=logged?(state.profile?.full_name||state.user.email||'Жеке кабинет'):'Жеке дайындық алаңы';
  el('openLogin').hidden=logged;el('logout').hidden=!logged;el('studentsTab').hidden=!teacher;
  if(!teacher&&state.view==='students')showView('theory');
}
function clearAccount() {
  state.epoch++;state.user=null;state.profile=null;state.workspace=null;
  el('loginPassword').value='';el('newPassword').value='';el('newFullName').value='';el('newLogin').value='';el('adminStatus').textContent='';
  el('studentsTable').replaceChildren();el('taskAdmin').replaceChildren();
  updateAccount();renderTasks();renderResults();notice('Жеке кабинеттен шықтыңыз. Теорияны оқуды жалғастыра аласыз.');
}
function makeLesson(event){
  event.preventDefault();const target=el('lessonText');target.replaceChildren(node('h3',el('lessonTopic').value.trim()||'Информатика'));
  [['Мақсат','Тақырыптың негізгі ұғымдарын түсіндіру және практикалық есептер шығару.'],['Сабақ барысы (45 минут)','Ұйымдастыру — 3 мин; түсіндіру — 12 мин; тәжірибе — 20 мин; бағалау — 7 мин; рефлексия — 3 мин.'],['Бағалау','Дұрыс жауап, есептеу жолы және түсіндіру.']].forEach(([title,text])=>{const p=node('p');p.append(node('b',title+': '),document.createTextNode(text));target.append(p);});
}
const measurementTheory=[...el('theory').childNodes].map(n=>n.cloneNode(true));
function appendTheoryReview(id,target){
 const r=window.THEORY_REVIEW?.[id];if(!r)return;const p=node('article',undefined,'panel');p.append(node('span','КҮРДЕЛІ ЕСЕПКЕ ДАЙЫНДЫҚ','eyebrow'),node('h3',r.scope),node('p',r.limits),node('p',r.example,'worked'),node('p',r.method));target.append(p);
}
function renderTheory(id){
 const target=el('theory');
 if(id==='measurement'){target.replaceChildren(...measurementTheory.map(n=>n.cloneNode(true)));appendTheoryReview(id,target);target.querySelector('#startPractice')?.addEventListener('click',()=>{showView('practice');el('content').focus();});return;}
 const lesson=window.LESSONS?.[id];if(!lesson){empty(target,'Теория файлы жүктелмеді. Бетті жаңартыңыз.');return;}
 const head=node('div',undefined,'section-heading');head.append(node('h2',topicNames[topicIds.indexOf(id)]));target.replaceChildren(head);
 const goals=node('article',undefined,'panel');goals.append(node('span','САБАҚ МАҚСАТТАРЫ','eyebrow'));const ul=node('ul');lesson.goals.forEach(g=>ul.append(node('li',g)));goals.append(ul);target.append(goals);
 lesson.sections.forEach((section,i)=>{const p=node('article',undefined,'panel');p.append(node('span',String(i+1).padStart(2,'0')+' / ТЕОРИЯ','chapter'),node('h3',section.title));section.paragraphs.forEach(text=>p.append(node('p',text)));if(section.formulas.length)p.append(node('pre',section.formulas.join('\n'),'formula'));if(section.example)p.append(node('p',section.example,'worked'));target.append(p);});
 appendTheoryReview(id,target);
 const check=node('article',undefined,'panel');check.append(node('h3','Өзіңді тексер'));const list=node('ul');lesson.checks.forEach(text=>list.append(node('li',text)));check.append(list);
 const button=node('button','Тапсырмаларға өту →','button');button.addEventListener('click',()=>{showView('practice');el('content').focus();});check.append(button,node('p','Авторлық ҰБТ дайындық материалы. Тапсырма жауаптары жеке тексеруден кейін ашылады.','muted'));
 const source=node('a',lesson.source[0]);source.href=lesson.source[1];source.target='_blank';source.rel='noopener noreferrer';check.append(source);target.append(check);
}
renderTopics();selectedTopic('measurement');
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>showView(b.dataset.view)));
document.querySelectorAll('[data-level]').forEach(b=>b.addEventListener('click',()=>{state.level=b.dataset.level;document.querySelectorAll('[data-level]').forEach(n=>n.setAttribute('aria-pressed',String(n===b)));renderTasks();}));
el('topicToggle').addEventListener('click',()=>{const open=el('topicList').classList.toggle('open');el('topicToggle').setAttribute('aria-expanded',String(open));});
el('openLogin').addEventListener('click',()=>el('loginDialog').showModal());el('closeLogin').addEventListener('click',()=>el('loginDialog').close());
el('returnMeasurement').addEventListener('click',()=>selectedTopic('measurement'));
el('refreshResults').addEventListener('click',refreshWorkspace);el('lessonForm').addEventListener('submit',makeLesson);
