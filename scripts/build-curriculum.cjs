const fs=require('node:fs');const {topics,tasks}=require('./curriculum-base.cjs');
const q=s=>"'"+String(s).replaceAll("'","''")+"'";
let sql='-- Generated private curriculum seed. Never include this file in static output.\nbegin;\n';
for(const t of topics)sql+=`update public.unt_topics set title=${q(t.title)},ready=true where id=${q(t.id)};\n`;
for(const t of tasks){
 if(t.topic_id==='measurement'){sql+=`update unt_private.answer_keys set explanation=${q(t.explanation)} where task_id=${q(t.id)};\n`;continue;}
 const keys=['id','topic_id','level','position','title','prompt','given_data','find_value','formulas','unit','code','answer_format'];
 sql+=`insert into public.unt_tasks(${keys.join(',')}) values(${keys.map(k=>k==='position'?t[k]:q(k==='formulas'?JSON.stringify(t[k]):t[k])).join(',')});\n`;
 sql+=`insert into unt_private.answer_keys(task_id,answer,steps,explanation) values(${q(t.id)},${q(t.answer)},${q(JSON.stringify(t.steps))},${q(t.explanation)});\n`;
}sql+='commit;\n';
const file='supabase/migrations/202610180004_full_curriculum.sql';
if(process.argv.includes('--check')){if(fs.readFileSync(file,'utf8')!==sql)throw Error('Curriculum seed is out of date');}else fs.writeFileSync(file,sql);
