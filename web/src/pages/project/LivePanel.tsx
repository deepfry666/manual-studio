import { useEffect, useState } from "react";
import { Card, Progress, Space, Tag, Typography } from "antd";
import { call, formatDuration } from "../../api";
import { STEP_LABELS, STEP_ORDER, useLoader } from "../../hooks";
import type { LiveProgress, LiveScreen, ProjectDetail } from "../../types";

const SCREEN_STATUS: Record<LiveScreen["status"], { label: string; color: string }> = {
  waiting: { label: "排队", color: "default" },
  kept: { label: "沿用", color: "default" },
  generating: { label: "生成中", color: "processing" },
  regenerating: { label: "重新生成", color: "warning" },
  generated: { label: "已出图", color: "success" },
  failed: { label: "失败", color: "error" },
  "waiting-check": { label: "待验收", color: "default" },
  checking: { label: "验收中", color: "processing" },
  passed: { label: "验收通过", color: "success" },
};

function useTick(active: boolean) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [active]);
  return now;
}

/** 运行中的实时进度：当前步骤、已用时、预计剩余、每张截图的状态。 */
export function LivePanel({ live, data }: { live: LiveProgress; data: ProjectDetail }) {
  const now = useTick(true);
  const estimates = useLoader(() => call<Record<string, number>>("stepEstimates"));
  const planned = live.plannedSteps.length ? live.plannedSteps : [...STEP_ORDER];
  const remainingSteps = planned.filter((step) => !live.doneSteps.includes(step) && step !== live.step);
  const est = estimates.data || {};
  const currentEst = live.step ? est[live.step] : undefined;
  const currentElapsed = live.stepStarted ? now - live.stepStarted : 0;
  // 只对「上次实际跑过」的步骤做估算；没有历史数据时不显示，免得乱报
  const hasEstimate = Boolean(live.step && currentEst) && remainingSteps.every((step) => est[step] !== undefined || ["design", "receipt", "prompts"].includes(step));
  const remainingMs = hasEstimate ? Math.max(0, (currentEst || 0) - currentElapsed) + remainingSteps.reduce((sum, step) => sum + (est[step] || 0), 0) : null;
  const index = live.step ? planned.indexOf(live.step) : 0;
  const screens = Object.entries(live.screens).filter(([, screen]) => screen.status !== "kept");
  const finished = screens.filter(([, screen]) => ["generated", "passed"].includes(screen.status)).length;
  const inside = screens.length && live.step && ["images", "gate"].includes(live.step) ? finished / screens.length : 0.3;
  const percent = Math.max(2, Math.min(99, Math.round(((Math.max(0, index) + inside) / Math.max(1, planned.length)) * 100)));
  const titles = new Map((data.plan?.screens || []).map((screen, order) => [screen.id, `图${order + 1} ${screen.title}`]));

  return (
    <Card size="small" style={{ marginBottom: 16 }} title={<Space>正在运行{live.reason && <Tag color="blue">{live.reason}</Tag>}</Space>}>
      <Space direction="vertical" style={{ width: "100%" }} size={8}>
        <Progress percent={percent} status="active" />
        <Space size="large" wrap>
          <span>
            当前：<b>{live.step ? STEP_LABELS[live.step] : "准备中"}</b>
            {live.detail ? `（${live.detail}）` : ""}
            {live.step && ["images", "gate"].includes(live.step) && screens.length ? `  ${finished}/${screens.length} 张` : ""}
          </span>
          <span className="muted">本步 {formatDuration(currentElapsed)}</span>
          <span>已用时 <b className="stat-number">{formatDuration(now - live.started)}</b></span>
          {remainingMs !== null && <span className="muted">预计还要约 {formatDuration(Math.max(remainingMs, 5000))}（按以往用时估算）</span>}
        </Space>
        {screens.length > 0 && (
          <div className="live-screens">
            {screens.map(([id, screen]) => {
              const status = SCREEN_STATUS[screen.status] || { label: screen.status, color: "default" };
              const elapsed = screen.startedAt ? (screen.finishedAt || now) - screen.startedAt : null;
              return (
                <div key={id} className="live-screen">
                  <div>
                    <b>{titles.get(id) || id}</b>
                  </div>
                  <Space size={4} wrap>
                    <Tag color={status.color} style={{ marginInlineEnd: 0 }}>{status.label}</Tag>
                    {elapsed !== null && ["generating", "regenerating", "generated"].includes(screen.status) && <span className="muted">{formatDuration(elapsed)}</span>}
                  </Space>
                  {(screen.provider || screen.hedged) && (
                    <Typography.Text className="muted" style={{ fontSize: 11, display: "block" }}>
                      {screen.provider}
                      {screen.hedged ? " · 补发过" : ""}
                    </Typography.Text>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </Space>
    </Card>
  );
}
