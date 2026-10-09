import { Alert, Button, Layout, Menu, Space } from "antd";
import { ApiOutlined, AppstoreOutlined, PlusCircleOutlined, SettingOutlined } from "@ant-design/icons";
import { navigate, useHashRoute, useLoader, useStudioEvents } from "./hooks";
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

export function App() {
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
      <Sider width={212} className="app-sider" theme="light">
        {/* 顶部留给红绿灯按钮，可拖动窗口 */}
        <div className="sider-top" />
        <Menu mode="inline" selectedKeys={[selected]} items={MENU} onClick={({ key }) => navigate(key)} style={{ borderInlineEnd: "none" }} />
        <div className="sider-footer">软件指南生成器</div>
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
