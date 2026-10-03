import { useEffect } from "react";
import { Alert, App, Button, Card, Col, Form, Input, InputNumber, Row, Select, Space, Switch, Typography } from "antd";
import { call } from "../api";
import { useLoader, useSettings } from "../hooks";

const TXT_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发该软件的操作系统",
  devTools: "软件开发环境/开发工具",
  runPlatform: "该软件的运行平台/操作系统",
  runSupport: "软件运行支撑环境/支持软件",
  language: "编程语言（没有代码来源时使用）",
};

export function SettingsPage() {
  const { message } = App.useApp();
  const settings = useSettings();
  const libre = useLoader(() => call<{ path: string | null }>("libreOfficeStatus"));
  const info = useLoader(() => call<{ version: string; dataDir: string }>("appInfo"));
  const [form] = Form.useForm();
  useEffect(() => {
    if (settings.data) form.setFieldsValue(settings.data.settings);
  }, [settings.data, form]);
  if (!settings.data) return <div className="page" />;

  const save = async () => {
    const values = await form.validateFields();
    await call("updateSettings", { workspaceDir: values.workspaceDir, pipeline: values.pipeline, txtFields: values.txtFields, codeDefaults: values.codeDefaults });
    message.success("设置已保存");
    settings.reload();
  };

  return (
    <div className="page">
      <div className="page-header">
        <h2>设置</h2>
        <Button type="primary" onClick={save}>
          保存
        </Button>
      </div>
      <Form form={form} layout="vertical">
        <Row gutter={16}>
          <Col span={12}>
            <Card size="small" title="工作区">
              <Form.Item label="新项目存放位置" required>
                <Space.Compact style={{ width: "100%" }}>
                  <Form.Item name="workspaceDir" noStyle>
                    <Input readOnly />
                  </Form.Item>
                  <Button
                    onClick={async () => {
                      const dir = await call<string | null>("chooseDirectory", "选择工作区", form.getFieldValue("workspaceDir"));
                      if (dir) form.setFieldValue("workspaceDir", dir);
                    }}
                  >
                    选择…
                  </Button>
                </Space.Compact>
              </Form.Item>
              <Alert
                type={libre.data?.path ? "success" : "warning"}
                showIcon
                message={libre.data?.path ? `LibreOffice 可用：${libre.data.path}` : "没有找到 LibreOffice，交付包里不会有 PDF"}
                action={<Button size="small" onClick={libre.reload}>重新检测</Button>}
              />
              <Typography.Paragraph className="muted" style={{ marginTop: 12, marginBottom: 0 }}>
                软件数据（设置、加密的密钥、调用记录、项目状态）：<span className="mono">{info.data?.dataDir}</span>
              </Typography.Paragraph>
            </Card>
            <Card size="small" title="流程" style={{ marginTop: 16 }}>
              <Row gutter={12}>
                <Col span={12}>
                  <Form.Item name={["pipeline", "defaultScreenCount"]} label="默认屏数（新建时的参考值）">
                    <InputNumber min={2} max={15} />
                  </Form.Item>
                </Col>
                <Col span={12}>
                  <Form.Item name={["pipeline", "batchConcurrency"]} label="批量时同时跑几个项目">
                    <InputNumber min={1} max={8} />
                  </Form.Item>
                </Col>
              </Row>
              <Form.Item name={["pipeline", "platform"]} label="默认平台">
                <Select options={[{ value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" }, { value: "Android 手机（原生 Android 界面）", label: "Android 手机" }]} />
              </Form.Item>
              <Form.Item name={["pipeline", "reviewPlanSingle"]} label="单个项目：规划完先停下让我确认" valuePropName="checked">
                <Switch />
              </Form.Item>
              <Form.Item name={["pipeline", "featureTextFloor"]} label="每屏说明最少字符数" extra="按普通字符串长度计，和旧 skill 一样是 300">
                <InputNumber min={100} max={1000} />
              </Form.Item>
            </Card>
          </Col>
          <Col span={12}>
            <Card size="small" title="TXT 环境字段默认值">
              <Typography.Paragraph className="muted">默认值和旧 skill 模板一致。【源程序量】不在这里填，按每个项目的代码来源实际行数统计。</Typography.Paragraph>
              {Object.entries(TXT_LABELS).map(([key, label]) => (
                <Form.Item key={key} name={["txtFields", key]} label={label}>
                  <Input />
                </Form.Item>
              ))}
            </Card>
            <Card size="small" title="代码来源默认值" style={{ marginTop: 16 }}>
              <Form.Item name={["codeDefaults", "extensions"]} label="代码文件类型">
                <Select mode="tags" />
              </Form.Item>
              <Form.Item name={["codeDefaults", "excludeDirs"]} label="读取代码时跳过的文件夹">
                <Select mode="tags" />
              </Form.Item>
            </Card>
          </Col>
        </Row>
      </Form>
    </div>
  );
}
