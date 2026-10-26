const {headers,authenticate,rpc}=require('./_lib/supabase.cjs');
module.exports=async(req,res)=>{
 headers(res);if(req.method!=='POST')return res.status(405).json({error:'Әдіс рұқсат етілмеген'});
 let verificationToken,context,changed=false;
 try{
  context=await authenticate(req);await rpc(context,'unt_account_access');
  const {current,password}=req.body||{};
  if(typeof current!=='string'||!current||current.length>128||typeof password!=='string'||password.length<12||password.length>128||!context.user.email)return res.status(400).json({error:'Қазіргі және 12–128 таңбалы жаңа құпиясөзді енгізіңіз'});
  const publicHeaders={apikey:process.env.SUPABASE_PUBLISHABLE_KEY,'Content-Type':'application/json'};
  const verified=await fetch(context.base+'/auth/v1/token?grant_type=password',{method:'POST',headers:publicHeaders,body:JSON.stringify({email:context.user.email,password:current}),signal:AbortSignal.timeout(10000)});
  const session=await verified.json().catch(()=>({}));
  if(!verified.ok||!session.access_token||session.user?.id!==context.user.id)return res.status(400).json({error:'Қазіргі құпиясөз дұрыс емес. Қажет болса, қайта кіріңіз.'});
  verificationToken=session.access_token;
  const update=await fetch(context.base+'/auth/v1/user',{method:'PUT',headers:{...publicHeaders,Authorization:'Bearer '+verificationToken},body:JSON.stringify({password}),signal:AbortSignal.timeout(10000)});
  if(!update.ok)return res.status(400).json({error:'Құпиясөз өзгермеді. Жаңа құпиясөз талаптарын тексеріп, қайта кіріңіз.'});
  changed=true;await rpc(context,'unt_revoke_access',{p_user_id:context.user.id});
  return res.status(200).json({ok:true,reauthenticate:true});
 }catch(e){return res.status(e.status||502).json({error:changed?'Құпиясөз өзгерді, бірақ қолданба сеанстарын жабу расталмады. Жүйеден шығып, жаңа құпиясөзбен кіріңіз.':e.status?e.message:'Құпиясөздің жаңаруы расталмады. Жаңа құпиясөзбен қайта кіріп тексеріңіз.'});}
 finally{
  if(verificationToken)try{await fetch(context.base+'/auth/v1/logout?scope='+ (changed?'global':'local'),{method:'POST',headers:{apikey:process.env.SUPABASE_PUBLISHABLE_KEY,Authorization:'Bearer '+verificationToken},signal:AbortSignal.timeout(10000)});}catch{/* Short-lived verification token is never returned or logged. */}
 }
};
