const {HyperFormula}=require('hyperformula');const assert=require('node:assert/strict');const {tasks}=require('../scripts/curriculum.cjs');
const sheet=()=>Array.from({length:10},()=>Array(8).fill(null));
// FALSE() is the engine-compatible spelling of Excel's FALSE boolean constant.
const fixtures={
'spreadsheets-b01':s=>{s[0][0]=12;s[0][1]=5;s[0][2]='=(A1+B1)*2';return [2,0];},
'spreadsheets-b02':s=>{s[2][0]=8;s[2][1]=11;s[1][2]='=A2+B2';return [2,1,2,2];},
'spreadsheets-c01':s=>{s[4][0]=240;s[0][1]=.15;s[0][3]=200;s[1][2]='=IF(A2>=$D$1,A2*(1-$B$1),A2)';return[2,1,2,4];},
'spreadsheets-c02':s=>{[2,4,6,8].forEach((v,i)=>s[4][i]=v);s[0][4]=3;s[1][5]=5;s[2][2]='=SUM($A3:B3)*C$1+$F$2';return[2,2,4,4];},
'spreadsheets-c03':s=>{[4,7,-2,9,6,12].forEach((v,i)=>s[i][0]=v);s[0][3]='=IF(COUNTIF(A1:A6,"<0")>0,SUM(A1:A6)-MAX(A1:A6)*2,AVERAGE(A1:A6))';return[3,0];},
'spreadsheets-c04':s=>{[40,75,90,75,60,100,55,80].forEach((v,i)=>s[i][0]=v);s[0][3]='=COUNTIF(A1:A8,">=75")-COUNTIF(A1:A8,">90")+COUNTIF(A1:A8,"<60")*2';return[3,0];},
'spreadsheets-c05':s=>{['A','B','A','A','B','A'].forEach((v,i)=>s[i][0]=v);[10,20,30,40,50,60].forEach((v,i)=>s[i][1]=v);[1,1,0,1,1,1].forEach((v,i)=>s[i][2]=v);s[0][4]='=SUMIFS(B1:B6,A1:A6,"A",C1:C6,1)/COUNTIFS(A1:A6,"A",C1:C6,1)';return[4,0];},
'spreadsheets-c06':s=>{s[3][0]=82;s[3][1]=3;[80,2,10].forEach((v,i)=>s[i][5]=v);s[1][2]='=IF(AND(A2>=$F$1,B2<=$F$2),A2+$F$3,IF(A2>=60,A2-5,0))';return[2,1,2,3];},
'spreadsheets-c07':s=>{[[101,12],[102,15],[103,20]].forEach((r,i)=>{s[i][0]=r[0];s[i][1]=r[1]});s[1][3]=102;s[1][4]=8;s[0][5]=.1;s[1][6]='=VLOOKUP(D2,$A$1:$B$3,2,FALSE())*E2*IF(E2>=5,1-$F$1,1)';return[6,1];},
'spreadsheets-c08':s=>{s[0][0]=10;s[2][0]="'20";s[3][0]='=5+5';s[4][0]='=""';s[5][0]='жоқ';s[0][3]='=COUNTA(A1:A6)*10-COUNT(A1:A6)-IF(LEN(A5)=0,2,0)';return[3,0];},
'spreadsheets-c09':s=>{s[0][0]=.125;s[1][0]=.075;s[0][1]='=SUM(A1:A2)*1.5';return[1,0];},
'spreadsheets-c10':s=>{[[3,1,2],[5,2,4],[7,3,6],[9,4,8]].forEach((r,i)=>r.forEach((v,j)=>s[i+1][j]=v));s[1][2]='=SUM($A$2:A2)-SUM($B$2:B2)';return[2,1,3,4];}
};
for(const task of tasks.filter(t=>t.topic_id==='spreadsheets')){
 const s=sheet(),[c,r,dc,dr]=fixtures[task.id](s);
 const canonical=f=>f.replace(/\s+/g,'').replace(/FALSE\(\)/g,'FALSE');assert.equal(canonical(s[r][c]),canonical(task.code),task.id+' formula drift');
 const hf=HyperFormula.buildFromArray(s,{licenseKey:'gpl-v3'});
 try{let target={sheet:0,col:c,row:r};if(dc!==undefined){hf.copy({start:target,end:target});target={sheet:0,col:dc,row:dr};hf.paste(target);}
 let v=hf.getCellValue(target);if(task.id==='spreadsheets-c05')v=Number(v.toFixed(4));if(task.id==='spreadsheets-c09')v=(v*100).toFixed(2)+'%';
 assert.equal(String(v).toLowerCase(),task.answer.toLowerCase(),task.id+': '+String(v));
 }finally{hf.destroy();}
}
console.log('All 12 Excel answers match independent HyperFormula evaluation, including formula copy and mixed references.');
