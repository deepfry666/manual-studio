import { Alert, Button, Layout, Menu, Space } from "antd";
import { AppstoreOutlined, HistoryOutlined, PictureOutlined, RobotOutlined, SettingOutlined, UnorderedListOutlined } from "@ant-design/icons";
import { navigate, useHashRoute, useLoader, useStudioEvents } from "./hooks";
import { call } from "./api";
import { ProjectsPage } from "./pages/Projects";
import { ProjectDetailPage } from "./pages/project/ProjectDetail";
import { BatchPage } from "./pages/Batch";
import { ProvidersPage } from "./pages/Providers";
import { LlmPage } from "./pages/Llm";
import { CallsPage } from "./pages/Calls";
import { SettingsPage } from "./pages/Settings";

const { Sider, Content } = Layout;

const MENU = [
  { key: "projects", icon: <AppstoreOutlined />, label: "项目" },
  { key: "batch", icon: <UnorderedListOutlined />, label: "批量队列" },
  { key: "providers", icon: <PictureOutlined />, label: "生图线路" },
  { key: "llm", icon: <RobotOutlined />, label: "大模型" },
  { key: "calls", icon: <HistoryOutlined />, label: "调用记录" },
  { key: "settings", icon: <SettingOutlined />, label: "设置" },
];

interface PendingJob {
  jobId: string;
  screenId: string;
  projectDir: string;
  state: string;
}

export function App() {
  const route = useHashRoute();
  const pending = useLoader(() => call<PendingJob[]>("pendingJobs"));
  useStudioEvents((event) => {
    if (event.type === "image" && ["job-failed", "winner", "job-recovered"].includes(String(event.kind))) pending.reload();
  });
  const selected = route.page === "project" ? "projects" : route.page;
  const unknown = (pending.data || []).filter((job) => job.state === "needs-attention");

  let page;
  switch (route.page) {
    case "project":
      page = <ProjectDetailPage dir={route.param} />;
      break;
    case "batch":
      page = <BatchPage />;
      break;
    case "providers":
      page = <ProvidersPage />;
      break;
    case "llm":
      page = <LlmPage />;
      break;
    case "calls":
      page = <CallsPage />;
      break;
    case "settings":
      page = <SettingsPage />;
      break;
    default:
      page = <ProjectsPage />;
  }

  return (
    <Layout style={{ height: "100%" }}>
      <Sider width={208} className="app-sider" theme="light" style={{ borderRight: "1px solid #eceef2" }}>
        <div className="drag-region" />
        <div className="brand">
          软件指南生成器
          <small>截图 · 文案 · 交付包</small>
        </div>
        <Menu mode="inline" selectedKeys={[selected]} items={MENU} onClick={({ key }) => navigate(key)} style={{ borderInlineEnd: "none", padding: "0 8px" }} />
      </Sider>
      <Layout>
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
