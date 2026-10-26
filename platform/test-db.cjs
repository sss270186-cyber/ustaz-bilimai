// Local test adapter for Cloudflare D1's prepared-statement API; never used in hosting.
const {DatabaseSync}=require('node:sqlite'),fs=require('node:fs'),path=require('node:path');
function openDatabase(filename=':memory:',initialize=true){
 const sqlite=new DatabaseSync(filename);sqlite.exec('PRAGMA foreign_keys=ON;');
 if(initialize)for(const file of fs.readdirSync(path.join(__dirname,'drizzle')).filter(f=>f.endsWith('.sql')).sort())sqlite.exec(fs.readFileSync(path.join(__dirname,'drizzle',file),'utf8'));
 const db={sqlite,close(){sqlite.close();},prepare(sql){let params=[];const statement={bind(...values){params=values;return statement;},
  async first(){const row=sqlite.prepare(sql).get(...params);return row?{...row}:null;},
  async all(){return {success:true,results:sqlite.prepare(sql).all(...params).map(r=>({...r}))};},
  async run(){const r=sqlite.prepare(sql).run(...params);return {success:true,meta:{changes:Number(r.changes)}};}};return statement;},
  async batch(statements){sqlite.exec('BEGIN');try{const results=[];for(const statement of statements)results.push(await statement.run());sqlite.exec('COMMIT');return results;}catch(e){sqlite.exec('ROLLBACK');throw e;}}
 };return db;
}
module.exports={openDatabase};
