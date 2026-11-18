import assert from 'node:assert/strict';
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
