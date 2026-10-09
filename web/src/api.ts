import type { StudioEvent } from "./types";

declare global {
  interface Window {
    studio?: {
      call: (method: string, ...args: unknown[]) => Promise<unknown>;
      onEvent: (callback: (event: StudioEvent) => void) => () => void;
    };
  }
}

/** 主进程抛出的错误会带上 "Error invoking remote method ..." 前缀，这里去掉只留中文说明。 */
function cleanError(error: unknown): Error {
  const message = error instanceof Error ? error.message : String(error);
  return new Error(message.replace(/^Error invoking remote method '[^']+': (?:Error: )?/, ""));
}

export async function call<T = unknown>(method: string, ...args: unknown[]): Promise<T> {
  if (!window.studio) throw new Error("请在桌面 App 里打开");
  try {
    return (await window.studio.call(method, ...args)) as T;
  } catch (error) {
    throw cleanError(error);
  }
}

export function onEvent(callback: (event: StudioEvent) => void) {
  return window.studio?.onEvent(callback) || (() => {});
}

export function assetUrl(file: string | null | undefined, version?: number | null) {
  if (!file) return "";
  return `asset://local/${encodeURIComponent(file)}${version ? `?v=${Math.round(version)}` : ""}`;
}

export function basename(target: string) {
  return target.split("/").filter(Boolean).pop() || target;
}

export function formatTime(iso?: string | null) {
  if (!iso) return "—";
  const date = new Date(iso);
  return date.toLocaleString("zh-CN", { hour12: false, month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" });
}

export function formatSeconds(value?: number | null) {
  if (value === null || value === undefined || Number.isNaN(value)) return "—";
  return value >= 100 ? `${Math.round(value)} 秒` : `${value.toFixed(1)} 秒`;
}

/** 用时：42秒、4分10秒、1小时2分。 */
export function formatDuration(ms?: number | null) {
  if (ms === null || ms === undefined || Number.isNaN(ms)) return "—";
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}秒`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}分${seconds % 60 ? `${seconds % 60}秒` : ""}`;
  return `${Math.floor(minutes / 60)}小时${minutes % 60 ? `${minutes % 60}分` : ""}`;
}

/** 软件名里的版本号（和后端规则一致），用于新建时提示。 */
export function detectVersion(name: string) {
  const match = String(name || "").match(/(?:V|v)\s?\d+(?:\.\d+)*|\d+(?:\.\d+)+/g);
  return match ? match[match.length - 1] : null;
}
