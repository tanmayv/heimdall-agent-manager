import http from 'node:http';
import { createHmac, createHash } from 'node:crypto';
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
  const media = new Map(), uploads = [], mediaGets = [], downloads = [];
  let mediaNext = 1, uploadNext = 1;
  const hash = bytes => createHash('sha256').update(bytes).digest('hex');
  const applyFailure = async (res, type) => {
    const failure = failures.find(f => f.type === type && f.count > 0);
    if (!failure) return false;
    failure.count--;
    if (failure.delay_ms) await new Promise(resolve => setTimeout(resolve, failure.delay_ms));
    if (failure.http_status != null) { error(res, failure.http_status, failure.code ?? 100); return true; }
    return false;
  };
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
      const bytes = Buffer.concat(chunks);
      const raw = bytes.toString('utf8');
      const match = /^\/(v\d+\.\d+)\/([^/]+)(\/(?:messages|media))?$/.exec(url.pathname);
      if (match) {
        versions.add(match[1]);
        if (req.headers.authorization !== 'Bearer ' + accessToken) return error(res, 401, 190);
      }
      const multipart = req.headers['content-type']?.startsWith('multipart/form-data');
      const data = raw && !multipart ? JSON.parse(raw) : {};
      if (req.method === 'GET' && url.pathname.startsWith('/_media/')) {
        if (req.headers.authorization !== 'Bearer ' + accessToken) return error(res, 401, 190);
        const id = decodeURIComponent(url.pathname.slice('/_media/'.length));
        const item = media.get(id);
        downloads.push({ id, authorized: true });
        if (!item || item.expired) return error(res, 404, 100);
        res.writeHead(200, { 'Content-Type': item.mime_type });
        return res.end(item.bytes);
      }
      if (url.pathname.startsWith('/_control/')) {
        const control = url.pathname.slice('/_control/'.length);
        if (req.method === 'GET' && control === 'sent') {
          const to = url.searchParams.get('to');
          return json(res, 200, { messages: sent.filter(m => !to || m.to === to) });
        }
        if (req.method === 'GET' && control === 'reads') return json(res, 200, { reads });
        if (req.method === 'GET' && control === 'versions') return json(res, 200, { versions: [...versions] });
        if (req.method === 'GET' && control === 'uploads') return json(res, 200, { uploads });
        if (req.method === 'GET' && control === 'media-gets') return json(res, 200, { gets: mediaGets });
        if (req.method === 'GET' && control === 'downloads') return json(res, 200, { downloads });
        if (req.method !== 'POST') return json(res, 404, {});
        switch (control) {
          case 'media-expire': {
            const item = media.get(data.id);
            if (!item) return json(res, 404, {});
            item.expired = true;
            return json(res, 200, {});
          }
          case 'inject': {
            const from = data.from ?? '15551230001';
            const user = data.user_id ?? 'US.' + from;
            const timestamp = data.timestamp ?? Math.floor(Date.now() / 1000);
            const id = data.id ?? 'wamid.FAKEIN' + incoming++;
            const type = data.type ?? 'text';
            let content = type === 'text' ? { body: data.text ?? 'hi' } : {};
            if (['image', 'document', 'audio', 'video', 'sticker'].includes(type) && data.media) {
              const id = 'FAKEMEDIA' + mediaNext++;
              const item = { ...data.media, bytes: Buffer.from(data.media.bytes_base64 ?? '', 'base64') };
              item.mime_type ??= 'application/octet-stream';
              item.sha256 = hash(item.bytes);
              media.set(id, item);
              content = { id, mime_type: item.mime_type, sha256: item.sha256 };
              for (const key of ['filename', 'caption', 'voice']) if (item[key] != null) content[key] = item[key];
            }
            const message = { ...(data.omit_from ? {} : { from }), from_user_id: user, id, timestamp: String(timestamp), type,
              [type]: content };
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
            if (data.delay_ms != null && (!Number.isInteger(data.delay_ms) || data.delay_ms < 0 || data.delay_ms > 10000)) return json(res, 400, {});
            failures.push({ ...data });
            return json(res, 200, {});
          default: return json(res, 404, {});
        }
      }
      if (!match) return json(res, 404, {});
      if (req.method === 'GET' && !match[3] && match[2] !== phoneNumberId) {
        const id = decodeURIComponent(match[2]);
        mediaGets.push({ id, phone_number_id: url.searchParams.get('phone_number_id') });
        const item = media.get(id);
        if (!item || item.expired || url.searchParams.get('phone_number_id') !== phoneNumberId) return error(res, 400, 100);
        return json(res, 200, { messaging_product: 'whatsapp',
          url: 'http://127.0.0.1:' + server.address().port + '/_media/' + encodeURIComponent(id),
          mime_type: item.mime_type, sha256: item.sha256, file_size: item.declare_size ?? item.bytes.length, id });
      }
      if (match[2] !== phoneNumberId) return error(res, 400, 100);
      if (req.method === 'GET' && !match[3]) return json(res, 200, { display_phone_number: displayPhone, verified_name: 'Ninjy Test', id: phoneNumberId });
      if (req.method === 'POST' && match[3] === '/media') {
        if (await applyFailure(res, 'upload')) return;
        if (!multipart) return error(res, 400, 100);
        // Node's standards-based parser preserves binary bytes and escaped names.
        const form = await new Response(bytes, { headers: { 'Content-Type': req.headers['content-type'] } }).formData();
        const file = form.get('file');
        if (form.get('messaging_product') !== 'whatsapp' || !file || typeof file.arrayBuffer !== 'function') return error(res, 400, 100);
        const content = Buffer.from(await file.arrayBuffer());
        const id = 'FAKEUP' + uploadNext++;
        const item = { bytes: content, mime_type: file.type, filename: file.name, sha256: hash(content), uploaded: true };
        media.set(id, item);
        uploads.push({ id, mime: file.type, filename: file.name, size: content.length, sha256: item.sha256 });
        return json(res, 200, { id });
      }
      if (req.method !== 'POST' || match[3] !== '/messages') return json(res, 404, {});
      const type = data.status === 'read' ? 'read' : data.type;
      if (await applyFailure(res, type)) return;
      if (data.status === 'read') {
        reads.push({ message_id: data.message_id });
        return json(res, 200, { success: true });
      }
      if (Boolean(data.to) === Boolean(data.recipient)) return error(res, 400, 100);
      const recipient = data.to?.replace(/^\+/, '') ?? data.recipient;
      if (!['text', 'reaction', 'template', 'image', 'document', 'audio'].includes(type)) return error(res, 400, 100);
      if (type === 'template' && (!approved.has(data.template?.name) || data.template?.language?.code !== 'en')) return error(res, 400, 132001);
      const isMedia = ['image', 'document', 'audio'].includes(type);
      const uploaded = isMedia ? media.get(data[type]?.id) : null;
      if (isMedia && !uploaded?.uploaded) return error(res, 400, 131053);
      const age = Date.now() / 1000 - (windows.get(recipient) ?? -Infinity);
      const windowOpen = !closed.has(recipient) && age >= 0 && age < 86400;
      if ((type === 'text' || isMedia) && !windowOpen && mode === 'sync') return error(res, 400, 131047);
      const id = 'wamid.FAKE' + next++;
      sent.push({ id, to: recipient, type, text: data.text?.body ?? null, template: data.template ?? null,
        reaction: data.reaction?.emoji ?? null, reaction_message_id: data.reaction?.message_id ?? null,
        ...(isMedia ? { media_id: data[type].id, caption: data[type].caption ?? null, filename: data[type].filename ?? null,
          voice: data[type].voice ?? null, mime: uploaded.mime_type, size: uploaded.bytes.length, sha256: uploaded.sha256 } : {}) });
      json(res, 200, { messaging_product: 'whatsapp', contacts: [{ input: recipient, wa_id: recipient }], messages: [{ id }] });
      if ((type === 'text' || isMedia) && !windowOpen && mode === 'async' && webhookUrl) {
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
