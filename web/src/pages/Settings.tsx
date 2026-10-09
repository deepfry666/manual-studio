import { useEffect, useState } from "react";
import { Alert, App, Button, Card, Col, Descriptions, Form, Input, InputNumber, Row, Select, Space, Switch, Table, Tabs, Tag, Typography } from "antd";
import { call, formatTime } from "../api";
import { GRADE_LABEL, navigate, useLoader, useSettings } from "../hooks";
import type { FontStatus } from "../types";

const TXT_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发该软件的操作系统",
  devTools: "软件开发环境/开发工具",
  runPlatform: "该软件的运行平台/操作系统",
  runSupport: "软件运行支撑环境/支持软件",
  language: "编程语言（没有代码来源时使用）",
};

const CODE_EXTENSIONS = [".java", ".kt", ".swift", ".dart", ".js", ".ts", ".vue", ".py", ".go", ".cs"];

export function SettingsPage({ tab }: { tab?: string }) {
  const active = ["general", "code", "pdf", "import", "txt"].includes(tab || "") ? (tab as string) : "general";
  return (
    <div className="page" style={{ maxWidth: 1100 }}>
      <div className="page-header">
        <h2>设置</h2>
      </div>
      <Tabs
        activeKey={active}
        onChange={(key) => navigate("settings", key)}
        items={[
          { key: "general", label: "常规", children: <GeneralSettings /> },
          { key: "code", label: "代码来源", children: <CodeSourceSettings /> },
          { key: "pdf", label: "PDF 与字体", children: <PdfSettings /> },
          { key: "import", label: "导入历史项目", children: <ImportPanel /> },
          { key: "txt", label: "TXT 环境字段", children: <TxtSettings /> },
        ]}
      />
    </div>
  );
}

function GeneralSettings() {
  const { message } = App.useApp();
  const settings = useSettings();
  const libre = useLoader(() => call<{ path: string | null }>("libreOfficeStatus"));
  const info = useLoader(() => call<{ version: string; dataDir: string }>("appInfo"));
  const [form] = Form.useForm();
  useEffect(() => {
    if (settings.data) form.setFieldsValue(settings.data.settings);
  }, [settings.data, form]);
  if (!settings.data) return null;
  const save = async () => {
    const values = await form.validateFields();
    await call("updateSettings", { workspaceDir: values.workspaceDir, pipeline: values.pipeline });
    message.success("设置已保存");
    settings.reload();
  };
  return (
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
        </Col>
        <Col span={12}>
          <Card size="small" title="流程">
            <Row gutter={12}>
              <Col span={12}>
                <Form.Item name={["pipeline", "batchConcurrency"]} label="批量时同时处理几个项目" extra="比如 50 个项目设 3：3 个同时跑，跑完一个补一个。生图总并发由生图线路控制，所有项目共用，调大这里不会把线路挤爆。">
                  <InputNumber min={1} max={8} />
                </Form.Item>
              </Col>
              <Col span={12}>
                <Form.Item name={["pipeline", "defaultScreenCount"]} label="默认屏数（新建时的参考值）">
                  <InputNumber min={2} max={15} />
                </Form.Item>
              </Col>
            </Row>
            <Form.Item name={["pipeline", "platform"]} label="默认平台">
              <Select options={[{ value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" }, { value: "Android 手机（原生 Android 界面）", label: "Android 手机" }]} />
            </Form.Item>
            <Form.Item name={["pipeline", "reviewPlanSingle"]} label="规划确认：规划完先停下让我检查" valuePropName="checked" extra="关闭时（默认）规划完直接生成截图，一路做完。批量新建的项目始终不停。">
              <Switch checkedChildren="先确认" unCheckedChildren="直接做完" />
            </Form.Item>
            <Form.Item name={["pipeline", "featureTextFloor"]} label="每屏说明最少字符数" extra="按普通字符串长度计。排版模板固定要求至少 300，所以不能低于 300。">
              <InputNumber min={300} max={1000} />
            </Form.Item>
          </Card>
        </Col>
      </Row>
      <Button type="primary" style={{ marginTop: 16 }} onClick={save}>
        保存
      </Button>
    </Form>
  );
}

interface CodeInfo {
  fileCount: number;
  lineCount: number;
  nonEmptyLines: number;
  estimatedPages: number;
  files: string[];
  warnings: string[];
}

function CodeSourceSettings() {
  const { message } = App.useApp();
  const settings = useSettings();
  const [info, setInfo] = useState<CodeInfo | null>(null);
  const [inspecting, setInspecting] = useState(false);
  const source = settings.data?.settings.codeSource || { path: "", extensions: [".java"] };
  const excludeDirs = settings.data?.settings.codeDefaults.excludeDirs || [];

  const inspect = async (target = source.path, extensions = source.extensions) => {
    if (!target) return setInfo(null);
    setInspecting(true);
    try {
      setInfo(await call<CodeInfo>("inspectCodeSource", { path: target, extensions }));
    } catch (error) {
      setInfo(null);
      message.error((error as Error).message);
    } finally {
      setInspecting(false);
    }
  };
  useEffect(() => {
    if (source.path) inspect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source.path, JSON.stringify(source.extensions)]);

  const save = async (patch: Partial<{ path: string; extensions: string[] }>) => {
    await call("updateSettings", { codeSource: { ...source, ...patch } });
    settings.reload();
  };
  if (!settings.data) return null;
  return (
    <Row gutter={16}>
      <Col span={14}>
        <Card size="small" title="代码来源（所有项目共用）">
          <Typography.Paragraph className="muted">
            代码文档只用这里的源码，按文件路径排序后原样排版，不改写、不生成。项目第一次生成交付包时会记下当时用的代码来源，之后这里改了，<b>已完成的项目不会重建</b>，仍是原来的代码文档；还没生成交付包的项目用新的。不设置时交付包只有说明书 3 个文件。
          </Typography.Paragraph>
          <Space.Compact style={{ width: "100%", marginBottom: 12 }}>
            <Input value={source.path} readOnly placeholder="未设置" />
            <Button
              onClick={async () => {
                const picked = await call<string | null>("choosePath", "选择源码文件夹或文件", source.path || undefined);
                if (picked) {
                  await save({ path: picked });
                  message.success("代码来源已保存");
                }
              }}
            >
              选择…
            </Button>
            {source.path && (
              <Button
                danger
                onClick={async () => {
                  await save({ path: "" });
                  setInfo(null);
                  message.success("已清除：之后新生成的交付包不含代码文档");
                }}
              >
                清除
              </Button>
            )}
          </Space.Compact>
          <Form layout="vertical">
            <Form.Item label="代码文件类型">
              <Select mode="tags" value={source.extensions} onChange={(value: string[]) => save({ extensions: value })} options={CODE_EXTENSIONS.map((value) => ({ value, label: value }))} />
            </Form.Item>
            <Form.Item label="读取代码时跳过的文件夹">
              <Select
                mode="tags"
                value={excludeDirs}
                onChange={async (value: string[]) => {
                  await call("updateSettings", { codeDefaults: { excludeDirs: value } });
                  settings.reload();
                }}
              />
            </Form.Item>
          </Form>
        </Card>
      </Col>
      <Col span={10}>
        <Card size="small" title="统计" loading={inspecting} extra={source.path && <Button size="small" onClick={() => inspect()}>重新统计</Button>}>
          {info ? (
            <>
              <Descriptions size="small" column={1} bordered>
                <Descriptions.Item label="文件">{info.fileCount} 个</Descriptions.Item>
                <Descriptions.Item label="行数">{info.lineCount}（非空 {info.nonEmptyLines}）</Descriptions.Item>
                <Descriptions.Item label="代码文档">约 {info.estimatedPages} 页</Descriptions.Item>
              </Descriptions>
              <div className="mono" style={{ maxHeight: 220, overflow: "auto", marginTop: 12 }}>
                {info.files.map((file) => (
                  <div key={file}>{file}</div>
                ))}
                {info.fileCount > info.files.length && <div>…</div>}
                {info.warnings.map((warning) => (
                  <div key={warning} className="warn-text">
                    {warning}
                  </div>
                ))}
              </div>
            </>
          ) : (
            <Typography.Text className="muted">{source.path ? "统计中…" : "还没有设置代码来源"}</Typography.Text>
          )}
        </Card>
      </Col>
    </Row>
  );
}

function PdfSettings() {
  const { message } = App.useApp();
  const fonts = useLoader(() => call<FontStatus>("fontStatus"));
  const [installing, setInstalling] = useState(false);
  const data = fonts.data;
  return (
    <Row gutter={16}>
      <Col span={14}>
        <Card size="small" title="PDF 字体" loading={fonts.loading} extra={<Button size="small" onClick={fonts.reload}>重新检测</Button>}>
          <Typography.Paragraph className="muted">
            模板里说明书用「微软雅黑」、代码文档用「新宋体」。Mac 上没有这两个字体，LibreOffice 以前会随便抓一个中文字体顶上，所以每次转出来字体都不一样。现在：装了原版字体就用原版；没装就固定换成下面选的系统字体，转完还会核对 PDF 里实际用的字体，不对会在项目里标出来。
          </Typography.Paragraph>
          {data &&
            Object.entries(data.docs).map(([kind, doc]) => (
              <Card key={kind} type="inner" size="small" style={{ marginBottom: 12 }} title={`${doc.label}（模板字体：${doc.original}）`}>
                {doc.installed ? (
                  <Tag color="green">已安装原版「{doc.original}」，PDF 直接用原版</Tag>
                ) : (
                  <Space direction="vertical" style={{ width: "100%" }}>
                    <span>
                      <Tag color="orange">本机没有「{doc.original}」</Tag>改用：
                    </span>
                    <Select
                      style={{ width: 320 }}
                      value={doc.choice}
                      options={doc.choices}
                      onChange={async (value) => {
                        await call("updateSettings", { pdf: { [kind]: value } });
                        message.success("已保存，之后生成的 PDF 生效");
                        fonts.reload();
                      }}
                    />
                  </Space>
                )}
              </Card>
            ))}
          {data && !data.detected && <Alert type="warning" showIcon message="没能读取本机字体列表，按「没有安装原版字体」处理" />}
        </Card>
      </Col>
      <Col span={10}>
        <Card size="small" title="安装原版字体（可选）">
          <Typography.Paragraph>
            想要和 Word 里完全一样（包括代码文档的页数），需要原版字体文件：微软雅黑 <span className="mono">msyh.ttc</span>、<span className="mono">msyhbd.ttc</span>，新宋体在 <span className="mono">simsun.ttc</span> 里。任何一台 Windows 电脑的 <span className="mono">C:\Windows\Fonts</span> 都有。
          </Typography.Paragraph>
          <Typography.Paragraph className="muted">
            这两个是微软的商业字体，软件不能自带，需要你从装了它们的电脑上拷过来。装好后点「重新检测」，之后生成的 PDF 自动改用原版。
          </Typography.Paragraph>
          <Button
            loading={installing}
            onClick={async () => {
              setInstalling(true);
              try {
                const result = await call<{ installed: string[]; skipped: string[] } | null>("installFonts");
                if (!result) return;
                if (result.installed.length) message.success(`已安装：${result.installed.join("、")}`);
                if (result.skipped.length) message.warning(result.skipped.join("；"));
                fonts.reload();
              } catch (error) {
                message.error((error as Error).message);
              } finally {
                setInstalling(false);
              }
            }}
          >
            选择字体文件安装…
          </Button>
          <Typography.Paragraph className="muted" style={{ marginTop: 12, marginBottom: 0 }}>
            已经做好的项目，可以在「历史项目」列表里勾选后点「重新导出 PDF」，只重转 PDF，Word 不动。
          </Typography.Paragraph>
        </Card>
      </Col>
    </Row>
  );
}

function TxtSettings() {
  const { message } = App.useApp();
  const settings = useSettings();
  const [form] = Form.useForm();
  useEffect(() => {
    if (settings.data) form.setFieldsValue(settings.data.settings.txtFields);
  }, [settings.data, form]);
  return (
    <Card size="small" style={{ maxWidth: 720 }}>
      <Typography.Paragraph className="muted">默认值和旧 skill 模板一致。【源程序量】不在这里填，按代码来源的实际行数统计。</Typography.Paragraph>
      <Form form={form} layout="vertical">
        {Object.entries(TXT_LABELS).map(([key, label]) => (
          <Form.Item key={key} name={key} label={label}>
            <Input />
          </Form.Item>
        ))}
        <Button
          type="primary"
          onClick={async () => {
            await call("updateSettings", { txtFields: form.getFieldsValue() });
            message.success("已保存");
            settings.reload();
          }}
        >
          保存
        </Button>
      </Form>
    </Card>
  );
}

interface ScanRow {
  dir: string;
  name: string;
  grade: "ready" | "needs-gate" | "readonly";
  screens: number;
  hasBundle: boolean;
  hasCodeDoc: boolean;
  managed: boolean;
  mtime: number;
}

function ImportPanel() {
  const { message, modal } = App.useApp();
  const [rows, setRows] = useState<ScanRow[] | null>(null);
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [scanning, setScanning] = useState(false);

  const scan = async (dir?: string) => {
    setScanning(true);
    try {
      const result = await call<ScanRow[]>("scanWorkspace", dir);
      setRows(result);
      setSelected(result.filter((row) => !row.managed && row.grade !== "readonly").map((row) => row.dir));
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setScanning(false);
    }
  };
  useEffect(() => {
    scan();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const importSelected = async () => {
    setBusy(true);
    try {
      const result = await call<{ imported: string[]; failed: string[]; timings: number }>("importProjects", selected);
      modal.info({
        title: "导入完成",
        content: (
          <div>
            <p>导入了 {result.imported.length} 个项目{result.timings ? `，并导入 ${result.timings} 条历史生图耗时记录（用于计算补发线）` : ""}。</p>
            {result.failed.length > 0 && (
              <ul>
                {result.failed.map((line) => (
                  <li key={line}>{line}</li>
                ))}
              </ul>
            )}
            <p className="muted">导入只是登记，不会改动这些项目文件夹里的任何文件。</p>
          </div>
        ),
        onOk: () => navigate("projects"),
      });
      scan();
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div>
      <Typography.Paragraph className="muted">
        扫描工作区里旧 skill 做过的项目。导入只是在本软件里登记，不复制、不改动项目文件夹。历史项目的代码文档是旧 skill 的固定正文，导入后不会重建；需要时可以在项目的「交付」里改用总设置的代码来源。
      </Typography.Paragraph>
      <Space style={{ marginBottom: 8 }}>
        <Button
          onClick={async () => {
            const dir = await call<string | null>("chooseDirectory", "选择要扫描的工作区");
            if (dir) scan(dir);
          }}
        >
          换个文件夹扫描…
        </Button>
        <Button onClick={() => rows && setSelected(rows.filter((row) => !row.managed && row.grade === "ready").map((row) => row.dir))}>只选「可直接编辑」</Button>
        <Button type="primary" loading={busy} disabled={!selected.length} onClick={importSelected}>
          导入 {selected.length} 个
        </Button>
      </Space>
      <Table<ScanRow>
        rowKey="dir"
        size="small"
        loading={scanning}
        dataSource={rows || []}
        pagination={{ pageSize: 15, showSizeChanger: false, showTotal: (total) => `共 ${total} 个` }}
        rowSelection={{ selectedRowKeys: selected, onChange: (keys) => setSelected(keys as string[]), getCheckboxProps: (row) => ({ disabled: row.managed }) }}
        columns={[
          { title: "软件名", dataIndex: "name" },
          { title: "状态", dataIndex: "grade", width: 130, render: (grade: string, row) => (row.managed ? <Tag>已导入</Tag> : <Tag color={GRADE_LABEL[grade]?.color}>{GRADE_LABEL[grade]?.label}</Tag>) },
          { title: "截图", dataIndex: "screens", width: 60 },
          { title: "交付包", dataIndex: "hasBundle", width: 80, render: (value: boolean) => (value ? "有" : "—") },
          { title: "修改时间", dataIndex: "mtime", width: 130, render: (value: number) => formatTime(new Date(value).toISOString()) },
        ]}
      />
    </div>
  );
}
