import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "../util/fsx.mjs";

const KEEP_FINISHED_DAYS = 14;

/**
 * 生图任务账本（思路来自四季画布的 run ledger）：
 * - 异步任务号拿到就落盘，重启后续查，不重复提交；
 * - 启动时还停在「提交中」的尝试标为「提交结果未知（可能已扣费）」，交给用户决定。
 */
export function createLedger(dataDir, now = () => Date.now()) {
  const file = path.join(dataDir, "image-jobs.json");
  const serial = createSerialQueue();
  let data = null;

  async function load() {
    if (!data) data = await readJson(file, { jobs: {} });
    return data;
  }
  const persist = () => serial(() => writeJsonAtomic(file, data));
  const iso = () => new Date(now()).toISOString();

  function findAttempt(jobId, attemptId) {
    return data.jobs[jobId]?.attempts.find((attempt) => attempt.attemptId === attemptId);
  }

  return {
    async init() {
      await load();
      const cutoff = now() - KEEP_FINISHED_DAYS * 86400_000;
      let changed = false;
      for (const [jobId, job] of Object.entries(data.jobs)) {
        if (job.state !== "running" && Date.parse(job.updatedAt) < cutoff) {
          delete data.jobs[jobId];
          changed = true;
          continue;
        }
        for (const attempt of job.attempts) {
          if (attempt.state === "submitting") {
            attempt.state = "unknown";
            attempt.error = "软件在提交途中退出，不确定中转站是否已收到请求（可能已扣费）";
            changed = true;
          }
        }
        if (job.state === "running" && !job.attempts.some((attempt) => attempt.state === "waiting")) {
          job.state = job.attempts.some((attempt) => attempt.state === "unknown") ? "needs-attention" : "interrupted";
          changed = true;
        }
      }
      if (changed) await persist();
    },
    get(jobId) {
      return data?.jobs[jobId] ? structuredClone(data.jobs[jobId]) : null;
    },
    list(filter = () => true) {
      return Object.values(data?.jobs || {}).filter(filter).map((job) => structuredClone(job));
    },
    async createJob(job) {
      await load();
      data.jobs[job.jobId] = { ...job, state: "running", attempts: [], createdAt: iso(), updatedAt: iso() };
      await persist();
    },
    async startAttempt(jobId, attempt) {
      const job = data.jobs[jobId];
      job.attempts.push({ ...attempt, state: "submitting", startedAt: iso() });
      job.updatedAt = iso();
      await persist();
    },
    async markTaskId(jobId, attemptId, taskId) {
      const attempt = findAttempt(jobId, attemptId);
      if (!attempt) return;
      attempt.taskId = taskId;
      attempt.state = "waiting";
      data.jobs[jobId].updatedAt = iso();
      await persist();
    },
    async markSubmitted(jobId, attemptId) {
      const attempt = findAttempt(jobId, attemptId);
      if (!attempt || attempt.state !== "submitting") return;
      attempt.state = "requesting";
    },
    async finishAttempt(jobId, attemptId, result) {
      const attempt = findAttempt(jobId, attemptId);
      if (!attempt) return;
      Object.assign(attempt, result, { endedAt: iso() });
      data.jobs[jobId].updatedAt = iso();
      await persist();
    },
    async finishJob(jobId, result) {
      const job = data.jobs[jobId];
      if (!job) return;
      Object.assign(job, result, { updatedAt: iso() });
      await persist();
    },
    /** 重启后需要续查的远端任务。 */
    remoteWaiting() {
      const result = [];
      for (const job of Object.values(data?.jobs || {})) {
        for (const attempt of job.attempts) {
          if (attempt.state === "waiting" && attempt.taskId) result.push({ job: structuredClone(job), attempt: { ...attempt } });
        }
      }
      return result;
    },
    async dismiss(jobId) {
      const job = data.jobs[jobId];
      if (!job) return;
      job.state = "dismissed";
      job.updatedAt = iso();
      await persist();
    },
  };
}
