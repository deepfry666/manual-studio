import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import http from "node:http";
import { execFileSync } from "node:child_process";
import { chatJson, extractJson } from "../core/llm/client.mjs";
import { runAttempt, ProviderError } from "../core/gateway/adapter.mjs";
import { newProviderFromPreset, PROVIDER_PRESETS } from "../core/gateway/presets.mjs";
import { parseBatchCsv } from "../core/batch.mjs";
import { collectCodeSource } from "../core/code-source.mjs";
import { createCore } from "../core/index.mjs";
import { startMockRelay } from "./helpers/mock-relay.mjs";
import { startMockLlm } from "./helpers/mock-llm.mjs";
import { makePng } from "./helpers/png.mjs";

/** 一个按脚本回复的假服务。handler(req, body, index) → { status, headers, body(string|object|Buffer) } */
async function scriptedServer(handler) {
  let index = 0;
  const calls = [];
  const server = http.createServer((req, res) => {
    let raw = "";
    req.on("data", (chunk) => (raw += chunk));
    req.on("end", async () => {
      const body = raw ? JSON.parse(raw) : null;
      calls.push({ url: req.url, method: req.method, body });
      const reply = await handler(req, body, index++);
      const payload = Buffer.isBuffer(reply.body) ? reply.body : typeof reply.body === "string" ? reply.body : JSON.stringify(reply.body);
      res.writeHead(reply.status || 200, { "content-type": reply.type || "application/json", ...(reply.headers || {}) });
      res.end(payload);
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, calls, close: () => new Promise((resolve) => { server.closeAllConnections?.(); server.close(() => resolve()); }) };
}

const vendor = (url, extra = {}) => ({ id: "v", name: "测试", preset: "custom", baseUrl: url, jsonMode: true, ...extra });
const chatReply = (content) => ({ body: { choices: [{ message: { content } }] } });

test("大模型输出带 <think> 和 ```json 代码块也能解析", () => {
  assert.deepEqual(extractJson('<think>先想一想</think>\n好的：\n```json\n{"a":1}\n```'), { a: 1 });
  assert.deepEqual(extractJson('结果如下 {"a":{"b":[1,2]}} 以上'), { a: { b: [1, 2] } });
  assert.throws(() => extractJson("完全不是 JSON"));
});

test("大模型第一次输出不合格，带着错误让它修正后通过", async (t) => {
  const server = await scriptedServer((req, body, index) => (index === 0 ? chatReply('{"name": 1}') : chatReply('{"name": "ok"}')));
  t.after(server.close);
  const result = await chatJson({ vendor: vendor(server.url), apiKey: "k", model: "m", system: "s", user: "u", schema: { type: "object", required: ["name"], properties: { name: { type: "string" } } } });
  assert.equal(result.name, "ok");
  assert.match(JSON.stringify(server.calls[1].body.messages.at(-1)), /不符合要求/);
});

test("厂商不支持 JSON 模式、输出上限更小时自动降级重试", async (t) => {
  const server = await scriptedServer((req, body) => {
    if (body.max_tokens > 8192) return { status: 400, body: { error: { message: "Invalid max_tokens value, the valid range of max_tokens is [1, 8192]" } } };
    if (body.response_format) return { status: 400, body: { error: { message: "1210 API 调用参数有误" } } };
    return chatReply('{"ok":true}');
  });
  t.after(server.close);
  const result = await chatJson({ vendor: vendor(server.url), apiKey: "k", model: "m", system: "s", user: "u", maxTokens: 12000 });
  assert.equal(result.ok, true);
  const last = server.calls.at(-1).body;
  assert.equal(last.max_tokens, 8192);
  assert.equal(last.response_format, undefined);
});

test("智谱看图请求发不带前缀的 base64，其他厂商发 data URL", async (t) => {
  const server = await scriptedServer(() => chatReply('{"ok":true}'));
  t.after(server.close);
  await chatJson({ vendor: vendor(server.url, { preset: "zhipu" }), apiKey: "k", model: "m", system: "s", user: "u", images: ["data:image/jpeg;base64,QUJD"] });
  await chatJson({ vendor: vendor(server.url), apiKey: "k", model: "m", system: "s", user: "u", images: ["data:image/jpeg;base64,QUJD"] });
  assert.equal(server.calls[0].body.messages[1].content[1].image_url.url, "QUJD");
  assert.equal(server.calls[1].body.messages[1].content[1].image_url.url, "data:image/jpeg;base64,QUJD");
});

const syncProvider = (url) => newProviderFromPreset("openai-sync", { id: "p", name: "p", baseUrl: url, model: "m" });

test("中转站返回网页（502）时报错是一句人话", async (t) => {
  const server = await scriptedServer(() => ({ status: 502, type: "text/html", body: "<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body>cloudflare</body></html>" }));
  t.after(server.close);
  await assert.rejects(runAttempt({ provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824" }), (error) => {
    assert.equal(error.kind, "server");
    assert.match(error.message, /返回了网页.*502 Bad Gateway/);
    return true;
  });
});

test("HTTP 200 里装着额度错误：按额度处理（会触发冷却）", async (t) => {
  const server = await scriptedServer(() => ({ body: { error: { message: "insufficient_quota: 余额不足" } } }));
  t.after(server.close);
  await assert.rejects(runAttempt({ provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824" }), (error) => error.kind === "quota");
});

test("b64_json 带 data: 前缀也能解码", async (t) => {
  const png = makePng(216, 456);
  const server = await scriptedServer(() => ({ body: { data: [{ b64_json: `data:image/png;base64,${png.toString("base64")}` }] } }));
  t.after(server.close);
  const result = await runAttempt({ provider: syncProvider(server.url), apiKey: "k", prompt: "p", size: "864x1824" });
  assert.ok(result.bytes.equals(png));
});

test("查询异步任务返回 404：算这次任务失败，不把线路判成配置错误", async (t) => {
  const server = await scriptedServer((req) => (req.method === "POST" ? { body: { data: [{ task_id: "a/b" }] } } : { status: 404, body: { error: { message: "task not found" } } }));
  t.after(server.close);
  const provider = newProviderFromPreset("apimart-async", { id: "p", name: "p", baseUrl: server.url, model: "m", mapping: null });
  const original = PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs;
  PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = 20;
  t.after(() => (PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = original));
  await assert.rejects(runAttempt({ provider, apiKey: "k", prompt: "p", size: "1:2" }), (error) => error.kind === "task-failed");
  assert.match(server.calls[1].url, /\/tasks\/a%2Fb/, "任务号经过转义");
});

test("中转站返回 JPEG 时转成 PNG 再验收", async (t) => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "jpeg-"));
  fs.writeFileSync(path.join(dir, "a.png"), makePng(216, 456));
  execFileSync("/usr/bin/sips", ["-s", "format", "jpeg", path.join(dir, "a.png"), "--out", path.join(dir, "a.jpg")]);
  const jpeg = fs.readFileSync(path.join(dir, "a.jpg"));
  const relay = await scriptedServer(() => ({ body: { data: [{ b64_json: jpeg.toString("base64") }] } }));
  t.after(relay.close);
  const { checkScreenImage } = await import("../core/gateway/image-check.mjs");
  const result = await runAttempt({ provider: syncProvider(relay.url), apiKey: "k", prompt: "p", size: "864x1824" });
  const check = await checkScreenImage(result.bytes);
  assert.equal(check.ok, true, check.reason);
  assert.equal(check.png.subarray(1, 4).toString(), "PNG");
});

test("CSV：表头、中文逗号、引号、制表符、空行、非法屏数", () => {
  const rows = parseBatchCsv('﻿软件名,截图数,重点功能\n"云伴日程, 专业版 V1.0",7,日程提醒\n\n快记账本 V1.0，abc，预算\n办公助手 V2\t5\t审批\t/Users/x/code\tnone\n');
  assert.equal(rows.length, 3);
  assert.deepEqual(rows[0], { softwareName: "云伴日程, 专业版 V1.0", screenCount: 7, emphasis: "日程提醒", codeSourcePath: "", versionPolicy: "in-name" });
  assert.equal(rows[1].screenCount, null);
  assert.equal(rows[1].emphasis, "预算");
  assert.equal(rows[2].codeSourcePath, "/Users/x/code");
  assert.equal(rows[2].versionPolicy, "none");
});

test("代码来源：跳过二进制和排除目录，去掉 BOM，统一换行，按路径排序", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "code-"));
  await fsp.mkdir(path.join(dir, "src", "b"), { recursive: true });
  await fsp.mkdir(path.join(dir, "build"), { recursive: true });
  fs.writeFileSync(path.join(dir, "src", "b", "Z.java"), "﻿class Z {}\r\n");
  fs.writeFileSync(path.join(dir, "src", "A.java"), "class A {}");
  fs.writeFileSync(path.join(dir, "src", "Bin.java"), Buffer.from([0x63, 0x00, 0x01]));
  fs.writeFileSync(path.join(dir, "build", "Gen.java"), "class Gen {}");
  const result = await collectCodeSource({ path: dir, extensions: ["java"] }, { excludeDirs: ["build"] });
  assert.deepEqual(result.files, ["src/A.java", "src/b/Z.java"]);
  assert.equal(result.body, "class A {}\nclass Z {}\n");
  assert.equal(result.lineCount, 2);
  assert.equal(result.warnings.length, 1);
  const single = await collectCodeSource({ path: path.join(dir, "src", "A.java"), extensions: [".java"] });
  assert.equal(single.fileCount, 1);
  await assert.rejects(collectCodeSource({ path: path.join(dir, "nope") }), /不存在/);
  await assert.rejects(collectCodeSource({ path: dir, extensions: [".kt"] }), /没有找到/);
});

// 测试用的「加密器」：只做 base64，让密钥能落盘、重启后还在
const testCipher = { encrypt: (value) => Buffer.from(value).toString("base64"), decrypt: (value) => Buffer.from(value, "base64").toString() };

async function coreWithMocks({ withVision = true, relayBehavior } = {}) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "edge-core-"));
  const relay = await startMockRelay(relayBehavior || (() => ({ delayMs: 60 })));
  const llm = await startMockLlm();
  const core = await createCore({ dataDir: path.join(root, "data"), cipher: testCipher });
  await core.updateSettings({ workspaceDir: path.join(root, "ws"), pipeline: { reviewPlanSingle: false } });
  await core.saveProvider({ id: "cpa", preset: "openai-sync", name: "CPA", baseUrl: relay.baseUrl, model: "m", apiKey: "sk-x" });
  const vendorId = await core.saveVendor({ name: "v", preset: "custom", baseUrl: llm.baseUrl, apiKey: "sk-y" });
  for (const step of ["plan", "content"]) await core.setAssignment(step, { vendorId, model: "t" });
  if (withVision) await core.setAssignment("gate", { vendorId, model: "v" });
  return { root, relay, llm, core, close: () => Promise.all([relay.close(), llm.close()]) };
}

test("软件名非法字符、重复建项目都会被拦下", async (t) => {
  const ctx = await coreWithMocks();
  t.after(ctx.close);
  await assert.rejects(ctx.core.createProject({ softwareName: "a/b V1.0" }), /不能包含/);
  await assert.rejects(ctx.core.createProject({ softwareName: ".隐藏 V1.0" }), /以点开头/);
  await assert.rejects(ctx.core.createProject({ softwareName: "   " }), /为空/);
  const dir = await ctx.core.createProject({ softwareName: "车辆投屏（Android 端）V1.0" });
  assert.ok(fs.existsSync(dir));
  await assert.rejects(ctx.core.createProject({ softwareName: "车辆投屏（Android 端）V1.0" }), /已经有/);
});

test("没有看图模型：截图等人工确认，全部确认后继续到交付包", async (t) => {
  const ctx = await coreWithMocks({ withVision: false });
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "人工确认 V1.0", screenCount: 2 });
  const first = await ctx.core.run(dir);
  assert.equal(first.status, "waiting");
  assert.equal(first.step, "gate");
  for (const id of ["screen-01", "screen-02"]) await ctx.core.actions.manualGate(dir, id, true);
  const second = await ctx.core.run(dir);
  const project = await ctx.core.getProject(dir);
  assert.equal(second.status, "done", project.state.lastError || "");
  assert.ok(project.state.warnings.some((warning) => warning.includes("文案未按截图对账")));
});

test("中途取消后再运行：只补生成缺的截图，不重复购买", async (t) => {
  const ctx = await coreWithMocks({ relayBehavior: (index) => ({ delayMs: index < 2 ? 50 : 1500 }) });
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "取消测试 V1.0", screenCount: 4 });
  const running = ctx.core.run(dir);
  await new Promise((resolve) => setTimeout(resolve, 900));
  ctx.core.cancel(dir);
  const canceled = await running;
  assert.equal(canceled.status, "canceled");
  const made = fs.readdirSync(path.join(dir, "screens")).filter((name) => name.endsWith(".png"));
  assert.ok(made.length >= 1 && made.length < 4, `取消前生成了 ${made.length} 张`);
  const submitsBefore = ctx.relay.submits().length;
  const done = await ctx.core.run(dir);
  assert.equal(done.status, "done");
  assert.equal(ctx.relay.submits().length - submitsBefore, 4 - made.length, "只补缺的");
});

test("只读的历史项目不能运行", async (t) => {
  const ctx = await coreWithMocks();
  t.after(ctx.close);
  const dir = path.join(ctx.root, "ws", "只读项目 V1.0");
  await fsp.mkdir(path.join(dir, "只读项目 V1.0"), { recursive: true });
  fs.writeFileSync(path.join(dir, "只读项目 V1.0", "只读项目 V1.0指南.docx"), "x");
  const scan = await ctx.core.scanWorkspace();
  assert.equal(scan[0].grade, "readonly");
  await ctx.core.importProjects([dir]);
  const result = await ctx.core.run(dir);
  assert.equal(result.status, "failed");
  assert.match(result.error, /只读/);
  assert.equal(ctx.llm.calls.length, 0);
});

test("批量：暂停、继续、软件重启后自动续跑", async (t) => {
  const ctx = await coreWithMocks({ relayBehavior: () => ({ delayMs: 300 }) });
  t.after(ctx.close);
  await ctx.core.updateSettings({ pipeline: { batchConcurrency: 1 } });
  const a = await ctx.core.createProject({ softwareName: "批量甲 V1.0", screenCount: 2 });
  const b = await ctx.core.createProject({ softwareName: "批量乙 V1.0", screenCount: 2 });
  await ctx.core.batch.init();
  await ctx.core.batch.enqueue([a, b]);
  await new Promise((resolve) => setTimeout(resolve, 150));
  await ctx.core.batch.pause();
  await new Promise((resolve) => setTimeout(resolve, 600));
  let list = await ctx.core.batch.list();
  assert.ok(list.items.every((item) => item.status !== "running"), JSON.stringify(list.items.map((item) => item.status)));
  // 模拟软件重启：用同一个数据目录建新的 core
  const core2 = await createCore({ dataDir: path.join(ctx.root, "data"), cipher: testCipher });
  await core2.batch.init();
  await core2.batch.resume();
  for (let i = 0; i < 100; i += 1) {
    list = await core2.batch.list();
    if (list.items.every((item) => item.status === "done")) break;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  assert.deepEqual(list.items.map((item) => item.status), ["done", "done"]);
});
