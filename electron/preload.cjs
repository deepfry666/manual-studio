const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("studio", {
  call: (method, ...args) => ipcRenderer.invoke("studio:call", method, args),
  onEvent: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on("studio:event", listener);
    return () => ipcRenderer.removeListener("studio:event", listener);
  },
});
