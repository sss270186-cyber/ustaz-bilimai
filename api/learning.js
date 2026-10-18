const {headers, authenticate, rpc} = require('./_lib/supabase.cjs');
module.exports = async function handler(req, res) {
  headers(res);
  if (!['GET', 'POST'].includes(req.method)) {res.setHeader('Allow', 'GET, POST'); return res.status(405).json({error:'Әдіс рұқсат етілмеген'});}
  try {
    const context = await authenticate(req);
    if (req.method === 'GET') {
      return res.status(200).json(await rpc(context, 'unt_workspace'));
    }
    const body = req.body;
    if (!body || typeof body !== 'object' || Array.isArray(body)) return res.status(400).json({error:'Сұрау форматы қате'});
    if (body.action === 'grade') {
      if (typeof body.task_id !== 'string' || !/^measure-[bc]\d{2}$/.test(body.task_id) ||
          typeof body.answer !== 'string' || body.answer.length > 64 || !body.answer.trim()) {
        return res.status(400).json({error:'Тапсырма мен сандық жауапты тексеріңіз'});
      }
      const result = await rpc(context, 'unt_submit_answer', {p_task_id:body.task_id,p_answer:body.answer});
      return res.status(200).json(result);
    }
    if (body.action === 'set_active') {
      if (typeof body.task_id !== 'string' || body.task_id.length > 80 || typeof body.active !== 'boolean') return res.status(400).json({error:'Тапсырма параметрлері қате'});
      return res.status(200).json(await rpc(context, 'unt_set_task_active', {p_task_id:body.task_id,p_active:body.active}));
    }
    return res.status(400).json({error:'Белгісіз әрекет'});
  } catch (error) {
    return res.status(error.status || 502).json({error:error.status ? error.message : 'Сервермен байланыс үзілді. Қайта көріңіз.'});
  }
};
