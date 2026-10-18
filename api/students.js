// Admin key stays exclusively in this server function.
const {headers, authenticate} = require('./_lib/supabase.cjs');
const EMAIL_DOMAIN = 'students.ustaz-bilimai.example.com';
module.exports = async function handler(req, res) {
  headers(res);
  if (!['GET','POST'].includes(req.method)) return res.status(405).json({error:'Method not allowed'});
  try {
    const {base,user} = await authenticate(req);
    const adminKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!adminKey) return res.status(503).json({error:'Оқушы тіркеуінің сервер баптауы толық емес'});
    const adminHeaders = {apikey:adminKey, Authorization:`Bearer ${adminKey}`, 'Content-Type':'application/json'};
    const request = (path, options={}) => fetch(`${base}/rest/v1/${path}`, {...options, headers:adminHeaders, signal:AbortSignal.timeout(10000)});
    const teachers = await request(`unt_teachers?user_id=eq.${encodeURIComponent(user.id)}&select=user_id`);
    let learningReady = teachers.ok;
    let teacher;
    if (learningReady) teacher = (await teachers.json()).length > 0;
    else {
      // Preserve existing account administration until the additive migration is installed.
      const failure = await teachers.json().catch(()=>({}));
      if (!['42P01','PGRST205'].includes(failure.code)) return res.status(503).json({error:'Мұғалім рөлін тексеру мүмкін болмады'});
      const old = await request(`profiles?id=eq.${encodeURIComponent(user.id)}&select=role`);
      if (!old.ok) return res.status(503).json({error:'Мұғалім рөлін тексеру мүмкін болмады'});
      teacher = (await old.json())[0]?.role === 'teacher';
    }
    if (!teacher) return res.status(403).json({error:'Тек мұғалімге рұқсат'});
    if (req.method === 'GET') {
      const r = await request('profiles?role=eq.student&select=username,full_name,class_name&order=created_at.asc');
      if (!r.ok) return res.status(502).json({error:'Оқушылар тізімі алынбады'});
      return res.status(200).json({students:await r.json()});
    }
    const {username,full_name,class_name,password,action} = req.body || {};
    if (typeof username !== 'string' || !/^[a-z][a-z0-9_]{2,23}$/.test(username)) return res.status(400).json({error:'Логин пішімі дұрыс емес'});
    const found = await request(`profiles?username=eq.${encodeURIComponent(username)}&select=id,role`);
    if (!found.ok) return res.status(502).json({error:'Логинді тексеру мүмкін болмады'});
    const existing = await found.json();
    const enroll = async id => {
      if (!learningReady) return false;
      const r = await fetch(`${base}/rest/v1/unt_enrollments`, {method:'POST', headers:{...adminHeaders,Prefer:'resolution=ignore-duplicates,return=minimal'}, body:JSON.stringify({teacher_id:user.id,student_id:id}),signal:AbortSignal.timeout(10000)});
      return r.ok;
    };
    if (action === 'enroll') {
      if (!existing[0] || existing[0].role !== 'student') return res.status(404).json({error:'Оқушы табылмады'});
      if (!(await enroll(existing[0].id))) return res.status(503).json({error:'Оқу тобына қосу орындалмады. Миграцияны тексеріңіз.'});
      return res.status(200).json({ok:true});
    }
    if (action && action !== 'create') return res.status(400).json({error:'Белгісіз әрекет'});
    if (typeof full_name !== 'string' || full_name.trim().length < 2 || full_name.length > 120 || !['9','10','11'].includes(class_name) || typeof password !== 'string' || password.length < 12 || password.length > 128) return res.status(400).json({error:'Аты-жөнін, сыныпты және кемінде 12 таңбалы құпиясөзді тексеріңіз'});
    if (existing.length) return res.status(409).json({error:'Бұл логин бос емес'});
    const created = await fetch(`${base}/auth/v1/admin/users`, {method:'POST', headers:adminHeaders, body:JSON.stringify({email:`${username}@${EMAIL_DOMAIN}`,password,email_confirm:true,app_metadata:{bilimai_account:'student'}}),signal:AbortSignal.timeout(10000)});
    const newUser = await created.json().catch(()=>({}));
    if (!created.ok || !newUser.id) return res.status(created.status===422?409:502).json({error:'Аккаунт жасалмады. Бұл логин басқа аккаунтта болуы мүмкін.'});
    const profile = await request('profiles', {method:'POST', body:JSON.stringify({id:newUser.id,username,full_name:full_name.trim(),class_name,role:'student'})});
    // Never delete an Auth user on a profile failure. An administrator can repair it.
    if (!profile.ok) return res.status(502).json({error:'Auth аккаунты жасалды, бірақ профиль жазылмады. Қайта тіркемей, әкімшіге логинді беріңіз.'});
    let enrolled = false;
    try { enrolled = await enroll(newUser.id); } catch { /* Account and profile are preserved. */ }
    return res.status(201).json({ok:true,username,enrolled,warning:enrolled?null:'Аккаунт сақталды. Оқу тобына қосу үшін «Топқа қосу» батырмасын қолданыңыз.'});
  } catch(error) {
    return res.status(error.status || 502).json({error:error.status?error.message:'Байланыс қатесі. Тіркеуден кейін қате шықса, алдымен оқушылар тізімін тексеріңіз.'});
  }
};
