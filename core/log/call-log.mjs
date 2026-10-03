import path from "node:path";
import { appendJsonLine, readJsonLinesSync, createSerialQueue } from "../util/fsx.mjs";

export function percentile(values, p) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const rank = (p / 100) * (sorted.length - 1);
  const low = Math.floor(rank);
  const high = Math.ceil(rank);
  return sorted[low] + (sorted[high] - sorted[low]) * (rank - low);
}

/**
 * 只追加的调用记录（一行一次调用）。旧 skill 每次运行都会覆盖 summary，
 * 历史耗时就丢了；这里全部保留，统计和补发线都从这里算。
 */
export function createCallLog(dataDir, fileName = "image-calls.jsonl") {
  const file = path.join(dataDir, fileName);
  const serial = createSerialQueue();
  const rows = readJsonLinesSync(file);
  const listeners = new Set();

  return {
    file,
    append(record) {
      const row = { ts: new Date().toISOString(), ...record };
      rows.push(row);
      for (const listener of listeners) listener(row);
      return serial(() => appendJsonLine(file, row));
    },
    onAppend(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    all() {
      return rows;
    },
    query({ limit = 200, providerId, projectDir, sinceTs } = {}) {
      const result = [];
      for (let index = rows.length - 1; index >= 0 && result.length < limit; index -= 1) {
        const row = rows[index];
        if (providerId && row.providerId !== providerId) continue;
        if (projectDir && row.projectDir !== projectDir) continue;
        if (sinceTs && row.ts < sinceTs) continue;
        result.push(row);
      }
      return result;
    },
    /**
     * 某条线路最近 window 次调用的耗时样本（秒），用来算补发线。
     * 除了成功的调用，也计入「补发后被取消」和「超时」的调用（按已等待的时间算，真实耗时只会更长）。
     * 否则慢的请求一旦被补发取消就不再进样本，补发线会越算越低、补发越来越多。
     */
    recentSuccessSeconds(providerId, window = 50) {
      const values = [];
      for (let index = rows.length - 1; index >= 0 && values.length < window; index -= 1) {
        const row = rows[index];
        if (row.providerId !== providerId || !Number.isFinite(row.durationMs) || row.durationMs <= 0) continue;
        const censored = (row.kind === "aborted" && row.outcome === "loser") || row.kind === "timeout";
        if (row.ok || censored) values.push(row.durationMs / 1000);
      }
      return values;
    },
    stats(providerId, window = 50) {
      const recent = [];
      for (let index = rows.length - 1; index >= 0 && recent.length < window; index -= 1) {
        const row = rows[index];
        if (row.providerId === providerId && row.kind !== "aborted") recent.push(row);
      }
      const durations = recent.filter((row) => row.ok).map((row) => row.durationMs / 1000);
      return {
        providerId,
        calls: recent.length,
        successRate: recent.length ? recent.filter((row) => row.ok).length / recent.length : null,
        p50: percentile(durations, 50),
        p85: percentile(durations, 85),
        p90: percentile(durations, 90),
        lastError: recent.find((row) => !row.ok)?.errorMessage || null,
        lastAt: recent[0]?.ts || null,
      };
    },
  };
}
