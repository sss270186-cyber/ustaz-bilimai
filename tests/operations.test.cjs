const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {PGlite}=require('@electric-sql/pglite');
const bootstrap=fs.readFileSync('ops/staging-bootstrap.sql','utf8');
const inventory=fs.readFileSync('ops/backup-inventory.sql','utf8');
const uid='11111111-1111-4111-8111-111111111111';
async function fixture(){const db=new PGlite();await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key,encrypted_password text);create table auth.identities(id uuid);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth to authenticated;`);return db;}
test('staging bootstrap rejects missing acknowledgement and existing users/tables',async()=>{
 const db=await fixture();try{
  await assert.rejects(db.exec(bootstrap),/acknowledgement/);await db.exec('rollback');
  await db.exec(`set bilimai.environment='staging';insert into auth.users values('${uid}','synthetic');`);
  await assert.rejects(db.exec(bootstrap),/Auth users already/);await db.exec('rollback');
  await db.exec('create table public.profiles(id uuid)');
  await assert.rejects(db.exec(bootstrap),/tables already/);await db.exec('rollback');
 }finally{await db.close();}
});
test('fresh staging profiles isolate reads and deny role promotion and self-registration',async()=>{
 const db=await fixture();try{
  await db.exec("set bilimai.environment='staging'");await db.exec(bootstrap);
  const other='22222222-2222-4222-8222-222222222222';
  await db.exec(`insert into auth.users values('${uid}','a'),('${other}','b');insert into public.profiles(id,full_name,role) values('${uid}','Synthetic A','student'),('${other}','Synthetic B','student');set role authenticated;select set_config('request.jwt.claim.sub','${uid}',false);`);
  assert.deepEqual((await db.query('select id from public.profiles')).rows,[{id:uid}]);
  await assert.rejects(db.query("update public.profiles set role='teacher' where id=$1",[uid]),/permission denied/);
  await assert.rejects(db.query("insert into public.profiles(id,full_name,role) values($1,'Forged','teacher')",[uid]),/permission denied/);
  await db.exec('reset role;set role anon');await assert.rejects(db.query('select * from public.profiles'),/permission denied/);
 }finally{await db.close();}
});
test('backup inventory executes read only and leaves synthetic data intact',async()=>{
 const db=await fixture();try{
  await db.exec("set bilimai.environment='staging'");await db.exec(bootstrap);
  await db.exec(`insert into auth.users values('${uid}','synthetic-secret-hash');insert into public.profiles(id,full_name,role) values('${uid}','Synthetic','teacher');`);
  const before=(await db.query('select * from public.profiles')).rows;
  const results=await db.exec(inventory);
  assert.ok(results.some(r=>r.rows.some(x=>x.read_only==='on')));
  assert.ok(results.some(r=>r.rows.some(x=>x.auth_user_count===1&&x.users_with_password_hash===1)));
  assert.equal(JSON.stringify(results).includes('synthetic-secret-hash'),false);
  assert.deepEqual((await db.query('select * from public.profiles')).rows,before);
  assert.equal((await db.query('select count(*) as n from auth.users')).rows[0].n,1);
 }finally{await db.close();}
});
