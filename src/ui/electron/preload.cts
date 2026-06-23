const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  request: (options: any) => ipcRenderer.invoke('odin-api:request', options),
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  getDebugInfo: () => ipcRenderer.invoke('odin-api:get-debug-info'),
  toggleDebugServer: (enable: boolean) => ipcRenderer.invoke('odin-api:toggle-debug-server', enable),
});
