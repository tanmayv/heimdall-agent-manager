const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  getDebugInfo: () => ipcRenderer.invoke('odin-api:get-debug-info'),
  toggleDebugServer: (enable: boolean) => ipcRenderer.invoke('odin-api:toggle-debug-server', enable),
  daemonUrl: process.env.HEIMDALL_DAEMON_URL || '',
});
