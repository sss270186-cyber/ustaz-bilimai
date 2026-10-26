const fs=require('node:fs');const {tasks}=require('./curriculum.cjs');const patches=require('./curriculum/reviewed.cjs');
const q=s=>"'"+String(s).replaceAll("'","''")+"'";
let f=fs.readFileSync('supabase/migrations/202610180003_answer_formats.sql','utf8');f=f.slice(f.indexOf('create or replace function'),f.lastIndexOf('commit;'));
f=f.replace("'explanation', key.explanation)","'explanation', key.explanation, 'feedback', case when is_correct then null else coalesce(key.mistakes ->> cleaned,key.error_feedback) end)");
f=f.replace('insert into public.unt_attempts(student_id, task_id, submitted_answer, correct)', 'insert into public.unt_attempts(student_id, task_id, submitted_answer, correct,task_revision,task_snapshot)').replace('values(actor, task.id, cleaned, is_correct)', 'values(actor, task.id, cleaned, is_correct,task.revision,to_jsonb(task))');
let sql="-- Quality audit revision: safe new columns; no user/account deletion.\nbegin;\nalter table public.unt_tasks add column revision integer not null default 1;\nalter table public.unt_attempts add column task_revision integer not null default 1;\nalter table public.unt_attempts add column task_snapshot jsonb;\nupdate public.unt_attempts a set task_snapshot=to_jsonb(t) from public.unt_tasks t where a.task_id=t.id;\nalter table unt_private.answer_keys add column error_feedback text not null default '';\nalter table unt_private.answer_keys add column mistakes jsonb not null default '{}'::jsonb;\n"+f;
const original=fs.readFileSync('supabase/migrations/202610180001_learning.sql','utf8');
let workspace=original.slice(original.indexOf('create function public.unt_workspace()'),original.indexOf('create function public.unt_submit_answer('));
workspace=workspace.replace('create function','create or replace function').replace('distinct on(student_id, task_id) student_id, task_id, correct','distinct on(student_id, task_id, task_revision) student_id, task_id, task_revision, correct').replace('order by student_id, task_id, id','order by student_id, task_id, task_revision, id');
sql+=workspace;
for(const t of tasks){
 if(patches[t.id]){
 const keys=['title','prompt','given_data','find_value','formulas','unit','code','answer_format'];
 sql+=`update public.unt_tasks set revision=revision+1,${keys.map(k=>`${k}=${q(k==='formulas'?JSON.stringify(t[k]):t[k])}`).join(',')} where id=${q(t.id)};\n`;
 sql+=`update unt_private.answer_keys set answer=${q(t.answer)},steps=${q(JSON.stringify(t.steps))},explanation=${q(t.explanation)} where task_id=${q(t.id)};\n`;
 }
 sql+=`update unt_private.answer_keys set error_feedback=${q(t.error_feedback)},mistakes=${q(JSON.stringify(t.mistakes))} where task_id=${q(t.id)};\n`;
}sql+='commit;\n';const file='supabase/migrations/202610180005_quality_review.sql';
if(process.argv.includes('--check')){if(fs.readFileSync(file,'utf8')!==sql)throw Error('Quality seed is out of date');}else fs.writeFileSync(file,sql);
