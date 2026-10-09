import { useEffect, useState } from "react";
import { App, Col, Empty, Input, InputNumber, Row as GridRow, Segmented, Select, Switch, Table } from "antd";
import { call, detectVersion, formatDuration, formatTime } from "../../api";
import { STEP_LABELS, STEP_ORDER } from "../../hooks";
import { Row, Section } from "../../ui";
import type { ProjectDetail } from "../../types";

const PLATFORMS = [
  { value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" },
  { value: "Android 手机（原生 Android 界面）", label: "Android 手机" },
];

/** 项目设置：改了就保存，下次运行只重做受影响的步骤。 */
export function OverviewTab({ data, running, onChanged }: { data: ProjectDetail; activity: string[]; running: boolean; onChanged: () => void }) {
  const { message } = App.useApp();
  const request = data.state.request;
  const [emphasis, setEmphasis] = useState(request.emphasis || "");
  const [notes, setNotes] = useState(request.notes || "");
  const [compileDate, setCompileDate] = useState(request.compileDate || "");
  useEffect(() => {
    setEmphasis(request.emphasis || "");
    setNotes(request.notes || "");
    setCompileDate(request.compileDate || "");
  }, [request.emphasis, request.notes, request.compileDate]);

  const update = async (patch: Record<string, unknown>) => {
    try {
      await call("action", "updateRequest", data.dir, patch);
      onChanged();
    } catch (error) {
      message.error((error as Error).message);
    }
  };
  const disabled = running || Boolean(data.state.readOnly);
  const version = detectVersion(request.softwareName);

  return (
    <GridRow gutter={20}>
      <Col span={13}>
        <Section title="项目设置" footer="改截图数、重点功能或平台，下次运行会重新规划并重新生图。">
          <Row label="截图数">
            <Segmented
              disabled={disabled}
              value={request.screenCount ? "fixed" : "auto"}
              onChange={(value) => update({ screenCount: value === "auto" ? null : request.screenCount || 7 })}
              options={[
                { value: "auto", label: "按功能决定" },
                { value: "fixed", label: "指定" },
              ]}
            />
            {request.screenCount ? <InputNumber disabled={disabled} min={2} max={15} value={request.screenCount} onChange={(value) => value && update({ screenCount: value })} addonAfter="屏" style={{ width: 100 }} /> : null}
          </Row>
          <Row label="重点功能">
            <Input disabled={disabled} value={emphasis} onChange={(event) => setEmphasis(event.target.value)} onBlur={() => emphasis !== (request.emphasis || "") && update({ emphasis })} style={{ width: 300 }} />
          </Row>
          <Row label="补充说明">
            <Input.TextArea disabled={disabled} value={notes} autoSize={{ minRows: 1, maxRows: 5 }} onChange={(event) => setNotes(event.target.value)} onBlur={() => notes !== (request.notes || "") && update({ notes })} style={{ width: 300 }} />
          </Row>
          <Row label="平台">
            <Select disabled={disabled} allowClear placeholder="用设置里的默认平台" value={request.platform || undefined} options={PLATFORMS} onChange={(value) => update({ platform: value || "" })} style={{ width: 260 }} />
          </Row>
        </Section>
        <Section>
          <Row label="设计说明章节">
            <Switch disabled={disabled} checked={Boolean(request.wantDesign)} onChange={(value) => update({ wantDesign: value })} />
          </Row>
          <Row label="额外禁词" info={`截图里也不能出现的词。默认已禁止：完整软件名、去掉版本号的名字${version ? `、版本号 ${version}` : ""}。`}>
            <Select disabled={disabled} mode="tags" value={request.extraBrandTokens || []} onChange={(value: string[]) => update({ extraBrandTokens: value })} placeholder="输入后回车" style={{ width: 300 }} />
          </Row>
          <Row label="编制时间" hint="留空用生成当天">
            <Input disabled={disabled} value={compileDate} placeholder="例如 2026年10月3日" onChange={(event) => setCompileDate(event.target.value)} onBlur={() => compileDate !== (request.compileDate || "") && update({ compileDate })} style={{ width: 200 }} />
          </Row>
        </Section>
        <TimingCard data={data} />
        {data.state.warnings.length > 0 && (
          <Section title="提醒">
            {data.state.warnings.map((warning) => (
              <Row key={warning} label={<span style={{ fontWeight: 400 }}>{warning}</span>} />
            ))}
          </Section>
        )}
      </Col>
      <Col span={11}>
        <Section title="日志">
          {data.state.log.length ? (
            <div className="log-list" style={{ padding: "10px 16px", maxHeight: 560 }}>
              {[...data.state.log].reverse().map((entry, index) => (
                <div key={index} className={entry.level}>
                  <span className="muted">{formatTime(entry.at)}</span> {entry.message}
                </div>
              ))}
            </div>
          ) : (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有日志" style={{ padding: 16 }} />
          )}
        </Section>
      </Col>
    </GridRow>
  );
}

/** 用时：完成用时、累计用时、每次运行和各步骤用时。 */
function TimingCard({ data }: { data: ProjectDetail }) {
  const timing = data.state.timing;
  if (!timing?.runs?.length) return null;
  const runs = [...timing.runs].reverse();
  return (
    <Section
      title="用时"
      extra={
        <span style={{ fontWeight: 400 }}>
          {timing.completedMs ? <>完成 <b>{formatDuration(timing.completedMs)}</b> · </> : null}累计 {formatDuration(timing.totalMs)}
        </span>
      }
    >
      <Table
        size="small"
        rowKey="startedAt"
        pagination={{ pageSize: 5, size: "small", hideOnSinglePage: true }}
        dataSource={runs}
        columns={[
          { title: "开始", dataIndex: "startedAt", width: 110, render: (value: string) => formatTime(value) },
          { title: "原因", dataIndex: "reason", width: 90, render: (value: string | null) => value || "运行" },
          { title: "结果", dataIndex: "status", width: 70, render: (value: string) => ({ done: "完成", waiting: "待确认", failed: "失败", canceled: "已停止", idle: "未完" })[value] || value },
          { title: "用时", dataIndex: "ms", width: 80, render: (value: number) => formatDuration(value) },
          {
            title: "各步骤",
            render: (_, run) => (
              <span className="muted" style={{ fontSize: 12 }}>
                {STEP_ORDER.filter((step) => (run.steps[step] || 0) >= 1000).map((step) => `${STEP_LABELS[step]} ${formatDuration(run.steps[step])}`).join(" · ") || "—"}
              </span>
            ),
          },
        ]}
      />
    </Section>
  );
}
