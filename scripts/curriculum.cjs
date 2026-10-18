const base=require('./curriculum-base.cjs');const patches=require('./curriculum/reviewed.cjs');
module.exports={topics:base.topics,tasks:base.tasks.map(original=>{
 const patch=patches[original.id]||{};const t={...original,...patch};
 return {...t,error_feedback:'Жауап берілген модельге сәйкес келмеді. Тексеру бағыты: '+t.explanation,mistakes:patch.mistakes||{}};
})};
