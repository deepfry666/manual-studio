import { useMemo, useState } from "react";
import { Card, Col, Row, Select, Space, Statistic, Table, Tag, Typography } from "antd";
import { InlineTabs } from "../ui";
import { call, formatSeconds, formatTime } from "../api";
import { useDebounced, useLoader, useSettings, useStudioEvents } from "../hooks";
import type { CallRow } from "../types";

const ROLE_LABEL: Record<string, string> = { primary: "首发", hedge: "补发", failover: "切换", retry: "重试", probe: "测速", resume: "续查", history: "历史导入" };
const OUTCOME_LABEL: Record<string, string> = { winner: "采用", alternate: "备选", loser: "被取消", canceled: "已取消", timeout: "超时", "job-failed": "整屏失败" };

function percentile(values: number[], p: number) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * (sorted.length - 1)))];
}

export function CallsPage() {
  const settings = useSettings();
  const [provider, setProvider] = useState<string | undefined>();
  const [tab, setTab] = useState("image");
  const calls = useLoader(() => call<CallRow[]>("queryCalls", { limit: 2000 }));
  const llmCalls = useLoader(() => call<CallRow[]>("queryLlmCalls", { limit: 500 }));
  const reload = useDebounced(calls.reload, 1000);
  useStudioEvents((event) => {
    if (event.type === "call") reload();
  });

  const rows = useMemo(() => (calls.data || []).filter((row) => row.role !== "history" && (!provider || row.providerId === provider)), [calls.data, provider]);
  const summary = useMemo(() => {
    const real = rows.filter((row) => row.kind !== "aborted");
    const ok = real.filter((row) => row.ok);
    const durations = ok.map((row) => (row.durationMs || 0) / 1000);
    return {
      total: real.length,
      successRate: real.length ? ok.length / real.length : null,
      p50: percentile(durations, 50),
      p90: percentile(durations, 90),
      hedges: rows.filter((row) => row.role === "hedge").length,
      hedgeWins: rows.filter((row) => row.role === "hedge" && row.outcome === "winner").length,
      alternates: rows.filter((row) => row.outcome === "alternate").length,
    };
  }, [rows]);

  return (
    <div className="page">
      <div className="page-header">
        <h2>调用记录</h2>
        <Select
          allowClear
          placeholder="全部线路"
          style={{ width: 220 }}
          value={provider}
          onChange={setProvider}
          options={(settings.data?.settings.providers || []).map((item) => ({ value: item.id, label: item.name }))}
        />
      </div>
      <Row gutter={16} style={{ marginBottom: 16 }}>
        <Col span={4}>
          <Card size="small">
            <Statistic title="生图调用" value={summary.total} />
          </Card>
        </Col>
        <Col span={4}>
          <Card size="small">
            <Statistic title="成功率" value={summary.successRate === null ? "—" : `${Math.round(summary.successRate * 100)}%`} />
          </Card>
        </Col>
        <Col span={4}>
          <Card size="small">
            <Statistic title="耗时 P50" value={formatSeconds(summary.p50)} />
          </Card>
        </Col>
        <Col span={4}>
          <Card size="small">
            <Statistic title="耗时 P90" value={formatSeconds(summary.p90)} />
          </Card>
        </Col>
        <Col span={4}>
          <Card size="small">
            <Statistic title="补发 / 补发胜出" value={`${summary.hedges} / ${summary.hedgeWins}`} />
          </Card>
        </Col>
        <Col span={4}>
          <Card size="small">
            <Statistic title="备选图" value={summary.alternates} />
          </Card>
        </Col>
      </Row>
      <InlineTabs
        activeKey={tab}
        onChange={setTab}
        items={[
          {
            key: "image",
            label: "生图",
            children: (
              <Table<CallRow>
                rowKey={(row, index) => `${row.ts}-${index}`}
                size="small"
                loading={calls.loading}
                dataSource={rows}
                pagination={{ pageSize: 50, showSizeChanger: false }}
                columns={[
                  { title: "时间", dataIndex: "ts", width: 120, render: formatTime },
                  { title: "项目 / 屏", render: (_, row) => <span>{row.projectName || "—"} <span className="muted mono">{row.screenId || ""}</span></span> },
                  { title: "线路", dataIndex: "providerName", width: 160, render: (value: string, row) => value || row.providerId },
                  { title: "类型", dataIndex: "role", width: 80, render: (role: string) => ROLE_LABEL[role] || role || "—" },
                  { title: "尺寸", dataIndex: "requestSize", width: 100, render: (value: string) => <span className="mono">{value || "—"}</span> },
                  { title: "耗时", dataIndex: "durationMs", width: 90, render: (value: number) => formatSeconds(value ? value / 1000 : null) },
                  {
                    title: "结果",
                    width: 230,
                    render: (_, row) =>
                      row.ok ? (
                        <Tag color={row.outcome === "alternate" ? "blue" : "green"}>{OUTCOME_LABEL[row.outcome || ""] || "成功"}</Tag>
                      ) : row.kind === "aborted" ? (
                        <Tag>{OUTCOME_LABEL[row.outcome || ""] || "已取消"}</Tag>
                      ) : (
                        <Typography.Text type="danger" ellipsis={{ tooltip: row.errorMessage }} style={{ maxWidth: 220 }}>
                          {row.kind}：{row.errorMessage}
                        </Typography.Text>
                      ),
                  },
                ]}
              />
            ),
          },
          {
            key: "llm",
            label: "大模型",
            children: (
              <Table<CallRow>
                rowKey={(row, index) => `${row.ts}-${index}`}
                size="small"
                loading={llmCalls.loading}
                dataSource={llmCalls.data || []}
                pagination={{ pageSize: 50, showSizeChanger: false }}
                columns={[
                  { title: "时间", dataIndex: "ts", width: 120, render: formatTime },
                  { title: "步骤", dataIndex: "step", width: 120, render: (step: string) => settings.data?.llmSteps[step]?.label || step },
                  { title: "模型", dataIndex: "model", width: 200 },
                  { title: "耗时", dataIndex: "durationMs", width: 90, render: (value: number) => formatSeconds(value ? value / 1000 : null) },
                  { title: "结果", render: (_, row) => (row.ok ? <Tag color="green">成功</Tag> : <Typography.Text type="danger">{row.errorMessage}</Typography.Text>) },
                ]}
              />
            ),
          },
        ]}
      />
      <Space />
    </div>
  );
}
