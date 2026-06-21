const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { pruneAndRegister, updatePort, deregister } = require('./instanceRegistry.cjs');
const { startDebugServer } = require('./debugServer.cjs');

// Namespace Electron state under "heimdall-ui" so it doesn't collide with the
// ham daemon/wrapper config dir at <appData>/heimdall/. Must be called before
// app.whenReady() and before any path lookup.
app.setName('heimdall-ui');

const isDev = !app.isPackaged;

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

ipcMain.handle('odin-api:request', async (_event, { url, method = 'GET', body }) => {
  const response = await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
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
  console.log(`[debug] instance registry port=${debugPort} pid=${process.pid}`);

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
