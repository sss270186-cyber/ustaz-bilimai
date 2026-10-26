const {checkEnvironment} = require('./_lib/environment.cjs');
module.exports = function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return res.status(405).json({error:'Method not allowed'});
  try { checkEnvironment(); }
  catch (error) { return res.status(503).json({error:error.message}); }
  const url = process.env.SUPABASE_URL;
  const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
  if (!url || !publishableKey) return res.status(503).json({error:'Supabase configuration missing'});
  return res.status(200).json({url, publishableKey});
};
