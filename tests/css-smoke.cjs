const {chromium}=require('playwright'),assert=require('node:assert/strict');const {tasks}=require('../scripts/curriculum.cjs');
(async()=>{
 const browser=await chromium.launch({headless:true,...(process.env.BROWSER_EXECUTABLE?{executablePath:process.env.BROWSER_EXECUTABLE}:{})});
 try{
  const page=await browser.newPage({viewport:{width:800,height:900}});
  const checks=[()=>page.locator('li').count(),()=>page.locator('span').evaluate(e=>parseFloat(getComputedStyle(e).fontSize)),
   ()=>page.locator('div').evaluate(e=>e.getBoundingClientRect().width),()=>page.locator('div').evaluate(e=>{const s=getComputedStyle(e);return e.clientWidth-parseFloat(s.paddingLeft)-parseFloat(s.paddingRight);}),
   ()=>page.locator('.box > p').count(),()=>page.locator('ul > li:nth-child(2n+1)').count(),()=>page.locator('p').evaluate(e=>getComputedStyle(e).color==='rgb(255, 0, 0)'?'red':'unexpected'),
   ()=>page.locator('p').evaluate(e=>getComputedStyle(e).color==='rgb(0, 128, 0)'?'green':'unexpected'),
   ()=>page.locator('p').evaluate(e=>{const s=getComputedStyle(e);return parseFloat(s.paddingLeft)+parseFloat(s.marginLeft)}),
   ()=>page.locator('div').evaluate(e=>e.children[1].getBoundingClientRect().left-e.children[0].getBoundingClientRect().right),
   ()=>page.locator('i').first().evaluate(e=>e.getBoundingClientRect().width),()=>page.locator('div').evaluate(e=>e.getBoundingClientRect().width)];
  const a=tasks.filter(t=>t.topic_id==='html-css');
  for(let i=0;i<a.length;i++){await page.setContent(a[i].code);const actual=await checks[i]();assert.equal(String(actual).toLowerCase(),a[i].answer.toLowerCase(),a[i].id);}
  console.log('All 12 HTML/CSS answers match Chromium DOM/computed styles/layout.');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
