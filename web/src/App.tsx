import { Alert, Button, Layout, Menu, Space } from "antd";
import { ApiOutlined, AppstoreOutlined, PlusCircleOutlined, SettingOutlined } from "@ant-design/icons";
import { useEffect } from "react";
import { navigate, useHashRoute, useLoader, useStudioEvents } from "./hooks";
import logoUrl from "./assets/logo.svg";
import { call } from "./api";
import { ProjectsPage } from "./pages/Projects";
import { ProjectDetailPage } from "./pages/project/ProjectDetail";
import { NewProjectPage } from "./pages/NewProject";
import { ModelsPage } from "./pages/Models";
import { SettingsPage } from "./pages/Settings";

const { Sider, Content } = Layout;

const MENU = [
  { key: "new", icon: <PlusCircleOutlined />, label: "新建项目" },
  { key: "projects", icon: <AppstoreOutlined />, label: "历史项目" },
  { key: "models", icon: <ApiOutlined />, label: "模型与线路" },
  { key: "settings", icon: <SettingOutlined />, label: "设置" },
];

/** 旧地址兼容：生图线路 / 大模型 / 调用记录 并进了「模型与线路」，批量队列并进了「历史项目」。 */
const LEGACY_MODEL_TABS: Record<string, string> = { providers: "providers", llm: "llm", calls: "calls" };

interface PendingJob {
  jobId: string;
  screenId: string;
  projectDir: string;
  state: string;
}

/** 玻璃反光跟着鼠标走：把鼠标位置写进 CSS 变量，所有玻璃面共用这个「光源」。 */
function usePointerLight() {
  useEffect(() => {
    let frame = 0;
    const onMove = (event: PointerEvent) => {
      if (frame) return;
      frame = requestAnimationFrame(() => {
        frame = 0;
        document.documentElement.style.setProperty("--mx", `${event.clientX}px`);
        document.documentElement.style.setProperty("--my", `${event.clientY}px`);
      });
    };
    window.addEventListener("pointermove", onMove, { passive: true });
    return () => window.removeEventListener("pointermove", onMove);
  }, []);
}

export function App() {
  usePointerLight();
  const route = useHashRoute();
  const pending = useLoader(() => call<PendingJob[]>("pendingJobs"));
  useStudioEvents((event) => {
    if (event.type === "image" && ["job-failed", "winner", "job-recovered"].includes(String(event.kind))) pending.reload();
  });
  const selected = route.page === "project" || route.page === "batch" ? "projects" : LEGACY_MODEL_TABS[route.page] ? "models" : route.page;
  const unknown = (pending.data || []).filter((job) => job.state === "needs-attention");

  let page;
  switch (route.page) {
    case "project":
      page = <ProjectDetailPage dir={route.param} />;
      break;
    case "new":
      page = <NewProjectPage />;
      break;
    case "models":
      page = <ModelsPage tab={route.param} />;
      break;
    case "providers":
    case "llm":
    case "calls":
      page = <ModelsPage tab={LEGACY_MODEL_TABS[route.page]} />;
      break;
    case "settings":
      page = <SettingsPage tab={route.param} />;
      break;
    default:
      page = <ProjectsPage />;
  }

  return (
    <Layout className="app-shell" style={{ height: "100%" }}>
      <LiquidGlassFilter />
      <Sider width={212} className="app-sider" theme="light">
        {/* 顶部留给红绿灯按钮，可拖动窗口 */}
        <div className="sider-top" />
        <div className="sider-brand">
          <img src={logoUrl} alt="" />
          <div>
            <b>软件指南生成器</b>
            <small>截图 · 文案 · 交付包</small>
          </div>
        </div>
        <Menu mode="inline" selectedKeys={[selected]} items={MENU} onClick={({ key }) => navigate(key)} style={{ borderInlineEnd: "none" }} />
        <div className="sider-footer">v{__APP_VERSION__}</div>
      </Sider>
      <Layout className="app-content">
        <div className="drag-region" />
        <Content style={{ overflow: "auto" }}>
          {unknown.length > 0 && (
            <div style={{ padding: "0 28px" }}>
              <Alert
                type="warning"
                showIcon
                message={`有 ${unknown.length} 个生图任务在提交途中软件退出了，不确定中转站是否已经扣费`}
                description="这些屏会在下次运行时重新生成。如果你在中转站后台确认已出图，可以忽略。"
                action={
                  <Space direction="vertical">
                    <Button size="small" onClick={async () => {
                      for (const job of unknown) await call("dismissJob", job.jobId);
                      pending.reload();
                    }}>
                      知道了
                    </Button>
                  </Space>
                }
              />
            </div>
          )}
          {page}
        </Content>
      </Layout>
    </Layout>
  );
}

/**
 * 液态玻璃的折射：像一块透镜，中间基本不变形，越靠近边缘弯折越厉害（边缘位移图），
 * 再叠一点低频起伏让它有「液体」感。只给浮动工具栏这类控件层用，内容本身不扭曲。
 */
const LENS_MAP = `data:image/svg+xml,${encodeURIComponent(
  `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200" preserveAspectRatio="none">
    <defs>
      <linearGradient id="x" x1="0" x2="1" y1="0" y2="0">
        <stop offset="0" stop-color="#ff0000"/><stop offset="0.16" stop-color="#800000"/>
        <stop offset="0.84" stop-color="#800000"/><stop offset="1" stop-color="#000000"/>
      </linearGradient>
      <linearGradient id="y" x1="0" x2="0" y1="0" y2="1">
        <stop offset="0" stop-color="#00ff00"/><stop offset="0.3" stop-color="#008000"/>
        <stop offset="0.7" stop-color="#008000"/><stop offset="1" stop-color="#000000"/>
      </linearGradient>
    </defs>
    <rect width="200" height="200" fill="url(#x)"/>
    <rect width="200" height="200" fill="url(#y)" style="mix-blend-mode:screen"/>
  </svg>`
)}`;

function LiquidGlassFilter() {
  return (
    <svg width="0" height="0" style={{ position: "absolute" }} aria-hidden="true">
      <filter id="liquid-glass" x="0%" y="0%" width="100%" height="100%" colorInterpolationFilters="sRGB" primitiveUnits="objectBoundingBox">
        <feImage href={LENS_MAP} x="0" y="0" width="1" height="1" preserveAspectRatio="none" result="lens" />
        <feDisplacementMap in="SourceGraphic" in2="lens" scale="0.07" xChannelSelector="R" yChannelSelector="G" />
      </filter>
    </svg>
  );
}
