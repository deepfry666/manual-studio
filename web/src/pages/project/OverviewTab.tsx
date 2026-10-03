import { useEffect } from "react";
import { App, Button, Card, Col, Form, Input, InputNumber, Radio, Row, Select, Switch, Typography, Empty } from "antd";
import { call, formatTime } from "../../api";
import type { ProjectDetail } from "../../types";

export function OverviewTab({ data, activity, running, onChanged }: { data: ProjectDetail; activity: string[]; running: boolean; onChanged: () => void }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const request = data.state.request;
  useEffect(() => {
    form.setFieldsValue({
      autoCount: !request.screenCount,
      screenCount: request.screenCount || 7,
      emphasis: request.emphasis,
      notes: request.notes,
      platform: request.platform || undefined,
      versionPolicy: request.versionPolicy,
      wantDesign: request.wantDesign,
      extraBrandTokens: request.extraBrandTokens || [],
      compileDate: request.compileDate,
    });
  }, [data.dir, request, form]);

  const save = async () => {
    const values = await form.validateFields();
    try {
      await call("action", "updateRequest", data.dir, {
        screenCount: values.autoCount ? null : values.screenCount,
        emphasis: values.emphasis || "",
        notes: values.notes || "",
        platform: values.platform || "",
        versionPolicy: values.versionPolicy,
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
            <Form.Item name="versionPolicy" label="版本号处理">
              <Radio.Group options={[{ value: "in-name", label: "在软件名里" }, { value: "none", label: "没有版本号" }]} />
            </Form.Item>
            <Form.Item name="extraBrandTokens" label="额外禁词（截图里也不能出现的词）" extra="默认已禁止：完整软件名、去掉版本号的名字、版本号。可以再加品牌简称等。">
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
