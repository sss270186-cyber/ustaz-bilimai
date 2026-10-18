// UI smoke tests use fake Auth and fake API data. They never connect to Supabase.
const {chromium}=require('playwright');const fs=require('node:fs');const http=require('node:http');const assert=require('node:assert/strict');
const {tasks,topics}=require('../scripts/measurement.cjs');
const active=new Map(tasks.map(t=>[t.id,true]));const attempts=[];let nextId=1;
const publicTask=t=>{const {answer,steps,...safe}=t;return {...safe,active:active.get(t.id)};};
const roster=[{id:'student',username:'student01',full_name:'Сынақ оқушысы',class_name:'11'}];
function workspace(role){
 const actor=role==='teacher'?'teacher':'student';
 const relevant=attempts.filter(a=>a.student_id===actor||role==='teacher');
 const first=new Map();for(const a of relevant)if(!first.has(`${a.student_id}/${a.task_id}`))first.set(`${a.student_id}/${a.task_id}`,a);
 const sums=new Map();for(const a of first.values()){const key=`${a.student_id}/${a.level}`;const s=sums.get(key)||{student_id:a.student_id,topic_id:'measurement',level:a.level,attempted:0,first_correct:0,first_wrong:0};s.attempted++;s.first_correct+=Number(a.correct);s.first_wrong+=Number(!a.correct);sums.set(key,s);}
 return {role,topics,tasks:tasks.filter(t=>active.get(t.id)||role==='teacher').map(publicTask),attempts:relevant.toReversed(),summary:[...sums.values()],roster:role==='teacher'?roster:[]};
}
const fakeSDK=`window.supabase={createClient(){let session=null,callback=()=>{};return {auth:{
 onAuthStateChange(fn){callback=fn;return {data:{subscription:{unsubscribe(){}}}}},async getSession(){return {data:{session}}},
 async signInWithPassword({email}){const role=email==='teacher@example.test'?'teacher':'student';session={user:{id:role,email},access_token:'fake-'+role};callback('SIGNED_IN',session);return {data:{session},error:null}},
 async signOut(){session=null;callback('SIGNED_OUT',null);return {error:null}}},from(){return {select(){return {eq(_k,id){return {async single(){return {data:{role:id,full_name:id==='teacher'?'Сынақ мұғалімі':'Сынақ оқушысы',class_name:'11'},error:null}}}}}}}}}}};`;
const config=JSON.parse(fs.readFileSync('vercel.json'));
const server=http.createServer(async(req,res)=>{
 for(const h of config.headers[0].headers)res.setHeader(h.key,h.value);
 const send=(data,status=200)=>{res.statusCode=status;res.setHeader('Content-Type','application/json');res.end(JSON.stringify(data));};
 if(req.url==='/api/config')return send({url:'https://fake.supabase.co',publishableKey:'fake-public'});
 if(req.url==='/api/learning'){
  const role=req.headers.authorization==='Bearer fake-teacher'?'teacher':'student';
  if(req.method==='GET')return send(workspace(role));
  let body='';for await(const chunk of req)body+=chunk;body=JSON.parse(body);
  if(body.action==='set_active'){assert.equal(role,'teacher');active.set(body.task_id,body.active);return send({ok:true});}
  const task=tasks.find(t=>t.id===body.task_id),correct=Number(body.answer.replaceAll(' ','').replace(',','.'))===Number(task.answer);
  attempts.push({id:nextId++,student_id:role,task_id:task.id,submitted_answer:body.answer,correct,topic_id:'measurement',level:task.level,created_at:new Date().toISOString()});
  return send({correct,answer:task.answer,unit:task.unit,steps:task.steps});
 }
 if(req.url==='/api/students'){
  if(req.method==='GET')return send({students:roster});
  return send({ok:true,enrolled:true},201);
 }
 const paths={'/':'index.html','/index.html':'index.html','/assets/style.css':'assets/style.css','/assets/app.js':'assets/app.js','/student.js':'student.js'};
 const file=paths[req.url];if(!file){res.statusCode=404;return res.end('Not found');}
 res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(file));
});
(async()=>{
 let browser;
 try {
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const base=`http://127.0.0.1:${server.address().port}`;
  browser=await chromium.launch({headless:true,...(process.env.BROWSER_EXECUTABLE?{executablePath:process.env.BROWSER_EXECUTABLE}:{})});
  const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://cdn.jsdelivr.net/**',route=>route.fulfill({contentType:'application/javascript',body:fakeSDK}));
  await page.goto(base);await page.waitForFunction(()=>state.client!==null);
  assert.equal(await page.locator('.topic-button').count(),19);
  assert.equal(await page.locator('#taskList').textContent(),'');
  assert.equal((await page.request.get(base+'/scripts/measurement.cjs')).status(),404);
  if(process.env.UI_SCREENSHOT_DIR){fs.mkdirSync(process.env.UI_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:process.env.UI_SCREENSHOT_DIR+'/desktop.png',fullPage:true});}
  await page.locator('#openLogin').click();await page.locator('#loginName').fill('student01');await page.locator('#loginPassword').fill('fake-password');await page.locator('#loginSubmit').click();
  await page.waitForFunction(()=>state.workspace?.role==='student');await page.locator('[data-view=practice]').click();assert.equal(await page.locator('.task').count(),2);
  await page.locator('#answer-measure-b01').fill('1 792');await page.locator('.task').first().getByRole('button',{name:'Тексеру',exact:true}).click();
  await page.locator('#feedback-measure-b01').getByText('Дұрыс! Нәтиже сақталды.').waitFor();
  await page.locator('#answer-measure-b02').fill('0');await page.locator('.task').nth(1).getByRole('button',{name:'Тексеру',exact:true}).click();
  await page.locator('#feedback-measure-b02').getByText('Дұрыс жауап: 3084 байт').waitFor();
  await page.locator('[data-view=results]').click();assert.deepEqual(await page.locator('.stat b').allTextContents(),['2','1','50%']);
  await page.locator('[data-view=practice]').click();await page.locator('[data-level=C]').click();assert.equal(await page.locator('.task').count(),10);
  await page.locator('#answer-measure-c01').fill('4352,5');await page.locator('.task').first().getByRole('button',{name:'Тексеру',exact:true}).click();await page.locator('#feedback-measure-c01').getByText('Дұрыс! Нәтиже сақталды.').waitFor();
  await page.locator('[data-view=lesson]').click();await page.locator('#lessonTopic').fill('<img src=x onerror=alert(1)>');await page.locator('#lessonForm button').click();assert.equal(await page.locator('#lessonText img').count(),0);assert.match(await page.locator('#lessonText h3').textContent(),/<img/);
  await page.locator('#logout').click();await page.waitForFunction(()=>state.user===null);assert.equal(await page.locator('.feedback').count(),0);
  await page.locator('#openLogin').click();await page.locator('#loginRole').selectOption('teacher');await page.locator('#loginName').fill('teacher@example.test');await page.locator('#loginPassword').fill('fake-password');await page.locator('#loginSubmit').click();
  await page.waitForFunction(()=>state.workspace?.role==='teacher');await page.locator('#studentsTab').click();await page.locator('#studentsTable').getByText('student01').waitFor();assert.equal(await page.locator('.admin-task').count(),12);
  await page.locator('.admin-task').first().getByRole('button',{name:'Жасыру'}).click();await page.waitForFunction(()=>state.workspace.tasks[0].active===false);
  await page.locator('[data-view=results]').click();assert.match(await page.locator('#resultList').textContent(),/Сынақ оқушысы/);
  await page.locator('#logout').click();await page.waitForFunction(()=>state.user===null);
  await page.setViewportSize({width:390,height:844});await page.locator('#topicToggle').click();await page.locator('[data-topic=hardware]').click();assert.equal(await page.locator('#pending').isVisible(),true);
  await page.locator('#returnMeasurement').click();assert.equal(await page.locator('#theory').isVisible(),true);
  const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>window.innerWidth);assert.equal(overflow,false);
  if(process.env.UI_SCREENSHOT_DIR)await page.screenshot({path:process.env.UI_SCREENSHOT_DIR+'/mobile.png',fullPage:true});
  assert.deepEqual(errors,[]);console.log('UI smoke passed: guest theory, student login, B/C grading, results, teacher roster and visibility, logout, QMJ escaping, mobile navigation and width. Auth/API are fixtures.');
 }finally{if(browser)await browser.close();await new Promise(resolve=>server.close(resolve));}
})().catch(e=>{console.error(e);process.exitCode=1;});
