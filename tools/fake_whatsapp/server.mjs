import http from 'node:http';
import { createHmac } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function createFakeWhatsApp({
  accessToken = 'TEST-WA-TOKEN', appSecret = 'test-app-secret', verifyToken = 'test-verify-token-0001',
  phoneNumberId = '100000000000001', businessAccountId = '200000000000002', displayPhone = '15550100001',
  webhookUrl = '',
} = {}) {
  const sent = [], reads = [], versions = new Set(), approved = new Set();
  const windows = new Map(), closed = new Set(), replays = new Map(), failures = [];
  const timers = new Set();
  let next = 1, incoming = 1, mode = 'sync';
  const sign = body => 'sha256=' + createHmac('sha256', appSecret).update(body).digest('hex');
  const payload = value => ({ object: 'whatsapp_business_account', entry: [{
    id: businessAccountId, changes: [{ field: 'messages', value: {
      messaging_product: 'whatsapp', metadata: { display_phone_number: displayPhone, phone_number_id: phoneNumberId }, ...value,
    } }],
  }] });
  const post = async (body, signature) => {
    const headers = { 'Content-Type': 'application/json' };
    if (signature != null) headers['X-Hub-Signature-256'] = signature;
    const response = await fetch(webhookUrl, { method: 'POST', headers, body });
    return { status: response.status, body: await response.text() };
  };
  const error = (res, status, code) => json(res, status, { error: {
    message: code === 190 ? 'Invalid OAuth access token.' : code === 131047 ? '(#131047) Re-engagement message' : 'Fake Graph request failed.',
    type: 'OAuthException', code,
    ...(code === 131047 ? { error_data: { messaging_product: 'whatsapp', details: 'Message failed to send because more than 24 hours have passed since the customer last replied to this number.' } } : {}),
    fbtrace_id: 'fake',
  } });
  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://127.0.0.1');
      const chunks = [];
      for await (const chunk of req) chunks.push(chunk);
      const raw = Buffer.concat(chunks).toString('utf8');
      const match = /^\/(v\d+\.\d+)\/([^/]+)(\/messages)?$/.exec(url.pathname);
      if (match) {
        versions.add(match[1]);
        if (req.headers.authorization !== 'Bearer ' + accessToken) return error(res, 401, 190);
      }
      const data = raw ? JSON.parse(raw) : {};
      if (url.pathname.startsWith('/_control/')) {
        const control = url.pathname.slice('/_control/'.length);
        if (req.method === 'GET' && control === 'sent') {
          const to = url.searchParams.get('to');
          return json(res, 200, { messages: sent.filter(m => !to || m.to === to) });
        }
        if (req.method === 'GET' && control === 'reads') return json(res, 200, { reads });
        if (req.method === 'GET' && control === 'versions') return json(res, 200, { versions: [...versions] });
        if (req.method !== 'POST') return json(res, 404, {});
        switch (control) {
          case 'inject': {
            const from = data.from ?? '15551230001';
            const user = data.user_id ?? 'US.' + from;
            const timestamp = data.timestamp ?? Math.floor(Date.now() / 1000);
            const id = data.id ?? 'wamid.FAKEIN' + incoming++;
            const type = data.type ?? 'text';
            const message = { ...(data.omit_from ? {} : { from }), from_user_id: user, id, timestamp: String(timestamp), type,
              [type]: type === 'text' ? { body: data.text ?? 'hi' } : {} };
            const body = JSON.stringify(payload({
              contacts: [{ profile: { name: data.name ?? 'Alice' }, ...(data.omit_from ? {} : { wa_id: from }), user_id: user }],
              messages: [message],
            }));
            const signature = sign(body);
            // Preserve the first bytes for an explicit id, just as a provider retry does.
            if (!replays.has(id)) replays.set(id, { body, signature });
            windows.set(from, Number(timestamp));
            windows.set(user, Number(timestamp));
            return json(res, 200, { id, ...await post(body, signature) });
          }
          case 'replay': {
            const replay = replays.get(data.id);
            if (!replay) return json(res, 404, {});
            return json(res, 200, await post(replay.body, replay.signature));
          }
          case 'post': return json(res, 200, await post(data.body, data.signature));
          case 'challenge': {
            const target = new URL(webhookUrl);
            target.searchParams.set('hub.mode', 'subscribe');
            target.searchParams.set('hub.challenge', data.challenge ?? '1158201444');
            target.searchParams.set('hub.verify_token', data.verify_token ?? verifyToken);
            const response = await fetch(target);
            return json(res, 200, { status: response.status, body: await response.text(), content_type: response.headers.get('content-type') });
          }
          case 'templates':
            approved.clear();
            for (const name of data.approved ?? []) approved.add(name);
            return json(res, 200, {});
          case 'window':
            if (data.open) closed.delete(data.to); else closed.add(data.to);
            return json(res, 200, {});
          case 'window-mode':
            if (!['sync', 'async'].includes(data.mode)) return json(res, 400, {});
            mode = data.mode;
            return json(res, 200, {});
          case 'fail':
            failures.push({ ...data });
            return json(res, 200, {});
          default: return json(res, 404, {});
        }
      }
      if (!match) return json(res, 404, {});
      if (match[2] !== phoneNumberId) return error(res, 400, 100);
      if (req.method === 'GET' && !match[3]) return json(res, 200, { display_phone_number: displayPhone, verified_name: 'Ninjy Test', id: phoneNumberId });
      if (req.method !== 'POST' || !match[3]) return json(res, 404, {});
      const type = data.status === 'read' ? 'read' : data.type;
      const failure = failures.find(f => f.type === type && f.count > 0);
      if (failure) { failure.count--; return error(res, failure.http_status, failure.code); }
      if (data.status === 'read') {
        reads.push({ message_id: data.message_id });
        return json(res, 200, { success: true });
      }
      if (Boolean(data.to) === Boolean(data.recipient)) return error(res, 400, 100);
      const recipient = data.to?.replace(/^\+/, '') ?? data.recipient;
      if (!['text', 'reaction', 'template'].includes(type)) return error(res, 400, 100);
      if (type === 'template' && (!approved.has(data.template?.name) || data.template?.language?.code !== 'en')) return error(res, 400, 132001);
      const age = Date.now() / 1000 - (windows.get(recipient) ?? -Infinity);
      const windowOpen = !closed.has(recipient) && age >= 0 && age < 86400;
      if (type === 'text' && !windowOpen && mode === 'sync') return error(res, 400, 131047);
      const id = 'wamid.FAKE' + next++;
      sent.push({ id, to: recipient, type, text: data.text?.body ?? null, template: data.template ?? null,
        reaction: data.reaction?.emoji ?? null, reaction_message_id: data.reaction?.message_id ?? null });
      json(res, 200, { messaging_product: 'whatsapp', contacts: [{ input: recipient, wa_id: recipient }], messages: [{ id }] });
      if (type === 'text' && !windowOpen && mode === 'async' && webhookUrl) {
        const timer = setTimeout(() => {
          timers.delete(timer);
          const body = JSON.stringify(payload({ statuses: [{ id, status: 'failed', timestamp: String(Math.floor(Date.now() / 1000)),
            ...(data.recipient ? { recipient_user_id: recipient } : { recipient_id: recipient }),
            errors: [{ code: 131047, title: 'Re-engagement message', message: 'Re-engagement message',
              error_data: { details: 'Message failed to send because more than 24 hours have passed since the customer last replied to this number.' } }],
          }] }));
          post(body, sign(body)).catch(() => {}); // Test endpoint can disappear during teardown.
        }, 50);
        timers.add(timer);
      }
    } catch {
      // Never print provider payloads, credentials or webhook URLs.
      if (!res.headersSent) json(res, 400, { error: 'invalid fake request' });
      else res.end();
    }
  });
  server.on('close', () => { for (const timer of timers) clearTimeout(timer); });
  return server;
}

function json(res, status, value) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(value));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = Object.fromEntries(Array.from({ length: Math.floor((process.argv.length - 2) / 2) }, (_, i) =>
    [process.argv[2 + i * 2].replace(/^--/, ''), process.argv[3 + i * 2]]));
  const options = {};
  for (const [flag, key] of Object.entries({ 'access-token': 'accessToken', 'app-secret': 'appSecret', 'verify-token': 'verifyToken',
    'phone-number-id': 'phoneNumberId', 'business-account-id': 'businessAccountId', 'display-phone': 'displayPhone', 'webhook-url': 'webhookUrl' })) {
    if (args[flag] !== undefined) options[key] = args[flag];
  }
  const server = createFakeWhatsApp(options);
  server.listen(Number(args.port ?? 18098), '127.0.0.1', () => {
    const base = 'http://127.0.0.1:' + server.address().port;
    if (args['ready-file']) writeFileSync(args['ready-file'], base);
    else console.log(base);
  });
}
