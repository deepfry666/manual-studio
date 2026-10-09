import { useEffect, useState, type ReactNode } from "react";
import { Segmented, Tooltip } from "antd";
import { InfoCircleOutlined } from "@ant-design/icons";

/**
 * macOS「系统设置」样式的基础组件：分组框 + 一行一项（左边标签、右边控件），
 * 长说明收进 ⓘ 提示，不在界面上铺大段文字。
 */
export function Section({ title, extra, children, footer }: { title?: ReactNode; extra?: ReactNode; children: ReactNode; footer?: ReactNode }) {
  return (
    <div className="mac-section">
      {(title || extra) && (
        <div className="mac-section-head">
          <span>{title}</span>
          {extra}
        </div>
      )}
      <div className="mac-group">{children}</div>
      {footer && <div className="mac-section-foot">{footer}</div>}
    </div>
  );
}

export function Row({ label, hint, info, children, vertical }: { label: ReactNode; hint?: ReactNode; info?: ReactNode; children?: ReactNode; vertical?: boolean }) {
  return (
    <div className={`mac-row${vertical ? " mac-row-vertical" : ""}`}>
      <div className="mac-row-label">
        <span>
          {label}
          {info && <Info text={info} />}
        </span>
        {hint && <small>{hint}</small>}
      </div>
      {children !== undefined && <div className="mac-row-control">{children}</div>}
    </div>
  );
}

export function Info({ text }: { text: ReactNode }) {
  return (
    <Tooltip title={text} placement="top" styles={{ root: { maxWidth: 360 } }}>
      <InfoCircleOutlined className="mac-info" />
    </Tooltip>
  );
}

/** 路径：家目录写成 ~，太长时中间省略，悬停看完整路径。 */
export function PathText({ path, empty = "未设置" }: { path?: string | null; empty?: string }) {
  if (!path) return <span className="muted">{empty}</span>;
  const short = path.replace(/^\/Users\/[^/]+/, "~");
  const parts = short.split("/");
  const name = parts.pop() || short;
  const head = parts.join("/");
  return (
    <Tooltip title={path}>
      <span className="mac-path">
        {head && <span className="mac-path-head">{head}/</span>}
        <span className="mac-path-name">{name}</span>
      </span>
    </Tooltip>
  );
}

export function Status({ tone, children }: { tone: "ok" | "warn" | "error" | "idle"; children: ReactNode }) {
  return (
    <span className="mac-status">
      <i className={`mac-dot mac-dot-${tone}`} />
      {children}
    </span>
  );
}

/**
 * 标签页：用真正的分段控件做切换（左右内边距一致、滑块平滑移动），
 * 打开过的页签保留在内存里，切回来时输入不会丢。
 */
export function GlassTabs({ activeKey, onChange, items, keepMounted = true }: { activeKey: string; onChange: (key: string) => void; items: { key: string; label: ReactNode; children: ReactNode }[]; keepMounted?: boolean }) {
  const [visited, setVisited] = useState<string[]>([activeKey]);
  useEffect(() => {
    setVisited((list) => (list.includes(activeKey) ? list : [...list, activeKey]));
  }, [activeKey]);
  return (
    <div className="glass-tabs">
      <Segmented className="glass-tabs-switch" value={activeKey} onChange={(value) => onChange(String(value))} options={items.map((item) => ({ value: item.key, label: item.label }))} />
      {items.map((item) =>
        item.key === activeKey || (keepMounted && visited.includes(item.key)) ? (
          <div key={item.key} style={{ display: item.key === activeKey ? undefined : "none" }}>
            {item.children}
          </div>
        ) : null
      )}
    </div>
  );
}
