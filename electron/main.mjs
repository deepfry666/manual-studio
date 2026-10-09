import { app, BrowserWindow, ipcMain, dialog, shell, safeStorage, nativeImage, protocol, net, Notification } from "electron";
import path from "node:path";
import fsp from "node:fs/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createCore } from "../core/index.mjs";
import { convertToPngWithSips } from "../core/gateway/image-check.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const APP_NAME = "软件指南生成器";
app.setName(APP_NAME);

protocol.registerSchemesAsPrivileged([{ scheme: "asset", privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }]);

let mainWindow = null;
let core = null;

/** 密钥用 safeStorage 加密（macOS 上由系统钥匙串保护）。 */
const cipher = {
  encrypt(value) {
    if (!safeStorage.isEncryptionAvailable()) throw new Error("系统加密不可用，无法安全保存密钥");
    return safeStorage.encryptString(value).toString("base64");
  },
  decrypt(value) {
    return safeStorage.decryptString(Buffer.from(value, "base64"));
  },
};

async function toPng(buffer, type) {
  const image = nativeImage.createFromBuffer(buffer);
  if (!image.isEmpty()) return image.toPNG();
  // nativeImage 读不了的格式（如 WebP）交给系统自带的 sips
  return convertToPngWithSips(buffer, type);
}

async function visionImage(file) {
  const image = nativeImage.createFromPath(file);
  if (image.isEmpty()) throw new Error("截图无法读取");
  const resized = image.getSize().width > 720 ? image.resize({ width: 720, quality: "good" }) : image;
  return `data:image/jpeg;base64,${resized.toJPEG(80).toString("base64")}`;
}

function send(event) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send("studio:event", event);
  // 单个项目跑完：窗口不在前台时发系统通知，带上用时
  if (event.type === "run-finished" && event.status === "done" && !mainWindow?.isFocused() && Notification.isSupported() && !batchActive()) {
    new Notification({ title: APP_NAME, body: `${event.name} 已完成，本次用时 ${core.formatDuration(event.ms)}` }).show();
  }
  if (event.type === "batch") lastBatch = event.items || [];
  if (event.type === "batch" && !mainWindow?.isFocused() && Notification.isSupported()) {
    const items = event.items || [];
    const unfinished = items.filter((item) => ["queued", "running"].includes(item.status)).length;
    if (items.length && unfinished === 0 && !send.notified) {
      send.notified = true;
      new Notification({ title: APP_NAME, body: "批量队列已全部跑完" }).show();
    }
    if (unfinished) send.notified = false;
  }
}

let lastBatch = [];
function batchActive() {
  return lastBatch.some((item) => ["queued", "running"].includes(item.status));
}

const ACTIONS = [
  "confirmPlan", "savePlanScreen", "savePrompt", "regenerateScreen", "useAlternate", "manualGate", "saveContent", "rewriteContent", "updateRequest",
  "useGlobalCodeSource", "addFeedback", "editFeedback", "removeFeedback", "analyzeFeedback", "applyFeedback",
];
const BACKGROUND_ACTIONS = new Set(["confirmPlan", "regenerateScreen", "rewriteContent"]);

function methods() {
  return {
    getSettings: () => core.getSettings(),
    updateSettings: (patch) => core.updateSettings(patch),
    libreOfficeStatus: () => core.libreOfficeStatus(),
    saveProvider: (input) => core.saveProvider(input),
    deleteProvider: (id) => core.deleteProvider(id),
    reorderProviders: (ids) => core.reorderProviders(ids),
    providerStatuses: () => core.providerStatuses(),
    probeProvider: (id, options) => core.probeProvider(id, options),
    resetProviderHealth: (id) => core.resetProviderHealth(id),
    importLegacyProviders: () => core.importLegacyProviders(),
    saveVendor: (input) => core.saveVendor(input),
    deleteVendor: (id) => core.deleteVendor(id),
    fetchVendorModels: (id) => core.fetchVendorModels(id),
    testVendor: (id, model, options) => core.testVendor(id, model, options),
    setAssignment: (step, value) => core.setAssignment(step, value),
    listProjects: () => core.listProjects(),
    getProject: (dir) => core.getProject(dir),
    createProject: (request) => core.createProject(request),
    createProjectsFromList: (text, defaults) => core.createProjectsFromList(text, defaults),
    getProgress: (dir) => core.getProgress(dir),
    stepEstimates: () => core.stepEstimates(),
    planExport: (dirs, targetDir, options) => core.planExport(dirs, targetDir, options),
    defaultExportGroupName: () => core.defaultExportGroupName(),
    exportBundles: (dirs, targetDir, options) => core.exportBundles(dirs, targetDir, options),
    reexportPdfs: (dirs) => {
      core.reexportPdfs(dirs).then((result) => send({ type: "pdf-reexport-done", ...result })).catch((error) => send({ type: "log", level: "error", message: error.message }));
      return true;
    },
    fontStatus: () => core.fontStatus(),
    installFonts: async () => {
      const result = await dialog.showOpenDialog(mainWindow, { title: "选择字体文件（可多选）", properties: ["openFile", "multiSelections"], filters: [{ name: "字体", extensions: ["ttf", "ttc", "otf"] }] });
      if (result.canceled) return null;
      return core.installFonts(result.filePaths);
    },
    removeFromList: (dir) => core.removeFromList(dir),
    scanWorkspace: (dir) => core.scanWorkspace(dir),
    importProjects: (dirs) => core.importProjects(dirs),
    renameSoftware: (dir, name) => core.renameSoftware(dir, name),
    run: (dir, options) => {
      core.run(dir, options).catch((error) => send({ type: "log", projectDir: dir, level: "error", message: error.message }));
      return true;
    },
    cancel: (dir) => core.cancel(dir),
    action: async (name, ...args) => {
      if (!ACTIONS.includes(name)) throw new Error(`未知操作：${name}`);
      const result = core.actions[name](...args);
      if (BACKGROUND_ACTIONS.has(name)) {
        result.catch((error) => send({ type: "log", projectDir: args[0], level: "error", message: error.message }));
        return true;
      }
      return result;
    },
    inspectCodeSource: (source) => core.inspectCodeSource(source),
    zipBundle: (dir) => core.zipBundle(dir),
    batchList: () => core.batch.list(),
    batchEnqueue: (dirs, options) => core.batch.enqueue(dirs, options),
    batchPause: () => core.batch.pause(),
    batchResume: () => core.batch.resume(),
    batchRetry: (id) => core.batch.retry(id),
    batchRemove: (id) => core.batch.remove(id),
    batchClearFinished: () => core.batch.clearFinished(),
    batchRemoveProjects: async (dirs) => {
      const { items } = await core.batch.list();
      for (const item of items) if (dirs.includes(item.projectDir) && ["queued", "paused", "failed", "needs-attention"].includes(item.status)) await core.batch.remove(item.id);
      return true;
    },
    queryCalls: (filter) => core.queryCalls(filter),
    queryLlmCalls: (filter) => core.queryLlmCalls(filter),
    pendingJobs: () => core.pendingJobs(),
    dismissJob: (id) => core.dismissJob(id),
    chooseDirectory: async (title, defaultPath) => {
      const result = await dialog.showOpenDialog(mainWindow, { title, defaultPath, properties: ["openDirectory", "createDirectory"] });
      return result.canceled ? null : result.filePaths[0];
    },
    choosePath: async (title, defaultPath) => {
      const result = await dialog.showOpenDialog(mainWindow, { title, defaultPath, properties: ["openDirectory", "openFile"] });
      return result.canceled ? null : result.filePaths[0];
    },
    chooseTextFile: async (title) => {
      const result = await dialog.showOpenDialog(mainWindow, { title, properties: ["openFile"], filters: [{ name: "表格文本", extensions: ["csv", "txt", "tsv"] }] });
      if (result.canceled) return null;
      return fsp.readFile(result.filePaths[0], "utf8");
    },
    openPath: async (target) => {
      await assertOpenable(target);
      return shell.openPath(target);
    },
    showInFolder: async (target) => {
      await assertOpenable(target);
      return shell.showItemInFolder(target);
    },
    appInfo: () => ({ version: app.getVersion(), dataDir: process.env.MS_DATA_DIR || app.getPath("userData"), platform: process.platform }),
  };
}

/** 只允许打开工作区和已登记项目里的文件夹、文档和图片，不打开可执行程序。 */
async function assertOpenable(target) {
  const resolved = path.resolve(String(target || ""));
  const settings = (await core.getSettings()).settings;
  const projects = (await core.listProjects()).map((project) => project.dir);
  const roots = [settings.workspaceDir, settings.export?.lastDir, ...projects].filter(Boolean).map((root) => path.resolve(root));
  const inside = roots.some((root) => resolved === root || resolved.startsWith(root + path.sep));
  if (!inside) throw new Error("只能打开工作区和项目里的文件");
  const stat = await fsp.stat(resolved).catch(() => null);
  if (!stat) throw new Error(`文件不存在：${resolved}`);
  if (stat.isFile() && !/\.(docx|pdf|txt|json|png|jpe?g|webp|zip|md|csv)$/i.test(resolved)) throw new Error("这种类型的文件不能从这里打开");
  if (stat.isDirectory() && /\.app$/i.test(resolved)) throw new Error("不能从这里打开应用程序");
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1120,
    minHeight: 720,
    title: APP_NAME,
    // macOS 27 样式：隐藏标题栏，红绿灯放进浮起来的侧边栏面板左上角；
    // 窗口底层用系统原生毛玻璃（透出桌面），界面在上面叠液态玻璃
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 26, y: 26 },
    vibrancy: "sidebar",
    visualEffectState: "active",
    backgroundColor: "#00000000",
    show: false,
    webPreferences: {
      preload: path.join(here, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.once("ready-to-show", () => mainWindow.show());
  if (process.env.VITE_DEV_SERVER_URL) mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  else mainWindow.loadFile(path.join(here, "..", "web", "dist", "index.html"));
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });
  mainWindow.on("close", (event) => {
    const running = core?.internals.pipeline.runningProjects() || [];
    if (!running.length || mainWindow.forceClose) return;
    event.preventDefault();
    const choice = dialog.showMessageBoxSync(mainWindow, {
      type: "warning",
      buttons: ["退出", "取消"],
      defaultId: 1,
      message: `还有 ${running.length} 个项目在运行`,
      detail: "退出后，已经提交的异步生图任务会在下次打开时继续查询，不会重复提交；同步请求会被中断。",
    });
    if (choice === 0) {
      mainWindow.forceClose = true;
      mainWindow.close();
    }
  });
}

/** 开发自检：MS_SCREENSHOT_DIR 设置时，依次截取各页面后退出。 */
async function captureScreens(dir) {
  const routes = (process.env.MS_SCREENSHOT_ROUTES || "projects,new,models,settings").split(",");
  await fsp.mkdir(dir, { recursive: true });
  await new Promise((resolve) => setTimeout(resolve, 2500));
  try {
    for (const [index, route] of routes.entries()) {
      await mainWindow.webContents.executeJavaScript(`location.hash = ${JSON.stringify(`#/${route}`)}`);
      await new Promise((resolve) => setTimeout(resolve, 1800));
      const image = await mainWindow.webContents.capturePage();
      await fsp.writeFile(path.join(dir, `${String(index + 1).padStart(2, "0")}-${route.split("/")[0]}.png`), image.toPNG());
    }
  } finally {
    mainWindow.forceClose = true;
    app.quit();
  }
}

// 只允许开一个：两个实例同时写同一份数据会出错
const isPrimaryInstance = Boolean(process.env.MS_AUTOMATION || process.env.MS_SCREENSHOT_DIR) || app.requestSingleInstanceLock();
if (!isPrimaryInstance) app.quit();
app.on("second-instance", () => {
  if (!mainWindow) return;
  if (mainWindow.isMinimized()) mainWindow.restore();
  mainWindow.focus();
});

app.whenReady().then(async () => {
  if (!isPrimaryInstance) return;
  const dataDir = process.env.MS_DATA_DIR || app.getPath("userData");
  // MS_TEST_MEMORY_SECRETS 仅用于开发自检：密钥只放内存，不碰系统钥匙串
  core = await createCore({ dataDir, cipher: process.env.MS_TEST_MEMORY_SECRETS ? undefined : cipher, toPng, visionImage, onEvent: send, trashItem: (target) => shell.trashItem(target) });
  protocol.handle("asset", (request) => {
    const url = new URL(request.url);
    const target = decodeURIComponent(url.pathname.replace(/^\//, ""));
    if (!path.isAbsolute(target) || !/\.(png|jpe?g|webp|pdf)$/i.test(target)) return new Response("forbidden", { status: 403 });
    return net.fetch(pathToFileURL(target).toString());
  });
  const table = methods();
  ipcMain.handle("studio:call", async (_event, method, args) => {
    const handler = table[method];
    if (!handler) throw new Error(`未知方法：${method}`);
    return handler(...(Array.isArray(args) ? args : []));
  });
  if (process.platform === "darwin" && !app.isPackaged) app.dock?.setIcon(path.join(here, "..", "build", "icon.iconset", "icon_512x512.png"));
  createWindow();
  core.start().catch((error) => send({ type: "log", level: "error", message: `启动恢复失败：${error.message}` }));
  if (process.env.MS_SCREENSHOT_DIR) mainWindow.webContents.once("did-finish-load", () => captureScreens(process.env.MS_SCREENSHOT_DIR));
  if (process.env.MS_AUTOMATION) {
    // 开发自检脚本：在主进程里驱动 core 并截图
    mainWindow.webContents.once("did-finish-load", async () => {
      try {
        const automation = await import(pathToFileURL(process.env.MS_AUTOMATION).toString());
        await automation.default({ app, mainWindow, core });
      } catch (error) {
        console.error("automation failed:", error);
      } finally {
        mainWindow.forceClose = true;
        app.quit();
      }
    });
  }
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  app.quit();
});
