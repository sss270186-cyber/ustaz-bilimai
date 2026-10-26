const http=require('node:http'),fs=require('node:fs'),path=require('node:path');
async function startPreview(workerPath){
 const source=fs.readFileSync(workerPath,'utf8'),worker=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
 let origin;const server=http.createServer(async(req,res)=>{
  try{
   const chunks=[];let total=0;for await(const chunk of req){total+=chunk.length;if(total>8192){res.writeHead(413);res.end();return;}chunks.push(chunk);}
   const request=new Request(origin+req.url,{method:req.method,headers:req.headers,...(['GET','HEAD'].includes(req.method)?{}:{body:Buffer.concat(chunks)})});
   const response=await worker.default.fetch(request,{},{});res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
  }catch{res.writeHead(500);res.end('Preview error');}
 });
 await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;
 return {origin,worker,close:()=>new Promise(r=>server.close(r))};
}
module.exports={startPreview};
