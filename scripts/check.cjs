const fs=require('node:fs'),path=require('node:path');const {execFileSync}=require('node:child_process');
function files(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name)):[path.join(dir,e.name)]);}
for(const f of [...files('api'),...files('assets'),...files('scripts'),'student.js'].filter(p=>/\.(c?js)$/.test(p)))execFileSync(process.execPath,['--check',f]);
const html=fs.readFileSync('index.html','utf8'),ids=[...html.matchAll(/\bid="([^"]+)"/g)].map(m=>m[1]);
if(new Set(ids).size!==ids.length)throw Error('Duplicate HTML ids');
if(/\son\w+\s*=|<script(?![^>]*src=)[^>]*>\s*\S/i.test(html))throw Error('Inline executable content violates CSP');
const pub=['index.html','student.js',...files('assets')].map(p=>fs.readFileSync(p,'utf8')).join('\n');
if(/SUPABASE_SERVICE_ROLE_KEY|answer_keys|correct_answer/.test(pub))throw Error('Private fields referenced in public assets');
for(const ref of html.matchAll(/(?:src|href)="(\/[^"?#]+)"/g))if(ref[1]!=='/'&&!fs.existsSync('.'+ref[1]))throw Error('Missing public asset '+ref[1]);
const config=JSON.parse(fs.readFileSync('vercel.json'));
if(config.builds.some(b=>b.use==='@vercel/static'&&!['index.html','student.js','assets/**'].includes(b.src)))throw Error('Unsafe static source glob');
for(const script of ['scripts/build-seed.cjs','scripts/build-curriculum.cjs','scripts/build-quality.cjs'])execFileSync(process.execPath,[script,'--check']);
console.log('JavaScript syntax, assets, HTML ids, public-source boundary, static build allowlist and all SQL seeds passed.');
