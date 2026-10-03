/**
 * 生图线路预设。内部全部转成「声明式映射」执行（思路来自四季画布的 provider registry）：
 * 请求体里的 "$model" "$prompt" "$size" "$quality" 会被替换成实际值。
 */
export const APIMART_RATIOS = ["1:1", "3:2", "2:3", "4:3", "3:4", "5:4", "4:5", "16:9", "9:16", "2:1", "1:2", "3:1", "1:3", "21:9", "9:21"];
export const OPENAI_COMMON_RATIOS = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "5:4", "4:5", "21:9"];

const OPENAI_SYNC_MAPPING = {
  submit: {
    method: "POST",
    path: "/images/generations",
    body: { model: "$model", prompt: "$prompt", size: "$size", quality: "$quality", n: 1, output_format: "png" },
  },
  response: { images: "$.data[*]" },
};

const APIMART_ASYNC_MAPPING = {
  submit: {
    method: "POST",
    path: "/images/generations",
    body: { model: "$model", prompt: "$prompt", size: "$size", resolution: "1K", n: 1 },
  },
  response: { taskId: "$.data[0].task_id", images: "$.data[*]" },
  polling: {
    method: "GET",
    path: "/tasks/$taskId?language=zh",
    statusPath: "$.data.status",
    successValues: ["completed", "succeeded", "success"],
    failureValues: ["failed", "error", "cancelled", "canceled"],
    resultPath: "$.data.result.images[*]",
    intervalMs: 3000,
  },
};

export const PROVIDER_PRESETS = {
  "openai-sync": {
    label: "OpenAI 兼容（同步出图，CPA 也选这个）",
    protocol: "sync",
    sizeMode: "pixel",
    pixelSize: "864x1824",
    ratios: OPENAI_COMMON_RATIOS,
    concurrency: 4,
    hardTimeoutSec: 150,
    hedgeDefaultSec: 45,
    mapping: OPENAI_SYNC_MAPPING,
  },
  "apimart-async": {
    label: "APIMart（异步任务）",
    protocol: "async",
    sizeMode: "ratio",
    pixelSize: "864x1824",
    ratios: APIMART_RATIOS,
    concurrency: 6,
    hardTimeoutSec: 240,
    hedgeDefaultSec: 60,
    mapping: APIMART_ASYNC_MAPPING,
  },
  custom: {
    label: "自定义（声明式 JSON）",
    protocol: "auto",
    sizeMode: "pixel",
    pixelSize: "864x1824",
    ratios: OPENAI_COMMON_RATIOS,
    concurrency: 3,
    hardTimeoutSec: 240,
    hedgeDefaultSec: 90,
    mapping: OPENAI_SYNC_MAPPING,
  },
};

export function providerMapping(provider) {
  if (provider.preset === "custom" && provider.mapping && typeof provider.mapping === "object") return provider.mapping;
  return (PROVIDER_PRESETS[provider.preset] || PROVIDER_PRESETS["openai-sync"]).mapping;
}

export function isAsyncProvider(provider) {
  return Boolean(providerMapping(provider).polling);
}

/** 新建线路时的默认字段。 */
export function newProviderFromPreset(preset, overrides = {}) {
  const base = PROVIDER_PRESETS[preset] || PROVIDER_PRESETS["openai-sync"];
  return {
    id: overrides.id,
    name: overrides.name || base.label,
    enabled: true,
    preset,
    baseUrl: "",
    model: "",
    modelGroup: "",
    sizeMode: base.sizeMode,
    pixelSize: base.pixelSize,
    ratios: [...base.ratios],
    quality: "low",
    concurrency: base.concurrency,
    hardTimeoutSec: base.hardTimeoutSec,
    hedgeDefaultSec: base.hedgeDefaultSec,
    mapping: preset === "custom" ? structuredClone(base.mapping) : null,
    ...overrides,
  };
}

export function hostOf(baseUrl) {
  try {
    return new URL(baseUrl).host;
  } catch {
    return String(baseUrl || "");
  }
}

export function modelGroupOf(provider) {
  return (provider.modelGroup || provider.model || "").trim().toLowerCase();
}
