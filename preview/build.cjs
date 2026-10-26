const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),out=path.resolve(process.argv[2]||path.join(root,'work','preview-build'));
const {tasks,topics}=require('../scripts/curriculum.cjs');const revised=new Set(Object.keys(require('../scripts/curriculum/reviewed.cjs')));
const publicFields=['id','topic_id','level','position','title','prompt','given_data','find_value','formulas','unit','code','answer_format'];
const publicTasks=tasks.map(t=>({...Object.fromEntries(publicFields.map(k=>[k,t[k]])),revision:revised.has(t.id)?2:1,active:true}));
const assets={};function asset(route,body,type){assets[route]={body,type};}
let html=fs.readFileSync(path.join(root,'index.html'),'utf8').replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js','/preview/sdk.js');
html=html.replace('<header class="topbar">',`<div class="preview-banner"><div><b>СЫНАҚ НҰСҚАСЫ</b><span>19 тақырып · 228 тапсырма. Нақты аккаунттар қосылмаған. Нәтижелер осы браузерде сақталады.</span></div><div class="preview-actions"><button data-demo-account="student01" type="button">Оқушы болып көру</button><button data-demo-account="teacher" type="button">Мұғалім болып көру</button></div></div><header class="topbar">`)
 .replace('<title>Ustaz BilimAI','<title>Сынақ нұсқасы · Ustaz BilimAI').replace('Оқушы логині мен құпиясөзін мұғалім береді.','Тек жасанды сынақ аккаунттарын қолданыңыз. Нақты парольді енгізбеңіз. Жоғарыдағы батырмалармен парольсіз қарап көре аласыз.')
 .replace('Жаңа тапсырма жасау мен мәтінін өңдеу келесі кезеңге жоспарланған.','Сынақта өзгерістер тек осы браузерде сақталады. Жаңа тапсырма редакторы әлі дайын емес.');
asset('/',html,'text/html; charset=utf-8');asset('/index.html',html,'text/html; charset=utf-8');
for(const f of ['assets/app.js','assets/lessons.js','assets/theory-review.js','student.js','assets/style.css']){
 let body=fs.readFileSync(path.join(root,f),'utf8');
 if(f==='assets/app.js')body=body.replaceAll('Нәтиже сақталды.','Сынақ нәтижесі сақталды.');
 if(f==='assets/style.css')body+=`\n.preview-banner{background:#eaf2df;border-bottom:1px solid #cbdcbb;padding:14px 36px;display:flex;justify-content:space-between;align-items:center;gap:16px;color:#254a3b;font-size:12px}.preview-banner b{display:block;font-size:10px;letter-spacing:1.5px;margin-bottom:5px}.preview-actions{display:flex;gap:8px;flex-shrink:0}.preview-actions button{border:1px solid #9aaf88;background:#fff;color:#174e43;border-radius:7px;padding:11px 13px;font-size:12px;font-weight:600;min-height:44px}@media(max-width:760px){.preview-banner{padding:14px 16px;display:block}.preview-actions{margin-top:12px}.preview-actions button{flex:1;padding:10px 8px}.preview-banner span{font-size:11px;line-height:1.6}}`;
 asset('/'+f,body,f.endsWith('.css')?'text/css; charset=utf-8':'application/javascript; charset=utf-8');
}
asset('/preview/sdk.js',fs.readFileSync(path.join(__dirname,'sdk.js'),'utf8'),'application/javascript; charset=utf-8');
const data=`const privateTasks=${JSON.stringify(tasks)};\nconst topics=${JSON.stringify(topics)};\nconst publicTasks=${JSON.stringify(publicTasks)};\nconst assets=${JSON.stringify(assets)};`;
const worker=fs.readFileSync(path.join(__dirname,'worker.mjs'),'utf8').replace('/*__DATA__*/',data);
fs.mkdirSync(path.join(out,'worker'),{recursive:true});fs.writeFileSync(path.join(out,'worker/index.js'),worker);
console.log('Preview Worker built: 19 topics, 228 private keys; only allowed client assets exposed.');
