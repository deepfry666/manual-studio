import os from "node:os";
import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "./util/fsx.mjs";

/** TXT 环境字段默认值与旧 skill 模板逐字一致。 */
export const DEFAULT_TXT_FIELDS = {
  devHardware: "CPU类型：Intel英特尔酷睿i5-4590",
  runHardware: "安卓机，8核处理器，ROM 64GB",
  devOs: "Windows Server 2012以上",
  devTools: "Visual Studio2010",
  runPlatform: "Android操作系统5.0版以上",
  runSupport: " Android Studio + Java jdk + Android SDK",
  language: "JAVA",
};

export const PIPELINE_STEPS = ["plan", "prompts", "images", "gate", "content", "design", "receipt", "build"];

export const LLM_STEPS = {
  plan: { label: "规划", needsVision: false },
  content: { label: "文案起草", needsVision: false },
  design: { label: "设计说明", needsVision: false },
  gate: { label: "截图品牌验收", needsVision: true },
  reconcile: { label: "截图文案对账", needsVision: true },
};

export function defaultSettings() {
  return {
    schemaVersion: 1,
    workspaceDir: path.join(os.homedir(), "Desktop", "软件指南生成"),
    image: {
      targetSize: "864x1824",
      quality: "low",
      globalConcurrency: 10,
      maxAttemptsPerScreen: 4,
      gateRegenerateLimit: 3,
      hedge: {
        enabled: true,
        percentile: 85,
        minSec: 20,
        maxSec: 120,
        maxPerBatch: 3,
        allowCrossModel: false,
      },
    },
    providers: [],
    llm: {
      vendors: [],
      assignments: { plan: null, content: null, design: null, gate: null, reconcile: null },
    },
    pipeline: {
      defaultScreenCount: 7,
      platform: "iPhone 16 Pro Max / iOS 26",
      reviewPlanSingle: true,
      reviewPlanBatch: false,
      batchConcurrency: 2,
      featureTextFloor: 300,
    },
    txtFields: { ...DEFAULT_TXT_FIELDS },
    codeDefaults: {
      extensions: [".java"],
      excludeDirs: ["node_modules", ".git", "build", "dist", "out", "target", ".gradle", ".idea", "Pods", "DerivedData"],
    },
  };
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

export function deepMerge(base, patch) {
  if (!isPlainObject(base) || !isPlainObject(patch)) return patch === undefined ? base : patch;
  const result = { ...base };
  for (const [key, value] of Object.entries(patch)) {
    result[key] = isPlainObject(value) && isPlainObject(base[key]) ? deepMerge(base[key], value) : value;
  }
  return result;
}

export function createSettingsStore(dataDir) {
  const file = path.join(dataDir, "settings.json");
  const serial = createSerialQueue();
  let cache = null;

  async function load() {
    if (cache) return cache;
    const stored = await readJson(file, {});
    cache = deepMerge(defaultSettings(), stored);
    return cache;
  }

  return {
    file,
    async get() {
      return structuredClone(await load());
    },
    /** patch 可以是对象（深合并）或函数（接收当前设置的副本，返回新设置）。 */
    update(patch) {
      return serial(async () => {
        const current = structuredClone(await load());
        const next = typeof patch === "function" ? await patch(current) : deepMerge(current, patch);
        await writeJsonAtomic(file, next);
        cache = next;
        return structuredClone(next);
      });
    },
  };
}
