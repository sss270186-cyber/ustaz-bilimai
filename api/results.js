const {headers,authenticate,rpc}=require('./_lib/supabase.cjs');
module.exports=async(req,res)=>{
 headers(res);if(req.method!=='GET')return res.status(405).json({error:'Әдіс рұқсат етілмеген'});
 try{
  const rows=await rpc(await authenticate(req),'unt_results_export');
  const cell=value=>'"'+String(value??'').replace(/^[\s]*[=+\-@]/,"'$&").replaceAll('"','""')+'"';
  const csv='\ufeff'+[['Логин','Оқушы','Есеп','Нұсқа','Жауап','Дұрыс','Уақыты'],...rows.map(r=>[r.username,r.full_name,r.task_id,r.task_revision,r.submitted_answer,r.correct?'Иә':'Жоқ',r.created_at])].map(row=>row.map(cell).join(',')).join('\r\n');
  res.setHeader('Content-Type','text/csv; charset=utf-8');res.setHeader('Content-Disposition','attachment; filename="bilimai-results.csv"');return res.status(200).send(csv);
 }catch(e){return res.status(e.status||502).json({error:e.status?e.message:'Нәтижелер жүктелмеді. Қайта көріңіз.'});}
};
