const {test,before,after}=require('node:test'),assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),os=require('node:os');
const {execFileSync}=require('node:child_process');const {tasks}=require('../scripts/curriculum.cjs');
let worker,tmp;
before(async()=>{tmp=fs.mkdtempSync(path.join(os.tmpdir(),'bilimai-preview-'));execFileSync(process.execPath,['preview/build.cjs',tmp]);worker=await import('data:text/javascript;base64,'+fs.readFileSync(path.join(tmp,'worker/index.js')).toString('base64'));});
after(()=>{if(tmp)fs.rmSync(tmp,{recursive:true,force:true});});
test('Preview exposes 19 topics and 228 public tasks without any answer key or solution',async()=>{
 const r=await worker.default.fetch(new Request('https://preview.test/api/preview/catalog'));const d=await r.json();assert.equal(d.topics.length,19);assert.equal(d.tasks.length,228);
 for(const t of d.tasks)for(const key of ['answer','steps','explanation','error_feedback','mistakes'])assert.equal(key in t,false,t.id+' '+key);
 for(const topic of d.topics){assert.equal(d.tasks.filter(t=>t.topic_id===topic.id&&t.level==='B').length,2);assert.equal(d.tasks.filter(t=>t.topic_id===topic.id&&t.level==='C').length,10);}
});
test('Preview server independently grades all 228 correct and wrong answers',()=>{
 for(const t of tasks){const yes=worker.grade(t.id,String(t.answer));assert.equal(yes.correct,true,t.id);assert.ok(yes.steps.length>0);assert.ok(yes.explanation);assert.equal(yes.feedback,null);
  const no=worker.grade(t.id,t.answer_format==='number'?'999999999999':'wrong-preview-answer');assert.equal(no.correct,false,t.id);assert.ok(no.feedback.length>20,t.id);}
 assert.equal(worker.grade('measure-b01','+001 792,000').correct,true);assert.equal(worker.grade('python-c02','15, 17; 15').correct,true);
 assert.match(worker.grade('ip-c04','10.42.9.99').feedback,/broadcast/);
});
test('invalid and cross-origin submissions never reveal a solution; private source paths are excluded',async()=>{
 const request=(body,origin='https://preview.test')=>new Request('https://preview.test/api/preview/grade',{method:'POST',headers:{origin,'Content-Type':'application/json'},body:JSON.stringify(body)});
 for(const body of [{task_id:'measure-b01',answer:''},{task_id:'measure-b01',answer:'1 MB'},{task_id:'nonexistent',answer:'1'}]){const r=await worker.default.fetch(request(body));assert.equal(r.status,400);const d=await r.json();assert.equal('answer' in d,false);assert.equal('steps' in d,false);}
 assert.equal((await worker.default.fetch(request({task_id:'measure-b01',answer:'1792'},'https://other.test'))).status,403);
 for(const p of ['/worker/index.js','/scripts/curriculum.cjs','/supabase/migrations/202610180005_quality_review.sql','/.env','/api/_lib/supabase.cjs'])assert.equal((await worker.default.fetch(new Request('https://preview.test'+p))).status,404);
});
test('Preview client has no external script or production connection and labels browser-local results',async()=>{
 const html=await (await worker.default.fetch(new Request('https://preview.test/'))).text();assert.ok(html.includes('СЫНАҚ НҰСҚАСЫ'));assert.ok(html.includes('осы браузерде сақталады'));assert.ok(!html.includes('cdn.jsdelivr.net'));
 const config=await (await worker.default.fetch(new Request('https://preview.test/api/config'))).json();assert.equal(config.url,'https://preview.test');assert.equal(config.mode,'preview');
 for(const p of ['/preview/sdk.js','/student.js','/assets/app.js']){const r=await worker.default.fetch(new Request('https://preview.test'+p));assert.equal(r.status,200);assert.ok(!(await r.text()).includes('kbnwfuvfnspanoomusmu'));assert.ok(r.headers.get('Content-Security-Policy').includes("connect-src 'self'"));}
});
