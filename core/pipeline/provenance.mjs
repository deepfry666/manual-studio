import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "../util/fsx.mjs";

export const RECORD_FILE = "generation-record.json";
const MAX_HISTORY = 500;
const queues = new Map();

function queueFor(dir) {
  let queue = queues.get(dir);
  if (!queue) {
    queue = createSerialQueue();
    queues.set(dir, queue);
  }
  return queue;
}

export function recordPath(projectDir) {
  return path.join(projectDir, RECORD_FILE);
}

/**
 * 项目文件夹里的生成记录（溯源用）：每张截图由哪条线路、哪个模型、什么时候生成，
 * 验收用了什么方式，各步骤用了哪个大模型，以及按时间顺序的事件。
 * 只在本软件真的生成或修改了东西时才写，导入历史项目不会写。
 */
export function updateRecord(projectDir, mutate) {
  return queueFor(projectDir)(async () => {
    const file = recordPath(projectDir);
    const record = await readJson(file, null).catch(() => null) || { generatedBy: "软件指南生成器", screens: {}, gate: {}, llm: {}, history: [] };
    record.screens ||= {};
    record.gate ||= {};
    record.llm ||= {};
    record.history ||= [];
    mutate(record);
    if (record.history.length > MAX_HISTORY) record.history.splice(0, record.history.length - MAX_HISTORY);
    record.updatedAt = new Date().toISOString();
    await writeJsonAtomic(file, record);
    return record;
  });
}

export async function readRecord(projectDir) {
  return readJson(recordPath(projectDir), null).catch(() => null);
}
