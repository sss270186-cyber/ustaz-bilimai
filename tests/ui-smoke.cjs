// Real local PostgreSQL grading with a clearly labelled local Auth emulator. No remote service is contacted.
const {chromium}=require('playwright');const fs=require('node:fs');const assert=require('node:assert/strict');
const {startLocal,PASSWORD}=require('../scripts/local-server.cjs');const {topics}=require('../scripts/curriculum.cjs');
(async()=>{
 let browser,app;
 try {
  app=await startLocal();browser=await chromium.launch({headless:true,...(process.env.BROWSER_EXECUTABLE?{executablePath:process.env.BROWSER_EXECUTABLE}:{})});
  const page=await browser.newPage({viewport:{width:1440,height:1000}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(app.origin);await page.waitForFunction(()=>state.client!==null);
  assert.equal(await page.locator('.local-banner').isVisible(),true);assert.equal(await page.locator('.topic-button').count(),19);
  for(const path of ['/scripts/curriculum.cjs','/scripts/local-server.cjs','/supabase/migrations/202610180004_full_curriculum.sql','/app.py'])assert.equal((await page.request.get(app.origin+path)).status(),404);
  if(process.env.UI_SCREENSHOT_DIR){fs.mkdirSync(process.env.UI_SCREENSHOT_DIR,{recursive:true});await page.screenshot({path:process.env.UI_SCREENSHOT_DIR+'/desktop.png',fullPage:true});}
  async function login(role,name,password=PASSWORD){await page.locator('#openLogin').click();await page.locator('#loginRole').selectOption(role);await page.locator('#loginName').fill(name);await page.locator('#loginPassword').fill(password);await page.locator('#loginSubmit').click();await page.waitForFunction(r=>state.workspace?.role===r,role);}
  async function logout(){await page.locator('#logout').click();await page.waitForFunction(()=>state.user===null);await page.locator('#openLogin').waitFor();}
  await login('student','student01');await page.locator('[data-view=practice]').click();assert.equal(await page.locator('.task').count(),2);
  const submit=async(id,answer)=>{assert.equal(await page.locator('#feedback-'+id).textContent(),'');await page.locator('#answer-'+id).fill(answer);await page.locator('#answer-'+id).locator('xpath=ancestor::form').getByRole('button',{name:'Тексеру',exact:true}).click();await page.locator('#feedback-'+id+' strong').waitFor();};
  await submit('measure-b01','1 792');assert.match(await page.locator('#feedback-measure-b01').textContent(),/Дұрыс!.*Шешуі.*Түсіндірме/s);
  await submit('measure-b02','0');assert.match(await page.locator('#feedback-measure-b02').textContent(),/Дұрыс жауап: 3084/);assert.match(await page.locator('#feedback-measure-b02').textContent(),/Қатені талдау/);
  await page.locator('[data-view=results]').click();assert.deepEqual(await page.locator('.stat b').allTextContents(),['2','1','50%']);
  for(const topic of topics){
   await page.locator(`[data-topic="${topic.id}"]`).click();assert.equal(await page.locator('#theory').isVisible(),true);assert.ok(await page.locator('#theory .panel').count()>=5,topic.id);
   await page.locator('[data-view=practice]').click();await page.locator('[data-level=B]').click();assert.equal(await page.locator('.task').count(),2,topic.id+' B');
   await page.locator('[data-level=C]').click();assert.equal(await page.locator('.task').count(),10,topic.id+' C');assert.equal(await page.locator('.feedback').count(),0);
  }
  await page.locator('[data-topic=python]').click();await page.locator('[data-view=practice]').click();assert.ok(await page.locator('.code-block').count());await submit('python-c02','15, 17, 15');assert.match(await page.locator('#feedback-python-c02').textContent(),/Дұрыс!/);
  await page.locator('[data-topic=ip]').click();await page.locator('[data-view=practice]').click();await submit('ip-c02','10.24.39.255');assert.match(await page.locator('#feedback-ip-c02').textContent(),/Дұрыс!/);
  await submit('ip-c04','10.42.9.99');assert.match(await page.locator('#feedback-ip-c04').textContent(),/Қатені талдау.*broadcast/s);
  await page.reload();await page.waitForFunction(()=>state.workspace?.role==='student');await page.locator('[data-view=results]').click();assert.equal(await page.locator('.stat b').first().textContent(),'5');
  await page.locator('[data-view=lesson]').click();await page.locator('#lessonTopic').fill('<img src=x onerror=alert(1)>');await page.locator('#lessonForm button').click();assert.equal(await page.locator('#lessonText img').count(),0);
  await logout();assert.equal(await page.locator('.feedback').count(),0);
  await login('teacher','teacher@local.test');await page.locator('#studentsTab').click();await page.locator('#studentsTable').getByText('student01').waitFor();assert.equal(await page.locator('.admin-task').count(),12);
  await page.locator('.admin-task').first().getByRole('button',{name:'Жасыру'}).click();await page.waitForFunction(()=>state.workspace.tasks.find(t=>t.id==='measure-b01').active===false);
  await page.locator('.admin-task').first().getByRole('button',{name:'Ашу',exact:true}).click();await page.waitForFunction(()=>state.workspace.tasks.find(t=>t.id==='measure-b01').active===true);
  await page.locator('#newLogin').fill('qa_browser');await page.locator('#newFullName').fill('Сынақ жаңа оқушы');await page.locator('#newPassword').fill(PASSWORD);await page.locator('#createStudentForm button[type=submit]').click();await page.locator('#studentsTable').getByText('qa_browser').waitFor();
  await page.locator('[data-view=results]').click();assert.match(await page.locator('#resultList').textContent(),/Жергілікті сынақ оқушысы/);
  await logout();await login('student','qa_browser');await page.locator('[data-view=results]').click();assert.equal(await page.locator('.stat b').first().textContent(),'0');await logout();
  await page.setViewportSize({width:390,height:844});await page.locator('#topicToggle').click();await page.locator('[data-topic=hardware]').click();assert.equal(await page.locator('#theory').isVisible(),true);assert.equal(await page.locator('#pending').isVisible(),false);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  if(process.env.UI_SCREENSHOT_DIR)await page.screenshot({path:process.env.UI_SCREENSHOT_DIR+'/mobile.png',fullPage:true});
  assert.deepEqual(errors,[]);console.log('UI passed: all 19 theory lessons and 228 task cards; local PostgreSQL grading, number/sequence/IP answers, explanation gating, saved results after reload, teacher controls, new account, result isolation, QMJ escaping and mobile layout. Auth is a local emulator.');
 }finally{if(browser)await browser.close();if(app)await app.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
