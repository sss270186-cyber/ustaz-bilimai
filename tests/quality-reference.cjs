// Independent models for reviewed non-programming tasks. Python/SQL/CSS/Excel use separate engines.
const C=(n,k)=>{let v=1;for(let i=1;i<=k;i++)v=v*(n-i+1)/i;return v;};
const count=(n,fn)=>Array.from({length:2**n},(_,i)=>Array.from({length:n},(_,j)=>(i>>(n-1-j))&1)).filter(a=>fn(...a)).length;
module.exports={
'hardware-c06':8*(3+60/7500*500+1/250*1000),
'hardware-c07':.98*(1-.05**2)*100,'hardware-c10':Number(((1000/120-2.5-4)*.8).toFixed(3)),
'software-c02':(0+5+8+0)/4,'software-c06':Math.max(3+4,Math.max(3,5)+2)+1,'software-c09':(120+180)/30+2*2,'software-c10':Math.ceil(53/6)*7+Math.ceil(5/2)*4,
'memory-c01':1+.1*(5+.2*80),'memory-c09':4096+7*Math.ceil(120/32)*32+18*4,
'alphabet-c05':50*(Math.ceil(1024*7/8)-Math.ceil(1024*5/8)),'alphabet-c08':2**8-32-150,
'encoding-c03':((100+60+128)%256)-128,'encoding-c04':((parseInt('11101010',2)-256+3)&255).toString(2),'encoding-c05':(()=>{let x=0x12f0+0x0130;return(x&255).toString(16)+' '+(x>>8).toString(16)})(),
'encoding-c06':'4 4','encoding-c07':(0x96^0x0f^0xc3).toString(16).toUpperCase(),'encoding-c08':(()=>{let l=4*Math.ceil(1025/3);return l+2*(Math.ceil(l/76)-1)+20;})(),'encoding-c09':603-(2*(Math.ceil(600/255)+1)+4),'encoding-c10':[1,2,3,4,1].reduce((a,b)=>a+b),
'number-systems-c02':5.625+7.5-10.5,'number-systems-c04':(0xafff00>>8)&0xfff,'number-systems-c05':(((250+19)%256*3)%256).toString(16),'number-systems-c06':(parseInt('1101',2)*parseInt('101',2)+parseInt('37',8)).toString(2).padStart(8,'0'),'number-systems-c07':(((0xb6&0x6d)<<2)&255)|15,
'number-systems-c08':count(8,(a,b,c,d,e,f,g,h)=>a===1&&h===0&&(a+b+c+d+e+f+g+h)===4&&b!==c),'number-systems-c09':2*(15.5-3.25),'number-systems-c10':[...((0x3f80^0x0ff0)&255).toString(2)].filter(x=>x==='1').length,
'networks-c02':6*2+5*.5,'networks-c05':.98*(1-.01**2)*100,'networks-c06':18-1,'networks-c07':6*Math.ceil(47/22),
'bandwidth-c02':.5+800*1.25/Math.min(100,40,80),'bandwidth-c09':Math.ceil(200e6*.04/8/65536)*64,
'ip-c01':'172.19.84.0/23','ip-c04':'10.42.9.98','ip-c05':[3,62,63,64,100,127,128,190,191,192].filter(x=>x%64!==0&&x%64!==63).length,'ip-c06':(2**5-2)*(2**11-2-10),'ip-c09':32-Math.ceil(Math.log2(Math.ceil(410*1.25)+13+2)),
'dns-c04':Math.min(0+300,80+120)-150,'dns-c07':'180 120','dns-c08':17+(1+4)+2,'dns-c09':(1+Math.floor(179/60))+(1+Math.floor(179/45)),'dns-c10':2*[[1,1,1],[1,0,1],[1,1,0],[1,1,1]].filter(a=>a.every(Boolean)).length,
'logic-c01':count(4,(a,b,c,d)=>((a^b)&&(c||d))||(a&&b&&!c&&!d)),'logic-c02':count(4,(a,b,c,d)=>!a&&!b&&(c||d)&&(c!==d)),'logic-c03':count(4,(a,b,c,d)=>((a&&b)||(a&&!b)||(!a&&c))&&d===a),'logic-c04':count(4,(b,c,d,e)=>(b+c+d+e)>=3),'logic-c05':'0110 2','logic-c06':(()=>{let s=0;for(let i=1;i<=6;i++)s=s%2===0?s+i:2*s-i;return s})(),'logic-c09':count(4,(a,b,c,d)=>(!a||b)&&(!b||c)&&(a||d)&&(a+b+c+d)===2),
'ai-c01':100*3/(3+2),'ai-c02':100*2/(2+2),'ai-c04':Math.abs(.5-.25)+Math.abs(.75-.25),'ai-c05':2*((76-60)/8)-(70-100)/20+.5,'ai-c06':'B','ai-c10':Number((1-(-.75*Math.log2(.75)-.25*Math.log2(.25))).toFixed(6)),
'neural-networks-c03':(3*3*3+1)*4+((8-3+1)**2*4+1)*3,'neural-networks-c04':(Math.floor((Math.floor((32+2-5)/2)+1-2)/2)+1)**2*8,'neural-networks-c06':'0.5 1','neural-networks-c07':'1/3 1/2 1/6','neural-networks-c08':-[.5,.25,.125].map(x=>Math.log2(x)).reduce((a,b)=>a+b)/3,'neural-networks-c09':Number((2/.75-6/.75+2).toFixed(6))
};
