import { useEffect, useMemo } from "react";
import { App, Button, Card, Col, Form, Input, InputNumber, Row, Select, Switch, Table, Typography, Empty } from "antd";
import { call, detectVersion, formatDuration, formatTime } from "../../api";
import { STEP_LABELS, STEP_ORDER } from "../../hooks";
import type { ProjectDetail } from "../../types";

export function OverviewTab({ data, activity, running, onChanged }: { data: ProjectDetail; activity: string[]; running: boolean; onChanged: () => void }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const request = data.state.request;
  const requestKey = useMemo(() => JSON.stringify(request), [request]);
  useEffect(() => {
    form.setFieldsValue({
      autoCount: !request.screenCount,
      screenCount: request.screenCount || 7,
      emphasis: request.emphasis,
      notes: request.notes,
      platform: request.platform || undefined,
      wantDesign: request.wantDesign,
      extraBrandTokens: request.extraBrandTokens || [],
      compileDate: request.compileDate,
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data.dir, requestKey, form]);

  const save = async () => {
    const values = await form.validateFields();
    try {
      await call("action", "updateRequest", data.dir, {
        screenCount: values.autoCount ? null : values.screenCount,
        emphasis: values.emphasis || "",
        notes: values.notes || "",
        platform: values.platform || "",
        wantDesign: values.wantDesign,
        extraBrandTokens: values.extraBrandTokens || [],
        compileDate: values.compileDate || "",
      });
      message.success("已保存。改动会在下次运行时生效，只重做受影响的步骤。");
      onChanged();
    } catch (error) {
      message.error((error as Error).message);
    }
  };

  const disabled = running || Boolean(data.state.readOnly);
  return (
    <Row gutter={16}>
      <Col span={13}>
        <Card title="项目设置" size="small" extra={<Button type="primary" size="small" disabled={disabled} onClick={save}>保存</Button>}>
          <Form form={form} layout="vertical" disabled={disabled}>
            <Row gutter={12}>
              <Col span={12}>
                <Form.Item name="autoCount" label="截图数" valuePropName="checked" extra="改屏数、重点功能或平台会重新规划并重新生图">
                  <Switch checkedChildren="自动" unCheckedChildren="指定" />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item noStyle shouldUpdate={(prev, next) => prev.autoCount !== next.autoCount}>
                  {({ getFieldValue }) =>
                    !getFieldValue("autoCount") && (
                      <Form.Item name="screenCount" label="屏数">
                        <InputNumber min={2} max={15} />
                      </Form.Item>
                    )
                  }
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name="emphasis" label="重点功能">
              <Input />
            </Form.Item>
            <Form.Item name="notes" label="补充说明">
              <Input.TextArea rows={2} />
            </Form.Item>
            <Form.Item name="platform" label="平台">
              <Select allowClear placeholder="使用设置里的默认平台" options={[{ value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" }, { value: "Android 手机（原生 Android 界面）", label: "Android 手机" }]} />
            </Form.Item>
            <Form.Item
              name="extraBrandTokens"
              label="额外禁词（截图里也不能出现的词）"
              extra={`默认已禁止：完整软件名、去掉版本号的名字${detectVersion(request.softwareName) ? `、版本号 ${detectVersion(request.softwareName)}` : ""}。可以再加品牌简称等。`}
            >
              <Select mode="tags" placeholder="输入后回车" />
            </Form.Item>
            <Row gutter={12}>
              <Col span={12}>
                <Form.Item name="compileDate" label="编制时间（留空用构建当天）">
                  <Input placeholder="例如 2026年10月3日" />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name="wantDesign" label="附加设计说明章节" valuePropName="checked">
                  <Switch />
                </Form.Item>
              </Col>
            </Row>
          </Form>
        </Card>
        <TimingCard data={data} />
        {data.state.warnings.length > 0 && (
          <Card title="提醒" size="small" style={{ marginTop: 16 }}>
            <ul style={{ margin: 0, paddingLeft: 18 }}>
              {data.state.warnings.map((warning) => (
                <li key={warning}>{warning}</li>
              ))}
            </ul>
          </Card>
        )}
      </Col>
      <Col span={11}>
        <Card title="实时生图动态" size="small">
          {activity.length ? (
            <div className="log-list mono">
              {activity.map((line, index) => (
                <div key={index}>{line}</div>
              ))}
            </div>
          ) : (
            <Typography.Text className="muted">运行时这里会显示每张图走了哪条线路、有没有补发。</Typography.Text>
          )}
        </Card>
        <Card title="项目日志" size="small" style={{ marginTop: 16 }}>
          {data.state.log.length ? (
            <div className="log-list">
              {[...data.state.log].reverse().map((entry, index) => (
                <div key={index} className={entry.level}>
                  <span className="muted mono">{formatTime(entry.at)}</span> {entry.message}
                </div>
              ))}
            </div>
          ) : (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有日志" />
          )}
        </Card>
      </Col>
    </Row>
  );
}

/** 用时：完成用时、累计用时、每次运行和各步骤用时。 */
function TimingCard({ data }: { data: ProjectDetail }) {
  const timing = data.state.timing;
  if (!timing?.runs?.length) return null;
  const runs = [...timing.runs].reverse();
  return (
    <Card
      title="用时"
      size="small"
      style={{ marginTop: 16 }}
      extra={
        <span>
          {timing.completedMs ? <>完成用时 <b>{formatDuration(timing.completedMs)}</b>，</> : null}累计 {formatDuration(timing.totalMs)}
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
    </Card>
  );
}
