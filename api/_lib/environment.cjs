// Fail closed on Vercel Preview before any Supabase request.
// The deployed Production configuration is not changed by this guard.
const PRODUCTION_HOST = 'kbnwfuvfnspanoomusmu.supabase.co';
function cleanOrigin(value) {
  const u = new URL(value);
  if (u.protocol !== 'https:' || !u.hostname.endsWith('.supabase.co') ||
      u.username || u.password || u.pathname !== '/' || u.search || u.hash || u.port) throw Error('Invalid origin');
  return u.origin;
}
function checkEnvironment(env = process.env) {
  if (env.VERCEL_ENV !== 'preview') return;
  try {
    const actual = cleanOrigin(env.SUPABASE_URL);
    const expected = cleanOrigin(env.BILIMAI_STAGING_SUPABASE_URL);
    if (new URL(actual).hostname === PRODUCTION_HOST || actual !== expected) throw Error('Unsafe Preview');
  } catch {
    throw Object.assign(Error('Preview тек бөлек staging Supabase жобасына қосылуы керек. Сервер баптауын тексеріңіз.'), {status: 503});
  }
}
module.exports = {checkEnvironment};
