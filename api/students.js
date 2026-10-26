// Only the server holds the admin key. Authorization always uses the caller's JWT/RPC.
const {headers,authenticate,rpc}=require('./_lib/supabase.cjs');
const EMAIL_DOMAIN='students.ustaz-bilimai.example.com';
module.exports=async(req,res)=>{
 headers(res);if(!['GET','POST'].includes(req.method))return res.status(405).json({error:'Әдіс рұқсат етілмеген'});
 try{
  const context=await authenticate(req);
  if(req.method==='GET')return res.status(200).json({students:await rpc(context,'unt_teacher_students')});
  const access=await rpc(context,'unt_account_access');if(access?.teacher!==true)return res.status(403).json({error:'Тек мұғалімге рұқсат'});
  const body=req.body||{},action=body.action||'create',username=body.username;
  if(typeof username!=='string'||!/^[a-z][a-z0-9_]{2,23}$/.test(username))return res.status(400).json({error:'Логин пішімі дұрыс емес'});
  if(action==='enroll')return res.status(200).json(await rpc(context,'unt_enroll_student',{p_username:username}));
  if(!['create','reset_password'].includes(action))return res.status(400).json({error:'Белгісіз әрекет'});
  const password=body.password;if(typeof password!=='string'||password.length<12||password.length>128)return res.status(400).json({error:'Құпиясөз 12–128 таңба болсын'});
  const admin=process.env.SUPABASE_SERVICE_ROLE_KEY;if(!admin)return res.status(503).json({error:'Оқушы басқаруының сервер баптауы толық емес'});
  const adminHeaders={apikey:admin,Authorization:'Bearer '+admin,'Content-Type':'application/json'};
  const request=(path,options={})=>fetch(context.base+path,{...options,headers:{...adminHeaders,...options.headers},signal:AbortSignal.timeout(10000)});
  if(action==='reset_password'){
   const target=await rpc(context,'unt_student_target',{p_username:username});
   const changed=await request('/auth/v1/admin/users/'+encodeURIComponent(target),{method:'PUT',body:JSON.stringify({password})});
   if(!changed.ok)return res.status(502).json({error:'Құпиясөз жаңартылмады. Қайта көріңіз.'});
   try{await rpc(context,'unt_revoke_access',{p_user_id:target});}catch{return res.status(502).json({error:'Құпиясөз жаңарды, бірақ ескі қолданба сеанстарын жабу расталмады. Әкімшіге хабарласыңыз.'});}
   return res.status(200).json({ok:true});
  }
  const {full_name,class_name}=body;
  if(typeof full_name!=='string'||full_name.trim().length<2||full_name.length>120||!['9','10','11'].includes(class_name))return res.status(400).json({error:'Аты-жөні мен сыныпты тексеріңіз'});
  const found=await request('/rest/v1/profiles?username=eq.'+encodeURIComponent(username)+'&select=id');if(!found.ok)return res.status(502).json({error:'Логинді тексеру мүмкін болмады'});
  if((await found.json()).length)return res.status(409).json({error:'Бұл логин бос емес'});
  const created=await request('/auth/v1/admin/users',{method:'POST',body:JSON.stringify({email:username+'@'+EMAIL_DOMAIN,password,email_confirm:true,app_metadata:{bilimai_account:'student'}})});
  const newUser=await created.json().catch(()=>({}));if(!created.ok||!newUser.id)return res.status(created.status===422?409:502).json({error:'Аккаунт жасалмады. Логин бұрыннан қолданылуы мүмкін.'});
  const profile=await request('/rest/v1/profiles?on_conflict=id',{method:'POST',headers:{Prefer:'resolution=merge-duplicates,return=minimal'},body:JSON.stringify({id:newUser.id,username,full_name:full_name.trim(),class_name,role:'student'})});
  if(!profile.ok)return res.status(502).json({error:'Auth аккаунты жасалды, бірақ профиль жазылмады. Қайта тіркемей, әкімшіге логинді беріңіз.'});
  let enrolled=false;try{await rpc(context,'unt_enroll_student',{p_username:username});enrolled=true;}catch{/* Preserve the new Auth account/profile on partial failure. */}
  return res.status(201).json({ok:true,username,enrolled,warning:enrolled?null:'Аккаунт сақталды. «Топқа қосу» арқылы байланыстырыңыз.'});
 }catch(e){return res.status(e.status||502).json({error:e.status?e.message:'Байланыс қатесі. Тіркеуден кейін алдымен оқушылар тізімін тексеріңіз.'});}
};
