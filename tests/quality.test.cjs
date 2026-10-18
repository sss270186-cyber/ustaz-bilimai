const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const {tasks,topics}=require('../scripts/curriculum.cjs'),base=require('../scripts/curriculum-base.cjs'),patches=require('../scripts/curriculum/reviewed.cjs'),paths=require('../scripts/curriculum/audit.cjs'),models=require('./quality-reference.cjs');
const engines=new Set(['python','functions','sql','html-css','spreadsheets']);
test('every task has an individual audit path, complete feedback and unique statement/code',()=>{
 assert.equal(tasks.length,228);assert.equal(Object.keys(patches).length,101);assert.equal(new Set(tasks.map(t=>t.prompt+'\n'+t.code)).size,228);
 for(const topic of topics){assert.equal(paths[topic.id].length,10);for(const t of tasks.filter(t=>t.topic_id===topic.id)){
  assert.ok(t.prompt.trim()&&t.given_data.trim()&&t.find_value.trim());assert.ok(t.steps.length>=2);assert.ok(t.explanation.trim());assert.ok(t.error_feedback.length>50);
  if(t.level==='C'){assert.equal(paths[t.topic_id][t.position-1].split('→').length>=3,true,t.id);}
  else assert.deepEqual(t.answer,base.tasks.find(b=>b.id===t.id).answer);
 }}
});
test('every reviewed answer has an independent model or executable engine',()=>{
 for(const id of Object.keys(patches)){const t=tasks.find(t=>t.id===id);if(engines.has(t.topic_id)){assert.ok(t.code,id);continue;}
 assert.ok(Object.hasOwn(models,id),'Missing reference: '+id);const v=models[id];
 if(t.answer_format==='number')assert.ok(Math.abs(Number(t.answer)-Number(v))<Math.max(1e-10,Math.abs(Number(v))*1e-12),`${id}: ${t.answer} != ${v}`);
 else assert.equal(t.answer.toLowerCase(),String(v).toLowerCase(),id);
 }
});
test('every theory has a reviewed boundary condition and distinct worked example',()=>{
 const s={window:{}};vm.runInNewContext(fs.readFileSync('assets/theory-review.js','utf8'),s);const r=s.window.THEORY_REVIEW;
 assert.equal(Object.keys(r).length,19);
 for(const t of topics){const v=r[t.id];assert.ok(v.scope&&v.limits.length>100&&v.example.length>100&&v.method.length>50,t.id);}
});
test('known wrong answers have targeted diagnostics and no correct-answer shortcut',()=>{
 assert.match(tasks.find(t=>t.id==='ip-c04').mistakes['10.42.9.99'],/broadcast/);
 assert.match(tasks.find(t=>t.id==='python-c02').mistakes['10 17 15'],/ортақ/);
 for(const t of tasks){for(const [wrong,message]of Object.entries(t.mistakes)){assert.notEqual(wrong.toLowerCase(),t.answer.toLowerCase());assert.ok(message.length>30);}}
});
test('all three displayed examples have complete consistent proofs',()=>{
 for(const id of ['python-c02','spreadsheets-c02','ip-c04']){const t=tasks.find(t=>t.id===id);assert.ok(t.steps.length>=4);assert.ok(t.prompt.split(/\s+/).length>=12);assert.ok(t.explanation.split(/\s+/).length>=10);}
 assert.equal(tasks.find(t=>t.id==='python-c02').answer,'15 17 15');
 assert.equal(tasks.find(t=>t.id==='spreadsheets-c02').answer,'65');
 assert.equal(tasks.find(t=>t.id==='ip-c04').answer,'10.42.9.98');
});
test('all 228 audit records are fresh and linked to reviewed content hashes',()=>{
 const {execFileSync}=require('node:child_process');execFileSync(process.execPath,['scripts/quality-report.cjs','--check']);
 const audit=JSON.parse(fs.readFileSync('docs/QUALITY-AUDIT.json','utf8'));assert.equal(audit.records.length,228);assert.equal(audit.replaced_C,101);
 for(const record of audit.records){assert.match(record.content_hash,/^[a-f0-9]{64}$/);assert.equal(record.reviewed_fields.length,7);}
});
