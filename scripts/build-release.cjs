// PREPARATION ONLY. This script writes SQL; it never connects to a database.
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),target='supabase/releases/20261026_initial_release.sql';
function source(){
 const names=fs.readdirSync(path.join(root,'supabase/migrations')).filter(n=>n.endsWith('.sql')).sort();
 const preflight=`do $preflight$
declare item text;
begin
 if to_regclass('public.profiles') is null or to_regclass('auth.users') is null or to_regclass('auth.sessions') is null then
  raise exception 'Required original profiles/Auth tables are missing. Do not continue on a different project.';
 end if;
 foreach item in array array['id','username','full_name','role','class_name','created_at'] loop
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name=item) then
   raise exception 'Required profiles column missing: %', item;
  end if;
 end loop;
 if not exists(select 1 from public.profiles where role='teacher') then
  raise exception 'No existing teacher profile. Verify the original project and teacher before installation.';
 end if;
 if exists(select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname like 'unt\\_%' escape '\\')
 or exists(select 1 from pg_namespace where nspname='unt_private') then
  raise exception 'UNT objects already exist. Use only reviewed pending migrations; never reapply the initial release.';
 end if;
end;
$preflight$;`;
 return '-- PREPARED ONLY: requires separate Production release authorization.\n-- INITIAL INSTALL ONLY, same Supabase project; preserves Auth users and profile rows.\n-- One transaction: any failure rolls back the entire installation.\nbegin;\n'+preflight+'\n'+names.map(name=>{
  let sql=fs.readFileSync(path.join(root,'supabase/migrations',name),'utf8');
  if(!/^begin;\s*$/m.test(sql)||! /\ncommit;\s*$/i.test(sql))throw Error('Unexpected transaction wrapper: '+name);
  sql=sql.replace(/^begin;\s*$/m,'').replace(/\ncommit;\s*$/i,'\n');
  return '\n-- SOURCE: '+name+'\n'+sql;
 }).join('\n')+"\nnotify pgrst, 'reload schema';\ncommit;\n";
}
module.exports={source,target};
if(require.main===module){const sql=source(),file=path.join(root,target);if(process.argv.includes('--check')){if(!fs.existsSync(file)||fs.readFileSync(file,'utf8')!==sql)throw Error('Release SQL is stale: run node scripts/build-release.cjs');console.log('Initial release SQL matches all six migrations.');}else{fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,sql);console.log('Prepared '+target+'; no database accessed.');}}
