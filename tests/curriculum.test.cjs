const {test}=require('node:test');const assert=require('node:assert/strict');const fs=require('node:fs');const vm=require('node:vm');
const {topics,tasks}=require('../scripts/curriculum.cjs');const reference=require('./curriculum-reference.cjs');
test('all 19 topics have exactly 2 B + 10 C unique complete tasks',()=>{
 assert.equal(topics.length,19);assert.equal(tasks.length,228);assert.equal(new Set(tasks.map(t=>t.id)).size,228);assert.equal(new Set(tasks.map(t=>t.prompt+'\n'+t.code)).size,228);
 for(const topic of topics){assert.ok(topic.ready);const a=tasks.filter(t=>t.topic_id===topic.id);assert.equal(a.length,12,topic.id);assert.equal(a.filter(t=>t.level==='B').length,2);assert.equal(a.filter(t=>t.level==='C').length,10);}
 for(const t of tasks){for(const k of ['title','prompt','given_data','find_value','explanation'])assert.ok(t[k]?.length>0,`${t.id}:${k}`);assert.ok(t.formulas.length);assert.ok(t.steps.length>=2);assert.ok(['number','text','sequence'].includes(t.answer_format));}
});
test('all public theory lessons have goals, five teaching sections, self-check and source',()=>{
 const sandbox={window:{}};vm.runInNewContext(fs.readFileSync('assets/lessons.js','utf8'),sandbox);const lessons=sandbox.window.LESSONS;
 for(const topic of topics.filter(t=>t.id!=='measurement')){const l=lessons[topic.id];assert.ok(l,topic.id);assert.equal(l.goals.length,3);assert.equal(l.sections.length,5);assert.ok(l.sections.every(s=>s.paragraphs.length>=2));assert.ok(l.checks.length>=3);assert.ok(l.source[1].startsWith('https://'));const text=l.sections.flatMap(s=>s.paragraphs).join(' ');assert.ok(text.length>1800,`${topic.id}: theory too short`);}
 assert.equal(Object.keys(lessons).length,18);const html=fs.readFileSync('index.html','utf8');assert.ok(html.includes('Ақпараттың көлемі қалай өлшенеді?'));assert.ok(!/answer_keys|correct_answer/.test(fs.readFileSync('assets/lessons.js','utf8')));
});
test('author answers match independent mathematical, bitwise and truth-table references',()=>{
 for(const [topic,values]of Object.entries(reference)){
 const a=require('../scripts/curriculum-base.cjs').tasks.filter(t=>t.topic_id===topic).sort((x,y)=>(x.level+x.position.toString().padStart(2,'0')).localeCompare(y.level+y.position.toString().padStart(2,'0')));
 assert.equal(values.length,a.length,topic);
 a.forEach((t,i)=>{if(t.answer_format==='number'){const expected=Number(values[i]);assert.ok(Math.abs(Number(t.answer)-expected)<=Math.max(1e-10,Math.abs(expected)*1e-12),`${t.id}: ${t.answer} != ${expected}`);}else assert.equal(t.answer.toLowerCase(),String(values[i]).toLowerCase(),t.id);});
 }
});
test('SQL curriculum seed matches authoring source',()=>{const {execFileSync}=require('node:child_process');execFileSync(process.execPath,['scripts/build-curriculum.cjs','--check']);});
