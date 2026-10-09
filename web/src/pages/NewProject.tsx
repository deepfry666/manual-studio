import { useMemo, useState } from "react";
import { Alert, App, Button, Card, Checkbox, Col, Form, Input, InputNumber, Row, Segmented, Select, Space, Switch, Typography } from "antd";
import { call, detectVersion } from "../api";
import { navigate, useSettings } from "../hooks";

const PLATFORMS = [
  { value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" },
  { value: "Android 手机（原生 Android 界面）", label: "Android 手机" },
];

export function NewProjectPage() {
  const [mode, setMode] = useState<"single" | "batch">("single");
  const settings = useSettings();
  const data = settings.data;
  const codePath = data?.settings.codeSource?.path || "";
  return (
    <div className="page" style={{ maxWidth: 920 }}>
      <div className="page-header">
        <h2>新建项目</h2>
        <Segmented
          value={mode}
          onChange={(value) => setMode(value as "single" | "batch")}
          options={[
            { value: "single", label: "单个项目" },
            { value: "batch", label: "批量新建" },
          ]}
        />
      </div>
      <Alert
        style={{ marginBottom: 16 }}
        type={codePath ? "info" : "warning"}
        showIcon
        message={codePath ? `代码来源：${codePath}` : "还没有设置代码来源：交付包只有说明书 3 个文件（Word、PDF、TXT），没有代码文档"}
        description={
          <span>
            代码来源在「设置 → 代码来源」里统一设置，所有项目共用；项目第一次生成交付包时记下当时用的来源，之后改设置不影响已完成的项目。
            <a style={{ marginLeft: 8 }} onClick={() => navigate("settings", "code")}>
              去设置
            </a>
          </span>
        }
      />
      {data && (mode === "single" ? <SingleForm defaultScreens={data.settings.pipeline.defaultScreenCount} defaultPlatform={data.settings.pipeline.platform} /> : <BatchForm defaultPlatform={data.settings.pipeline.platform} concurrency={data.settings.pipeline.batchConcurrency} />)}
    </div>
  );
}

function SingleForm({ defaultScreens, defaultPlatform }: { defaultScreens: number; defaultPlatform: string }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const [busy, setBusy] = useState(false);
  const name = Form.useWatch("softwareName", form) || "";
  const version = detectVersion(name);

  const submit = async (runNow: boolean) => {
    const values = await form.validateFields();
    setBusy(true);
    try {
      const dir = await call<string>("createProject", {
        softwareName: values.softwareName.trim(),
        screenCount: values.autoCount ? null : values.screenCount,
        emphasis: values.emphasis || "",
        notes: values.notes || "",
        platform: values.platform || "",
        wantDesign: values.wantDesign,
      });
      form.resetFields();
      if (runNow) call("run", dir);
      navigate("project", dir);
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <Form form={form} layout="vertical" initialValues={{ screenCount: defaultScreens, autoCount: true, wantDesign: false, platform: defaultPlatform }}>
        <Form.Item
          name="softwareName"
          label="软件名（含版本号，按原样填写）"
          rules={[{ required: true, message: "请填写软件名" }]}
          extra={
            name.trim()
              ? version
                ? `识别到版本号 ${version}：截图里不会出现软件名和版本号`
                : "没有识别到版本号：截图里不会出现软件名"
              : "软件名只用于文件名、文档标题和页眉，截图界面里不会出现。"
          }
        >
          <Input placeholder="例如：云伴日程 V1.0" autoFocus />
        </Form.Item>
        <Space size="large" align="start">
          <Form.Item name="autoCount" label="截图数" valuePropName="checked">
            <Checkbox>让大模型按功能决定（默认 7 屏）</Checkbox>
          </Form.Item>
          <Form.Item noStyle shouldUpdate={(prev, next) => prev.autoCount !== next.autoCount}>
            {({ getFieldValue }) =>
              !getFieldValue("autoCount") && (
                <Form.Item name="screenCount" label="指定屏数">
                  <InputNumber min={2} max={15} />
                </Form.Item>
              )
            }
          </Form.Item>
        </Space>
        <Form.Item name="emphasis" label="需要重点体现的功能（可选）">
          <Input placeholder="例如：违章查询、在线缴费、电子回执" />
        </Form.Item>
        <Form.Item name="notes" label="补充说明（可选）">
          <Input.TextArea rows={2} placeholder="给规划用的额外信息，比如目标用户、风格偏好" />
        </Form.Item>
        <Row gutter={16}>
          <Col span={14}>
            <Form.Item name="platform" label="平台">
              <Select options={PLATFORMS} />
            </Form.Item>
          </Col>
          <Col span={10}>
            <Form.Item name="wantDesign" label="附加软件设计说明章节" valuePropName="checked">
              <Switch />
            </Form.Item>
          </Col>
        </Row>
        <Space>
          <Button type="primary" loading={busy} onClick={() => submit(true)}>
            创建并开始
          </Button>
          <Button loading={busy} onClick={() => submit(false)}>
            只创建
          </Button>
        </Space>
      </Form>
    </Card>
  );
}

function BatchForm({ defaultPlatform, concurrency }: { defaultPlatform: string; concurrency: number }) {
  const { message, modal } = App.useApp();
  const [text, setText] = useState("");
  const [autoCount, setAutoCount] = useState(true);
  const [screenCount, setScreenCount] = useState(7);
  const [platform, setPlatform] = useState(defaultPlatform);
  const [wantDesign, setWantDesign] = useState(false);
  const [startNow, setStartNow] = useState(true);
  const [busy, setBusy] = useState(false);
  const count = useMemo(() => text.split(/\r?\n/).filter((line) => line.trim() && !/^(软件名|名称|name)[,，\t]/i.test(line.trim())).length, [text]);

  const submit = async () => {
    setBusy(true);
    try {
      const result = await call<{ created: string[]; errors: string[] }>("createProjectsFromList", text, { screenCount: autoCount ? null : screenCount, platform, wantDesign });
      if (startNow && result.created.length) await call("batchEnqueue", result.created);
      setText("");
      const finish = () => navigate("projects");
      if (result.errors.length) {
        modal.warning({
          title: `创建了 ${result.created.length} 个，${result.errors.length} 个没有创建`,
          content: (
            <ul style={{ paddingLeft: 18, maxHeight: 300, overflow: "auto" }}>
              {result.errors.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
          ),
          onOk: finish,
        });
      } else {
        message.success(`已创建 ${result.created.length} 个项目${startNow ? `，按每次 ${concurrency} 个开始处理` : ""}`);
        finish();
      }
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Card>
      <Typography.Paragraph className="muted">
        每行一个软件名。需要的话可以在名字后面用逗号带上：<b>截图数,重点功能,补充说明</b>（例如 <span className="mono">快记账本 V1.0,7,预算提醒</span>）。也可以从表格里整列复制粘贴进来。
      </Typography.Paragraph>
      <Space style={{ marginBottom: 8 }}>
        <Button
          onClick={async () => {
            const content = await call<string | null>("chooseTextFile", "选择 CSV 或文本文件");
            if (content) setText(content);
          }}
        >
          从文件读取…
        </Button>
        <span className="muted">已填 {count} 个</span>
      </Space>
      <Input.TextArea rows={14} value={text} onChange={(event) => setText(event.target.value)} placeholder={"云伴日程 V1.0\n快记账本 V1.0,7,预算提醒\n掌上违章助手 V1.0"} className="mono" />
      <Row gutter={16} style={{ marginTop: 16 }}>
        <Col span={8}>
          <Typography.Text>没写截图数的项目</Typography.Text>
          <div style={{ marginTop: 6 }}>
            <Space>
              <Checkbox checked={autoCount} onChange={(event) => setAutoCount(event.target.checked)}>
                按功能决定
              </Checkbox>
              {!autoCount && <InputNumber min={2} max={15} value={screenCount} onChange={(value) => setScreenCount(Number(value) || 7)} />}
            </Space>
          </div>
        </Col>
        <Col span={10}>
          <Typography.Text>平台</Typography.Text>
          <Select style={{ width: "100%", marginTop: 6 }} value={platform} onChange={setPlatform} options={PLATFORMS} />
        </Col>
        <Col span={6}>
          <Typography.Text>设计说明章节</Typography.Text>
          <div style={{ marginTop: 6 }}>
            <Switch checked={wantDesign} onChange={setWantDesign} />
          </div>
        </Col>
      </Row>
      <Space style={{ marginTop: 20 }}>
        <Button type="primary" loading={busy} disabled={!count} onClick={submit}>
          创建 {count || ""} 个项目
        </Button>
        <Checkbox checked={startNow} onChange={(event) => setStartNow(event.target.checked)}>
          创建后直接开始（每次同时处理 {concurrency} 个，在「设置」里调整）
        </Checkbox>
      </Space>
      <Typography.Paragraph className="muted" style={{ marginTop: 12, marginBottom: 0 }}>
        批量项目跳过「规划确认」，直接跑到交付包。进度在「历史项目」列表里看；软件中途关闭，下次打开会自动接着跑。
      </Typography.Paragraph>
    </Card>
  );
}
