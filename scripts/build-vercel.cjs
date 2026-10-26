// Deterministic deployment-source package. No credentials or database connection required.
const fs=require('node:fs'),path=require('node:path'),{execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
function build(out=path.join(root,'work','vercel-release')){
 out=path.resolve(out);if(out===root||!out.startsWith(path.join(root,'work')+path.sep))throw Error('Use an output under this repository work/ directory');
 fs.rmSync(out,{recursive:true,force:true});fs.mkdirSync(out,{recursive:true});
 const copy=relative=>{const target=path.join(out,relative);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(path.join(root,relative),target);};
 for(const f of ['index.html','student.js','vercel.json'])copy(f);
 fs.cpSync(path.join(root,'assets'),path.join(out,'assets'),{recursive:true});
 const functions=fs.readdirSync(path.join(root,'api')).filter(f=>f.endsWith('.js')).sort();
 for(const f of functions){copy('api/'+f);execFileSync(process.execPath,['--check',path.join(out,'api',f)]);}
 fs.cpSync(path.join(root,'api/_lib'),path.join(out,'api/_lib'),{recursive:true});
 fs.writeFileSync(path.join(out,'package.json'),JSON.stringify({name:'ustaz-bilimai-vercel',private:true,engines:{node:'24.x'}},null,2)+'\n');
 fs.writeFileSync(path.join(out,'release-manifest.json'),JSON.stringify({target:'https://ustaz-bilimai.vercel.app',functions:functions.map(f=>'/api/'+f.slice(0,-3)),topics:19,tasks:228},null,2)+'\n');
 return {out,functions};
}
module.exports={build};if(require.main===module){const r=build();console.log(`Vercel source package checked: ${r.functions.length} Node functions; allowed static assets only; no Sites, SQL keys, tests or secrets.`);}
