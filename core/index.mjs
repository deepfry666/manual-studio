import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import JSZip from "jszip";
import { createSettingsStore, PIPELINE_STEPS, LLM_STEPS } from "./settings.mjs";
import { createFileSecrets, createMemorySecrets, secretIds } from "./secrets.mjs";
import { createCallLog } from "./log/call-log.mjs";
import { createLedger } from "./gateway/ledger.mjs";
import { createHealthStore } from "./gateway/health.mjs";
import { createImageGateway } from "./gateway/gateway.mjs";
import { PROVIDER_PRESETS, newProviderFromPreset } from "./gateway/presets.mjs";
import { createProjectStore, newState, projectPaths, readPlan, listAlternates } from "./pipeline/project.mjs";
import { createPipeline, STEP_LABELS, codeSourceFor, detectVersion, formatDuration } from "./pipeline/runner.mjs";
import { createBatchQueue, parseBatchList } from "./batch.mjs";
import { scanWorkspace, inspectProject, createImportedState, importLegacyTimings, importLegacyProviders } from "./importer.mjs";
import { collectCodeSource } from "./code-source.mjs";
import { assertSafeSoftwareName } from "./build/build.mjs";
import { findLibreOffice, resetLibreOfficeCache } from "./build/runtime.mjs";
import { DOC_FONTS, SUBSTITUTES, SUBSTITUTE_CHOICES, installedFontFamilies, resolveFontPlan, installFontFiles } from "./build/fonts.mjs";
import { planExport, exportBundles } from "./export.mjs";
import { LLM_PRESETS, listModels, chatCompletion } from "./llm/client.mjs";
import { readJson, writeJsonAtomic, createSerialQueue, exists } from "./util/fsx.mjs";
import { solidPng } from "./util/png.mjs";

function newId(prefix) {
  return `${prefix}-${crypto.randomBytes(3).toString("hex")}`;
}

/**
 * 组装所有核心服务。Electron 主进程和测试都通过它使用核心功能。
 * options: { dataDir, cipher（safeStorage 加密器，测试可省略）, toPng, visionImage, fetchImpl, onEvent }
 */
export async function createCore({ dataDir, cipher, toPng, visionImage, fetchImpl = fetch, onEvent = () => {}, trashItem = null }) {
  await fsp.mkdir(dataDir, { recursive: true });
  const emit = (event) => {
    try {
      onEvent(event);
    } catch {
      // 界面事件失败不影响任务
    }
  };
  const settingsStore = createSettingsStore(dataDir);
  const secrets = cipher ? createFileSecrets(dataDir, cipher) : createMemorySecrets();
  const callLog = createCallLog(dataDir, "image-calls.jsonl");
  const llmLog = createCallLog(dataDir, "llm-calls.jsonl");
  const ledger = createLedger(dataDir);
  await ledger.init();
  const health = createHealthStore(dataDir);
  await health.init();
  const projectStore = createProjectStore(dataDir);

  const gateway = createImageGateway({
    getSettings: () => settingsStore.get(),
    updateProvider: (id, patch) =>
      settingsStore.update((current) => ({ ...current, providers: current.providers.map((provider) => (provider.id === id ? { ...provider, ...patch } : provider)) })),
    secrets,
    ledger,
    health,
    callLog,
    fetchImpl,
    toPng,
    onEvent: (event) => {
      pipelineRef?.onImageEvent(event);
      emit({ ...event, kind: event.type, type: "image" });
    },
  });
  let pipelineRef = null;
  const appVersion = (await readJson(new URL("../package.json", import.meta.url), {}).catch(() => ({}))).version || "";
  const pipeline = createPipeline({ settingsStore, secrets, gateway, projectStore, llmLog, emit, fetchImpl, visionImage, appVersion, statsFile: path.join(dataDir, "step-durations.json") });
  pipelineRef = pipeline;
  const batch = createBatchQueue({ dataDir, settingsStore, pipeline, emit });

  // 项目索引：工作区里由本软件管理的项目
  const indexFile = path.join(dataDir, "projects-index.json");
  const indexSerial = createSerialQueue();
  const readIndex = () => readJson(indexFile, { projects: [] });
  const updateIndex = (mutate) =>
    indexSerial(async () => {
      const index = await readIndex();
      const next = (await mutate(index)) || index;
      await writeJsonAtomic(indexFile, next);
      return next;
    });

  callLog.onAppend((row) => emit({ type: "call", row }));

  async function summarize(entry, settings, queueByDir) {
    const state = await projectStore.read(entry.dir);
    if (!state) return null;
    const alive = await exists(entry.dir);
    const queued = queueByDir?.get(entry.dir) || null;
    const live = pipeline.getProgress(entry.dir);
    return {
      dir: entry.dir,
      name: state.request.softwareName,
      origin: state.origin,
      grade: state.imported?.grade || null,
      readOnly: Boolean(state.readOnly),
      status: !alive ? "missing" : state.readOnly ? "readonly" : pipeline.isRunning(entry.dir) ? "running" : state.status,
      steps: Object.fromEntries(PIPELINE_STEPS.map((step) => [step, state.steps[step]?.status || "pending"])),
      screens: Object.keys(state.screens).length || state.request.screenCount || 0,
      hasCodeSource: Boolean(codeSourceFor(state, settings).source?.path),
      hasBundle: Boolean(state.lastBuild) || state.origin === "imported",
      bundleFiles: state.lastBuild?.files?.length || null,
      pdfFontProblem: Object.values(state.lastBuild?.pdfFonts || {}).some((font) => font && font.ok === false),
      timing: state.timing ? { totalMs: state.timing.totalMs, completedMs: state.timing.completedMs || null, completedAt: state.timing.completedAt || null, lastMs: state.timing.runs?.at(-1)?.ms || null } : null,
      queue: queued ? { id: queued.id, status: queued.status, position: queued.position, error: queued.error || null } : null,
      progress: live ? { step: live.step, started: live.started, stepStarted: live.stepStarted, screens: summarizeScreens(live.screens), detail: live.detail } : null,
      feedbackPending: (state.feedback || []).filter((item) => item.status === "pending").length,
      lastBuildAt: state.lastBuild?.at || null,
      lastError: state.lastError || null,
      warnings: state.warnings?.length || 0,
      addedAt: entry.addedAt,
      updatedAt: state.log?.at(-1)?.at || entry.addedAt,
    };
  }

  function summarizeScreens(screens = {}) {
    const values = Object.values(screens).filter((screen) => screen.status !== "kept");
    if (!values.length) return null;
    const finished = values.filter((screen) => ["generated", "passed"].includes(screen.status)).length;
    return { total: values.length, finished, failed: values.filter((screen) => screen.status === "failed").length };
  }

  async function queueIndex() {
    const { items } = await batch.list();
    const map = new Map();
    let position = 0;
    for (const item of items) {
      if (item.status === "queued") position += 1;
      const previous = map.get(item.projectDir);
      // 同一项目在队列里有多条时，以「排队/运行中」的那条为准
      if (!previous || ["queued", "running"].includes(item.status)) map.set(item.projectDir, { ...item, position: item.status === "queued" ? position : null });
    }
    return map;
  }

  const api = {
    // ---------- 设置 ----------
    async getSettings() {
      const settings = await settingsStore.get();
      const providerKeys = {};
      for (const provider of settings.providers) providerKeys[provider.id] = await secrets.has(secretIds.imageProvider(provider.id));
      const vendorKeys = {};
      for (const vendor of settings.llm.vendors) vendorKeys[vendor.id] = await secrets.has(secretIds.llmVendor(vendor.id));
      return { settings, providerKeys, vendorKeys, presets: { image: PROVIDER_PRESETS, llm: LLM_PRESETS }, llmSteps: LLM_STEPS, steps: PIPELINE_STEPS, stepLabels: STEP_LABELS };
    },
    async updateSettings(patch) {
      const allowed = ["workspaceDir", "image", "pipeline", "txtFields", "codeDefaults", "codeSource", "pdf", "export"];
      const filtered = Object.fromEntries(Object.entries(patch).filter(([key]) => allowed.includes(key)));
      const next = await settingsStore.update(filtered);
      // 调大「同时处理几个项目」后马上补上排队的项目
      if (filtered.pipeline) batch.kick();
      return next;
    },
    async libreOfficeStatus() {
      resetLibreOfficeCache();
      return { path: await findLibreOffice() };
    },

    // ---------- 生图线路 ----------
    async saveProvider(input) {
      const { apiKey, ...fields } = input;
      const id = fields.id || newId("img");
      if (!fields.baseUrl) throw new Error("请填写接口地址");
      if (!fields.model) throw new Error("请填写模型名");
      await settingsStore.update((current) => {
        const providers = [...current.providers];
        const index = providers.findIndex((provider) => provider.id === id);
        const base = index >= 0 ? providers[index] : newProviderFromPreset(fields.preset || "openai-sync", { id });
        const merged = { ...base, ...fields, id, baseUrl: String(fields.baseUrl).trim().replace(/\/+$/, "") };
        if (index >= 0) providers[index] = merged;
        else providers.push(merged);
        return { ...current, providers };
      });
      if (apiKey) await secrets.set(secretIds.imageProvider(id), apiKey.trim());
      await health.reset(id);
      return id;
    },
    async deleteProvider(id) {
      await settingsStore.update((current) => ({ ...current, providers: current.providers.filter((provider) => provider.id !== id) }));
      await secrets.delete(secretIds.imageProvider(id));
    },
    async reorderProviders(ids) {
      await settingsStore.update((current) => {
        const byId = new Map(current.providers.map((provider) => [provider.id, provider]));
        const ordered = ids.map((id) => byId.get(id)).filter(Boolean);
        for (const provider of current.providers) if (!ids.includes(provider.id)) ordered.push(provider);
        return { ...current, providers: ordered };
      });
    },
    async providerStatuses() {
      const settings = await settingsStore.get();
      const result = {};
      for (const provider of settings.providers) {
        result[provider.id] = { ...gateway.providerStatus(provider), hedgeThresholdSec: gateway.hedgeThresholdMs(provider, settings.image.hedge) / 1000 };
      }
      return result;
    },
    async probeProvider(id, options) {
      const report = await gateway.probe(id, options);
      if (report.image?.png) {
        report.image.dataUrl = `data:image/png;base64,${report.image.png.toString("base64")}`;
        delete report.image.png;
      }
      return report;
    },
    resetProviderHealth: (id) => health.reset(id),
    importLegacyProviders: (file) => importLegacyProviders({ settingsStore, secrets, file }),

    // ---------- 大模型 ----------
    async saveVendor(input) {
      const { apiKey, ...fields } = input;
      const id = fields.id || newId("llm");
      if (!fields.baseUrl) throw new Error("请填写接口地址");
      await settingsStore.update((current) => {
        const vendors = [...current.llm.vendors];
        const index = vendors.findIndex((vendor) => vendor.id === id);
        const merged = { jsonMode: true, models: [], ...(index >= 0 ? vendors[index] : {}), ...fields, id, baseUrl: String(fields.baseUrl).trim().replace(/\/+$/, "") };
        if (index >= 0) vendors[index] = merged;
        else vendors.push(merged);
        return { ...current, llm: { ...current.llm, vendors } };
      });
      if (apiKey) await secrets.set(secretIds.llmVendor(id), apiKey.trim());
      return id;
    },
    async deleteVendor(id) {
      await settingsStore.update((current) => {
        const assignments = { ...current.llm.assignments };
        for (const [step, value] of Object.entries(assignments)) if (value?.vendorId === id) assignments[step] = null;
        return { ...current, llm: { vendors: current.llm.vendors.filter((vendor) => vendor.id !== id), assignments } };
      });
      await secrets.delete(secretIds.llmVendor(id));
    },
    async fetchVendorModels(id) {
      const settings = await settingsStore.get();
      const vendor = settings.llm.vendors.find((item) => item.id === id);
      if (!vendor) throw new Error("厂商不存在");
      const apiKey = await secrets.get(secretIds.llmVendor(id));
      if (!apiKey) throw new Error("请先填写密钥");
      const models = await listModels({ vendor, apiKey, fetchImpl });
      await settingsStore.update((current) => ({ ...current, llm: { ...current.llm, vendors: current.llm.vendors.map((item) => (item.id === id ? { ...item, models } : item)) } }));
      return models;
    },
    async testVendor(id, model, { vision = false } = {}) {
      const settings = await settingsStore.get();
      const vendor = settings.llm.vendors.find((item) => item.id === id);
      const apiKey = await secrets.get(secretIds.llmVendor(id));
      const started = Date.now();
      const imageUrl = `data:image/png;base64,${solidPng(64, 64, [220, 38, 38]).toString("base64")}`;
      const content = vision
        ? [{ type: "text", text: "这张图主要是什么颜色？只回答一个词。" }, { type: "image_url", image_url: { url: vendor.preset === "zhipu" ? imageUrl.replace(/^data:[^;]+;base64,/, "") : imageUrl } }]
        : "回复「连接正常」四个字。";
      const result = await chatCompletion({ vendor, apiKey, model, messages: [{ role: "user", content }], maxTokens: 50, jsonMode: false, fetchImpl, timeoutMs: 60_000 });
      return { ok: true, reply: result.text.slice(0, 100), ms: Date.now() - started };
    },
    async setAssignment(step, value) {
      if (!LLM_STEPS[step]) throw new Error("未知步骤");
      await settingsStore.update((current) => ({ ...current, llm: { ...current.llm, assignments: { ...current.llm.assignments, [step]: value } } }));
    },

    // ---------- 项目 ----------
    async listProjects() {
      const index = await readIndex();
      const settings = await settingsStore.get();
      const queueByDir = await queueIndex();
      const rows = await Promise.all(index.projects.map((entry) => summarize(entry, settings, queueByDir).catch(() => null)));
      return rows.filter(Boolean);
    },
    getProgress: (dir) => pipeline.getProgress(dir),
    stepEstimates: () => pipeline.stepEstimates(),
    async getProject(dir) {
      const state = await projectStore.read(dir);
      if (!state) throw new Error("项目不存在");
      const plan = await readPlan(dir).catch(() => null);
      const content = await readJson(projectPaths(dir).content, null).catch(() => null);
      const paths = projectPaths(dir);
      const screens = [];
      const ids = plan?.screens?.map((screen) => screen.id) || content?.screens?.map((screen, index) => screen.id || `screen-${String(index + 1).padStart(2, "0")}`) || [];
      for (const id of ids) {
        const file = paths.screenFile(id);
        let mtime = null;
        try {
          mtime = (await fsp.stat(file)).mtimeMs;
        } catch {
          // 尚未生成
        }
        const prompt = await fsp.readFile(paths.promptFile(id), "utf8").catch(() => "");
        screens.push({ id, file: mtime ? file : null, mtime, prompt, state: state.screens[id] || {}, alternates: await listAlternates(dir, id), plan: plan?.screens?.find((screen) => screen.id === id) || null });
      }
      const bundleDir = paths.bundle(state.request.softwareName);
      let bundleFiles = [];
      try {
        bundleFiles = (await fsp.readdir(bundleDir)).filter((name) => !name.startsWith("."));
      } catch {
        // 还没有交付包
      }
      const settings = await settingsStore.get();
      const code = codeSourceFor(state, settings);
      return { dir, state, plan, content, screens, bundleDir, bundleFiles, running: pipeline.isRunning(dir), progress: pipeline.getProgress(dir), codeSource: { ...code, global: settings.codeSource?.path ? settings.codeSource : null } };
    },
    async createProject(request) {
      const settings = await settingsStore.get();
      const softwareName = String(request.softwareName || "").trim();
      assertSafeSoftwareName(softwareName);
      const dir = path.join(request.workspaceDir || settings.workspaceDir, softwareName);
      if (await projectStore.exists(dir)) throw new Error(`已经有「${softwareName}」这个项目了，可以在项目列表里找到它`);
      if (await exists(dir)) {
        const info = await inspectProject(dir).catch(() => null);
        if (info) throw new Error(`工作区里已经有「${softwareName}」这个项目，请用「导入历史项目」或换个名字`);
      }
      await fsp.mkdir(dir, { recursive: true });
      // 版本号自动判断；代码来源用总设置里的（第一次生成交付包时记下来）
      const versionPolicy = request.versionPolicy === "separate-metadata" ? "separate-metadata" : detectVersion(softwareName) ? "in-name" : "none";
      const state = newState({ ...request, softwareName, versionPolicy, codeSource: null });
      await projectStore.write(dir, state);
      await updateIndex((index) => {
        if (!index.projects.some((entry) => entry.dir === dir)) index.projects.unshift({ dir, addedAt: new Date().toISOString(), origin: "created" });
      });
      return dir;
    },
    /** 批量新建：每行一个软件名，可选用逗号带上 截图数、重点功能、补充说明。 */
    async createProjectsFromList(text, defaults = {}) {
      const rows = parseBatchList(text);
      if (!rows.length) throw new Error("没有读到软件名（每行一个）");
      const created = [];
      const errors = [];
      const seen = new Set();
      for (const row of rows) {
        try {
          if (seen.has(row.softwareName)) throw new Error("列表里重复了");
          seen.add(row.softwareName);
          const dir = await api.createProject({
            softwareName: row.softwareName,
            screenCount: row.screenCount || defaults.screenCount || null,
            emphasis: row.emphasis,
            notes: row.notes,
            platform: defaults.platform || "",
            wantDesign: Boolean(defaults.wantDesign),
          });
          created.push(dir);
        } catch (error) {
          errors.push(`${row.softwareName}：${error.message}`);
        }
      }
      return { created, errors };
    },
    async removeFromList(dir) {
      if (pipeline.isRunning(dir)) throw new Error("项目正在运行，先停止");
      await updateIndex((index) => ({ ...index, projects: index.projects.filter((entry) => entry.dir !== dir) }));
      await projectStore.remove(dir);
    },
    async scanWorkspace(workspaceDir) {
      const settings = await settingsStore.get();
      return scanWorkspace(workspaceDir || settings.workspaceDir, { isManaged: (dir) => projectStore.exists(dir) });
    },
    async importProjects(dirs) {
      const imported = [];
      const failed = [];
      for (const dir of dirs) {
        try {
          if (await projectStore.exists(dir)) continue;
          const info = await inspectProject(dir);
          if (!info) throw new Error("不是项目文件夹");
          const state = await createImportedState(dir, info);
          await projectStore.write(dir, state);
          if (!state.readOnly) await pipeline.adoptImported(dir);
          await updateIndex((index) => {
            if (!index.projects.some((entry) => entry.dir === dir)) index.projects.push({ dir, addedAt: new Date().toISOString(), origin: "imported" });
          });
          imported.push(dir);
        } catch (error) {
          failed.push(`${path.basename(dir)}：${error.message}`);
        }
      }
      const settings = await settingsStore.get();
      const timings = await importLegacyTimings(settings.workspaceDir, callLog).catch(() => 0);
      return { imported, failed, timings };
    },
    async renameSoftware(dir, newName) {
      const name = String(newName || "").trim();
      assertSafeSoftwareName(name);
      if (pipeline.isRunning(dir)) throw new Error("项目正在运行，先停止");
      const queued = (await batch.list()).items.some((item) => item.projectDir === dir && ["queued", "running"].includes(item.status));
      if (queued) throw new Error("项目还在批量队列里，先从队列移除再改名");
      const state = await projectStore.read(dir);
      if (state.request.softwareName === name) return dir;
      await pipeline.actions.updateRequest(dir, { softwareName: name });
      // 文件夹名和软件名一致时，一并改名
      let finalDir = dir;
      if (path.basename(dir) === state.request.softwareName) {
        const target = path.join(path.dirname(dir), name);
        if (!(await exists(target))) {
          await fsp.rename(dir, target);
          await projectStore.move(dir, target);
          await updateIndex((index) => ({ ...index, projects: index.projects.map((entry) => (entry.dir === dir ? { ...entry, dir: target } : entry)) }));
          finalDir = target;
        }
      }
      return finalDir;
    },
    run: (dir, options = {}) => pipeline.run(dir, options),
    cancel: (dir) => pipeline.cancel(dir),
    actions: pipeline.actions,
    // ---------- 导出 ----------
    async planExport(dirs, targetDir) {
      return planExport({ dirs, targetDir, projectStore });
    },
    async exportBundles(dirs, targetDir, options = {}) {
      for (const dir of dirs) if (pipeline.isRunning(dir)) throw new Error(`「${path.basename(dir)}」正在运行，等它跑完再导出`);
      const result = await exportBundles({ dirs, targetDir, projectStore, conflict: options.conflict || "skip", trashItem });
      await settingsStore.update({ export: { lastDir: targetDir } });
      return result;
    },

    // ---------- PDF 与字体 ----------
    async fontStatus() {
      const settings = await settingsStore.get();
      const families = await installedFontFamilies({ refresh: true });
      const plan = await resolveFontPlan(settings.pdf, { families });
      return {
        detected: Boolean(families),
        docs: Object.fromEntries(Object.entries(DOC_FONTS).map(([kind, doc]) => [kind, { label: doc.label, original: doc.original, installed: plan[kind].mode === "original", using: plan[kind].label, choice: settings.pdf?.[kind], choices: SUBSTITUTE_CHOICES[kind].map((key) => ({ value: key, label: SUBSTITUTES[key].label })) }])),
      };
    },
    installFonts: (files) => installFontFiles(files),
    /** 批量只重导 PDF（一个个来；LibreOffice 本来就排队）。 */
    async reexportPdfs(dirs) {
      const done = [];
      const failed = [];
      for (const [index, dir] of dirs.entries()) {
        emit({ type: "pdf-reexport", current: dir, index, total: dirs.length });
        try {
          const result = await pipeline.actions.reexportPdfs(dir);
          done.push({ dir, warnings: result.warnings });
        } catch (error) {
          failed.push(`${path.basename(dir)}：${error.message}`);
        }
      }
      emit({ type: "pdf-reexport", current: null, index: dirs.length, total: dirs.length });
      return { done, failed };
    },
    formatDuration,

    async inspectCodeSource(source) {
      const settings = await settingsStore.get();
      const result = await collectCodeSource(source, { excludeDirs: settings.codeDefaults.excludeDirs });
      return { fileCount: result.fileCount, lineCount: result.lineCount, nonEmptyLines: result.nonEmptyLines, estimatedPages: result.estimatedPages, files: result.files.slice(0, 50), warnings: result.warnings };
    },
    async zipBundle(dir) {
      const state = await projectStore.read(dir);
      const bundleDir = projectPaths(dir).bundle(state.request.softwareName);
      const zip = new JSZip();
      const folder = zip.folder(state.request.softwareName);
      for (const name of await fsp.readdir(bundleDir)) {
        if (name.startsWith(".")) continue;
        folder.file(name, await fsp.readFile(path.join(bundleDir, name)));
      }
      const target = path.join(dir, `${state.request.softwareName}.zip`);
      await fsp.writeFile(target, await zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" }));
      return target;
    },

    // ---------- 批量 ----------
    batch,

    // ---------- 记录 ----------
    queryCalls: (filter) => callLog.query(filter),
    queryLlmCalls: (filter) => llmLog.query(filter),
    pendingJobs: () => ledger.list((job) => job.state === "needs-attention" || job.state === "interrupted"),
    dismissJob: (jobId) => ledger.dismiss(jobId),

    async start() {
      // 清理一天前失败构建留下的临时文件夹（成功的构建会自己清理）
      try {
        const stagingRoot = projectStore.stagingRoot;
        for (const name of await fsp.readdir(stagingRoot)) {
          const target = path.join(stagingRoot, name);
          const stat = await fsp.stat(target);
          if (Date.now() - stat.mtimeMs > 86400_000) await fsp.rm(target, { recursive: true, force: true });
        }
      } catch {
        // 没有临时文件夹
      }
      await gateway.resumePending().catch(() => []);
      await batch.init();
    },
    internals: { settingsStore, secrets, callLog, llmLog, ledger, health, gateway, pipeline, projectStore },
  };
  return api;
}
