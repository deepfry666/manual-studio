import { useEffect, useState } from "react";
import { Alert, App, Breadcrumb, Button, Dropdown, Input, Modal, Space, Spin, Steps, Tabs, Tag, Tooltip, Typography } from "antd";
import { CaretRightOutlined, EditOutlined, EllipsisOutlined, FolderOpenOutlined, PauseOutlined } from "@ant-design/icons";
import { call, formatDuration } from "../../api";
import { PROJECT_STATUS, STEP_LABELS, STEP_ORDER, navigate, useDebounced, useLoader, useStudioEvents } from "../../hooks";
import type { LiveProgress, ProjectDetail, StepStatus } from "../../types";
import { OverviewTab } from "./OverviewTab";
import { PlanTab } from "./PlanTab";
import { ScreensTab } from "./ScreensTab";
import { ContentTab } from "./ContentTab";
import { DeliveryTab } from "./DeliveryTab";
import { LivePanel } from "./LivePanel";
import { FeedbackPanel } from "./FeedbackPanel";

const STEP_STATUS: Record<StepStatus, "wait" | "process" | "finish" | "error"> = {
  pending: "wait",
  running: "process",
  done: "finish",
  skipped: "finish",
  failed: "error",
  review: "process",
};

export function ProjectDetailPage({ dir }: { dir: string }) {
  const { message, modal } = App.useApp();
  const project = useLoader(() => call<ProjectDetail>("getProject", dir), [dir]);
  const reload = useDebounced(project.reload, 250);
  const [activity, setActivity] = useState<string[]>([]);
  const [tab, setTab] = useState<string | null>(null);
  const [live, setLive] = useState<LiveProgress | null>(null);
  useEffect(() => {
    setLive(project.data?.progress || null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project.data?.dir, project.data?.running]);
  useStudioEvents((event) => {
    if (event.projectDir !== dir) return;
    if (event.type === "progress") {
      // 进度事件很密，只更新进度面板，不整页刷新
      setLive((event.progress as LiveProgress) || null);
      if (!event.progress) reload();
      return;
    }
    reload();
    if (event.type === "image") {
      const kind = String(event.kind);
      const labels: Record<string, string> = {
        "attempt-start": `${event.screenId} 开始生成（${event.providerName}${event.role === "hedge" ? "，补发" : event.role === "failover" ? "，切换线路" : event.role === "retry" ? "，重试" : ""}）`,
        hedge: `${event.screenId} 超过补发线，补发到 ${event.providerName}`,
        winner: `${event.screenId} 出图：${event.providerName}，${Math.round(Number(event.durationMs) / 1000)} 秒`,
        "attempt-failed": `${event.screenId} ${event.providerName} 失败：${event.message}`,
        alternate: `${event.screenId} 收到一张备选图（${event.providerName}）`,
        "size-switched": `${event.screenId} 线路不收像素尺寸，已改用 ${event.ratio}`,
      };
      if (labels[kind]) setActivity((list) => [`${new Date().toLocaleTimeString("zh-CN", { hour12: false })}  ${labels[kind]}`, ...list].slice(0, 60));
    }
  });

  if (project.loading && !project.data) return <Spin style={{ margin: 80 }} />;
  if (project.error || !project.data) {
    return (
      <div className="page">
        <Alert type="error" message={project.error || "项目不存在"} action={<Button onClick={() => navigate("projects")}>返回列表</Button>} />
      </div>
    );
  }
  const data = project.data;
  const { state } = data;
  const activeTab = tab || (data.screens.some((screen) => screen.file) ? "screens" : "overview");
  const running = data.running || state.status === "running";
  const readOnly = Boolean(state.readOnly);
  const status = PROJECT_STATUS[running ? "running" : readOnly ? "readonly" : state.status] || { label: state.status, color: "default" };
  const waitingStep = STEP_ORDER.find((step) => state.steps[step]?.status === "review");

  const run = async (options: Record<string, unknown> = {}) => {
    try {
      await call("run", dir, options);
    } catch (error) {
      message.error((error as Error).message);
    }
  };

  return (
    <div className="page">
      <Breadcrumb style={{ marginBottom: 8 }} items={[{ title: <a onClick={() => navigate("projects")}>历史项目</a> }, { title: state.request.softwareName }]} />
      <div className="page-header">
        <Space align="center" size="middle">
          <h2>{state.request.softwareName}</h2>
          <Tag color={status.color}>{status.label}</Tag>
          {state.origin === "imported" && <Tag>历史项目</Tag>}
          {state.timing?.completedMs ? (
            <Tooltip title={`累计 ${formatDuration(state.timing.totalMs)}（含之后的修改和更新），共运行 ${state.timing.runs.length} 次`}>
              <Tag color="green">完成用时 {formatDuration(state.timing.completedMs)}</Tag>
            </Tooltip>
          ) : state.timing?.totalMs ? (
            <Tag>已用时 {formatDuration(state.timing.totalMs)}</Tag>
          ) : null}
          {!readOnly && <RenameButton dir={dir} name={state.request.softwareName} disabled={running} />}
        </Space>
        <Space>
          <Tooltip title="在访达中打开">
            <Button icon={<FolderOpenOutlined />} onClick={() => call("openPath", dir)} />
          </Tooltip>
          <Dropdown
            trigger={["click"]}
            menu={{
              items: [{ key: "remove", label: "从列表移除…", disabled: running }],
              onClick: () =>
                modal.confirm({
                  title: "从列表移除这个项目？",
                  content: "只是不在软件里显示，项目文件夹不会删除。",
                  okText: "移除",
                  onOk: async () => {
                    await call("removeFromList", dir);
                    navigate("projects");
                  },
                }),
            }}
          >
            <Button icon={<EllipsisOutlined />} />
          </Dropdown>
          {running ? (
            <Button danger icon={<PauseOutlined />} onClick={() => call("cancel", dir)}>
              停止
            </Button>
          ) : (
            !readOnly && (
              <Button type="primary" icon={<CaretRightOutlined />} onClick={() => run()}>
                {state.status === "done" ? "检查并更新" : "继续运行"}
              </Button>
            )
          )}
        </Space>
      </div>

      {readOnly && <Alert style={{ marginBottom: 12 }} type="info" showIcon message="这个历史项目只有交付包，没有文案和截图源文件，只能查看。" />}
      {state.lastError && !running && <Alert style={{ marginBottom: 12 }} type="error" showIcon message="需要处理" description={<div style={{ whiteSpace: "pre-wrap" }}>{state.lastError}</div>} />}
      {waitingStep && !running && (
        <Alert
          style={{ marginBottom: 12 }}
          type="warning"
          showIcon
          message={waitingStep === "plan" ? "界面规划已生成，请在「规划」里检查，确认后继续生图" : state.steps[waitingStep]?.message || `「${STEP_LABELS[waitingStep]}」等待确认`}
          action={
            waitingStep === "plan" ? (
              <Button type="primary" onClick={() => call("action", "confirmPlan", dir)}>
                确认规划，继续
              </Button>
            ) : (
              <Button onClick={() => setTab("screens")}>去确认截图</Button>
            )
          }
        />
      )}

      {live && <LivePanel live={live} data={data} />}
      {!readOnly && <FeedbackPanel data={data} running={running} onChanged={project.reload} />}

      <Steps
        size="small"
        style={{ margin: "8px 0 20px" }}
        items={STEP_ORDER.map((step) => {
          const stepState = state.steps[step] || { status: "pending" };
          return {
            title: STEP_LABELS[step],
            status: STEP_STATUS[stepState.status] || "wait",
            description: stepState.status === "skipped" ? "不需要" : stepState.status === "review" ? "待确认" : undefined,
          };
        })}
      />

      <Tabs
        activeKey={activeTab}
        onChange={setTab}
        items={[
          { key: "overview", label: "概览", children: <OverviewTab data={data} activity={activity} running={running} onChanged={project.reload} /> },
          { key: "plan", label: "规划", children: <PlanTab data={data} running={running} onChanged={project.reload} /> },
          { key: "screens", label: `截图${data.screens.length ? ` (${data.screens.length})` : ""}`, children: <ScreensTab data={data} running={running} onChanged={project.reload} /> },
          { key: "content", label: "文案", children: <ContentTab data={data} running={running} onChanged={project.reload} /> },
          { key: "delivery", label: "交付", children: <DeliveryTab data={data} running={running} onChanged={project.reload} /> },
        ]}
      />
    </div>
  );
}

function RenameButton({ dir, name, disabled }: { dir: string; name: string; disabled: boolean }) {
  const { message } = App.useApp();
  const [open, setOpen] = useState(false);
  const [value, setValue] = useState(name);
  const [busy, setBusy] = useState(false);
  return (
    <>
      <Tooltip title="改软件名（含版本号）">
        <Button type="text" size="small" icon={<EditOutlined />} disabled={disabled} onClick={() => setOpen(true)} />
      </Tooltip>
      <Modal
        title="改软件名"
        open={open}
        confirmLoading={busy}
        onCancel={() => setOpen(false)}
        onOk={async () => {
          setBusy(true);
          try {
            const newDir = await call<string>("renameSoftware", dir, value.trim());
            setOpen(false);
            message.success("已改名。截图会按新名字重新验收，然后重建交付包。");
            navigate("project", newDir);
            call("run", newDir);
          } catch (error) {
            message.error((error as Error).message);
          } finally {
            setBusy(false);
          }
        }}
      >
        <Typography.Paragraph className="muted">不会重新规划和生图；会用新名字重新验收截图，再重建交付包。</Typography.Paragraph>
        <Input value={value} onChange={(event) => setValue(event.target.value)} />
      </Modal>
    </>
  );
}
