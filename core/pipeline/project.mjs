import path from "node:path";
import fsp from "node:fs/promises";
import crypto from "node:crypto";
import { readJson, writeJsonAtomic, createSerialQueue, exists } from "../util/fsx.mjs";
import { PIPELINE_STEPS } from "../settings.mjs";

export const STATE_VERSION = 1;

export function screenId(index) {
  return `screen-${String(index + 1).padStart(2, "0")}`;
}

export function projectPaths(dir) {
  return {
    dir,
    prompts: path.join(dir, "prompts"),
    screens: path.join(dir, "screens"),
    alternates: path.join(dir, "screens", "alternates"),
    archive: path.join(dir, "archive"),
    content: path.join(dir, "content.json"),
    profile: path.join(dir, "software-profile.json"),
    featureMap: path.join(dir, "feature-map.json"),
    screenPlan: path.join(dir, "screen-plan.json"),
    uiContract: path.join(dir, "ui-contract.json"),
    manifest: path.join(dir, "project-manifest.json"),
    regionIndex: path.join(dir, "region-index.json"),
    screenFile: (id) => path.join(dir, "screens", `${id}.png`),
    promptFile: (id) => path.join(dir, "prompts", `${id}.md`),
    bundle: (softwareName) => path.join(dir, softwareName),
  };
}

export function newState(request) {
  const steps = {};
  for (const step of PIPELINE_STEPS) steps[step] = { status: "pending" };
  return {
    schemaVersion: STATE_VERSION,
    request: {
      softwareName: request.softwareName,
      versionPolicy: request.versionPolicy || "in-name",
      applicableVersion: request.applicableVersion || "",
      screenCount: request.screenCount || null,
      emphasis: request.emphasis || "",
      notes: request.notes || "",
      platform: request.platform || "",
      wantDesign: Boolean(request.wantDesign),
      codeSource: request.codeSource || null,
      txtFields: request.txtFields || null,
      extraBrandTokens: request.extraBrandTokens || [],
      compileDate: request.compileDate || "",
      createdAt: request.createdAt || new Date().toISOString().slice(0, 10),
    },
    status: "idle",
    steps,
    screens: {},
    warnings: [],
    log: [],
    origin: request.origin || "created",
  };
}

export function projectKey(dir) {
  return crypto.createHash("sha1").update(path.resolve(dir)).digest("hex").slice(0, 16);
}

/**
 * 项目状态存在软件自己的数据目录里（不往项目文件夹写隐藏文件），
 * 每个项目一个串行写队列，避免多个步骤同时改状态。
 */
export function createProjectStore(dataDir) {
  const queues = new Map();
  const queueFor = (dir) => {
    let queue = queues.get(dir);
    if (!queue) {
      queue = createSerialQueue();
      queues.set(dir, queue);
    }
    return queue;
  };
  const stateFile = (dir) => path.join(dataDir, "projects", `${projectKey(dir)}.json`);

  async function read(dir) {
    const state = await readJson(stateFile(dir), null);
    if (!state) return null;
    for (const step of PIPELINE_STEPS) if (!state.steps[step]) state.steps[step] = { status: "pending" };
    state.dir = dir;
    return state;
  }

  return {
    read,
    stateFile,
    stagingRoot: path.join(dataDir, "staging"),
    async exists(dir) {
      return exists(stateFile(dir));
    },
    write(dir, state) {
      return queueFor(dir)(() => writeJsonAtomic(stateFile(dir), { ...state, dir }));
    },
    update(dir, mutate) {
      return queueFor(dir)(async () => {
        const state = await read(dir);
        if (!state) throw new Error(`项目状态不存在：${dir}`);
        const next = (await mutate(state)) || state;
        next.dir = dir;
        await writeJsonAtomic(stateFile(dir), next);
        return next;
      });
    },
    async remove(dir) {
      await queueFor(dir)(() => fsp.rm(stateFile(dir), { force: true }));
    },
    /** 项目文件夹改名后，把状态搬到新路径名下。 */
    async move(fromDir, toDir) {
      const state = await read(fromDir);
      if (!state) return;
      await writeJsonAtomic(stateFile(toDir), { ...state, dir: toDir });
      await fsp.rm(stateFile(fromDir), { force: true });
    },
  };
}

export async function readPlan(dir) {
  const paths = projectPaths(dir);
  const [profile, featureMap, screenPlan, uiContract] = await Promise.all([
    readJson(paths.profile, null),
    readJson(paths.featureMap, null),
    readJson(paths.screenPlan, null),
    readJson(paths.uiContract, null),
  ]);
  if (!screenPlan) return null;
  const screens = (Array.isArray(screenPlan) ? screenPlan : screenPlan.screens || []).map((screen, index) => ({
    ...screen,
    id: screen.id || screen.screenId || screenId(index),
    title: screen.title || screen.purpose || screenId(index),
  }));
  return { profile, featureMap, screenPlan: { ...screenPlan, screens }, uiContract, screens };
}

export async function listScreenFiles(dir) {
  try {
    return (await fsp.readdir(projectPaths(dir).screens)).filter((name) => /^screen-\d+\.png$/i.test(name)).sort();
  } catch {
    return [];
  }
}

export async function listAlternates(dir, id) {
  const folder = path.join(projectPaths(dir).alternates, id);
  try {
    const names = (await fsp.readdir(folder)).filter((name) => name.endsWith(".png")).sort().reverse();
    return names.map((name) => ({ file: path.join(folder, name), name }));
  } catch {
    return [];
  }
}

export function appendLog(state, message, level = "info") {
  state.log.push({ at: new Date().toISOString(), level, message });
  if (state.log.length > 400) state.log.splice(0, state.log.length - 400);
}
