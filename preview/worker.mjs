// Isolated Preview: no credentials, external requests, Auth administration or SQL access.
/*__DATA__*/
const headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'same-origin','X-Frame-Options':'SAMEORIGIN',
  'Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'self'; form-action 'self'"};
const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{...headers,'Content-Type':'application/json; charset=utf-8'}});
export function normalize(value,format){
 if(format==='number'){
  if(value.length>64)throw Error('Сандық жауап тым ұзын.');
  const s=value.trim().replace(/[ \u00a0]/g,'').replaceAll(',','.');
  if(!/^[+-]?\d+(\.\d+)?$/.test(s))throw Error('Тек сан енгізіңіз. Өлшем бірлігін жазбаңыз.');
  let [whole,decimal='']=s.replace(/^[+-]/,'').split('.');whole=whole.replace(/^0+(?=\d)/,'');decimal=decimal.replace(/0+$/,'');
  return (s.startsWith('-')&&(whole!=='0'||decimal)?'-':'')+whole+(decimal?'.'+decimal:'');
 }
 return value.trim().toLowerCase().replace(format==='sequence'?/[,;\s]+/g:/\s+/g,' ');
}
export function grade(taskId,answer){
 if(typeof answer!=='string'||!answer.trim()||answer.length>256)throw Error('Жауап енгізіңіз (256 таңбаға дейін).');
 const task=privateTasks.find(t=>t.id===taskId);if(!task)throw Error('Тапсырма табылмады.');
 const cleaned=normalize(answer,task.answer_format),correct=cleaned===normalize(String(task.answer),task.answer_format);
 return {correct,answer:String(task.answer),unit:task.unit,steps:task.steps,explanation:task.explanation,
  feedback:correct?null:task.mistakes?.[cleaned]||task.error_feedback,submitted_answer:cleaned};
}
export default {
 async fetch(request){
  const url=new URL(request.url),path=url.pathname;
  if(request.method==='GET'&&assets[path])return new Response(assets[path].body,{headers:{...headers,'Content-Type':assets[path].type}});
  if(request.method==='GET'&&path==='/api/config')return json({url:url.origin,publishableKey:'preview-only',mode:'preview'});
  if(request.method==='GET'&&path==='/api/preview/catalog')return json({topics,tasks:publicTasks});
  if(path==='/api/preview/grade'&&request.method==='POST'){
   if(request.headers.get('origin')!==url.origin)return json({error:'Сұрау осы сынақ сайтынан жіберілуі керек.'},403);
   if(!request.headers.get('content-type')?.startsWith('application/json'))return json({error:'JSON қажет.'},415);
   try{
    const reader=request.body?.getReader();if(!reader)return json({error:'Жауап енгізіңіз.'},400);
    const chunks=[];let size=0;
    while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>4096){await reader.cancel();return json({error:'Сұрау тым ұзын.'},413);}chunks.push(value);}
    const bytes=new Uint8Array(size);let offset=0;for(const part of chunks){bytes.set(part,offset);offset+=part.length;}
    const body=JSON.parse(new TextDecoder().decode(bytes));return json(grade(body?.task_id,body?.answer));
   }catch(error){return json({error:error instanceof SyntaxError?'Жауап пішімі дұрыс емес.':error.message},400);}
  }
  return json({error:'Бет табылмады.'},404);
 }
};
