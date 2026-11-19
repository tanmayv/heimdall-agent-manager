import http from 'node:http';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';

export function createFakeTelegram({token='TEST:FAKE', botUsername='ninjy_test_bot'}={}) {
  let nextUpdate=1, nextMessage=1, nextFile=1, updates=[];
  const files=new Map();
  const storeFile=(bytes,declareSize)=>{
    const n=nextFile++, file_id='FAKEFILE'+n;
    const file={file_id,file_unique_id:'UNIQUE'+n,file_size:declareSize??bytes.length,file_path:'files/'+n,bytes};
    files.set(file_id,file);
    return file;
  };
  const wireFile=({bytes,expired,...file})=>file;
  const sent=[], reactions=[], offsets=[], failures=new Map(), polls=new Set();
  const reply=(res,status,value)=>{
    if (!res.destroyed && !res.writableEnded) {
      res.writeHead(status, {'content-type':'application/json'});
      res.end(JSON.stringify(value));
    }
  };
  const server=http.createServer(async(req,res)=>{
    try {
      const url=new URL(req.url,'http://localhost');
      const chunks=[];
      let size=0;
      for await (const chunk of req) {
        chunks.push(chunk); size+=chunk.length;
        if (size>60_000_000) {reply(res,413,{ok:false});return;}
      }
      const raw=Buffer.concat(chunks);
      const multipart=req.headers['content-type']?.startsWith('multipart/form-data');
      const form=multipart ? await new Response(raw,{headers:{'content-type':req.headers['content-type']}}).formData() : null;
      const body=!multipart && raw.length ? JSON.parse(raw.toString('utf8')) : {};
      if (url.pathname==='/_control/inject' && req.method==='POST') {
        const explicit=body.update_id ?? body.raw_update?.update_id;
        if (explicit !== undefined && (!Number.isSafeInteger(explicit) || explicit < 0)) {
          reply(res,400,{ok:false,error:'invalid_update_id'});return;
        }
        const update_id=explicit ?? nextUpdate++;
        nextUpdate=Math.max(nextUpdate,update_id+1);
        const message={message_id:body.message_id??update_id,chat:{id:body.chat_id,type:body.chat_type??'private'},
          from:{id:body.from_id,username:body.username,first_name:body.first_name??'Test'}};
        if (Object.hasOwn(body,'text')) message.text=body.text;
        else if (!body.media) message.photo=[];
        if (body.media) {
          const media=body.media, type=media.type;
          const bytes=Buffer.from(media.bytes_base64??'','base64');
          const file=storeFile(bytes,media.declare_size);
          const common={file_id:file.file_id,file_unique_id:file.file_unique_id,file_size:file.file_size};
          if (type==='photo') {
            const photo=(f,width,height)=>({file_id:f.file_id,file_unique_id:f.file_unique_id,file_size:f.file_size,width,height});
            message.photo=[photo(storeFile(Buffer.from('small')),90,90),photo(file,1280,960),photo(storeFile(Buffer.from('medium')),320,240)];
          } else if (['document','voice','audio','video','video_note','animation'].includes(type)) {
            const item={...common};
            if (type!=='video_note' && media.mime_type!==undefined) item.mime_type=media.mime_type;
            if (!['voice','video_note'].includes(type) && media.file_name!==undefined) item.file_name=media.file_name;
            message[type]=item;
            if (type==='animation') message.document={...item};
          } else if (['sticker','location','contact','poll'].includes(type)) message[type]={};
          if (media.caption!==undefined) message.caption=media.caption;
        }
        updates.push(body.raw_update ? {...body.raw_update,update_id} : {update_id,message});
        reply(res,200,{update_id});
        for (const poll of [...polls]) poll(false);
        return;
      }
      if (url.pathname==='/_control/sent') {
        const chat=url.searchParams.get('chat_id');
        reply(res,200,{messages:sent.filter(m=>chat===null || String(m.chat_id)===chat)});return;
      }
      if (url.pathname==='/_control/reactions') {
        const chat=url.searchParams.get('chat_id');
        reply(res,200,{reactions:reactions.filter(row=>chat===null || String(row.chat_id)===chat)});return;
      }
      if (url.pathname==='/_control/offsets') {reply(res,200,offsets);return;}
      if (url.pathname==='/_control/fail' && req.method==='POST') {
        const delay=body.delay_ms??0;
        if (!Number.isSafeInteger(delay) || delay<0) {
          reply(res,400,{ok:false,error:'invalid_delay_ms'});return;
        }
        failures.set(body.method,{...body,count:body.count??1,delay_ms:Math.min(delay,10000)});
        reply(res,200,{ok:true});return;
      }
      const pathname=decodeURIComponent(url.pathname);
      if (pathname==='/_control/file-expire' && req.method==='POST') {
        const file=files.get(body.file_id);
        if (file) file.expired=true;
        reply(res,200,{ok:true});return;
      }
      const filePrefix='/file/bot'+token+'/';
      if (pathname.startsWith(filePrefix) && req.method==='GET') {
        const file=[...files.values()].find(f=>f.file_path===pathname.slice(filePrefix.length));
        if (!file || file.expired) {reply(res,404,{ok:false});return;}
        res.writeHead(200,{'content-type':'application/octet-stream'});
        res.end(file.bytes);return;
      }
      const prefix='/bot'+token+'/';
      if (!pathname.startsWith(prefix)) {
        reply(res,401,{ok:false,error_code:401,description:'Unauthorized'});return;
      }
      const method=pathname.slice(prefix.length), fail=failures.get(method);
      if (fail?.count>0) {
        if (--fail.count===0) failures.delete(method);
        if (fail.delay_ms) await new Promise(resolve=>setTimeout(resolve,fail.delay_ms));
        reply(res,fail.status,{ok:false,error_code:fail.status,
          description:fail.description??'injected failure',parameters:{retry_after:fail.retry_after??0}});return;
      }
      if (method==='setMessageReaction' && req.method==='POST') {
        const validReaction=Number.isSafeInteger(body.message_id) && Array.isArray(body.reaction) &&
          body.reaction.every(item=>item.type==='emoji' && typeof item.emoji==='string');
        if (!Number.isSafeInteger(body.chat_id) || !validReaction) {
          reply(res,400,{ok:false,error_code:400,description:'Bad Request'});return;
        }
        reactions.push({chat_id:body.chat_id,message_id:body.message_id,reaction:body.reaction});
        reply(res,200,{ok:true,result:true});return;
      }
      if (method==='getFile') {
        const id=req.method==='GET' ? url.searchParams.get('file_id') : body.file_id;
        const file=files.get(id);
        if (!file || file.expired) {
          reply(res,400,{ok:false,error_code:400,description:'Bad Request: invalid file_id'});return;
        }
        reply(res,200,{ok:true,result:wireFile(file)});return;
      }
      const mediaField={sendPhoto:'photo',sendDocument:'document',sendVoice:'voice',sendAudio:'audio'}[method];
      if (mediaField && req.method==='POST') {
        const chat=form?.get('chat_id'), file=form?.get(mediaField);
        if (typeof chat!=='string' || !/^-?\d+$/.test(chat) || !Number.isSafeInteger(Number(chat)) ||
            !file || typeof file==='string' || typeof file.arrayBuffer!=='function') {
          reply(res,400,{ok:false,error_code:400,description:'Bad Request'});return;
        }
        const bytes=Buffer.from(await file.arrayBuffer());
        const message={message_id:nextMessage++,method,chat_id:Number(chat),
          ...(form.has('caption') ? {caption:form.get('caption')} : {}),
          filename:file.name,mime:file.type,size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};
        sent.push(message);
        reply(res,200,{ok:true,result:{...message,chat:{id:Number(chat)}}});return;
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
