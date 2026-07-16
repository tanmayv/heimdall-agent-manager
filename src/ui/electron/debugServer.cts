import * as http from 'http';
import { BrowserWindow } from 'electron';

type Handler = (body: string) => Promise<unknown>;

function getWindow(): BrowserWindow | null {
  const wins = BrowserWindow.getAllWindows();
  return wins.length ? wins[0] : null;
}

async function evalInRenderer(js: string): Promise<unknown> {
  const win = getWindow();
  if (!win) return null;
  try {
    return await win.webContents.executeJavaScript(js, true);
  } catch {
    return null;
  }
}

const routes: Array<{ method: string; path: string; handler: Handler }> = [
  {
    method: 'GET',
    path: '/info',
    handler: async () => ({
      pid: process.pid,
      uptime: process.uptime(),
      platform: process.platform,
    }),
  },
  {
    method: 'GET',
    path: '/state',
    handler: async () => {
      const json = await evalInRenderer('JSON.stringify(window.__debugStore?.getState?.() ?? null)');
      try { return JSON.parse(json as string); } catch { return null; }
    },
  },
  {
    method: 'GET',
    path: '/context',
    handler: async () => {
      const json = await evalInRenderer('JSON.stringify(window.__heimdallPageContext ?? null)');
      try { return JSON.parse(json as string); } catch { return null; }
    },
  },
  {
    method: 'GET',
    path: '/logs',
    handler: async () => {
      const json = await evalInRenderer('JSON.stringify(window.__debugLogs ?? [])');
      try { return JSON.parse(json as string); } catch { return []; }
    },
  },
  {
    method: 'POST',
    path: '/state/select',
    handler: async (body) => {
      let dotPath = '';
      try { dotPath = JSON.parse(body).path ?? ''; } catch { return null; }
      const escaped = JSON.stringify(dotPath);
      const js = `(function(){
        const state = window.__debugStore?.getState?.();
        if (!state) return null;
        const parts = ${escaped}.split('.').filter(Boolean);
        let cur = state;
        for (const p of parts) { if (cur == null) return null; cur = cur[p]; }
        return JSON.stringify(cur ?? null);
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return null; }
    },
  },
  {
    method: 'POST',
    path: '/query-selector',
    handler: async (body) => {
      let query = '';
      try { query = JSON.parse(body).query ?? ''; } catch { return []; }
      const escaped = JSON.stringify(query);
      const js = `JSON.stringify(Array.from(document.querySelectorAll(${escaped})).map(el => ({
        tag: el.tagName,
        id: el.id || undefined,
        class: el.className || undefined,
        text: el.textContent?.trim().slice(0, 120) || undefined,
      })))`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return []; }
    },
  },
  {
    method: 'GET',
    path: '/elements',
    handler: async () => {
      const js = `JSON.stringify(
        Array.from(document.querySelectorAll('button,input,textarea,select,a[href],[data-debug-id]'))
          .map(el => {
            const rect = el.getBoundingClientRect();
            const visible = rect.width > 0 && rect.height > 0 && rect.top < window.innerHeight && rect.bottom > 0;
            const debugId = el.getAttribute('data-debug-id');
            const selector = debugId
              ? '[data-debug-id="' + debugId + '"]'
              : el.id ? '#' + el.id : null;
            return {
              tag: el.tagName,
              type: el.type || undefined,
              text: (el.textContent?.trim() || el.placeholder || el.value || '').slice(0, 80) || undefined,
              debugId: debugId || undefined,
              selector: selector || undefined,
              visible,
              disabled: el.disabled || undefined,
              rect: visible ? {x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height)} : undefined,
            };
          })
      )`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return []; }
    },
  },
  {
    method: 'POST',
    path: '/click',
    handler: async (body) => {
      let params: any = {};
      try { params = JSON.parse(body); } catch { return { ok: false, message: 'invalid json' }; }
      const query: string = params.query ?? '';
      const index: number = params.index ?? 0;
      const textGuard: string | undefined = params.text;
      const dryRun: boolean = params.dry_run ?? false;
      if (!query) return { ok: false, message: 'query required' };
      const js = `(function() {
        const els = Array.from(document.querySelectorAll(${JSON.stringify(query)}));
        const el = els[${index}];
        if (!el) return JSON.stringify({ ok: false, found: false, message: 'no element at index ${index}' });
        const elText = el.textContent?.trim() ?? '';
        const guard = ${JSON.stringify(textGuard ?? null)};
        if (guard !== null && elText !== guard) {
          return JSON.stringify({ ok: false, found: true, message: 'text guard failed: found ' + JSON.stringify(elText) + ', expected ' + JSON.stringify(guard) });
        }
        const info = { ok: true, found: true, tag: el.tagName, text: elText.slice(0, 80), index: ${index}, total: els.length };
        if (!${dryRun}) {
          el.scrollIntoView({ block: 'nearest' });
          el.click();
        }
        return JSON.stringify(info);
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return { ok: false, message: 'eval failed' }; }
    },
  },
  {
    method: 'POST',
    path: '/type',
    handler: async (body) => {
      let params: any = {};
      try { params = JSON.parse(body); } catch { return { ok: false, message: 'invalid json' }; }
      const query: string = params.query ?? '';
      const text: string = params.text ?? '';
      const clear: boolean = params.clear !== false;
      const index: number = params.index ?? 0;
      if (!query) return { ok: false, message: 'query required' };
      const js = `(function() {
        const els = Array.from(document.querySelectorAll(${JSON.stringify(query)}));
        const el = els[${index}];
        if (!el) return JSON.stringify({ ok: false, found: false });
        el.scrollIntoView({ block: 'nearest' });
        el.focus();
        const isTextarea = el.tagName === 'TEXTAREA';
        const proto = isTextarea ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
        if (!descriptor || !descriptor.set) return JSON.stringify({ ok: false, found: true, message: 'no value setter' });
        const newVal = ${clear} ? ${JSON.stringify(text)} : (el.value + ${JSON.stringify(text)});
        descriptor.set.call(el, newVal);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return JSON.stringify({ ok: true, found: true, value: el.value });
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return { ok: false, message: 'eval failed' }; }
    },
  },
  {
    method: 'POST',
    path: '/select',
    handler: async (body) => {
      let params: any = {};
      try { params = JSON.parse(body); } catch { return { ok: false, message: 'invalid json' }; }
      const query: string = params.query ?? '';
      const value: string = params.value ?? '';
      const index: number = params.index ?? 0;
      if (!query) return { ok: false, message: 'query required' };
      const js = `(function() {
        const els = Array.from(document.querySelectorAll(${JSON.stringify(query)}));
        const el = els[${index}];
        if (!el) return JSON.stringify({ ok: false, found: false });
        el.scrollIntoView({ block: 'nearest' });
        if (el.tagName === 'SELECT') {
          const descriptor = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value');
          descriptor.set.call(el, ${JSON.stringify(value)});
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return JSON.stringify({ ok: true, found: true, value: el.value });
        }
        if (el.tagName === 'INPUT' && (el.type === 'radio' || el.type === 'checkbox')) {
          const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'checked');
          descriptor.set.call(el, true);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          el.click();
          return JSON.stringify({ ok: true, found: true, checked: el.checked });
        }
        return JSON.stringify({ ok: false, found: true, message: 'unsupported tag ' + el.tagName });
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return { ok: false, message: 'eval failed' }; }
    },
  },
  {
    method: 'GET',
    path: '/screenshot',
    handler: async () => {
      const win = getWindow();
      if (!win) return { ok: false, message: 'no window' };
      const image = await win.capturePage();
      return { ok: true, mime: 'image/png', dataUrl: `data:image/png;base64,${image.toPNG().toString('base64')}` };
    },
  },
  {
    method: 'POST',
    path: '/highlight',
    handler: async (body) => {
      let params: any = {};
      try { params = JSON.parse(body); } catch { return { ok: false, message: 'invalid json' }; }
      const clearAll: boolean = params.clear ?? false;
      const query: string = params.query ?? '';
      const color: string = params.color ?? '#f59e0b';
      const label: string = params.label ?? '';
      const duration: number = params.duration ?? 3000;
      const clearJs = `document.querySelectorAll('[data-debug-overlay]').forEach(el => el.remove())`;
      if (clearAll || !query) {
        await evalInRenderer(clearJs);
        return { ok: true, cleared: true };
      }
      const js = `(function() {
        ${clearJs};
        const els = Array.from(document.querySelectorAll(${JSON.stringify(query)}));
        if (!els.length) return JSON.stringify({ ok: false, found: 0 });
        const color = ${JSON.stringify(color)};
        const label = ${JSON.stringify(label)};
        const duration = ${duration};
        els.forEach((target, i) => {
          const rect = target.getBoundingClientRect();
          const overlay = document.createElement('div');
          overlay.setAttribute('data-debug-overlay', 'true');
          overlay.style.cssText = [
            'position:fixed',
            'top:' + rect.top + 'px',
            'left:' + rect.left + 'px',
            'width:' + rect.width + 'px',
            'height:' + rect.height + 'px',
            'outline:2px solid ' + color,
            'pointer-events:none',
            'z-index:99999',
            'box-shadow:inset 0 0 0 1px ' + color + '40',
          ].join(';');
          if (label) {
            const badge = document.createElement('span');
            badge.textContent = els.length > 1 ? label + ' [' + i + ']' : label;
            badge.style.cssText = [
              'position:absolute',
              'top:-20px',
              'left:0',
              'background:' + color,
              'color:#000',
              'font-size:10px',
              'font-family:monospace',
              'padding:1px 5px',
              'white-space:nowrap',
              'border-radius:3px',
              'font-weight:600',
            ].join(';');
            overlay.appendChild(badge);
          }
          document.body.appendChild(overlay);
          if (duration > 0) setTimeout(() => overlay.remove(), duration);
        });
        return JSON.stringify({ ok: true, found: els.length, highlighted: els.length });
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return { ok: false, message: 'eval failed' }; }
    },
  },
  {
    // Drive a real artifact upload <input type="file"> end-to-end without a native
    // file chooser. Builds a File from base64 content, assigns it to the target
    // input's files, and dispatches a real 'change' event so the production
    // onChange -> uploadFile -> createArtifact path runs unchanged. This unblocks
    // debug-harness validation of UI artifact create/upload (task-19f68af38b7).
    method: 'POST',
    path: '/upload-file',
    handler: async (body) => {
      let params: any = {};
      try { params = JSON.parse(body); } catch { return { ok: false, message: 'invalid json' }; }
      const debugId: string = params.debug_id ?? params.debugId ?? '';
      const query: string = params.query ?? (debugId ? `[data-debug-id="${debugId}"]` : '');
      const index: number = params.index ?? 0;
      const fileName: string = params.file_name ?? params.fileName ?? 'debug-artifact.png';
      const mime: string = params.mime ?? 'image/png';
      // 1x1 transparent PNG default so callers can omit content.
      const contentBase64: string = params.content_base64 ?? params.contentBase64
        ?? 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
      if (!query) return { ok: false, message: 'debug_id or query required' };
      const js = `(async function() {
        const els = Array.from(document.querySelectorAll(${JSON.stringify(query)}));
        const el = els[${index}];
        if (!el) return JSON.stringify({ ok: false, found: false, message: 'no input at index ${index}' });
        if (el.tagName !== 'INPUT' || el.type !== 'file') return JSON.stringify({ ok: false, found: true, message: 'target is not a file input' });
        try {
          const bin = atob(${JSON.stringify(contentBase64)});
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          const file = new File([bytes], ${JSON.stringify(fileName)}, { type: ${JSON.stringify(mime)} });
          const dt = new DataTransfer();
          dt.items.add(file);
          const descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'files');
          if (descriptor && descriptor.set) descriptor.set.call(el, dt.files); else el.files = dt.files;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return JSON.stringify({ ok: true, found: true, file_name: ${JSON.stringify(fileName)}, mime: ${JSON.stringify(mime)} });
        } catch (err) {
          return JSON.stringify({ ok: false, found: true, message: String(err && err.message || err) });
        }
      })()`;
      const json = await evalInRenderer(js);
      try { return JSON.parse(json as string); } catch { return { ok: false, message: 'eval failed' }; }
    },
  },
];

let activeServer: http.Server | null = null;

export function startDebugServer(): Promise<number> {
  return new Promise((resolve, reject) => {
    if (activeServer) {
      const addr = activeServer.address() as { port: number };
      return resolve(addr.port);
    }
    const server = http.createServer(async (req, res) => {
      const method = req.method ?? 'GET';
      const url = (req.url ?? '/').split('?')[0];

      const route = routes.find((r) => r.method === method && r.path === url);

      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', async () => {
        if (!route) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: 'not found' }));
          return;
        }
        try {
          const result = await route.handler(body);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(result));
        } catch (err: any) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, message: err?.message ?? 'internal error' }));
        }
      });
    });

    server.listen(0, '127.0.0.1', () => {
      activeServer = server;
      const addr = server.address() as { port: number };
      resolve(addr.port);
    });

    server.on('error', reject);
  });
}

export function stopDebugServer(): Promise<void> {
  return new Promise((resolve) => {
    if (!activeServer) return resolve();
    activeServer.close(() => {
      activeServer = null;
      resolve();
    });
  });
}
