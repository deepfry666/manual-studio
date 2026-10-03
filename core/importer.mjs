import fsp from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { readJson, sha256File, exists, hashObject } from "./util/fsx.mjs";
import { projectPaths, newState, screenId } from "./pipeline/project.mjs";
import { forbiddenBrandTokens } from "./pipeline/brand.mjs";
import { newProviderFromPreset } from "./gateway/presets.mjs";
import { secretIds } from "./secrets.mjs";

const SKIP_DIRS = new Set(["node_modules", "docs", "tools", "tmp", "archive", "尺寸兼容测试"]);

async function isDir(target) {
  try {
    return (await fsp.stat(target)).isDirectory();
  } catch {
    return false;
  }
}

/**
 * 扫描工作区里的历史项目（只读）。分级：
 * - ready：文案、截图齐全，审查回执和当前截图一致，可以直接编辑
 * - needs-gate：有文案和截图，但回执缺失或对不上，需要重新验收
 * - readonly：只有交付包，没有 content.json，只能查看
 */
export async function scanWorkspace(workspaceDir, { isManaged = async () => false } = {}) {
  let entries;
  try {
    entries = await fsp.readdir(workspaceDir, { withFileTypes: true });
  } catch {
    throw new Error(`工作区不存在：${workspaceDir}`);
  }
  const results = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".") || SKIP_DIRS.has(entry.name)) continue;
    const dir = path.join(workspaceDir, entry.name);
    const info = await inspectProject(dir).catch(() => null);
    if (!info) continue;
    results.push({ ...info, managed: await isManaged(dir) });
  }
  return results.sort((a, b) => b.mtime - a.mtime);
}

export async function inspectProject(dir) {
  const paths = projectPaths(dir);
  const content = await readJson(paths.content, null).catch(() => null);
  const manifest = await readJson(paths.manifest, null).catch(() => null);
  const softwareName = content?.softwareName || manifest?.softwareName || path.basename(dir);
  const hasBundle = await isDir(paths.bundle(softwareName));
  let screenFiles = [];
  try {
    screenFiles = (await fsp.readdir(paths.screens)).filter((name) => /^screen-\d+\.png$/i.test(name)).sort();
  } catch {
    // 没有截图目录
  }
  if (!content && !hasBundle && !screenFiles.length) return null;
  const stat = await fsp.stat(dir);
  let grade = "readonly";
  let receiptMatches = false;
  if (content?.screens?.length && screenFiles.length >= content.screens.length) {
    const reviewed = content.screenshotReview?.reviewedScreens || [];
    receiptMatches = content.screenshotReview?.status === "passed" && reviewed.length === content.screens.length;
    if (receiptMatches) {
      for (let index = 0; index < content.screens.length; index += 1) {
        const id = screenId(index);
        const record = reviewed.find((item) => item.screenId === id);
        const file = paths.screenFile(id);
        if (!record || !(await exists(file)) || record.sha256 !== (await sha256File(file))) {
          receiptMatches = false;
          break;
        }
      }
    }
    grade = receiptMatches ? "ready" : "needs-gate";
  }
  return {
    dir,
    name: softwareName,
    grade,
    screens: content?.screens?.length || screenFiles.length,
    hasBundle,
    hasPlan: await exists(paths.screenPlan),
    hasCodeDoc: hasBundle && (await exists(path.join(paths.bundle(softwareName), `${softwareName}指南_代码-（JAVA）.docx`))),
    mtime: stat.mtimeMs,
  };
}

/** 为历史项目建立状态（不改动项目文件夹里的任何文件）。 */
export async function createImportedState(dir, info) {
  const paths = projectPaths(dir);
  const content = await readJson(paths.content, null).catch(() => null);
  const manifest = await readJson(paths.manifest, null).catch(() => null);
  const state = newState({
    softwareName: info.name,
    versionPolicy: content?.versionPolicy || manifest?.versionPolicy || "in-name",
    applicableVersion: content?.applicableVersion || "",
    screenCount: content?.screens?.length || info.screens || null,
    createdAt: content?.createdAt || manifest?.createdAt,
    wantDesign: Boolean(content?.design?.sections?.length),
    origin: "imported",
  });
  state.imported = { grade: info.grade, importedAt: new Date().toISOString(), hadCodeDoc: info.hasCodeDoc };
  state.readOnly = info.grade === "readonly";
  if (info.hasCodeDoc) {
    state.warnings.push("这个历史项目的代码文档来自旧 skill 内置的固定正文，不是这个软件的代码。重建前请在「交付」里指定代码来源；不指定则重建后不含代码文档（旧交付包会先归档）。");
  }
  if (state.readOnly) return state;

  const plan = await readJson(paths.screenPlan, null);
  if (plan) state.steps.plan = { status: "done", finishedAt: state.imported.importedAt, message: "沿用历史规划" };
  let promptsAll = Boolean(content?.screens?.length);
  for (let index = 0; index < (content?.screens?.length || 0); index += 1) {
    if (!(await exists(paths.promptFile(screenId(index))))) promptsAll = false;
  }
  if (plan && promptsAll) state.steps.prompts = { status: "done", finishedAt: state.imported.importedAt };
  if (content?.screens?.length) {
    state.steps.images = { status: "done", finishedAt: state.imported.importedAt };
    state.steps.content = { status: "done", finishedAt: state.imported.importedAt };
    state.steps.design = { status: content.design?.sections?.length ? "done" : "skipped" };
    const tokensHash = hashObject(forbiddenBrandTokens(info.name));
    for (let index = 0; index < content.screens.length; index += 1) {
      const id = screenId(index);
      const file = paths.screenFile(id);
      if (!(await exists(file))) continue;
      const sha = await sha256File(file);
      state.screens[id] = { imageSha: sha };
      if (info.grade === "ready") {
        state.screens[id].gate = { status: "passed", method: "imported-receipt", sha, tokensHash, checkedAt: state.imported.importedAt, reasons: [] };
      }
    }
    if (info.grade === "ready") {
      state.steps.gate = { status: "done", finishedAt: state.imported.importedAt, message: "沿用历史审查回执" };
      state.steps.receipt = { status: "done", finishedAt: state.imported.importedAt };
      if (info.hasBundle) state.steps.build = { status: "done", finishedAt: state.imported.importedAt, message: "沿用历史交付包" };
    }
  }
  const allDone = Object.values(state.steps).every((step) => step.status === "done" || step.status === "skipped");
  state.status = allDone ? "done" : "idle";
  return state;
}

/** 历史生图记录（image-cli-summary.json）导入为调用记录，作为补发线的初始数据。 */
export async function importLegacyTimings(workspaceDir, callLog) {
  const existingKeys = new Set(callLog.all().filter((row) => row.role === "history").map((row) => `${row.projectDir}|${row.startedAt}|${row.durationMs}`));
  let added = 0;
  let entries = [];
  try {
    entries = await fsp.readdir(workspaceDir, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const summary = await readJson(path.join(workspaceDir, entry.name, "tmp", "imagegen-cli", "image-cli-summary.json"), null).catch(() => null);
    if (!summary?.invocations) continue;
    for (const invocation of summary.invocations) {
      if (invocation.exitCode !== 0) continue;
      const providerId = invocation.providerId || "legacy-gpt-image-2-cli";
      const jobTimes = [...String(invocation.stderrTail || "").matchAll(/completed in ([\d.]+)s/g)].map((match) => Number(match[1]) * 1000);
      const durations = jobTimes.length ? jobTimes : invocation.jobCount === 1 && invocation.durationMs ? [invocation.durationMs] : [];
      for (const durationMs of durations) {
        const key = `${path.join(workspaceDir, entry.name)}|${invocation.startedAt}|${Math.round(durationMs)}`;
        if (existingKeys.has(key)) continue;
        existingKeys.add(key);
        await callLog.append({ ts: invocation.startedAt, projectDir: path.join(workspaceDir, entry.name), providerId, model: invocation.model || summary.model, role: "history", ok: true, kind: "success", durationMs: Math.round(durationMs), startedAt: invocation.startedAt });
        added += 1;
      }
    }
  }
  return added;
}

/**
 * 从旧 skill 的线路配置（~/.codex/software-manual-image-providers.json）导入线路和密钥。
 * 只读取，不修改旧文件；密钥加密保存在本软件里。
 */
export async function importLegacyProviders({ settingsStore, secrets, file = path.join(os.homedir(), ".codex", "software-manual-image-providers.json") }) {
  const legacy = await readJson(file, null);
  if (!legacy) throw new Error(`没有找到旧线路配置：${file}`);
  const rows = Array.isArray(legacy) ? legacy : legacy.providers || [];
  const imported = [];
  const skipped = [];
  const settings = await settingsStore.get();
  const providers = [...settings.providers];
  for (const row of rows) {
    if (!row?.id) continue;
    const protocol = row.protocol || "cli";
    if (protocol === "cli") {
      skipped.push(`${row.id}（命令行路线依赖 Codex 自带脚本，新软件不支持；如果它是 OpenAI 兼容中转，可以手动按「OpenAI 兼容」添加）`);
      continue;
    }
    const preset = protocol === "async" ? "apimart-async" : "openai-sync";
    const sizeIsRatio = /^\d+(?:\.\d+)?:\d+(?:\.\d+)?$/.test(String(row.size || ""));
    const provider = newProviderFromPreset(preset, {
      id: row.id,
      name: row.id,
      baseUrl: String(row.baseUrl || "").replace(/\/+$/, ""),
      model: row.model || "gpt-image-2",
      modelGroup: /2\.5/.test(row.model || "") ? "gpt-image-2.5" : row.model || "",
      enabled: row.enabled !== false,
      ...(sizeIsRatio ? { sizeMode: "ratio" } : row.size ? { sizeMode: "pixel", pixelSize: row.size } : {}),
    });
    if (preset === "openai-sync" && provider.sizeMode === "pixel" && row.size && row.size !== "864x1824") provider.pixelSize = "864x1824";
    const index = providers.findIndex((item) => item.id === provider.id);
    if (index >= 0) providers[index] = { ...providers[index], ...provider };
    else providers.push(provider);
    if (row.apiKey) await secrets.set(secretIds.imageProvider(provider.id), row.apiKey);
    else if (row.apiKeyEnv && process.env[row.apiKeyEnv]) await secrets.set(secretIds.imageProvider(provider.id), process.env[row.apiKeyEnv]);
    imported.push(provider.id);
  }
  await settingsStore.update((current) => ({ ...current, providers }));
  return { imported, skipped };
}
