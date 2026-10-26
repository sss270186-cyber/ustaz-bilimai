const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),{PGlite}=require('@electric-sql/pglite');
const {source,target}=require('../scripts/build-release.cjs');
test('single-transaction initial release preserves existing identities and refuses reinstallation',async()=>{
 const db=new PGlite();try{
 await db.exec(`create role anon;create role authenticated;create role service_role bypassrls;create schema auth;create table auth.users(id uuid primary key);create table auth.sessions(id uuid primary key,user_id uuid references auth.users,created_at timestamptz default now());create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;create table public.profiles(id uuid primary key references auth.users,username text unique,full_name text,role text,class_name text,created_at timestamptz default now());insert into auth.users values('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');insert into public.profiles values('10000000-0000-4000-8000-000000000001','old_teacher','Original Teacher','teacher','11',default),('10000000-0000-4000-8000-000000000002','old_student','Original Student','student','11',default);`);
 const original=(await db.query('select * from public.profiles order by id')).rows;
 assert.equal(source(),fs.readFileSync(target,'utf8'));await db.exec(source());
 assert.deepEqual((await db.query('select * from public.profiles order by id')).rows,original);
 assert.equal((await db.query('select count(*)::int n from auth.users')).rows[0].n,2);
 assert.equal((await db.query('select count(*)::int n from unt_tasks')).rows[0].n,228);
 assert.equal((await db.query('select count(*)::int n from unt_enrollments')).rows[0].n,1);
 await assert.rejects(()=>db.exec(source()),/already exist/);await db.exec('rollback');
 assert.deepEqual((await db.query('select * from public.profiles order by id')).rows,original);
 assert.equal((await db.query('select count(*)::int n from unt_tasks')).rows[0].n,228);
 }finally{await db.close();}
});
