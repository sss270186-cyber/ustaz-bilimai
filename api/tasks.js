const {headers,authenticate,rpc}=require('./_lib/supabase.cjs');
module.exports=async(req,res)=>{
 headers(res);if(!['GET','POST'].includes(req.method))return res.status(405).json({error:'Әдіс рұқсат етілмеген'});
 try{
  const context=await authenticate(req),body=req.body||{},id=req.method==='GET'?req.query?.id:body.task_id;
  if(typeof id!=='string'||!/^[a-z][a-z0-9-]{0,47}-[bc]\d{2}$/.test(id))return res.status(400).json({error:'Тапсырма пішімі дұрыс емес'});
  if(req.method==='GET')return res.status(200).json({task:await rpc(context,'unt_task_for_edit',{p_task_id:id})});
  if(!Number.isSafeInteger(body.revision)||body.revision<1||!body||typeof body!=='object'||Array.isArray(body))return res.status(400).json({error:'Тапсырма нұсқасын тексеріңіз'});
  const fields=['title','prompt','given_data','find_value','unit','code','answer','answer_format','steps','formulas','explanation'];
  const data=Object.fromEntries(fields.map(k=>[k,body[k]]));
  return res.status(200).json(await rpc(context,'unt_edit_task',{p_task_id:id,p_revision:body.revision,p_data:data}));
 }catch(e){return res.status(e.status||502).json({error:e.status?e.message:'Тапсырма сақталмады. Қайта көріңіз.'});}
};
