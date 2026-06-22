const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { pruneAndRegister, updatePort, deregister } = require('./instanceRegistry.cjs');
const { startDebugServer } = require('./debugServer.cjs');

// Bypass Nix sandbox GPU library mismatches and enable full hardware-accelerated rendering!
app.commandLine.appendSwitch('disable-gpu-sandbox');


// Namespace Electron state under "heimdall-ui" so it doesn't collide with the
// ham daemon/wrapper config dir at <appData>/heimdall/. Must be called before
// app.whenReady() and before any path lookup.
app.setName('heimdall-ui');

// app.isPackaged is false when Electron loads a loose .cjs (Nix install, CI).
// Treat as dev only when the Vite dev server URL is explicitly provided.
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);

function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 760,
    minWidth: 920,
    minHeight: 620,
    title: 'Heimdall',
    backgroundColor: '#0f172a',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.cjs'),
    },
  });

  if (isDev) {
    win.loadURL(process.env.VITE_DEV_SERVER_URL || 'http://127.0.0.1:5173');
  } else {
    win.loadFile(path.join(__dirname, '..', 'dist', 'index.html'));
  }
}

ipcMain.handle('odin-api:pick-directory', async (event) => {
  const owner = BrowserWindow.fromWebContents(event.sender);
  const result = await dialog.showOpenDialog(owner || undefined, {
    title: 'Select project anchor directory',
    properties: ['openDirectory'],
  });
  if (result.canceled || !result.filePaths.length) return { ok: true, canceled: true, path: '' };
  return { ok: true, canceled: false, path: result.filePaths[0] };
});

ipcMain.handle('odin-api:request', async (_event, { url, method = 'GET', body, headers }) => {
  const startTime = performance.now();
  const timestamp = new Date().toISOString();
  
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: { 
        'Content-Type': 'application/json',
        ...headers
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (err: any) {
    const duration = (performance.now() - startTime).toFixed(1);
    console.log(`[API FETCH ERROR] ${timestamp} | ${method} ${url} | Failed to connect | Latency: ${duration}ms | Error: ${err.message}`);
    throw err;
  }

  const text = await response.text();
  const duration = (performance.now() - startTime).toFixed(1);
  const bytes = Buffer.byteLength(text, 'utf8');

  console.log(`[API FETCH] ${timestamp} | ${method} ${url} | Status: ${response.status} | Latency: ${duration}ms | Size: ${bytes} bytes`);

  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { ok: false, message: text || 'Invalid JSON response' };
  }
  if (!response.ok) {
    throw new Error(data?.message || `Daemon request failed with ${response.status}`);
  }
  return data;
});

app.whenReady().then(async () => {
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';
  pruneAndRegister(daemonUrl);

  const debugPort = await startDebugServer();
  updatePort(debugPort);

  console.log('[heimdall] startup config:');
  console.log(`  daemon_url=${daemonUrl}`);
  console.log(`  daemon_url_source=${process.env.HEIMDALL_DAEMON_URL ? 'env' : 'default'}`);
  console.log(`  debug_port=${debugPort}`);
  console.log(`  pid=${process.pid}`);
  console.log(`  platform=${process.platform}`);
  console.log(`  electron=${process.versions.electron}`);
  console.log(`  packaged=${app.isPackaged}`);
  console.log(`  dev=${isDev}`);

  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('before-quit', () => {
  deregister();
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
