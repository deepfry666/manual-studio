import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { startMockRelay } from "./helpers/mock-relay.mjs";
import { createImageGateway } from "../core/gateway/gateway.mjs";
import { createLedger } from "../core/gateway/ledger.mjs";
import { createHealthStore } from "../core/gateway/health.mjs";
import { createCallLog } from "../core/log/call-log.mjs";
import { createMemorySecrets, secretIds } from "../core/secrets.mjs";
import { newProviderFromPreset } from "../core/gateway/presets.mjs";
import { nearestRatio, parseAllowedRatios, resolveRequestSize } from "../core/gateway/sizes.mjs";
import { classifyHttpError, readPath, fillTemplate } from "../core/gateway/adapter.mjs";
import { defaultSettings } from "../core/settings.mjs";

async function setup(providerSpecs, imageOverrides = {}) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "gw-test-"));
  const project = path.join(dir, "proj");
  await fsp.mkdir(path.join(project, "screens"), { recursive: true });
  const settings = defaultSettings();
  settings.image = { ...settings.image, ...imageOverrides, hedge: { ...settings.image.hedge, ...(imageOverrides.hedge || {}) } };
  const secrets = createMemorySecrets();
  settings.providers = [];
  for (const spec of providerSpecs) {
    const provider = newProviderFromPreset(spec.preset || "openai-sync", { id: spec.id, name: spec.id, baseUrl: spec.baseUrl, model: spec.model || "gpt-image-2.5", ...spec.overrides });
    settings.providers.push(provider);
    await secrets.set(secretIds.imageProvider(provider.id), "sk-test-secret-value");
  }
  const ledger = createLedger(dir);
  await ledger.init();
  const health = createHealthStore(dir);
  await health.init();
  const callLog = createCallLog(dir);
  const events = [];
  const updates = [];
  const gateway = createImageGateway({
    getSettings: async () => settings,
    updateProvider: async (id, patch) => {
      updates.push({ id, patch });
      Object.assign(settings.providers.find((provider) => provider.id === id), patch);
    },
    secrets,
    ledger,
    health,
    callLog,
    onEvent: (event) => events.push(event),
    randomDelayMs: () => 20,
  });
  const request = (screenId, extra = {}) => ({
    projectDir: project,
    projectName: "测试项目",
    screenId,
    prompt: `prompt for ${screenId}`,
    outputPath: path.join(project, "screens", `${screenId}.png`),
    alternatesDir: path.join(project, "screens", "alternates"),
    archiveRoot: path.join(project, "archive"),
    ...extra,
  });
  return { dir, project, settings, secrets, ledger, health, callLog, gateway, events, updates, request };
}

test("尺寸换算：864x1824 在 APIMart 比例里选 1:2，能从 CPA 报错里解析允许比例", () => {
  const ratios = ["1:1", "16:9", "9:16", "2:1", "1:2", "21:9", "9:21"];
  assert.equal(nearestRatio({ width: 864, height: 1824 }, ratios), "1:2");
  const message = "size must be auto or one of 1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3, 5:4, 4:5, 21:9; pixel sizes are not supported";
  assert.deepEqual(parseAllowedRatios(message), ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "5:4", "4:5", "21:9"]);
  assert.equal(classifyHttpError(400, message).kind, "size");
  assert.deepEqual(resolveRequestSize({ sizeMode: "ratio", ratios: parseAllowedRatios(message) }, "864x1824"), { mode: "ratio", size: "9:16" });
  assert.deepEqual(resolveRequestSize({ sizeMode: "pixel", pixelSize: "864x1824" }, "864x1824"), { mode: "pixel", size: "864x1824" });
});

test("报错分类：额度冷却能解析剩余秒数", () => {
  const quota = classifyHttpError(429, "credentials for model gpt-image-2 are cooling down (last error: credential_quota)', 'reset_seconds': 2901");
  assert.equal(quota.kind, "quota");
  assert.equal(quota.retryAfterSec, 2901);
  assert.equal(classifyHttpError(400, "48m20s cooling down quota").retryAfterSec, 48 * 60 + 20);
  assert.equal(classifyHttpError(404, 'Model "gpt-image-1" is not supported by any configured account').kind, "config");
  assert.equal(classifyHttpError(401, "bad key").kind, "auth");
  assert.equal(classifyHttpError(502, "bad gateway").kind, "server");
});

test("JSON 路径与模板替换", () => {
  const data = { data: [{ task_id: "t1" }], result: { images: [{ url: "a" }, { url: "b" }] } };
  assert.equal(readPath(data, "$.data[0].task_id"), "t1");
  assert.deepEqual(readPath(data, "$.result.images[*]"), [{ url: "a" }, { url: "b" }]);
  assert.deepEqual(fillTemplate({ model: "$model", size: "$size", n: 1, quality: "$quality" }, { model: "m", size: "1:2" }), { model: "m", size: "1:2", n: 1 });
});

test("同步线路真正并发：4 屏同时发出，而不是一张做完再发下一张", async (t) => {
  const relay = await startMockRelay(() => ({ delayMs: 400 }));
  t.after(() => relay.close());
  const ctx = await setup([{ id: "cpa", baseUrl: relay.baseUrl, overrides: { concurrency: 4 } }], { hedge: { enabled: false } });
  const started = Date.now();
  const results = await Promise.all(["screen-01", "screen-02", "screen-03", "screen-04"].map((id) => ctx.gateway.generate(ctx.request(id))));
  const elapsed = Date.now() - started;
  const arrivals = relay.submits().map((request) => request.arrivedAt);
  assert.ok(Math.max(...arrivals) - Math.min(...arrivals) < 200, `请求到达时间应几乎相同：${arrivals}`);
  assert.ok(elapsed < 1200, `4 张并发应约 0.4 秒，实际 ${elapsed}ms`);
  for (const result of results) assert.ok(fs.existsSync(result.outputPath));
  assert.equal(ctx.callLog.all().filter((row) => row.ok).length, 4);
});

test("线路并发上限生效：concurrency=2 时最多同时 2 个请求", async (t) => {
  let inFlight = 0;
  let peak = 0;
  const relay = await startMockRelay(() => {
    inFlight += 1;
    peak = Math.max(peak, inFlight);
    setTimeout(() => (inFlight -= 1), 300);
    return { delayMs: 300 };
  });
  t.after(() => relay.close());
  const ctx = await setup([{ id: "cpa", baseUrl: relay.baseUrl, overrides: { concurrency: 2 } }], { hedge: { enabled: false } });
  await Promise.all(["screen-01", "screen-02", "screen-03", "screen-04"].map((id) => ctx.gateway.generate(ctx.request(id))));
  assert.equal(peak, 2);
});

test("一屏失败不连累其他屏，失败的屏切到下一条线路", async (t) => {
  const relayA = await startMockRelay((index, body) => (body.prompt.includes("screen-02") ? { status: 500, error: "upstream exploded" } : { delayMs: 50 }));
  const relayB = await startMockRelay(() => ({ delayMs: 50 }));
  t.after(() => Promise.all([relayA.close(), relayB.close()]));
  const ctx = await setup([{ id: "a", baseUrl: relayA.baseUrl }, { id: "b", baseUrl: relayB.baseUrl }], { hedge: { enabled: false } });
  const results = await Promise.all(["screen-01", "screen-02", "screen-03"].map((id) => ctx.gateway.generate(ctx.request(id))));
  assert.deepEqual(results.map((result) => result.providerId), ["a", "b", "a"]);
  // screen-02 在 A 上 5xx 先同线路重试 1 次，再切到 B
  assert.equal(relayA.submits().filter((request) => request.prompt.includes("screen-02")).length, 2);
  assert.equal(relayB.submits().length, 1);
  assert.equal(relayA.submits().filter((request) => !request.prompt.includes("screen-02")).length, 2, "其他屏不重新购买");
});

test("超时补发：慢线路超过补发线后补发到另一条线路，先出图的胜出，慢的同步请求被取消", async (t) => {
  const slow = await startMockRelay(() => ({ delayMs: 3000 }));
  const fast = await startMockRelay(() => ({ delayMs: 100 }));
  t.after(() => Promise.all([slow.close(), fast.close()]));
  const ctx = await setup(
    [
      { id: "slow", baseUrl: slow.baseUrl, overrides: { hedgeDefaultSec: 0.3, modelGroup: "gpt-image-2.5" } },
      { id: "fast", baseUrl: fast.baseUrl, overrides: { modelGroup: "gpt-image-2.5" } },
    ],
    { hedge: { enabled: true, minSec: 0.3, maxSec: 1, maxPerBatch: 3 } }
  );
  const started = Date.now();
  const result = await ctx.gateway.generate(ctx.request("screen-01", { batchId: "b1" }));
  assert.equal(result.providerId, "fast");
  assert.equal(result.hedged, true);
  assert.ok(Date.now() - started < 1500);
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(slow.submits()[0].aborted, true, "慢的同步请求应被取消");
  assert.ok(ctx.events.some((event) => event.type === "hedge"));
});

test("补发不跨模型（默认）：只有不同模型的线路时不补发", async (t) => {
  const slow = await startMockRelay(() => ({ delayMs: 900 }));
  const other = await startMockRelay(() => ({ delayMs: 50 }));
  t.after(() => Promise.all([slow.close(), other.close()]));
  const ctx = await setup(
    [
      { id: "slow", baseUrl: slow.baseUrl, model: "gpt-image-2", overrides: { hedgeDefaultSec: 0.2 } },
      { id: "other", baseUrl: other.baseUrl, model: "gpt-image-2.5" },
    ],
    { hedge: { enabled: true, minSec: 0.2, maxSec: 1, allowCrossModel: false } }
  );
  const result = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(result.providerId, "slow");
  assert.equal(other.submits().length, 0);
});

test("异步线路作为补发输家：不取消，后台查完存为备选图", async (t) => {
  const asyncRelay = await startMockRelay(() => ({ mode: "async", delayMs: 20, readyAfterMs: 1200 }));
  const syncRelay = await startMockRelay(() => ({ delayMs: 100 }));
  t.after(() => Promise.all([asyncRelay.close(), syncRelay.close()]));
  const ctx = await setup(
    [
      { id: "apimart", preset: "apimart-async", baseUrl: asyncRelay.baseUrl, overrides: { hedgeDefaultSec: 0.3, modelGroup: "2.5", mapping: null } },
      { id: "cpa", baseUrl: syncRelay.baseUrl, overrides: { modelGroup: "2.5" } },
    ],
    { hedge: { enabled: true, minSec: 0.3, maxSec: 1 } }
  );
  // 加快轮询
  const { PROVIDER_PRESETS } = await import("../core/gateway/presets.mjs");
  PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = 100;
  const result = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(result.providerId, "cpa");
  assert.equal(asyncRelay.submits()[0].size, "1:2", "APIMart 按比例发送");
  await new Promise((resolve) => setTimeout(resolve, 1800));
  const alternates = fs.readdirSync(path.join(ctx.project, "screens", "alternates", "screen-01"));
  assert.equal(alternates.length, 1);
  assert.ok(ctx.events.some((event) => event.type === "alternate"));
  PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = 3000;
});

test("额度冷却：429 后这条线路进入冷却，后续任务直接跳过它", async (t) => {
  const quota = await startMockRelay(() => ({ status: 429, error: "credential_quota cooling down, reset_seconds: 600" }));
  const backup = await startMockRelay(() => ({ delayMs: 30 }));
  t.after(() => Promise.all([quota.close(), backup.close()]));
  const ctx = await setup([{ id: "q", baseUrl: quota.baseUrl }, { id: "b", baseUrl: backup.baseUrl }], { hedge: { enabled: false } });
  const first = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(first.providerId, "b");
  assert.match(ctx.health.unavailableReason("q"), /冷却/);
  await ctx.gateway.generate(ctx.request("screen-02"));
  assert.equal(quota.submits().length, 1, "冷却期间不再请求");
});

test("线路不收像素尺寸时，自动改用报错里允许的最接近比例并立即重试", async (t) => {
  const relay = await startMockRelay((index, body) =>
    /x/.test(body.size) ? { status: 400, error: "invalid size: must be auto or one of 1:1, 16:9, 9:16, 1:2, 2:1; pixel sizes are not supported" } : { delayMs: 30 }
  );
  t.after(() => relay.close());
  const ctx = await setup([{ id: "cpa", baseUrl: relay.baseUrl }], { hedge: { enabled: false } });
  const result = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(result.requestSize, "1:2");
  assert.deepEqual(relay.submits().map((request) => request.size), ["864x1824", "1:2"]);
  assert.equal(ctx.updates[0].patch.sizeMode, "ratio");
  assert.equal(ctx.health.unavailableReason("cpa"), null, "尺寸问题不算线路故障");
});

test("空白图判为无效并切换线路", async (t) => {
  const blank = await startMockRelay(() => ({ blank: true }));
  const good = await startMockRelay(() => ({}));
  t.after(() => Promise.all([blank.close(), good.close()]));
  const ctx = await setup([{ id: "blank", baseUrl: blank.baseUrl }, { id: "good", baseUrl: good.baseUrl }], { hedge: { enabled: false } });
  const result = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(result.providerId, "good");
});

test("替换截图前先归档旧图", async (t) => {
  const relay = await startMockRelay(() => ({}));
  t.after(() => relay.close());
  const ctx = await setup([{ id: "cpa", baseUrl: relay.baseUrl }], { hedge: { enabled: false } });
  await ctx.gateway.generate(ctx.request("screen-01"));
  await ctx.gateway.generate(ctx.request("screen-01"));
  const archived = fs.readdirSync(path.join(ctx.project, "archive"));
  assert.equal(archived.length, 1);
});

test("重启续查：账本里有任务号的异步任务继续查询，不重复提交", async (t) => {
  const relay = await startMockRelay(() => ({ mode: "async", readyAfterMs: 300 }));
  t.after(() => relay.close());
  const ctx = await setup([{ id: "apimart", preset: "apimart-async", baseUrl: relay.baseUrl }], { hedge: { enabled: false } });
  const { PROVIDER_PRESETS } = await import("../core/gateway/presets.mjs");
  PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = 100;
  // 模拟上次运行：已提交并拿到任务号，然后软件退出
  relay.tasks.set("task_prev", { readyAt: Date.now() + 200, seed: 9 });
  const request = ctx.request("screen-03");
  await ctx.ledger.createJob({ jobId: "j1", projectDir: request.projectDir, screenId: "screen-03", outputPath: request.outputPath, alternatesDir: request.alternatesDir, archiveRoot: request.archiveRoot, prompt: "p" });
  await ctx.ledger.startAttempt("j1", { attemptId: "a1", providerId: "apimart", role: "primary" });
  await ctx.ledger.markTaskId("j1", "a1", "task_prev");
  const ledger2 = createLedger(ctx.dir);
  await ledger2.init();
  const gateway2 = createImageGateway({ getSettings: async () => ctx.settings, secrets: ctx.secrets, ledger: ledger2, health: ctx.health, callLog: ctx.callLog });
  const resumed = await gateway2.resumePending();
  assert.deepEqual(resumed, ["j1"]);
  const viaGenerate = await gateway2.generate(request);
  assert.equal(viaGenerate.resumed, true, "同一屏正在续查时，不会重新提交");
  assert.ok(fs.existsSync(request.outputPath));
  assert.equal(relay.submits().length, 0);
  assert.equal(ledger2.get("j1").state, "done");
  PROVIDER_PRESETS["apimart-async"].mapping.polling.intervalMs = 3000;
});

test("启动时还在「提交中」的尝试标为提交结果未知", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "ledger-"));
  const ledger = createLedger(dir);
  await ledger.init();
  await ledger.createJob({ jobId: "j", projectDir: "/p", screenId: "screen-01" });
  await ledger.startAttempt("j", { attemptId: "a", providerId: "x" });
  const reopened = createLedger(dir);
  await reopened.init();
  const job = reopened.get("j");
  assert.equal(job.attempts[0].state, "unknown");
  assert.equal(job.state, "needs-attention");
});

test("所有线路都失败时报出每条线路的原因，日志里不出现密钥", async (t) => {
  const bad = await startMockRelay(() => ({ status: 401, error: "invalid key sk-test-secret-value" }));
  t.after(() => bad.close());
  const ctx = await setup([{ id: "bad", baseUrl: bad.baseUrl }], { hedge: { enabled: false } });
  await assert.rejects(ctx.gateway.generate(ctx.request("screen-01")), (error) => {
    assert.match(error.message, /bad/);
    assert.doesNotMatch(error.message, /sk-test-secret-value/);
    return true;
  });
  const logText = fs.readFileSync(ctx.callLog.file, "utf8");
  assert.doesNotMatch(logText, /sk-test-secret-value/);
  assert.match(ctx.health.unavailableReason("bad"), /配置错误/);
});

test("首选线路满载时分流到同画风组的空闲线路", async (t) => {
  const a = await startMockRelay(() => ({ delayMs: 400 }));
  const b = await startMockRelay(() => ({ delayMs: 400 }));
  t.after(() => Promise.all([a.close(), b.close()]));
  const ctx = await setup(
    [
      { id: "a", baseUrl: a.baseUrl, overrides: { concurrency: 1, modelGroup: "g" } },
      { id: "b", baseUrl: b.baseUrl, overrides: { concurrency: 3, modelGroup: "g" } },
    ],
    { hedge: { enabled: false } }
  );
  const started = Date.now();
  const results = await Promise.all(["screen-01", "screen-02", "screen-03", "screen-04"].map((id) => ctx.gateway.generate(ctx.request(id))));
  assert.equal(results.filter((result) => result.providerId === "a").length, 1);
  assert.equal(results.filter((result) => result.providerId === "b").length, 3);
  assert.ok(Date.now() - started < 900, "4 张同时出图，而不是在 A 上排队");
});

test("关闭分流时按顺序排队，不用后面的线路", async (t) => {
  const a = await startMockRelay(() => ({ delayMs: 100 }));
  const b = await startMockRelay(() => ({ delayMs: 100 }));
  t.after(() => Promise.all([a.close(), b.close()]));
  const ctx = await setup([{ id: "a", baseUrl: a.baseUrl, overrides: { concurrency: 1, modelGroup: "g" } }, { id: "b", baseUrl: b.baseUrl, overrides: { modelGroup: "g" } }], { spillover: false, hedge: { enabled: false } });
  const results = await Promise.all(["screen-01", "screen-02", "screen-03"].map((id) => ctx.gateway.generate(ctx.request(id))));
  assert.ok(results.every((result) => result.providerId === "a"));
});

test("线路只收固定像素尺寸时，按报错改用宽高比最接近的那个", async (t) => {
  const relay = await startMockRelay((index, body) =>
    body.size === "864x1824" ? { status: 400, error: "Invalid value: '864x1824'. Supported values are: '1024x1024', '1024x1536', '1536x1024', and 'auto'." } : { delayMs: 20 }
  );
  t.after(() => relay.close());
  const ctx = await setup([{ id: "openai", baseUrl: relay.baseUrl }], { hedge: { enabled: false } });
  const result = await ctx.gateway.generate(ctx.request("screen-01"));
  assert.equal(result.requestSize, "1024x1536");
  assert.deepEqual(ctx.updates[0].patch, { sizeMode: "pixel", pixelSize: "1024x1536" });
});

test("补发线样本包含被补发取消的慢请求，避免补发线越算越低", async () => {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "calllog-"));
  const log = createCallLog(dir);
  for (let index = 0; index < 5; index += 1) await log.append({ providerId: "p", ok: true, kind: "success", durationMs: 10_000 });
  await log.append({ providerId: "p", ok: false, kind: "aborted", outcome: "loser", durationMs: 90_000 });
  await log.append({ providerId: "p", ok: false, kind: "aborted", outcome: "canceled", durationMs: 5_000 });
  assert.deepEqual(log.recentSuccessSeconds("p").sort((a, b) => a - b), [10, 10, 10, 10, 10, 90]);
});
