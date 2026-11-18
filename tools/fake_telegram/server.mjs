import http from 'node:http';
import {pathToFileURL} from 'node:url';

export function createFakeTelegram({token='TEST:FAKE', botUsername='ninjy_test_bot'}={}) {
  let nextUpdate=1, nextMessage=1, updates=[];
  const sent=[], offsets=[], failures=new Map(), polls=new Set();
  const reply=(res,status,value)=>{
    if (!res.destroyed && !res.writableEnded) {
      res.writeHead(status, {'content-type':'application/json'});
      res.end(JSON.stringify(value));
    }
  };
  const server=http.createServer(async(req,res)=>{
    try {
      const url=new URL(req.url,'http://localhost');
      let raw='';
      for await (const chunk of req) {
        raw+=chunk;
        if (raw.length>4*1024*1024) {reply(res,413,{ok:false});return;}
      }
      const body=raw ? JSON.parse(raw) : {};
      if (url.pathname==='/_control/inject' && req.method==='POST') {
        const explicit=body.update_id ?? body.raw_update?.update_id;
        if (explicit !== undefined && (!Number.isSafeInteger(explicit) || explicit < 0)) {
          reply(res,400,{ok:false,error:'invalid_update_id'});return;
        }
        const update_id=explicit ?? nextUpdate++;
        nextUpdate=Math.max(nextUpdate,update_id+1);
        const message={chat:{id:body.chat_id,type:body.chat_type??'private'},
          from:{id:body.from_id,username:body.username,first_name:body.first_name??'Test'}};
        if (Object.hasOwn(body,'text')) message.text=body.text;
        else message.photo=[];
        updates.push(body.raw_update ? {...body.raw_update,update_id} : {update_id,message});
        reply(res,200,{update_id});
        for (const poll of [...polls]) poll(false);
        return;
      }
      if (url.pathname==='/_control/sent') {
        const chat=url.searchParams.get('chat_id');
        reply(res,200,{messages:sent.filter(m=>chat===null || String(m.chat_id)===chat)});return;
      }
      if (url.pathname==='/_control/offsets') {reply(res,200,offsets);return;}
      if (url.pathname==='/_control/fail' && req.method==='POST') {
        failures.set(body.method,{...body,count:body.count??1});reply(res,200,{ok:true});return;
      }
      const pathname=decodeURIComponent(url.pathname);
      const prefix='/bot'+token+'/';
      if (!pathname.startsWith(prefix)) {
        reply(res,401,{ok:false,error_code:401,description:'Unauthorized'});return;
      }
      const method=pathname.slice(prefix.length), fail=failures.get(method);
      if (fail?.count>0) {
        if (--fail.count===0) failures.delete(method);
        reply(res,fail.status,{ok:false,error_code:fail.status,
          description:fail.description??'injected failure',parameters:{retry_after:fail.retry_after??0}});return;
      }
      if (method==='getMe') {reply(res,200,{ok:true,result:{id:123456,username:botUsername}});return;}
      if (method==='sendMessage' && req.method==='POST') {
        if (!Number.isSafeInteger(body.chat_id) || typeof body.text!=='string' || Buffer.byteLength(body.text)>4000) {
          reply(res,400,{ok:false,error_code:400,description:'Bad Request'});return;
        }
        const message={message_id:nextMessage++,chat_id:body.chat_id,text:body.text};
        sent.push(message);reply(res,200,{ok:true,result:message});return;
      }
      if (method==='getUpdates') {
        const offset=url.searchParams.has('offset') ? Number(url.searchParams.get('offset')) : null;
        offsets.push(offset);
        if (offset!==null) updates=updates.filter(u=>u.update_id>=offset);
        const timeout=Math.max(0,Math.min(30,Number(url.searchParams.get('timeout')??0)));
        let timer;
        const poll=(expired)=>{
          if (!expired && updates.length===0) return;
          polls.delete(poll);clearTimeout(timer);
          reply(res,200,{ok:true,result:updates});
        };
        polls.add(poll);
        res.on('close',()=>{polls.delete(poll);clearTimeout(timer);});
        if (updates.length || timeout===0) poll(true);
        else timer=setTimeout(()=>poll(true),timeout*1000);
        return;
      }
      reply(res,404,{ok:false,error_code:404,description:'Not Found'});
    } catch {reply(res,400,{ok:false,error_code:400,description:'Bad Request'});}
  });
  server.on('close',()=>{for(const poll of [...polls]) poll(true);});
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = new Map();
  for (let i=2; i<process.argv.length; i+=2) args.set(process.argv[i],process.argv[i+1]);
  const server = createFakeTelegram({token:args.get('--token'),botUsername:args.get('--bot-username')});
  server.listen(Number(args.get('--port') ?? 18099), '127.0.0.1', async () => {
    const base = 'http://127.0.0.1:' + server.address().port;
    if (args.has('--ready-file')) {
      const {writeFileSync} = await import('node:fs');
      writeFileSync(args.get('--ready-file'),base);
    }
    console.log(JSON.stringify({listening:base}));
  });
  for (const signal of ['SIGINT','SIGTERM']) process.on(signal,()=>{server.close();server.closeAllConnections();});
}
