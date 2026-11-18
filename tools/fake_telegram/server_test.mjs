import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import test from 'node:test';
import {createFakeTelegram} from './server.mjs';

test('control inject preserves explicit duplicate IDs and advances automatic IDs', async () => {
  const server=createFakeTelegram();
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const base='http://127.0.0.1:'+server.address().port;
  try {
    const inject=async body=>{
      const res=await fetch(base+'/_control/inject',{method:'POST',body:JSON.stringify(body)});
      return [res.status,await res.json()];
    };
    assert.deepEqual(await inject({text:'a',chat_id:7}),[200,{update_id:1}]);
    assert.deepEqual(await inject({text:'b',chat_id:7,update_id:42}),[200,{update_id:42}]);
    assert.deepEqual(await inject({raw_update:{update_id:42,message:{text:'b'}}}),[200,{update_id:42}]);
    assert.deepEqual(await inject({text:'c',chat_id:7}),[200,{update_id:43}]);
    assert.equal((await inject({update_id:1.5}))[0],400);
    assert.equal((await inject({update_id:-1}))[0],400);
    const result=await (await fetch(base+'/botTEST:FAKE/getUpdates')).json();
    assert.deepEqual(result.result.map(u=>u.update_id),[1,42,42,43]);
  } finally {
    server.closeAllConnections();
    await new Promise(r=>server.close(r));
  }
});

test('reactions are recorded, filtered, validated and failure-injected', async () => {
  const server=createFakeTelegram();
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const base='http://127.0.0.1:'+server.address().port;
  const post=async(path,body)=>{
    const res=await fetch(base+path,{method:'POST',body:JSON.stringify(body)});
    return [res.status,await res.json()];
  };
  const get=async(path)=>(await fetch(base+path)).json();
  try {
    const reaction={chat_id:7,message_id:99,reaction:[{type:'emoji',emoji:'👀'}]};
    assert.deepEqual(await post('/botTEST:FAKE/setMessageReaction',reaction),[200,{ok:true,result:true}]);
    assert.deepEqual(await get('/_control/reactions?chat_id=7'),{reactions:[reaction]});
    assert.deepEqual(await get('/_control/reactions?chat_id=8'),{reactions:[]});
    assert.equal((await post('/botTEST:FAKE/setMessageReaction',{...reaction,message_id:'99'}))[0],400);
    assert.equal((await post('/_control/fail',{method:'setMessageReaction',status:500,delay_ms:-1}))[0],400);
    assert.equal((await post('/_control/fail',{method:'setMessageReaction',status:500,delay_ms:0.5}))[0],400);
    await post('/_control/fail',{method:'setMessageReaction',status:500,delay_ms:100});
    const started=performance.now();
    assert.equal((await post('/botTEST:FAKE/setMessageReaction',reaction))[0],500);
    assert.ok(performance.now()-started>=80,'injected failure waits for delay_ms');
    assert.deepEqual(await get('/_control/reactions'),{reactions:[reaction]});
    await post('/_control/inject',{chat_id:7,text:'id mapping',message_id:123});
    const updates=await get('/botTEST:FAKE/getUpdates');
    assert.equal(updates.result[0].message.message_id,123);
    assert.notEqual(updates.result[0].update_id,123);
  } finally {
    server.closeAllConnections();
    await new Promise(r=>server.close(r));
  }
});

async function fixture(fn) {
  const server=createFakeTelegram();
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base='http://127.0.0.1:'+server.address().port;
  const post=async(path,body)=>{
    const response=await fetch(base+path,{method:'POST',body:JSON.stringify(body)});
    return {status:response.status,body:await response.json()};
  };
  const get=async path=>(await fetch(base+path)).json();
  try { await fn({base,post,get}); }
  finally { server.closeAllConnections(); await new Promise(resolve=>server.close(resolve)); }
}

test('media injection maps every supported type and preserves binary file bytes', async()=>{
  await fixture(async({base,post,get})=>{
    const bytes=Buffer.from([0,255,128,13,10,42]);
    for (const type of ['photo','document','voice','audio','video','video_note','animation','sticker','location','contact','poll']) {
      assert.equal((await post('/_control/inject',{chat_id:7,from_id:8,media:{type,bytes_base64:bytes.toString('base64'),
        mime_type:'application/octet-stream',file_name:'file.bin',caption:'caption 🌏'}})).status,200);
    }
    const updates=(await get('/botTEST%3AFAKE/getUpdates')).result;
    assert.equal(updates.length,11);
    const photo=updates[0].message.photo;
    assert.deepEqual(photo.map(p=>[p.width,p.height]),[[90,90],[1280,960],[320,240]]);
    for (let i=0;i<7;i++) {
      const type=['photo','document','voice','audio','video','video_note','animation'][i];
      const message=updates[i].message;
      assert.equal(message.caption,'caption 🌏');
      const item=type==='photo'?message.photo[1]:message[type];
      if (type==='animation') assert.deepEqual(message.document,item);
      if (['voice','video_note'].includes(type)) assert.equal(Object.hasOwn(item,'file_name'),false);
      if (type==='video_note') assert.equal(Object.hasOwn(item,'mime_type'),false);
      const meta=await get('/botTEST%3AFAKE/getFile?file_id='+item.file_id);
      assert.equal(meta.ok,true); assert.equal(meta.result.file_size,bytes.length);
      assert.equal(Object.hasOwn(meta.result,'bytes'),false);
      const download=await fetch(base+'/file/botTEST%3AFAKE/'+meta.result.file_path);
      assert.equal(download.status,200);
      assert.equal(download.headers.get('content-type'),'application/octet-stream');
      assert.deepEqual(Buffer.from(await download.arrayBuffer()),bytes);
      const viaPost=await post('/botTEST:FAKE/getFile',{file_id:item.file_id});
      assert.deepEqual(viaPost.body,meta);
    }
    for (let i=7;i<11;i++) assert.deepEqual(updates[i].message[['sticker','location','contact','poll'][i-7]],{});
    for (const size of [photo[0],photo[2]]) {
      const meta=await get('/botTEST:FAKE/getFile?file_id='+size.file_id);
      assert.notEqual(meta.result.file_id,photo[1].file_id);
      assert.ok(meta.result.file_size>0);
    }
  });
});

test('file expiry and declared sizes are separate from stored bytes', async()=>{
  await fixture(async({base,post,get})=>{
    await post('/_control/inject',{chat_id:7,media:{type:'document',bytes_base64:'AP+A',declare_size:4294967296}});
    const meta=await get('/botTEST:FAKE/getFile?file_id=FAKEFILE1');
    assert.equal(meta.result.file_size,4294967296);
    assert.equal((await fetch(base+'/file/botTEST:FAKE/'+meta.result.file_path)).status,200);
    await post('/_control/file-expire',{file_id:'FAKEFILE1'});
    for (const file_id of ['FAKEFILE1','missing']) {
      assert.deepEqual(await post('/botTEST:FAKE/getFile',{file_id}),{status:400,
        body:{ok:false,error_code:400,description:'Bad Request: invalid file_id'}});
    }
    assert.equal((await fetch(base+'/file/botTEST:FAKE/unknown')).status,404);
    assert.equal((await fetch(base+'/file/botWRONG/'+meta.result.file_path)).status,401);
  });
});

test('all media sends parse multipart and record metadata and digest without bytes', async()=>{
  await fixture(async({base,post,get})=>{
    const bytes=Buffer.from([0,255,128]);
    const sha256=createHash('sha256').update(bytes).digest('hex');
    const send=async(method,field,chat='7',caption)=>{
      const form=new FormData();
      form.set('chat_id',chat);
      if (field) form.set(field,new Blob([bytes],{type:'application/octet-stream'}),'binary.bin');
      if (caption!==undefined) form.set('caption',caption);
      const response=await fetch(base+'/botTEST%3AFAKE/'+method,{method:'POST',body:form});
      return {status:response.status,body:await response.json()};
    };
    for (const [method,field] of Object.entries({sendPhoto:'photo',sendDocument:'document',sendVoice:'voice',sendAudio:'audio'})) {
      const caption=method==='sendVoice'?undefined:'caption 🌏';
      const result=await send(method,field,'7',caption);
      assert.equal(result.status,200);
      assert.equal(result.body.result.chat.id,7);
      const messages=(await get('/_control/sent?chat_id=7')).messages;
      const row=messages.at(-1);
      assert.deepEqual(row,{message_id:messages.length,method,chat_id:7,
        ...(caption===undefined?{}:{caption}),filename:'binary.bin',mime:'application/octet-stream',size:bytes.length,sha256});
      assert.equal((await send(method,field,'1.2')).status,400);
      assert.equal((await send(method,null)).status,400);
      await post('/_control/fail',{method,status:400});
      assert.equal((await send(method,field)).status,400);
    }
    assert.equal((await get('/_control/sent')).messages.length,4);
    assert.deepEqual(await post('/botTEST:FAKE/sendMessage',{chat_id:7,text:'still text'}),{
      status:200,body:{ok:true,result:{message_id:5,chat_id:7,text:'still text'}}});
    assert.deepEqual((await get('/_control/sent')).messages.at(-1),{message_id:5,chat_id:7,text:'still text'});
  });
});

test('media bodies above the old 4 MiB cap preserve their digest', async()=>{
  await fixture(async({base,get})=>{
    const bytes=Buffer.alloc(5_000_000,0x8f);
    const form=new FormData();
    form.set('chat_id','7');
    form.set('document',new Blob([bytes],{type:'application/pdf'}),'large.pdf');
    const response=await fetch(base+'/botTEST:FAKE/sendDocument',{method:'POST',body:form});
    assert.equal(response.status,200);
    const row=(await get('/_control/sent')).messages[0];
    assert.equal(row.size,bytes.length);
    assert.equal(row.sha256,createHash('sha256').update(bytes).digest('hex'));
  });
});
