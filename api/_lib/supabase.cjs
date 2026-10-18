function headers(res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
}
async function authenticate(req) {
  const base = process.env.SUPABASE_URL?.replace(/\/$/, '');
  const key = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!base || !key) throw Object.assign(Error('Сервер баптауы толық емес'), {status: 503});
  const token = (req.headers.authorization || '').match(/^Bearer ([^\s]+)$/)?.[1];
  if (!token) throw Object.assign(Error('Жүйеге кіріңіз'), {status: 401});
  const userHeaders = {apikey: key, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json'};
  const response = await fetch(`${base}/auth/v1/user`, {headers: userHeaders, signal: AbortSignal.timeout(10000)});
  if (!response.ok) throw Object.assign(Error('Сеанс аяқталды. Қайта кіріңіз.'), {status: 401});
  const user = await response.json();
  if (!user.id) throw Object.assign(Error('Сеанс жарамсыз'), {status: 401});
  return {base, userHeaders, user};
}
async function rpc(context, name, body = {}) {
  const response = await fetch(`${context.base}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: context.userHeaders, body: JSON.stringify(body), signal: AbortSignal.timeout(10000)
  });
  const data = await response.json().catch(() => null);
  if (!response.ok) {
    if (data?.code === 'P0001') throw Object.assign(Error(data.message), {status: 400});
    if (data?.code === '42501') throw Object.assign(Error('Бұл әрекетке рұқсат жоқ'), {status: 403});
    if (['PGRST202', '42P01', '42883'].includes(data?.code)) {
      throw Object.assign(Error('Оқу жүйесінің дерекқор миграциясы әлі қосылмаған'), {status: 503});
    }
    throw Object.assign(Error('Дерекқор сұрауы орындалмады. Қайта көріңіз.'), {status: 502});
  }
  return data;
}
module.exports = {headers, authenticate, rpc};
