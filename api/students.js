// Server-only. Requires SUPABASE_SERVICE_ROLE_KEY (legacy service_role JWT).
const EMAIL_DOMAIN='students.ustaz-bilimai.example.com';
module.exports=async function handler(req,res){
  res.setHeader('Cache-Control','no-store');res.setHeader('X-Content-Type-Options','nosniff');
  if(!['GET','POST'].includes(req.method))return res.status(405).json({error:'Method not allowed'});
  const url=process.env.SUPABASE_URL;
  const publicKey=process.env.SUPABASE_PUBLISHABLE_KEY;
  const adminKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
  if(!url||!publicKey||!adminKey)return res.status(503).json({error:'Сервер баптауы толық емес'});
  const bearer=(req.headers.authorization||'').match(/^Bearer (.+)$/);
  if(!bearer)return res.status(401).json({error:'Кіру қажет'});
  const base=url.replace(/\/$/,'');
  const auth=await fetch(`${base}/auth/v1/user`,{headers:{apikey:publicKey,Authorization:`Bearer ${bearer[1]}`}}).catch(()=>null);
  if(!auth||!auth.ok)return res.status(401).json({error:'Сеанс жарамсыз'});
  const user=await auth.json();
  const adminHeaders={apikey:adminKey,Authorization:`Bearer ${adminKey}`};
  const roleRes=await fetch(`${base}/rest/v1/profiles?id=eq.${encodeURIComponent(user.id)}&select=role`,{headers:adminHeaders});
  if(!roleRes.ok)return res.status(503).json({error:'Рөлді тексеру мүмкін болмады'});
  const roles=await roleRes.json();
  if(roles[0]?.role!=='teacher')return res.status(403).json({error:'Тек мұғалімге рұқсат'});
  if(req.method==='GET'){
    const r=await fetch(`${base}/rest/v1/profiles?role=eq.student&select=username,full_name,class_name&order=created_at.asc`,{headers:adminHeaders});
    if(!r.ok)return res.status(502).json({error:'Оқушылар тізімі алынбады'});
    return res.status(200).json({students:await r.json()});
  }
  const {username,full_name,class_name,password}=req.body||{};
  if(typeof username!=='string'||!/^[a-z][a-z0-9_]{2,23}$/.test(username)||typeof full_name!=='string'||full_name.trim().length<2||full_name.length>120||!['9','10','11'].includes(class_name)||typeof password!=='string'||password.length<12||password.length>128)return res.status(400).json({error:'Мәліметтерді тексеріңіз (құпиясөз кемінде 12 таңба)'});
  const email=`${username}@${EMAIL_DOMAIN}`;
  const exists=await fetch(`${base}/rest/v1/profiles?username=eq.${encodeURIComponent(username)}&select=id`,{headers:adminHeaders});
  if(!exists.ok)return res.status(502).json({error:'Логинді тексеру мүмкін болмады'});
  if((await exists.json()).length)return res.status(409).json({error:'Бұл логин бос емес'});
  const create=await fetch(`${base}/auth/v1/admin/users`,{method:'POST',headers:{...adminHeaders,'Content-Type':'application/json'},body:JSON.stringify({email,password,email_confirm:true,app_metadata:{bilimai_account:'student'}})});
  const newUser=await create.json().catch(()=>({}));
  if(!create.ok||!newUser.id)return res.status(create.status===422?409:502).json({error:'Аккаунт жасау мүмкін болмады. Логин басқа аккаунтта болуы мүмкін.'});
  const insert=await fetch(`${base}/rest/v1/profiles`,{method:'POST',headers:{...adminHeaders,'Content-Type':'application/json',Prefer:'return=minimal'},body:JSON.stringify({id:newUser.id,username,full_name:full_name.trim(),class_name,role:'student'})});
  if(!insert.ok){await fetch(`${base}/auth/v1/admin/users/${newUser.id}`,{method:'DELETE',headers:adminHeaders}).catch(()=>{});return res.status(502).json({error:'Профиль жасалмады. Қайта көріңіз.'});}
  return res.status(201).json({ok:true,username});
};
