import AjvModule from "ajv";
import { redact } from "../secrets.mjs";

const Ajv = AjvModule.default || AjvModule;
const ajv = new Ajv({ allErrors: true, strict: false });
const validatorCache = new WeakMap();

export const LLM_PRESETS = {
  openai: { label: "OpenAI", baseUrl: "https://api.openai.com/v1", jsonMode: true, vision: true, suggestedModels: [] },
  deepseek: { label: "DeepSeek", baseUrl: "https://api.deepseek.com/v1", jsonMode: true, vision: false, suggestedModels: ["deepseek-chat", "deepseek-reasoner"] },
  zhipu: { label: "智谱 GLM", baseUrl: "https://open.bigmodel.cn/api/paas/v4", jsonMode: true, vision: true, suggestedModels: [] },
  custom: { label: "OpenAI 兼容（自定义 / CPA）", baseUrl: "", jsonMode: true, vision: true, suggestedModels: [] },
};

export class LlmError extends Error {
  constructor(message, info = {}) {
    super(message);
    this.name = "LlmError";
    this.kind = info.kind || "unknown";
    this.status = info.status;
  }
}

function joinUrl(baseUrl, pathPart) {
  return `${String(baseUrl || "").trim().replace(/\/+$/, "")}${pathPart}`;
}

function combineSignals(signals) {
  const active = signals.filter(Boolean);
  if (active.length <= 1) return active[0];
  return AbortSignal.any(active);
}

function errorMessage(data, status) {
  if (data && typeof data === "object") {
    const message = data.error?.message || data.error || data.message || data.msg;
    if (typeof message === "string") return message;
    return JSON.stringify(data).slice(0, 500);
  }
  return String(data || `HTTP ${status}`).slice(0, 500);
}

/** 从模型输出里取出 JSON：兼容 ```json 代码块、<think> 推理段、前后多余文字。 */
export function extractJson(text) {
  let content = String(text || "").replace(/<think>[\s\S]*?<\/think>/gi, "").trim();
  const fenced = content.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fenced) content = fenced[1].trim();
  try {
    return JSON.parse(content);
  } catch {
    const start = content.indexOf("{");
    const end = content.lastIndexOf("}");
    if (start >= 0 && end > start) {
      try {
        return JSON.parse(content.slice(start, end + 1));
      } catch {
        // 落到下面的报错
      }
    }
    throw new LlmError("模型输出不是有效的 JSON", { kind: "bad-json" });
  }
}

function contentText(message) {
  if (!message) return "";
  if (typeof message.content === "string") return message.content;
  if (Array.isArray(message.content)) return message.content.map((part) => part.text || "").join("");
  return "";
}

function schemaValidator(schema) {
  if (!schema) return null;
  let validate = validatorCache.get(schema);
  if (!validate) {
    validate = ajv.compile(schema);
    validatorCache.set(schema, validate);
  }
  return validate;
}

function describeAjvErrors(errors) {
  return (errors || [])
    .slice(0, 12)
    .map((error) => `${error.instancePath || "(根)"} ${error.message}`)
    .join("；");
}

/**
 * 一次对话补全（OpenAI 兼容 /chat/completions）。
 * 处理：网络和 5xx 重试 2 次；推理模型不支持 response_format / temperature 时自动去掉重发。
 */
export async function chatCompletion({ vendor, apiKey, model, messages, temperature = 0.7, maxTokens = 4096, jsonMode, signal, fetchImpl = fetch, timeoutMs = 240_000 }) {
  if (!vendor?.baseUrl) throw new LlmError("大模型接口地址为空", { kind: "config" });
  if (!apiKey) throw new LlmError(`「${vendor.name || vendor.id}」还没有填写密钥`, { kind: "auth" });
  if (!model) throw new LlmError("没有选择模型", { kind: "config" });
  let useJsonMode = jsonMode ?? vendor.jsonMode !== false;
  let useTemperature = true;
  let tokenLimit = maxTokens;
  let lastError;
  for (let attempt = 0; attempt < 7; attempt += 1) {
    const body = { model, messages, max_tokens: tokenLimit, stream: false };
    if (useTemperature) body.temperature = temperature;
    if (useJsonMode) body.response_format = { type: "json_object" };
    let response;
    try {
      response = await fetchImpl(joinUrl(vendor.baseUrl, "/chat/completions"), {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify(body),
        signal: combineSignals([signal, AbortSignal.timeout(timeoutMs)]),
      });
    } catch (error) {
      if (signal?.aborted) throw new LlmError("已取消", { kind: "aborted" });
      lastError = new LlmError(`网络错误：${error.cause?.code || error.message}`, { kind: "network" });
      await new Promise((resolve) => setTimeout(resolve, 1500 * (attempt + 1)));
      continue;
    }
    const raw = await response.text();
    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      data = raw;
    }
    if (!response.ok) {
      const message = redact(errorMessage(data, response.status), [apiKey]);
      if (response.status === 400 || response.status === 422) {
        // 兼容不同厂商的限制：输出上限（DeepSeek 为 8192）、不支持 JSON 模式、不支持 temperature
        if (/max_tokens|max_completion_tokens|maximum.{0,30}tokens|tokens?.{0,20}(?:limit|exceed|range)|最大.{0,10}(?:token|长度)/i.test(message) && tokenLimit > 4096) {
          tokenLimit = tokenLimit > 8192 ? 8192 : 4096;
          continue;
        }
        if (useTemperature && /temperature/i.test(message)) {
          useTemperature = false;
          continue;
        }
        if (useJsonMode) {
          useJsonMode = false;
          continue;
        }
      }
      const kind = response.status === 401 || response.status === 403 ? "auth" : response.status === 429 ? "quota" : response.status >= 500 ? "server" : "request";
      lastError = new LlmError(`HTTP ${response.status}：${message}`, { kind, status: response.status });
      if (kind === "server" || kind === "quota") {
        await new Promise((resolve) => setTimeout(resolve, 2000 * (attempt + 1)));
        continue;
      }
      throw lastError;
    }
    const message = data?.choices?.[0]?.message;
    return { text: contentText(message), usage: data?.usage || null, raw: data };
  }
  throw lastError || new LlmError("大模型请求失败", { kind: "unknown" });
}

/**
 * 让模型按 JSON Schema 输出。不合格时把错误带回去让模型修一次。
 * images：data URL 数组，用于看图模型。
 */
export async function chatJson({ vendor, apiKey, model, system, user, images = [], schema, check, temperature = 0.6, maxTokens = 8000, signal, fetchImpl = fetch, onUsage }) {
  // 智谱看图接口按官方示例传不带 data: 前缀的 base64
  const imageUrl = (url) => (vendor?.preset === "zhipu" ? String(url).replace(/^data:[^;]+;base64,/, "") : url);
  const userContent = images.length
    ? [{ type: "text", text: user }, ...images.map((url) => ({ type: "image_url", image_url: { url: imageUrl(url) } }))]
    : user;
  const messages = [
    { role: "system", content: `${system}\n\n只输出一个 JSON 对象，不要输出任何解释、Markdown 或代码块标记。` },
    { role: "user", content: userContent },
  ];
  const validate = schemaValidator(schema);
  let lastProblem = "";
  for (let round = 0; round < 3; round += 1) {
    const started = Date.now();
    const result = await chatCompletion({ vendor, apiKey, model, messages, temperature, maxTokens, signal, fetchImpl });
    onUsage?.({ ms: Date.now() - started, usage: result.usage, round });
    let parsed;
    try {
      parsed = extractJson(result.text);
    } catch (error) {
      lastProblem = error.message;
    }
    if (parsed !== undefined) {
      const problems = [];
      if (validate && !validate(parsed)) problems.push(describeAjvErrors(validate.errors));
      if (check) {
        const extra = check(parsed);
        if (extra && extra.length) problems.push(...extra);
      }
      if (!problems.length) return parsed;
      lastProblem = problems.join("；");
    }
    messages.push({ role: "assistant", content: result.text.slice(0, 12000) });
    messages.push({ role: "user", content: `上面的输出不符合要求：${lastProblem}。请修正后重新输出完整的 JSON 对象。` });
  }
  throw new LlmError(`模型多次输出都不符合格式要求：${lastProblem}`, { kind: "bad-output" });
}

export async function listModels({ vendor, apiKey, fetchImpl = fetch }) {
  const response = await fetchImpl(joinUrl(vendor.baseUrl, "/models"), { headers: { Authorization: `Bearer ${apiKey}` }, signal: AbortSignal.timeout(30_000) });
  const raw = await response.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    data = raw;
  }
  if (!response.ok) throw new LlmError(`HTTP ${response.status}：${redact(errorMessage(data, response.status), [apiKey])}`, { status: response.status });
  return (Array.isArray(data?.data) ? data.data : []).map((item) => item.id).filter(Boolean).sort();
}
