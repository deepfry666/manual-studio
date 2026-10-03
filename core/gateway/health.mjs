import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "../util/fsx.mjs";

const DEFAULT_QUOTA_COOLDOWN_SEC = 15 * 60;
const CIRCUIT_THRESHOLD = 3;
const CIRCUIT_OPEN_SEC = 5 * 60;

/**
 * 线路健康状态：额度冷却、连续失败熔断、配置错误停用。
 * 写盘保存，软件重启后冷却时间依然有效。
 */
export function createHealthStore(dataDir, now = () => Date.now()) {
  const file = path.join(dataDir, "provider-health.json");
  const serial = createSerialQueue();
  let state = null;

  async function load() {
    if (!state) state = await readJson(file, {});
    return state;
  }
  function entry(id) {
    if (!state[id]) state[id] = { consecutiveFailures: 0, cooldownUntil: 0, circuitOpenUntil: 0, configError: null };
    return state[id];
  }
  const persist = () => serial(() => writeJsonAtomic(file, state));

  return {
    async init() {
      await load();
    },
    snapshot(id) {
      const current = state?.[id] || { consecutiveFailures: 0, cooldownUntil: 0, circuitOpenUntil: 0, configError: null };
      return { ...current };
    },
    /** 返回 null 表示可用，否则返回不可用原因。 */
    unavailableReason(id) {
      const current = state?.[id];
      if (!current) return null;
      const t = now();
      if (current.configError) return `配置错误：${current.configError.message}`;
      if (current.cooldownUntil > t) return `额度冷却中，${new Date(current.cooldownUntil).toLocaleTimeString("zh-CN", { hour12: false })} 恢复`;
      if (current.circuitOpenUntil > t) return `连续失败已熔断，${new Date(current.circuitOpenUntil).toLocaleTimeString("zh-CN", { hour12: false })} 恢复`;
      return null;
    },
    async recordSuccess(id) {
      await load();
      const current = entry(id);
      current.consecutiveFailures = 0;
      current.circuitOpenUntil = 0;
      await persist();
    },
    async recordFailure(id, error) {
      await load();
      const current = entry(id);
      const t = now();
      if (error.kind === "auth" || error.kind === "config") {
        current.configError = { message: String(error.message).slice(0, 200), at: new Date(t).toISOString() };
      } else if (error.kind === "quota") {
        const seconds = Number.isFinite(error.retryAfterSec) && error.retryAfterSec > 0 ? error.retryAfterSec : DEFAULT_QUOTA_COOLDOWN_SEC;
        current.cooldownUntil = t + seconds * 1000;
        current.cooldownReason = String(error.message).slice(0, 200);
      } else if (["server", "network", "timeout", "task-failed", "invalid-image"].includes(error.kind)) {
        current.consecutiveFailures += 1;
        if (current.consecutiveFailures >= CIRCUIT_THRESHOLD) {
          current.circuitOpenUntil = t + CIRCUIT_OPEN_SEC * 1000;
          current.consecutiveFailures = 0;
        }
      }
      await persist();
    },
    /** 测试通过或用户手动恢复后清除所有不可用状态。 */
    async reset(id) {
      await load();
      state[id] = { consecutiveFailures: 0, cooldownUntil: 0, circuitOpenUntil: 0, configError: null };
      await persist();
    },
  };
}
