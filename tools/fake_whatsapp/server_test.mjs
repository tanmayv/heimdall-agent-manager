import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHmac } from 'node:crypto';
import { once } from 'node:events';
import { createFakeWhatsApp } from './server.mjs';

async function fixture(t) {
  const received = [];
  const webhook = http.createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    received.push({ body, signature: req.headers['x-hub-signature-256'], url: req.url });
    if (req.method === 'GET') {
      const url = new URL(req.url, 'http://localhost');
      res.writeHead(url.searchParams.get('hub.verify_token') === 'test-verify-token-0001' ? 200 : 403, { 'Content-Type': 'text/plain' });
      res.end(url.searchParams.get('hub.challenge'));
    } else { res.writeHead(200); res.end('ok'); }
  });
  webhook.listen(0, '127.0.0.1');
  await once(webhook, 'listening');
  const server = createFakeWhatsApp({ webhookUrl: 'http://127.0.0.1:' + webhook.address().port + '/webhook' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    await Promise.all([new Promise(resolve => server.close(resolve)), new Promise(resolve => webhook.close(resolve))]);
  });
  const base = 'http://127.0.0.1:' + server.address().port;
  const request = async (path, body, token = 'TEST-WA-TOKEN') => {
    const response = await fetch(base + path, { method: body === undefined ? 'GET' : 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' }, body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const control = (name, body) => request('/_control/' + name, body);
  const graph = body => request('/v27.0/100000000000001/messages', { messaging_product: 'whatsapp', recipient_type: 'individual', ...body });
  return { received, request, control, graph };
}

test('auth refusal, identity and graph versions', async t => {
  const f = await fixture(t);
  const refused = await f.request('/v27.0/100000000000001', undefined, 'wrong');
  assert.equal(refused.status, 401);
  assert.equal(refused.body.error.code, 190);
  assert.deepEqual((await f.request('/v27.0/100000000000001?fields=display_phone_number,verified_name')).body,
    { display_phone_number: '15550100001', verified_name: 'Ninjy Test', id: '100000000000001' });
  assert.equal((await f.request('/v26.0/wrong/messages', {})).body.error.code, 100);
  assert.deepEqual((await f.control('versions')).body, { versions: ['v27.0', 'v26.0'] });
});

test('text, BSUID, reaction, read and template recording in send order', async t => {
  const f = await fixture(t);
  await f.control('inject', { from: '15551230001' });
  for (const address of [{ to: '+15551230001' }, { recipient: 'US.15551230001' }]) {
    const sent = await f.graph({ ...address, type: 'text', text: { preview_url: false, body: 'echo: hi' } });
    assert.equal(sent.status, 200);
    assert.match(sent.body.messages[0].id, /^wamid.FAKE/);
  }
  assert.equal((await f.graph({ to: '+15551230001', type: 'reaction', reaction: { message_id: 'wamid.IN', emoji: '👀' } })).status, 200);
  assert.deepEqual((await f.graph({ status: 'read', message_id: 'wamid.IN' })).body, { success: true });
  assert.equal((await f.graph({ type: 'text' })).body.error.code, 100);
  assert.equal((await f.graph({ to: '+1', recipient: 'US.x', type: 'text' })).body.error.code, 100);
  const template = { name: 'ninjy_reply_waiting', language: { code: 'en' } };
  assert.equal((await f.graph({ to: '+15551230001', type: 'template', template })).body.error.code, 132001);
  await f.control('templates', { approved: ['ninjy_reply_waiting'] });
  assert.equal((await f.graph({ to: '+15551230001', type: 'template', template: { ...template, language: { code: 'en_US' } } })).body.error.code, 132001);
  assert.equal((await f.graph({ to: '+15551230001', type: 'template', template })).status, 200);
  await f.control('templates', { approved: [] });
  assert.equal((await f.graph({ to: '+15551230001', type: 'template', template })).body.error.code, 132001);
  const sent = (await f.control('sent')).body.messages;
  assert.deepEqual(sent.map(m => m.type), ['text', 'text', 'reaction', 'template']);
  assert.equal(sent[0].to, '15551230001');
  assert.equal(sent[1].to, 'US.15551230001');
  assert.equal(sent[0].text, 'echo: hi');
  assert.deepEqual(sent[3].template, template);
  assert.equal(sent[2].reaction, '👀');
  assert.equal(sent[2].reaction_message_id, 'wamid.IN');
  assert.equal((await f.control('sent?to=15551230001')).body.messages.length, 3);
  assert.deepEqual((await f.control('reads')).body, { reads: [{ message_id: 'wamid.IN' }] });
});

test('sync and async closed windows, sticky close and timestamps', async t => {
  const f = await fixture(t);
  const text = { to: '+15551230001', type: 'text', text: { body: 'hello' } };
  assert.equal((await f.graph(text)).body.error.code, 131047);
  await f.control('inject', { from: '15551230001', timestamp: Math.floor(Date.now() / 1000) - 86401 });
  assert.equal((await f.graph(text)).status, 400);
  await f.control('inject', { from: '15551230001' });
  assert.equal((await f.graph(text)).status, 200);
  await f.control('window', { to: '15551230001', open: false });
  await f.control('inject', { from: '15551230001' });
  assert.equal((await f.graph(text)).status, 400);
  await f.control('window-mode', { mode: 'async' });
  const asyncSend = await f.graph(text);
  assert.equal(asyncSend.status, 200);
  for (let i = 0; i < 100 && !f.received.some(r => r.body.includes('"statuses"')); i++) await new Promise(r => setTimeout(r, 10));
  const event = f.received.find(r => r.body.includes('"statuses"'));
  assert.ok(event);
  assert.equal(event.signature, 'sha256=' + createHmac('sha256', 'test-app-secret').update(event.body).digest('hex'));
  const status = JSON.parse(event.body).entry[0].changes[0].value.statuses[0];
  assert.equal(status.id, asyncSend.body.messages[0].id);
  assert.equal(status.errors[0].code, 131047);
  assert.equal(status.recipient_id, '15551230001');
  await f.control('window', { to: '15551230001', open: true });
  await f.control('window-mode', { mode: 'sync' });
  assert.equal((await f.graph(text)).status, 200);
});

test('signed injection, exact replay, BSUID-only and raw post', async t => {
  const f = await fixture(t);
  const injected = await f.control('inject', { from: '15551230001', user_id: 'US.alice', name: 'Alice', text: 'escaped 🌏', id: 'wamid.X', timestamp: 1763452800 });
  assert.equal(injected.body.status, 200);
  const first = f.received[0];
  assert.equal(first.signature, 'sha256=' + createHmac('sha256', 'test-app-secret').update(first.body).digest('hex'));
  const value = JSON.parse(first.body).entry[0].changes[0].value;
  assert.equal(value.metadata.phone_number_id, '100000000000001');
  assert.equal(value.messages[0].id, 'wamid.X');
  assert.equal(value.messages[0].text.body, 'escaped 🌏');
  assert.equal(value.contacts[0].user_id, 'US.alice');
  await f.control('replay', { id: 'wamid.X' });
  assert.deepEqual(f.received[1], first);
  await f.control('inject', { from: '15551230001', user_id: 'US.alice', omit_from: true, type: 'image' });
  const omitted = JSON.parse(f.received[2].body).entry[0].changes[0].value;
  assert.ok(!('from' in omitted.messages[0]));
  assert.ok(!('wa_id' in omitted.contacts[0]));
  assert.deepEqual(omitted.messages[0].image, {});
  await f.control('post', { body: 'raw bytes \\u1234', signature: null });
  assert.equal(f.received[3].body, 'raw bytes \\u1234');
  assert.equal(f.received[3].signature, undefined);
  await f.control('post', { body: '{}', signature: 'sha256=bad' });
  assert.equal(f.received[4].signature, 'sha256=bad');
});

test('challenge and fail queue counts and type isolation', async t => {
  const f = await fixture(t);
  const challenge = await f.control('challenge', { challenge: '1158201444' });
  assert.deepEqual(challenge.body, { status: 200, body: '1158201444', content_type: 'text/plain' });
  assert.equal((await f.control('challenge', { verify_token: 'wrong' })).body.status, 403);
  await f.control('inject', {});
  await f.control('fail', { type: 'text', http_status: 429, code: 131056, count: 2 });
  await f.control('fail', { type: 'text', http_status: 500, code: 100, count: 1 });
  assert.equal((await f.graph({ to: '+15551230001', type: 'reaction', reaction: { message_id: 'x', emoji: '👀' } })).status, 200);
  for (const [status, code] of [[429, 131056], [429, 131056], [500, 100]]) {
    const failed = await f.graph({ to: '+15551230001', type: 'text', text: { body: 'hi' } });
    assert.equal(failed.status, status);
    assert.equal(failed.body.error.code, code);
  }
  assert.equal((await f.graph({ to: '+15551230001', type: 'text', text: { body: 'hi' } })).status, 200);
});
