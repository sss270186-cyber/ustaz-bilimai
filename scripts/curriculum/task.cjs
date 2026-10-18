// Authoring helper: all solutions remain outside the public static output.
function lessonTasks(topic, rows) {
 return rows.map((r,i)=>({id:`${topic}-${i<2?'b':'c'}${String(i<2?i+1:i-1).padStart(2,'0')}`,topic_id:topic,
 level:i<2?'B':'C',position:i<2?i+1:i-1,title:r[0],prompt:r[1],given_data:r[2],find_value:r[3],formulas:r[4].split('\n'),
 unit:r[5],answer:String(r[6]),steps:r[7],explanation:r[8],code:r[9]||'',answer_format:r[10]||'number'}));
}
module.exports={lessonTasks};
