const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  getDebugInfo: () => ipcRenderer.invoke('odin-api:get-debug-info'),
  toggleDebugServer: (enable: boolean) => ipcRenderer.invoke('odin-api:toggle-debug-server', enable),
  daemonUrl: process.env.HEIMDALL_DAEMON_URL || '',
  hubApiBaseUrl: process.env.HEIMDALL_HUB_API_URL || process.env.HEIMDALL_HUB_URL || '',
  deviceAuth: {
    getConfig: () => ipcRenderer.invoke('heimdall-device-auth:get-config'),
    getStoredToken: () => ipcRenderer.invoke('heimdall-device-auth:get-token'),
    storeToken: (token: string) => ipcRenderer.invoke('heimdall-device-auth:store-token', token),
    clearToken: () => ipcRenderer.invoke('heimdall-device-auth:clear-token'),
    getDeviceInfo: () => ipcRenderer.invoke('heimdall-device-auth:device-info'),
    openExternal: (url: string) => ipcRenderer.invoke('heimdall-device-auth:open-external', url),
  },
});
