const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  request: (options) => ipcRenderer.invoke('odin-api:request', options),
});
