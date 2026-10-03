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
import { createPipeline, STEP_LABELS } from "./pipeline/runner.mjs";
import { createBatchQueue, parseBatchCsv } from "./batch.mjs";
import { scanWorkspace, inspectProject, createImportedState, importLegacyTimings, importLegacyProviders } from "./importer.mjs";
import { collectCodeSource } from "./code-source.mjs";
import { assertSafeSoftwareName } from "./build/build.mjs";
import { findLibreOffice, resetLibreOfficeCache } from "./build/runtime.mjs";
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
export async function createCore({ dataDir, cipher, toPng, visionImage, fetchImpl = fetch, onEvent = () => {} }) {
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
    onEvent: (event) => emit({ ...event, kind: event.type, type: "image" }),
  });
  const pipeline = createPipeline({ settingsStore, secrets, gateway, projectStore, llmLog, emit, fetchImpl, visionImage });
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

  async function summarize(entry) {
    const state = await projectStore.read(entry.dir);
    if (!state) return null;
    const alive = await exists(entry.dir);
    return {
      dir: entry.dir,
      name: state.request.softwareName,
      origin: state.origin,
      grade: state.imported?.grade || null,
      readOnly: Boolean(state.readOnly),
      status: alive ? (pipeline.isRunning(entry.dir) ? "running" : state.status) : "missing",
      steps: Object.fromEntries(PIPELINE_STEPS.map((step) => [step, state.steps[step]?.status || "pending"])),
      screens: Object.keys(state.screens).length || state.request.screenCount || 0,
      hasCodeSource: Boolean(state.request.codeSource?.path),
      lastBuildAt: state.lastBuild?.at || null,
      lastError: state.lastError || null,
      warnings: state.warnings?.length || 0,
      addedAt: entry.addedAt,
      updatedAt: state.log?.at(-1)?.at || entry.addedAt,
    };
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
      const allowed = ["workspaceDir", "image", "pipeline", "txtFields", "codeDefaults"];
      const filtered = Object.fromEntries(Object.entries(patch).filter(([key]) => allowed.includes(key)));
      return settingsStore.update(filtered);
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
      const rows = await Promise.all(index.projects.map((entry) => summarize(entry).catch(() => null)));
      return rows.filter(Boolean);
    },
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
      return { dir, state, plan, content, screens, bundleDir, bundleFiles, running: pipeline.isRunning(dir) };
    },
    async createProject(request) {
      const settings = await settingsStore.get();
      const softwareName = String(request.softwareName || "").trim();
      assertSafeSoftwareName(softwareName);
      const dir = path.join(request.workspaceDir || settings.workspaceDir, softwareName);
      if (await exists(dir)) {
        const info = await inspectProject(dir).catch(() => null);
        if (info) throw new Error(`工作区里已经有「${softwareName}」这个项目，请用「导入历史项目」或换个名字`);
      }
      await fsp.mkdir(dir, { recursive: true });
      const state = newState({ ...request, softwareName });
      await projectStore.write(dir, state);
      await updateIndex((index) => {
        if (!index.projects.some((entry) => entry.dir === dir)) index.projects.unshift({ dir, addedAt: new Date().toISOString(), origin: "created" });
      });
      return dir;
    },
    async createProjectsFromCsv(text, defaults = {}) {
      const rows = parseBatchCsv(text);
      const created = [];
      const errors = [];
      for (const row of rows) {
        try {
          if (row.codeSourcePath) {
            if (!path.isAbsolute(row.codeSourcePath)) throw new Error("代码来源要写完整路径（以 / 开头）");
            if (!(await exists(row.codeSourcePath))) throw new Error(`代码来源不存在：${row.codeSourcePath}`);
          }
          const dir = await api.createProject({
            softwareName: row.softwareName,
            screenCount: row.screenCount || defaults.screenCount || null,
            emphasis: row.emphasis,
            versionPolicy: row.versionPolicy,
            codeSource: row.codeSourcePath ? { path: row.codeSourcePath, extensions: defaults.extensions || [".java"] } : null,
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
