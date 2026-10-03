import { providerMapping } from "./presets.mjs";
import { parseAllowedRatios, looksLikeUnsupportedPixelSize } from "./sizes.mjs";

export class ProviderError extends Error {
  constructor(message, info = {}) {
    super(message);
    this.name = "ProviderError";
    this.kind = info.kind || "unknown";
    this.status = info.status;
    this.retryAfterSec = info.retryAfterSec;
    this.allowedRatios = info.allowedRatios;
    this.taskId = info.taskId;
  }
}

export function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(abortError());
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

function abortError() {
  return new ProviderError("请求已取消", { kind: "aborted" });
}

/** 读取 JSON 路径：$.data[0].task_id、$.data[*]、$.data.result.images[*] */
export function readPath(value, pathExpr) {
  if (!pathExpr || pathExpr === "$") return value;
  const tokens = String(pathExpr)
    .replace(/^\$\.?/, "")
    .replace(/\[(\d+|\*)\]/g, ".[$1]")
    .split(".")
    .filter(Boolean);
  let current = [value];
  let fanOut = false;
  for (const token of tokens) {
    const next = [];
    for (const item of current) {
      if (item === null || item === undefined) continue;
      if (token === "[*]") {
        fanOut = true;
        if (Array.isArray(item)) next.push(...item);
      } else if (/^\[\d+\]$/.test(token)) {
        if (Array.isArray(item)) next.push(item[Number(token.slice(1, -1))]);
      } else {
        next.push(item[token]);
      }
    }
    current = next;
  }
  const defined = current.filter((item) => item !== undefined);
  return fanOut ? defined : defined[0];
}

/** 把模板里的 "$model" 等占位替换成实际值；值为 undefined 的字段会被去掉。 */
export function fillTemplate(template, context) {
  if (typeof template === "string") {
    const exact = template.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
    if (exact) return context[exact[1]];
    return template.replace(/\$([A-Za-z_][A-Za-z0-9_]*)/g, (match, key) =>
      context[key] === undefined || context[key] === null ? "" : String(context[key])
    );
  }
  if (Array.isArray(template)) return template.map((item) => fillTemplate(item, context));
  if (template && typeof template === "object") {
    const result = {};
    for (const [key, value] of Object.entries(template)) {
      const filled = fillTemplate(value, context);
      if (filled !== undefined && filled !== "") result[key] = filled;
    }
    return result;
  }
  return template;
}

export function joinUrl(baseUrl, pathPart) {
  if (/^https?:\/\//i.test(pathPart)) return pathPart;
  const base = String(baseUrl || "").trim().replace(/\/+$/, "");
  return `${base}${pathPart.startsWith("/") ? pathPart : `/${pathPart}`}`;
}

function errorText(data) {
  if (typeof data === "string") {
    if (/<!doctype html|<html[\s>]/i.test(data)) {
      const title = data.match(/<title>([^<]{0,120})<\/title>/i)?.[1]?.trim();
      return `中转站返回了网页而不是接口数据${title ? `（${title}）` : ""}，可能是网关故障或地址填错`;
    }
    return data.slice(0, 600);
  }
  if (!data || typeof data !== "object") return "";
  const candidates = [data.error?.message, data.error, data.message, data.msg, data.detail, data.data?.error, data.data?.message];
  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate) return candidate.slice(0, 600);
  }
  return JSON.stringify(data).slice(0, 600);
}

/** 从报错里解析冷却时间：Retry-After、reset_seconds、48m20s、reset in 15 min。 */
export function parseRetryAfter(headers, message) {
  const header = headers?.get?.("retry-after");
  if (header && /^\d+$/.test(header.trim())) return Number(header.trim());
  const text = String(message || "");
  const seconds = text.match(/reset_seconds['"]?\s*[:=]\s*(\d+)/i);
  if (seconds) return Number(seconds[1]);
  const hms = text.match(/(?:(\d+)h)?(\d+)m(\d+)s/i);
  if (hms) return Number(hms[1] || 0) * 3600 + Number(hms[2]) * 60 + Number(hms[3]);
  const minutes = text.match(/(?:reset|retry|try again)[^\d]{0,20}(\d+)\s*(?:min|minutes|分钟)/i);
  if (minutes) return Number(minutes[1]) * 60;
  return undefined;
}

export function classifyHttpError(status, message, headers) {
  const text = String(message || "");
  if (status === 401 || status === 403) return { kind: "auth" };
  if (status === 429 || /quota|credential_quota|cooling down|rate.?limit|insufficient_quota|余额不足|额度/i.test(text)) {
    return { kind: "quota", retryAfterSec: parseRetryAfter(headers, text) };
  }
  if (looksLikeUnsupportedPixelSize(text)) return { kind: "size", allowedRatios: parseAllowedRatios(text) };
  if (status === 404 || /model_not_found|model .* (?:not|isn't) (?:supported|found)|model .* does not exist|no such model|模型不存在|无效的模型/i.test(text)) {
    return { kind: "config" };
  }
  if (/safety|moderation|content[_ ]policy|违规|敏感/i.test(text)) return { kind: "content" };
  if (status >= 500) return { kind: "server" };
  if (status === 408 || status === 409 || status === 425) return { kind: "server" };
  return { kind: "request" };
}

async function readBody(response) {
  const type = response.headers.get("content-type") || "";
  const text = await response.text();
  if (type.includes("json") || /^[\s]*[{[]/.test(text)) {
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return text;
}

async function request(fetchImpl, url, init) {
  try {
    return await fetchImpl(url, init);
  } catch (error) {
    if (init.signal?.aborted) throw abortError();
    throw new ProviderError(`网络错误：${error.cause?.code || error.message}`, { kind: "network" });
  }
}

function authHeaders(mapping, apiKey) {
  const auth = mapping.auth || { type: "bearer" };
  if (auth.type === "header" && auth.name) return { [auth.name]: apiKey };
  if (auth.type === "query") return {};
  return { Authorization: `Bearer ${apiKey}` };
}

function withQueryAuth(url, mapping, apiKey) {
  const auth = mapping.auth;
  if (auth?.type !== "query" || !auth.name) return url;
  return `${url}${url.includes("?") ? "&" : "?"}${encodeURIComponent(auth.name)}=${encodeURIComponent(apiKey)}`;
}

function normalizeImageItems(raw) {
  const list = Array.isArray(raw) ? raw.flat(Infinity) : raw === undefined ? [] : [raw];
  const result = [];
  for (const item of list) {
    if (typeof item === "string") {
      if (item) result.push(item.startsWith("data:") ? { dataUrl: item } : { url: item });
    } else if (item && typeof item === "object") {
      if (typeof item.b64_json === "string" && item.b64_json) result.push({ b64: item.b64_json });
      else if (typeof item.url === "string") result.push({ url: item.url });
      else if (Array.isArray(item.url)) item.url.forEach((url) => typeof url === "string" && result.push({ url }));
      else if (typeof item.image_url === "string") result.push({ url: item.image_url });
      else if (typeof item.image === "string") result.push(item.image.startsWith("http") ? { url: item.image } : { b64: item.image });
    }
  }
  return result;
}

async function materialize(item, fetchImpl, signal) {
  // 有的中转站在 b64_json 里也带 data: 前缀
  if (item.b64) return Buffer.from(item.b64.replace(/^data:[^,]*,/, ""), "base64");
  if (item.dataUrl) return Buffer.from(item.dataUrl.replace(/^data:[^,]*,/, ""), "base64");
  const response = await request(fetchImpl, item.url, { signal });
  if (!response.ok) throw new ProviderError(`下载图片失败（HTTP ${response.status}）`, { kind: "server", status: response.status });
  return Buffer.from(await response.arrayBuffer());
}

/**
 * 执行一次生图尝试（真正的异步 fetch，不阻塞其他屏）。
 * - 同步线路：一个请求直接拿到图。
 * - 异步线路：提交拿任务号 → onTaskId 立即落盘 → 轮询，临时错误按「还在处理」继续等。
 * - resumeTaskId：软件重启后直接续查，不重复提交，避免重复扣费。
 */
export async function runAttempt({
  provider,
  apiKey,
  prompt,
  size,
  quality,
  signal,
  resumeTaskId,
  onTaskId,
  fetchImpl = fetch,
  maxPollMs = 30 * 60 * 1000,
}) {
  const mapping = providerMapping(provider);
  const context = { model: provider.model, prompt, size, quality: quality || provider.quality || undefined };
  let taskId = resumeTaskId || null;

  if (!taskId) {
    const submit = mapping.submit;
    const url = withQueryAuth(joinUrl(provider.baseUrl, fillTemplate(submit.path, context)), mapping, apiKey);
    const body = fillTemplate(submit.body || {}, context);
    if (provider.extraBody && typeof provider.extraBody === "object") Object.assign(body, provider.extraBody);
    const response = await request(fetchImpl, url, {
      method: submit.method || "POST",
      headers: { "Content-Type": "application/json", ...authHeaders(mapping, apiKey), ...(submit.headers || {}) },
      body: JSON.stringify(body),
      signal,
    });
    const data = await readBody(response);
    if (!response.ok) {
      const message = errorText(data) || `HTTP ${response.status}`;
      throw new ProviderError(message, { status: response.status, ...classifyHttpError(response.status, message, response.headers) });
    }
    if (data && typeof data === "object" && typeof data.code === "number" && data.code !== 0 && data.code !== 200) {
      const message = errorText(data);
      throw new ProviderError(message, { status: response.status, ...classifyHttpError(400, message) });
    }
    const immediate = normalizeImageItems(readPath(data, mapping.response?.images || "$.data[*]"));
    const rawTaskId = mapping.response?.taskId ? readPath(data, mapping.response.taskId) : undefined;
    const foundTaskId = typeof rawTaskId === "number" ? String(rawTaskId) : rawTaskId;
    if (immediate.length && !(mapping.polling && foundTaskId)) {
      return { bytes: await materialize(immediate[0], fetchImpl, signal), taskId: null };
    }
    if (typeof foundTaskId === "string" && foundTaskId && mapping.polling) {
      taskId = foundTaskId;
      await onTaskId?.(taskId);
    } else {
      // 有的中转站把额度、尺寸等错误放在 HTTP 200 的响应体里，照样按内容分类（额度错误要触发冷却）
      const message = errorText(data);
      throw new ProviderError(`线路返回里没有图片：${message}`, classifyHttpError(400, message));
    }
  }

  const polling = mapping.polling;
  if (!polling) throw new ProviderError("线路没有配置轮询接口，无法续查任务", { kind: "config", taskId });
  const started = Date.now();
  while (Date.now() - started < maxPollMs) {
    await sleep(polling.intervalMs || 3000, signal);
    const url = withQueryAuth(joinUrl(provider.baseUrl, fillTemplate(polling.path, { ...context, taskId: encodeURIComponent(taskId) })), mapping, apiKey);
    let response;
    try {
      response = await request(fetchImpl, url, { method: polling.method || "GET", headers: authHeaders(mapping, apiKey), signal });
    } catch (error) {
      if (error.kind === "aborted") throw error;
      continue; // 查询时的网络抖动不算失败
    }
    const data = await readBody(response);
    if (!response.ok) {
      if ([408, 409, 425, 429, 500, 502, 503, 504].includes(response.status)) continue;
      const message = errorText(data);
      // 查询任务时的 404 是「任务不存在/已过期」，不是线路配置错，不能因此停用整条线路
      if (response.status === 404) throw new ProviderError(`任务不存在或已过期：${message}`, { kind: "task-failed", status: 404, taskId });
      throw new ProviderError(message, { status: response.status, taskId, ...classifyHttpError(response.status, message) });
    }
    const status = String(readPath(data, polling.statusPath) ?? "").toLowerCase();
    if ((polling.failureValues || []).map((value) => value.toLowerCase()).includes(status)) {
      const message = errorText(data);
      throw new ProviderError(`任务失败（${status}）：${message}`, { kind: classifyHttpError(400, message).kind === "content" ? "content" : "task-failed", taskId });
    }
    if (!(polling.successValues || []).map((value) => value.toLowerCase()).includes(status)) continue;
    const images = normalizeImageItems(readPath(data, polling.resultPath));
    if (!images.length) throw new ProviderError("任务已完成，但结果里没有图片", { kind: "task-failed", taskId });
    return { bytes: await materialize(images[0], fetchImpl, signal), taskId };
  }
  throw new ProviderError("任务还在处理中，已保留任务号，稍后可以继续查询", { kind: "pending", taskId });
}

/** 免费的连通性检查：GET /models，确认 key 和模型名。 */
export async function probeModels({ provider, apiKey, fetchImpl = fetch, signal }) {
  const mapping = providerMapping(provider);
  const url = withQueryAuth(joinUrl(provider.baseUrl, "/models"), mapping, apiKey);
  const response = await request(fetchImpl, url, { headers: authHeaders(mapping, apiKey), signal });
  const data = await readBody(response);
  if (!response.ok) {
    const message = errorText(data) || `HTTP ${response.status}`;
    throw new ProviderError(message, { status: response.status, ...classifyHttpError(response.status, message) });
  }
  const ids = Array.isArray(data?.data) ? data.data.map((item) => item?.id).filter(Boolean) : [];
  return { models: ids, hasModel: ids.length ? ids.includes(provider.model) : null };
}
