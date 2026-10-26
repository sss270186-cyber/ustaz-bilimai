// Independent numerical/algorithmic models; not imported by lesson authoring code.
function pageFaults(seq,policy){const pages=[],last=new Map();let faults=0;seq.forEach((v,i)=>{if(!pages.includes(v)){faults++;if(pages.length===3){const index=policy==='FIFO'?0:pages.indexOf([...pages].sort((a,b)=>last.get(a)-last.get(b))[0]);pages.splice(index,1);}pages.push(v);}last.set(v,i);});return faults;}
function hamming(a,b){return [...a].filter((v,i)=>v!==b[i]).length;}
function truth(fn,n){return Array.from({length:2**n},(_,i)=>fn(...Array.from({length:n},(_,j)=>(i>>(n-j-1))&1)));}
module.exports={
 hardware:[3*2*.5,'ssd',1.2*1.5/3,1/(.2+.8/4),64/8*.8*2,(95+180+65)*1.25,3840*2160*4*3,60/7500*500,.98*.95*100,40*150-30*160,2*8/(10*.8),Number((1000/144).toFixed(3))],
 software:['драйвер',18*8000*.85,'/home/teacher/materials/plan.txt',(0+9+12)/3,8,39*600/1000,'750','иә',(512-120)/2,9*20-(20+8*3),'жоқ',Math.ceil(48/6)*7],
 memory:[2**18/1024,4096*16/8192,2+.1*80,32-Math.log2(64)-Math.log2(16384/64),(2**20*16)/(2**18*8),2**20*4/2**20,pageFaults([1,2,3,1,4,1,2,5],'FIFO'),pageFaults([1,2,3,1,4,1,2,5],'LRU'),8+10*12,12,4096+37*4,2*8*3.2],
 alphabet:[Math.log2(32),256*Math.log2(64)/8,Math.ceil(1000*Math.ceil(Math.log2(70))/8),2**(3072*8/4096),(200*7-300*4)/8,800*Math.ceil(13*7/8),1024*(6-5)/8,Math.floor(8192/6),40*(512+24)/1024,256-130,4*5+3*4,Math.floor(9*1024/(32*48*6/8))],
 encoding:[65+3,Buffer.byteLength('AӘ🙂','utf8'),120*2+30*4,150*4-(100+50*2),((-37)&255).toString(2),parseInt('11101010',2)-256,'7f 3a',hamming('10110100','10001101'),(0x5a^0xc3).toString(16),4*Math.ceil(1025/3),2*5,'abcda'],
 'number-systems':[parseInt('110101',2),(254).toString(16),parseInt('2f',16)+parseInt('101101',2)+parseInt('73',8),5+.5+.125,6,(2**20-1).toString(16),(250+19)%256,(13*5).toString(2),0xb6&0x6d,3,8+7+4/8,[...(0x3f80).toString(2)].filter(x=>x==='1').length],
 networks:[12,'lan',8*7/2-2,Math.min(6,10-6),3*(1500*8/1e8*1000+.2),(5+3-1)*2,(1-.01*.01)*100,3,6,Math.ceil(10000/1460),50-12-17-4-4,8],
 bandwidth:[20e6*8/80e6,12*15/8,300*2**20*8/75e6,800/40,90*8/(120/5),10500*1200*8/84e6,Math.floor(80/6),60*8/24+40*8/40,(64/40-1)*100,10000*1040*8/104e6,200e6*.04/8/1000,24-(4+60*8/40)],
 ip:['192.168.14.0',2**5-2,'172.19.80.0','10.24.39.255','192.168.5.190',64+32+16,'жоқ',2**5,'192.168.32.0/21','172.16.9.44',32-Math.ceil(Math.log2(502)),'2001:db8::20:0:0:1'],
 dns:['dns',600-(460-100),'2001:db8::5',3*20+6,.8*2+.2*52,Math.min(300,120),Math.min(63,255-3*63-3-6),'mail4',180,(1+3)+(1+6)+(1+4)+1,[0,60,120].length,'жоқ'],
 logic:[1,2**5,truth((a,b,c)=>(a^b)&c,3).filter(Boolean).length,'not a and not b and c','a',truth((a,b,c)=>(a&b)|(a&c)|(b&c),3).filter(Boolean).length,0,[1,3,5,7,9].reduce((a,b)=>a+b,0),13,truth((a,b,c,d)=>Number(a===b)&(c^d),4).filter(Boolean).length,'1 0',truth((a,b,c)=>((1-a)&b)|(a&(1-c)),3).join('')],
 spreadsheets:[(12+5)*2,8+11,240*.15,7*9,[4,7,-2,9,6].reduce((a,b)=>a+b,0)-9,5-1,(10+30+50)/3,'b',15*4,4-2,'12.50%',3+5+7+9],
 ai:['supervised',2000*.8,36/48*100,42/56*100,Number((2*.8*.5/1.3).toFixed(4)),(30-10)/(50-10),(76-60)/8,'b',((5-4)**2+(7-8)**2+(9-8)**2)/3,'95 0',(8+9*4)-(20+5*4),1],
 'neural-networks':[2*3-4+1,Math.max(0,-2.5),2*Math.max(0,2-2+1)-Math.max(0,-2+3)+1,(4+1)*6+(6+1)*3,(3*3*3+1)*8,(32-5)/1+1,1-.1*(2*(1*2-5)*2),'0.5 1',.5,-Math.log2(.125),6/.75,.8-.2*((2-1+3+0)/4)]
};
