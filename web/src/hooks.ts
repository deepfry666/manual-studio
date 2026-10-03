import { useCallback, useEffect, useRef, useState } from "react";
import { call, onEvent } from "./api";
import type { SettingsBundle, StudioEvent } from "./types";

export function useHashRoute() {
  const read = () => {
    const raw = decodeURIComponent(window.location.hash.replace(/^#\/?/, ""));
    const [page = "projects", ...rest] = raw.split("/");
    return { page: page || "projects", param: rest.join("/") };
  };
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const handler = () => setRoute(read());
    window.addEventListener("hashchange", handler);
    return () => window.removeEventListener("hashchange", handler);
  }, []);
  return route;
}

export function navigate(page: string, param?: string) {
  window.location.hash = `#/${page}${param ? `/${encodeURIComponent(param)}` : ""}`;
}

export function useStudioEvents(handler: (event: StudioEvent) => void) {
  const ref = useRef(handler);
  ref.current = handler;
  useEffect(() => onEvent((event) => ref.current(event)), []);
}

/** 读取一次数据并提供 reload；loading 只在第一次加载时为 true。 */
export function useLoader<T>(loader: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const loaderRef = useRef(loader);
  loaderRef.current = loader;
  const reload = useCallback(async () => {
    try {
      const value = await loaderRef.current();
      setData(value);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    setLoading(true);
    reload();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return { data, setData, error, loading, reload };
}

/** 事件很密时合并刷新。 */
export function useDebounced(fn: () => void, ms = 300) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const fnRef = useRef(fn);
  fnRef.current = fn;
  return useCallback(() => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => fnRef.current(), ms);
  }, [ms]);
}

export function useSettings() {
  return useLoader(() => call<SettingsBundle>("getSettings"));
}

export const STEP_ORDER = ["plan", "prompts", "images", "gate", "content", "design", "receipt", "build"] as const;

export const STEP_LABELS: Record<string, string> = {
  plan: "规划界面",
  prompts: "提示词",
  images: "生成截图",
  gate: "截图验收",
  content: "撰写文案",
  design: "设计说明",
  receipt: "审查回执",
  build: "交付包",
};

export const PROJECT_STATUS: Record<string, { label: string; color: string }> = {
  idle: { label: "未完成", color: "default" },
  running: { label: "运行中", color: "processing" },
  done: { label: "已完成", color: "success" },
  waiting: { label: "等待确认", color: "warning" },
  "needs-attention": { label: "需要处理", color: "error" },
  canceled: { label: "已停止", color: "default" },
  missing: { label: "文件夹不见了", color: "error" },
};

export const GRADE_LABEL: Record<string, { label: string; color: string }> = {
  ready: { label: "可直接编辑", color: "green" },
  "needs-gate": { label: "待重新验收", color: "orange" },
  readonly: { label: "只读", color: "default" },
};
