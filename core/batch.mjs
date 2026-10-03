import path from "node:path";
import crypto from "node:crypto";
import { readJson, writeJsonAtomic, createSerialQueue } from "./util/fsx.mjs";

/**
 * 批量队列：按设置的项目并发数依次跑完整流程；软件重启后，之前「运行中」的项目回到队列续跑。
 */
export function createBatchQueue({ dataDir, settingsStore, pipeline, emit = () => {} }) {
  const file = path.join(dataDir, "batch-queue.json");
  const serial = createSerialQueue();
  let data = null;
  let paused = false;
  const active = new Map();

  async function load() {
    if (!data) {
      data = await readJson(file, { items: [], paused: false });
      paused = Boolean(data.paused);
      for (const item of data.items) if (item.status === "running") item.status = "queued";
    }
    return data;
  }
  const persist = () => serial(() => writeJsonAtomic(file, { ...data, paused }));
  const notify = () => emit({ type: "batch", items: structuredClone(data.items), paused });

  async function pump() {
    await load();
    if (paused) return;
    const settings = await settingsStore.get();
    const limit = Math.max(1, settings.pipeline.batchConcurrency || 2);
    while (active.size < limit) {
      const item = data.items.find((candidate) => candidate.status === "queued");
      if (!item) break;
      item.status = "running";
      item.startedAt = new Date().toISOString();
      item.error = null;
      await persist();
      notify();
      const promise = pipeline
        .run(item.projectDir, { reviewPlan: false, batchId: item.batchId })
        .then((result) => {
          item.status = result.status === "done" ? "done" : result.status === "waiting" ? "needs-attention" : result.status === "canceled" ? "paused" : "failed";
          item.error = result.error || (result.status === "waiting" ? `等待确认：${result.step}` : null);
        })
        .catch((error) => {
          item.status = "failed";
          item.error = error.message;
        })
        .finally(async () => {
          item.finishedAt = new Date().toISOString();
          active.delete(item.id);
          await persist();
          notify();
          pump();
        });
      active.set(item.id, promise);
    }
  }

  return {
    async init() {
      await load();
      await persist();
      pump();
    },
    async list() {
      await load();
      return { items: structuredClone(data.items), paused };
    },
    async enqueue(projectDirs, { name } = {}) {
      await load();
      const batchId = `batch-${crypto.randomBytes(4).toString("hex")}`;
      for (const projectDir of projectDirs) {
        if (data.items.some((item) => item.projectDir === projectDir && ["queued", "running"].includes(item.status))) continue;
        data.items.push({ id: crypto.randomBytes(6).toString("hex"), projectDir, batchId, batchName: name || "", status: "queued", addedAt: new Date().toISOString() });
      }
      await persist();
      notify();
      pump();
      return batchId;
    },
    async pause() {
      await load();
      paused = true;
      for (const item of data.items) if (item.status === "running") pipeline.cancel(item.projectDir);
      await persist();
      notify();
    },
    async resume() {
      await load();
      paused = false;
      for (const item of data.items) if (item.status === "paused") item.status = "queued";
      await persist();
      notify();
      pump();
    },
    async retry(itemId) {
      await load();
      const item = data.items.find((candidate) => candidate.id === itemId);
      if (item && !["running", "queued"].includes(item.status)) item.status = "queued";
      await persist();
      notify();
      pump();
    },
    async remove(itemId) {
      await load();
      const item = data.items.find((candidate) => candidate.id === itemId);
      if (item?.status === "running") pipeline.cancel(item.projectDir);
      data.items = data.items.filter((candidate) => candidate.id !== itemId);
      await persist();
      notify();
    },
    async clearFinished() {
      await load();
      data.items = data.items.filter((item) => !["done"].includes(item.status));
      await persist();
      notify();
    },
  };
}

/** 解析批量 CSV：软件名,截图数,功能侧重,代码来源,版本处理（第一行是表头时自动跳过）。 */
export function parseBatchCsv(text) {
  const rows = [];
  const lines = String(text || "").replace(/^﻿/, "").split(/\r?\n/).filter((line) => line.trim());
  for (const [index, line] of lines.entries()) {
    const cells = [];
    let current = "";
    let quoted = false;
    for (let i = 0; i < line.length; i += 1) {
      const char = line[i];
      if (char === '"') {
        if (quoted && line[i + 1] === '"') {
          current += '"';
          i += 1;
        } else quoted = !quoted;
      } else if ((char === "," || char === "，" || char === "\t") && !quoted) {
        cells.push(current.trim());
        current = "";
      } else current += char;
    }
    cells.push(current.trim());
    if (index === 0 && /软件名|名称|name/i.test(cells[0])) continue;
    if (!cells[0]) continue;
    const count = Number.parseInt(cells[1], 10);
    rows.push({
      softwareName: cells[0],
      screenCount: Number.isFinite(count) && count > 0 ? count : null,
      emphasis: cells[2] || "",
      codeSourcePath: cells[3] || "",
      versionPolicy: ["none", "in-name", "separate-metadata"].includes(cells[4]) ? cells[4] : "in-name",
    });
  }
  return rows;
}
