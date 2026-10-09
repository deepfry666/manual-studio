import { useEffect, useState, type ReactNode } from "react";
import { Segmented, Tooltip } from "antd";
import { InfoCircleOutlined, LeftOutlined } from "@ant-design/icons";

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

export interface PageTabs {
  activeKey: string;
  onChange: (key: string) => void;
  items: { key: string; label: ReactNode; children: ReactNode }[];
  /** 打开过的页签保留在内存里（切回来时没保存的输入不会丢）；false 时只渲染当前页签 */
  keepMounted?: boolean;
}

/**
 * 统一的页面框架，所有页面都是同样的三层：
 * 1. 标题栏（浮动玻璃）：只放标题（详情页多一个返回和状态），所有页面位置、高度完全一样；
 * 2. 页面操作栏：左边是切换 / 搜索，右边是这一页的操作按钮，紧贴在标题栏下面；
 * 3. 内容。
 */
export function Page({ title, back, accessory, tabs, bar, actions, children }: { title: ReactNode; back?: () => void; accessory?: ReactNode; tabs?: PageTabs; bar?: ReactNode; actions?: ReactNode; children?: ReactNode }) {
  return (
    <div className="page">
      <header className="page-header">
        {back && (
          <button type="button" className="page-back" onClick={back} aria-label="返回">
            <LeftOutlined />
          </button>
        )}
        <h2>{title}</h2>
        {accessory && <div className="page-accessory">{accessory}</div>}
      </header>
      {(tabs || bar || actions) && (
        <div className="page-bar">
          <div className="page-bar-left">
            {tabs && <Segmented className="page-tabs" value={tabs.activeKey} onChange={(value) => tabs.onChange(String(value))} options={tabs.items.map((item) => ({ value: item.key, label: item.label }))} />}
            {bar}
          </div>
          {actions && <div className="page-bar-right">{actions}</div>}
        </div>
      )}
      {children}
      {tabs && <TabPanels tabs={tabs} />}
    </div>
  );
}

function TabPanels({ tabs }: { tabs: PageTabs }) {
  const { activeKey, items, keepMounted = true } = tabs;
  const [visited, setVisited] = useState<string[]>([activeKey]);
  useEffect(() => {
    setVisited((list) => (list.includes(activeKey) ? list : [...list, activeKey]));
  }, [activeKey]);
  return (
    <>
      {items.map((item) =>
        item.key === activeKey || (keepMounted && visited.includes(item.key)) ? (
          <div key={item.key} style={{ display: item.key === activeKey ? undefined : "none" }}>
            {item.children}
          </div>
        ) : null
      )}
    </>
  );
}

/** 内容里的二级切换（比如调用记录里的「生图 / 大模型」）：同样的分段控件，放在内容区里。 */
export function InlineTabs(tabs: PageTabs) {
  return (
    <div>
      <Segmented className="inline-tabs" value={tabs.activeKey} onChange={(value) => tabs.onChange(String(value))} options={tabs.items.map((item) => ({ value: item.key, label: item.label }))} />
      <TabPanels tabs={tabs} />
    </div>
  );
}
