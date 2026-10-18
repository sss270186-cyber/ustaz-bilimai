const {test}=require('node:test');const assert=require('node:assert/strict');
const {topics,tasks}=require('../scripts/measurement.cjs');
test('19 ordered topics; only the first-stage lesson is ready',()=>{
 assert.equal(topics.length,19);assert.deepEqual(topics.map(t=>t.position),Array.from({length:19},(_,i)=>i));
 assert.deepEqual(topics.filter(t=>t.ready).map(t=>t.id),['measurement']);
});
test('measurement has 2 B and 10 C distinct, complete tasks',()=>{
 assert.equal(tasks.filter(t=>t.level==='B').length,2);assert.equal(tasks.filter(t=>t.level==='C').length,10);
 assert.equal(new Set(tasks.map(t=>t.id)).size,12);assert.equal(new Set(tasks.map(t=>t.prompt)).size,12);
 for(const t of tasks){for(const key of ['title','prompt','given_data','find_value','unit'])assert.ok(t[key].length>0);assert.ok(t.formulas.length);assert.ok(t.steps.length>=2);}
});
test('all answers agree with independently calculated unit and storage models',()=>{
 const reference=[1.75*1024,3*1024+96/8,3.5*1024+768+4096/8192,24*40*64*16/8192,
 Math.floor((2*1024*.875-192)/180),12*(512*5/8+2),900*Math.ceil((6*1024+1)/(4*1024))*4,
 2*1024**2+100+Math.ceil((2*1024**2+100)/1024)*24,2*(1.5*1024+5*240)/1024,
 48000*24*2*75/8/1024**2,Math.ceil((1023*24/8)/4)*4*512/1024**2,Math.floor(256*10**9/(1.5*1024**3))];
 assert.deepEqual(tasks.map(t=>Number(t.answer)),reference);
});
