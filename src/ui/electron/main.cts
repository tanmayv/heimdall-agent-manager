const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const { pruneAndRegister, updatePort, deregister } = require('./instanceRegistry.cjs');
const { startDebugServer, stopDebugServer } = require('./debugServer.cjs');

// Bypass Nix sandbox GPU library mismatches on Linux to enable full hardware-accelerated rendering.
if (process.platform === 'linux') {
  app.commandLine.appendSwitch('disable-gpu-sandbox');
}
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

let currentDebugPort = 0;

ipcMain.handle('odin-api:get-debug-info', () => {
  return { enabled: currentDebugPort !== 0, port: currentDebugPort, pid: process.pid };
});

ipcMain.handle('odin-api:toggle-debug-server', async (_event, enable: boolean) => {
  if (enable) {
    if (currentDebugPort === 0) {
      currentDebugPort = await startDebugServer();
      updatePort(currentDebugPort);
    }
  } else {
    if (currentDebugPort !== 0) {
      await stopDebugServer();
      currentDebugPort = 0;
      updatePort(0);
    }
  }
  return { enabled: currentDebugPort !== 0, port: currentDebugPort, pid: process.pid };
});


app.whenReady().then(async () => {
  const daemonUrl = process.env.HEIMDALL_DAEMON_URL || 'http://127.0.0.1:49322';
  pruneAndRegister(daemonUrl);
  updatePort(0); // Explicitly 0 since disabled by default

  console.log('[heimdall] startup config:');
  console.log(`  daemon_url=${daemonUrl}`);
  console.log(`  daemon_url_source=${process.env.HEIMDALL_DAEMON_URL ? 'env' : 'default'}`);
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
