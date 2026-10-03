import path from "node:path";
import fsp from "node:fs/promises";
import crypto from "node:crypto";
import { runAttempt, probeModels, ProviderError, sleep } from "./adapter.mjs";
import { resolveRequestSize, parsePixelSize, sizeFallback } from "./sizes.mjs";
import { checkScreenImage } from "./image-check.mjs";
import { isAsyncProvider, hostOf, modelGroupOf } from "./presets.mjs";
import { percentile } from "../log/call-log.mjs";
import { secretIds, redact } from "../secrets.mjs";
import { writeFileAtomic, exists, timestampSlug } from "../util/fsx.mjs";

export class Semaphore {
  constructor(limit) {
    this.limit = Math.max(1, limit || 1);
    this.active = 0;
    this.waiters = [];
  }
  setLimit(limit) {
    this.limit = Math.max(1, limit || 1);
    this.drain();
  }
  acquire(signal) {
    if (this.active < this.limit) {
      this.active += 1;
      return Promise.resolve();
    }
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject };
      this.waiters.push(waiter);
      signal?.addEventListener(
        "abort",
        () => {
          const index = this.waiters.indexOf(waiter);
          if (index >= 0) {
            this.waiters.splice(index, 1);
            reject(new ProviderError("请求已取消", { kind: "aborted" }));
          }
        },
        { once: true }
      );
    });
  }
  hasCapacity() {
    return this.active < this.limit && this.waiters.length === 0;
  }
  release() {
    this.active = Math.max(0, this.active - 1);
    this.drain();
  }
  drain() {
    while (this.active < this.limit && this.waiters.length) {
      this.active += 1;
      this.waiters.shift().resolve();
    }
  }
}

const PROBE_PROMPT =
  "A single portrait mobile app settings screen, light theme, clean list of toggles and section headers in Simplified Chinese. No logo, no brand name, no device frame.";

/**
 * 生图网关：每屏一个独立任务，真正异步并发；失败切换、超时补发、额度冷却、任务账本续查。
 */
export function createImageGateway({
  getSettings,
  updateProvider = async () => {},
  secrets,
  ledger,
  health,
  callLog,
  fetchImpl = fetch,
  toPng,
  checkImage = (bytes) => checkScreenImage(bytes, toPng ? { toPng } : {}),
  now = () => Date.now(),
  onEvent = () => {},
  sleepImpl = sleep,
  randomDelayMs = () => 2000 + Math.floor(Math.random() * 3000),
}) {
  const globalSemaphore = new Semaphore(10);
  const providerSemaphores = new Map();
  const hedgesByBatch = new Map();
  const inflightByScreen = new Map();

  function providerSemaphore(provider) {
    let semaphore = providerSemaphores.get(provider.id);
    if (!semaphore) {
      semaphore = new Semaphore(provider.concurrency || 3);
      providerSemaphores.set(provider.id, semaphore);
    } else {
      semaphore.setLimit(provider.concurrency || 3);
    }
    return semaphore;
  }

  async function secretList() {
    try {
      return await secrets.values();
    } catch {
      return [];
    }
  }

  function hedgeThresholdMs(provider, hedge) {
    const recent = callLog.recentSuccessSeconds(provider.id, 50);
    const base = recent.length >= 5 ? percentile(recent, hedge.percentile || 85) : provider.hedgeDefaultSec || 60;
    const clamped = Math.min(hedge.maxSec || 120, Math.max(hedge.minSec || 20, base));
    return Math.round(clamped * 1000);
  }

  async function installFile(outputPath, png, archiveRoot) {
    if (await exists(outputPath)) {
      const archiveDir = path.join(archiveRoot, `screens-${timestampSlug(new Date(now()))}`);
      await fsp.mkdir(archiveDir, { recursive: true });
      await fsp.copyFile(outputPath, path.join(archiveDir, path.basename(outputPath)));
    }
    await writeFileAtomic(outputPath, png);
  }

  async function saveAlternate(request, provider, png) {
    const dir = path.join(request.alternatesDir, request.screenId);
    await fsp.mkdir(dir, { recursive: true });
    const file = path.join(dir, `${timestampSlug(new Date(now()))}-${provider.id}.png`);
    await writeFileAtomic(file, png);
    return file;
  }

  function pickHedgeProvider(providers, current, tried, hedge) {
    const candidates = providers.filter((provider) => provider.id !== current.id && !tried.includes(provider.id) && !health.unavailableReason(provider.id));
    const group = modelGroupOf(current);
    const host = hostOf(current.baseUrl);
    return (
      candidates.find((provider) => modelGroupOf(provider) === group && hostOf(provider.baseUrl) !== host) ||
      candidates.find((provider) => modelGroupOf(provider) === group) ||
      (hedge.allowCrossModel ? candidates[0] : null) ||
      null
    );
  }

  /**
   * 生成一屏。request: { projectDir, projectName, screenId, prompt, outputPath, alternatesDir, archiveRoot, batchId, signal }
   */
  async function generate(request) {
    if (request.signal?.aborted) throw new ProviderError("已取消", { kind: "aborted" });
    const screenKey = `${request.projectDir}::${request.screenId}`;
    const inflight = inflightByScreen.get(screenKey);
    if (inflight) {
      const result = await inflight;
      // 重启后续查的任务失败了：这一屏重新正常生成
      if (result?.resumed && !result.ok) return generate(request);
      return result;
    }
    const promise = generateInner(request).finally(() => inflightByScreen.delete(screenKey));
    inflightByScreen.set(screenKey, promise);
    return promise;
  }

  async function generateInner(request) {
    const settings = await getSettings();
    const imageSettings = settings.image;
    const hedge = imageSettings.hedge || {};
    globalSemaphore.setLimit(imageSettings.globalConcurrency || 10);
    const providers = (settings.providers || []).filter((provider) => provider.enabled);
    if (!providers.length) throw new Error("还没有可用的生图线路，请先到「生图线路」里添加并启用");
    const target = parsePixelSize(imageSettings.targetSize) || { width: 864, height: 1824 };
    const maxAttempts = imageSettings.maxAttemptsPerScreen || 4;
    const secretValues = await secretList();
    const jobId = `${path.basename(request.projectDir)}:${request.screenId}:${crypto.randomBytes(4).toString("hex")}`;
    await ledger.createJob({
      jobId,
      projectDir: request.projectDir,
      screenId: request.screenId,
      outputPath: request.outputPath,
      alternatesDir: request.alternatesDir,
      archiveRoot: request.archiveRoot,
      prompt: request.prompt,
      batchId: request.batchId || null,
    });

    return new Promise((resolve, reject) => {
      const job = {
        settled: false,
        active: new Map(),
        background: new Map(),
        tried: [],
        failures: [],
        started: 0,
        hedged: false,
        retried: new Set(),
        sizeOverrides: new Map(),
        startedAt: now(),
      };

      const emit = (event) => onEvent({ jobId, projectDir: request.projectDir, screenId: request.screenId, ...event });

      function nextProvider() {
        const candidates = providers.filter((provider) => !job.tried.includes(provider.id) && !health.unavailableReason(provider.id));
        const first = candidates[0];
        if (!first) return null;
        // 首选线路满载时，分流到同画风组里还有空位的线路（不改变画风）
        if (imageSettings.spillover !== false && !providerSemaphore(first).hasCapacity()) {
          const group = modelGroupOf(first);
          const spare = candidates.find((provider) => provider !== first && modelGroupOf(provider) === group && providerSemaphore(provider).hasCapacity());
          if (spare) return spare;
        }
        return first;
      }

      function unavailableSummary() {
        return providers
          .map((provider) => {
            const reason = health.unavailableReason(provider.id);
            return reason ? `${provider.name}：${reason}` : null;
          })
          .filter(Boolean);
      }

      async function failJob(extraMessage) {
        if (job.settled) return;
        job.settled = true;
        for (const attempt of [...job.active.values(), ...job.background.values()]) {
          attempt.abortReason = "job-failed";
          attempt.controller.abort();
        }
        const lines = job.failures.map((failure) => `${failure.providerName}：${failure.message}`);
        const unavailable = unavailableSummary();
        const message = [extraMessage, ...lines, ...(unavailable.length ? ["不可用的线路：", ...unavailable] : [])].filter(Boolean).join("\n");
        await ledger.finishJob(jobId, { state: "failed", error: message });
        emit({ type: "job-failed", message });
        const error = new Error(message || "生图失败");
        error.failures = job.failures;
        reject(error);
      }

      function failover() {
        if (job.settled) return;
        if (job.active.size > 0 || job.background.size > 0) return;
        if (job.started >= maxAttempts) {
          failJob(`已尝试 ${job.started} 次，仍未成功`);
          return;
        }
        const next = nextProvider();
        if (!next) {
          failJob(job.tried.length ? "所有可用线路都试过了" : "没有可用的生图线路");
          return;
        }
        launch(next, job.tried.length ? "failover" : "primary");
      }

      async function launch(provider, role) {
        if (job.settled) return;
        const attempt = {
          attemptId: crypto.randomBytes(6).toString("hex"),
          provider,
          role,
          controller: new AbortController(),
          timers: {},
          taskId: null,
          holdsGlobal: false,
          holdsProvider: false,
        };
        job.active.set(attempt.attemptId, attempt);
        job.tried.push(provider.id);
        job.started += 1;
        const signal = attempt.controller.signal;
        try {
          // 先等线路名额再占全局名额：排队等某条线路的任务不占全局名额，补发和分流不会被堵住
          await providerSemaphore(provider).acquire(signal);
          attempt.holdsProvider = true;
          await globalSemaphore.acquire(signal);
          attempt.holdsGlobal = true;
        } catch (error) {
          releaseSlots(attempt);
          handleFailure(attempt, error);
          return;
        }
        if (job.settled) {
          releaseSlots(attempt);
          job.active.delete(attempt.attemptId);
          return;
        }
        attempt.startedAt = now();
        const sizeSpec = job.sizeOverrides.get(provider.id) || resolveRequestSize(provider, imageSettings.targetSize);
        attempt.sizeSpec = sizeSpec;
        await ledger.startAttempt(jobId, {
          attemptId: attempt.attemptId,
          providerId: provider.id,
          model: provider.model,
          role,
          requestSize: sizeSpec.size,
        });
        emit({ type: "attempt-start", providerId: provider.id, providerName: provider.name, role, requestSize: sizeSpec.size });
        const apiKey = await secrets.get(secretIds.imageProvider(provider.id));
        if (job.settled) {
          releaseSlots(attempt);
          job.active.delete(attempt.attemptId);
          await ledger.finishAttempt(jobId, attempt.attemptId, { state: "aborted", outcome: "not-needed" });
          return;
        }
        if (!apiKey) {
          releaseSlots(attempt);
          handleFailure(attempt, new ProviderError("这条线路还没有填写密钥", { kind: "auth" }));
          return;
        }
        if (role !== "hedge" && hedge.enabled && hedge.maxPerBatch !== 0) {
          attempt.timers.hedge = setTimeout(() => onHedgeTimer(attempt), hedgeThresholdMs(provider, hedge));
        }
        attempt.timers.hard = setTimeout(() => onHardTimeout(attempt), (provider.hardTimeoutSec || 240) * 1000);
        runAttempt({
          provider,
          apiKey,
          prompt: request.prompt,
          size: sizeSpec.size,
          quality: imageSettings.quality,
          signal,
          fetchImpl,
          onTaskId: async (taskId) => {
            attempt.taskId = taskId;
            await ledger.markTaskId(jobId, attempt.attemptId, taskId);
            emit({ type: "attempt-task", providerId: provider.id, taskId });
          },
        }).then(
          (result) => handleSuccess(attempt, result),
          (error) => handleFailure(attempt, error)
        );
      }

      function releaseSlots(attempt) {
        if (attempt.holdsGlobal) {
          attempt.holdsGlobal = false;
          globalSemaphore.release();
        }
        if (attempt.holdsProvider) {
          attempt.holdsProvider = false;
          providerSemaphore(attempt.provider).release();
        }
      }

      function clearTimers(attempt) {
        clearTimeout(attempt.timers.hedge);
        clearTimeout(attempt.timers.hard);
      }

      function logCall(attempt, fields) {
        const durationMs = attempt.startedAt ? now() - attempt.startedAt : 0;
        return callLog.append({
          jobId,
          projectDir: request.projectDir,
          projectName: request.projectName,
          screenId: request.screenId,
          providerId: attempt.provider.id,
          providerName: attempt.provider.name,
          model: attempt.provider.model,
          role: attempt.role,
          requestSize: attempt.sizeSpec?.size,
          taskId: attempt.taskId || undefined,
          durationMs,
          ...fields,
        });
      }

      async function handleSuccess(attempt, result) {
        clearTimers(attempt);
        releaseSlots(attempt);
        const check = await checkImage(result.bytes);
        if (!check.ok) {
          handleFailure(attempt, new ProviderError(check.reason, { kind: "invalid-image" }));
          return;
        }
        job.active.delete(attempt.attemptId);
        job.background.delete(attempt.attemptId);
        const durationMs = now() - attempt.startedAt;
        await health.recordSuccess(attempt.provider.id);
        if (!job.settled) {
          job.settled = true;
          await installFile(request.outputPath, check.png, request.archiveRoot);
          await logCall(attempt, { ok: true, kind: "success", outcome: "winner", width: check.width, height: check.height, hedged: job.hedged });
          await ledger.finishAttempt(jobId, attempt.attemptId, { state: "completed", outcome: "winner" });
          await ledger.finishJob(jobId, { state: "done", winnerAttemptId: attempt.attemptId, providerId: attempt.provider.id });
          for (const other of job.active.values()) {
            if (isAsyncProvider(other.provider) && other.taskId) {
              // 异步任务已经在中转站跑了，取消也不退钱：继续在后台查，出图后存为备选。
              job.active.delete(other.attemptId);
              job.background.set(other.attemptId, other);
              clearTimers(other);
            } else {
              other.abortReason = "loser";
              other.controller.abort();
            }
          }
          emit({ type: "winner", providerId: attempt.provider.id, providerName: attempt.provider.name, durationMs, hedged: job.hedged });
          resolve({
            jobId,
            outputPath: request.outputPath,
            providerId: attempt.provider.id,
            providerName: attempt.provider.name,
            model: attempt.provider.model,
            requestSize: attempt.sizeSpec.size,
            width: check.width,
            height: check.height,
            durationMs: now() - job.startedAt,
            hedged: job.hedged,
            attempts: job.started,
            warnings: check.warnings,
          });
        } else {
          const file = await saveAlternate(request, attempt.provider, check.png);
          await logCall(attempt, { ok: true, kind: "success", outcome: "alternate", width: check.width, height: check.height });
          await ledger.finishAttempt(jobId, attempt.attemptId, { state: "completed", outcome: "alternate", alternatePath: file });
          emit({ type: "alternate", providerId: attempt.provider.id, providerName: attempt.provider.name, file });
        }
      }

      async function handleFailure(attempt, rawError) {
        clearTimers(attempt);
        releaseSlots(attempt);
        job.active.delete(attempt.attemptId);
        const wasBackground = job.background.delete(attempt.attemptId);
        let error = rawError instanceof ProviderError ? rawError : new ProviderError(rawError?.message || String(rawError), { kind: "unknown" });
        if (error.kind === "aborted" && attempt.abortReason === "timeout") {
          error = new ProviderError(`超过 ${attempt.provider.hardTimeoutSec || 240} 秒没有出图`, { kind: "timeout" });
        }
        const message = redact(error.message, secretValues);
        if (error.kind === "aborted") {
          if (attempt.startedAt) await logCall(attempt, { ok: false, kind: "aborted", outcome: attempt.abortReason || "canceled", errorMessage: "已取消" });
          await ledger.finishAttempt(jobId, attempt.attemptId, { state: "aborted", outcome: attempt.abortReason || "canceled" });
          if (!job.settled && attempt.abortReason !== "loser") failover();
          return;
        }
        await logCall(attempt, { ok: false, kind: error.kind, httpStatus: error.status, errorMessage: message });
        await ledger.finishAttempt(jobId, attempt.attemptId, { state: "failed", error: message, kind: error.kind });
        if (error.kind !== "content" && error.kind !== "size" && error.kind !== "pending") {
          await health.recordFailure(attempt.provider.id, { ...error, message });
        }
        emit({ type: "attempt-failed", providerId: attempt.provider.id, providerName: attempt.provider.name, kind: error.kind, message });
        if (job.settled || wasBackground && job.active.size > 0) return;

        const fallback = error.kind === "size" && !job.sizeOverrides.has(attempt.provider.id) ? sizeFallback(error, attempt.provider, imageSettings.targetSize, attempt.sizeSpec?.size) : null;
        if (fallback) {
          // 线路不支持当前尺寸：按报错改用它支持的尺寸立即重试，并记到线路配置里，以后直接用对的尺寸
          job.sizeOverrides.set(attempt.provider.id, fallback.spec);
          await updateProvider(attempt.provider.id, fallback.patch);
          emit({ type: "size-switched", providerId: attempt.provider.id, ratio: fallback.spec.size });
          job.tried = job.tried.filter((id) => id !== attempt.provider.id);
          job.started -= 1;
          launch(attempt.provider, attempt.role);
          return;
        }

        job.failures.push({ providerId: attempt.provider.id, providerName: attempt.provider.name, kind: error.kind, message });
        if ((error.kind === "server" || error.kind === "network") && !job.retried.has(attempt.provider.id) && job.started < maxAttempts) {
          job.retried.add(attempt.provider.id);
          await sleepImpl(randomDelayMs()).catch(() => {});
          if (job.settled) return;
          job.tried = job.tried.filter((id) => id !== attempt.provider.id);
          launch(attempt.provider, "retry");
          return;
        }
        failover();
      }

      function onHedgeTimer(attempt) {
        if (job.settled || job.hedged || !job.active.has(attempt.attemptId)) return;
        const candidate = pickHedgeProvider(providers, attempt.provider, job.tried, hedge);
        if (!candidate) return;
        if (request.batchId) {
          const used = hedgesByBatch.get(request.batchId) || 0;
          if (used >= (hedge.maxPerBatch ?? 3)) return;
          hedgesByBatch.set(request.batchId, used + 1);
        }
        job.hedged = true;
        emit({ type: "hedge", fromProviderId: attempt.provider.id, providerId: candidate.id, providerName: candidate.name });
        launch(candidate, "hedge");
      }

      function onHardTimeout(attempt) {
        if (job.settled || !job.active.has(attempt.attemptId)) return;
        if (isAsyncProvider(attempt.provider) && attempt.taskId) {
          // 异步任务超时：不放弃任务号，转后台继续查；同时换下一条线路。
          job.active.delete(attempt.attemptId);
          job.background.set(attempt.attemptId, attempt);
          releaseSlots(attempt);
          emit({ type: "attempt-background", providerId: attempt.provider.id, taskId: attempt.taskId });
          job.failures.push({ providerId: attempt.provider.id, providerName: attempt.provider.name, kind: "timeout", message: "超时，已转后台继续查询" });
          if (job.active.size === 0) {
            const next = nextProvider();
            if (next && job.started < maxAttempts) launch(next, "failover");
          }
          return;
        }
        attempt.abortReason = "timeout";
        attempt.controller.abort();
      }

      request.signal?.addEventListener(
        "abort",
        () => {
          if (job.settled) return;
          job.settled = true;
          for (const attempt of [...job.active.values(), ...job.background.values()]) {
            attempt.abortReason = "canceled";
            attempt.controller.abort();
          }
          ledger.finishJob(jobId, { state: "canceled" }).catch(() => {});
          reject(new ProviderError("已取消", { kind: "aborted" }));
        },
        { once: true }
      );

      failover();
    });
  }

  /** 软件重启后，把账本里还在等结果的异步任务接着查完。 */
  async function resumePending() {
    const settings = await getSettings();
    const resumed = [];
    for (const { job, attempt } of ledger.remoteWaiting()) {
      const provider = (settings.providers || []).find((item) => item.id === attempt.providerId);
      if (!provider) continue;
      const apiKey = await secrets.get(secretIds.imageProvider(provider.id));
      if (!apiKey) continue;
      const startedAt = now();
      const promise = runAttempt({ provider, apiKey, prompt: job.prompt, resumeTaskId: attempt.taskId, fetchImpl })
        .then(async (result) => {
          const check = await checkImage(result.bytes);
          if (!check.ok) throw new ProviderError(check.reason, { kind: "invalid-image" });
          const latest = ledger.get(job.jobId);
          const request = { ...job, alternatesDir: job.alternatesDir, archiveRoot: job.archiveRoot };
          let outcome = "alternate";
          let file;
          if (latest && (latest.state === "running" || latest.state === "interrupted")) {
            await installFile(job.outputPath, check.png, job.archiveRoot);
            await ledger.finishJob(job.jobId, { state: "done", winnerAttemptId: attempt.attemptId, providerId: provider.id });
            outcome = "winner";
            file = job.outputPath;
          } else {
            file = await saveAlternate(request, provider, check.png);
          }
          await ledger.finishAttempt(job.jobId, attempt.attemptId, { state: "completed", outcome, resumed: true });
          await callLog.append({ jobId: job.jobId, projectDir: job.projectDir, screenId: job.screenId, providerId: provider.id, providerName: provider.name, model: provider.model, role: "resume", ok: true, kind: "success", outcome, durationMs: now() - startedAt, taskId: attempt.taskId });
          onEvent({ type: outcome === "winner" ? "job-recovered" : "alternate", jobId: job.jobId, projectDir: job.projectDir, screenId: job.screenId, file, providerId: provider.id });
        })
        .catch(async (error) => {
          await ledger.finishAttempt(job.jobId, attempt.attemptId, { state: "failed", error: error.message, resumed: true });
          const latest = ledger.get(job.jobId);
          if (latest?.state === "running" || latest?.state === "interrupted") await ledger.finishJob(job.jobId, { state: "failed", error: error.message });
        });
      const key = `${job.projectDir}::${job.screenId}`;
      if (!inflightByScreen.has(key)) {
        const tracked = promise
          .then(() => {
            const latest = ledger.get(job.jobId);
            const ok = latest?.state === "done" && latest.winnerAttemptId === attempt.attemptId;
            return { resumed: true, ok, jobId: job.jobId, outputPath: job.outputPath, providerId: provider.id, providerName: provider.name, model: provider.model, requestSize: attempt.requestSize, durationMs: now() - startedAt, hedged: false, attempts: 1, warnings: [] };
          })
          .finally(() => inflightByScreen.delete(key));
        inflightByScreen.set(key, tracked);
      }
      resumed.push(job.jobId);
    }
    return resumed;
  }

  /** 测试线路：先免费查模型列表，需要时再真实生成一张（会扣一张图的费用）。 */
  async function probe(providerId, { realImage = false } = {}) {
    const settings = await getSettings();
    const provider = (settings.providers || []).find((item) => item.id === providerId);
    if (!provider) throw new Error("线路不存在");
    const apiKey = await secrets.get(secretIds.imageProvider(provider.id));
    if (!apiKey) throw new Error("这条线路还没有填写密钥");
    const secretValues = await secretList();
    const report = { providerId, models: null, hasModel: null, image: null };
    try {
      const models = await probeModels({ provider, apiKey, fetchImpl });
      report.models = models.models.slice(0, 200);
      report.hasModel = models.hasModel;
    } catch (error) {
      report.modelsError = redact(error.message, secretValues);
      if (error.kind === "auth") throw new Error(`鉴权失败：${report.modelsError}`);
    }
    if (!realImage) return report;
    let sizeSpec = resolveRequestSize(provider, settings.image.targetSize);
    for (let round = 0; round < 2; round += 1) {
      const startedAt = now();
      try {
        const result = await runAttempt({ provider, apiKey, prompt: PROBE_PROMPT, size: sizeSpec.size, quality: "low", fetchImpl, signal: AbortSignal.timeout((provider.hardTimeoutSec || 240) * 1000) });
        const check = await checkImage(result.bytes);
        const durationMs = now() - startedAt;
        await callLog.append({ providerId: provider.id, providerName: provider.name, model: provider.model, role: "probe", ok: check.ok, kind: check.ok ? "success" : "invalid-image", durationMs, requestSize: sizeSpec.size, width: check.width, height: check.height, errorMessage: check.ok ? undefined : check.reason });
        if (check.ok) await health.reset(provider.id);
        report.image = { ok: check.ok, durationMs, requestSize: sizeSpec.size, width: check.width, height: check.height, reason: check.reason, warnings: check.warnings, png: check.ok ? check.png : undefined };
        return report;
      } catch (error) {
        const message = redact(error.message, secretValues);
        await callLog.append({ providerId: provider.id, providerName: provider.name, model: provider.model, role: "probe", ok: false, kind: error.kind || "unknown", durationMs: now() - startedAt, requestSize: sizeSpec.size, errorMessage: message });
        const fallback = error.kind === "size" && round === 0 ? sizeFallback(error, provider, settings.image.targetSize, sizeSpec.size) : null;
        if (fallback) {
          sizeSpec = fallback.spec;
          await updateProvider(provider.id, fallback.patch);
          report.sizeSwitched = sizeSpec.size;
          continue;
        }
        report.image = { ok: false, requestSize: sizeSpec.size, reason: message, kind: error.kind };
        return report;
      }
    }
    return report;
  }

  function providerStatus(provider) {
    return {
      ...callLog.stats(provider.id),
      unavailable: health.unavailableReason(provider.id),
      health: health.snapshot(provider.id),
    };
  }

  return { generate, resumePending, probe, providerStatus, hedgeThresholdMs };
}
