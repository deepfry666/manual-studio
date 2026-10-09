import os from "node:os";
import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "./util/fsx.mjs";
import { DEFAULT_PDF_FONTS } from "./build/fonts.mjs";

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

/** gate 用看图模型一次完成两件事：品牌验收 + 抄录界面实际内容（供文案对账）。 */
export const LLM_STEPS = {
  plan: { label: "规划界面", needsVision: false },
  gate: { label: "截图验收与内容抄录", needsVision: true },
  content: { label: "撰写说明文字", needsVision: false },
  design: { label: "设计说明（可选）", needsVision: false },
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
      spillover: true,
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
      assignments: { plan: null, gate: null, content: null, design: null },
    },
    pipeline: {
      defaultScreenCount: 7,
      platform: "iPhone 16 Pro Max / iOS 26",
      // 规划完是否先停下让人确认；默认不停，直接做完
      reviewPlanSingle: false,
      reviewPlanBatch: false,
      batchConcurrency: 3,
      featureTextFloor: 300,
    },
    txtFields: { ...DEFAULT_TXT_FIELDS },
    codeDefaults: {
      extensions: [".java"],
      excludeDirs: ["node_modules", ".git", "build", "dist", "out", "target", ".gradle", ".idea", "Pods", "DerivedData"],
    },
    // 代码来源只在这里设一次，所有项目共用；项目第一次生成交付包时记下当时用的来源，之后改这里不影响已完成的项目
    codeSource: { path: "", extensions: [".java"] },
    // 原版字体没装时 PDF 用哪个系统字体代替
    pdf: { ...DEFAULT_PDF_FONTS },
    export: { lastDir: "" },
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
    // 旧版本把代码文件类型放在 codeDefaults 里
    if (!stored.codeSource && Array.isArray(stored.codeDefaults?.extensions)) cache.codeSource.extensions = [...stored.codeDefaults.extensions];
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
