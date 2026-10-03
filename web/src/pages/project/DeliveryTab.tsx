import { useEffect, useMemo, useState } from "react";
import { Alert, App, Button, Card, Col, Collapse, Descriptions, Empty, Form, Input, List, Row, Select, Space, Typography } from "antd";
import { BuildOutlined, FileZipOutlined, FolderOpenOutlined } from "@ant-design/icons";
import { call, formatTime } from "../../api";
import { useSettings } from "../../hooks";
import type { ProjectDetail } from "../../types";

interface CodeInfo {
  fileCount: number;
  lineCount: number;
  nonEmptyLines: number;
  estimatedPages: number;
  files: string[];
  warnings: string[];
}

const TXT_FIELD_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发该软件的操作系统",
  devTools: "软件开发环境/开发工具",
  runPlatform: "该软件的运行平台/操作系统",
  runSupport: "软件运行支撑环境/支持软件",
  language: "编程语言（留空按代码来源自动判断）",
};

export function DeliveryTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message } = App.useApp();
  const settings = useSettings();
  const request = data.state.request;
  const [codePath, setCodePath] = useState(request.codeSource?.path || "");
  const [extensions, setExtensions] = useState<string[]>(request.codeSource?.extensions || [".java"]);
  const [codeInfo, setCodeInfo] = useState<CodeInfo | null>(null);
  const [inspecting, setInspecting] = useState(false);
  const [txtForm] = Form.useForm();
  const readOnly = Boolean(data.state.readOnly);
  const build = data.state.lastBuild;

  const codeKey = useMemo(() => JSON.stringify(request.codeSource), [request.codeSource]);
  const txtKey = useMemo(() => JSON.stringify(request.txtFields), [request.txtFields]);
  useEffect(() => {
    setCodePath(request.codeSource?.path || "");
    setExtensions(request.codeSource?.extensions || [".java"]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [codeKey]);
  useEffect(() => {
    txtForm.resetFields();
    txtForm.setFieldsValue(request.txtFields || {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txtKey, txtForm]);
  const oldCodeDoc = data.bundleFiles.some((file) => file.includes("_代码-（JAVA）"));

  const inspect = async (target = codePath, exts = extensions) => {
    if (!target) return;
    setInspecting(true);
    try {
      setCodeInfo(await call<CodeInfo>("inspectCodeSource", { path: target, extensions: exts }));
    } catch (error) {
      setCodeInfo(null);
      message.error((error as Error).message);
    } finally {
      setInspecting(false);
    }
  };

  const saveCode = async (target: string | null, exts = extensions) => {
    await call("action", "updateRequest", data.dir, { codeSource: target ? { path: target, extensions: exts } : null });
    message.success(target ? "代码来源已保存，下次生成交付包时生效" : "已清除代码来源，以后生成的交付包不含代码文档");
    onChanged();
  };

  const saveTxt = async () => {
    const values = await txtForm.validateFields();
    const cleaned = Object.fromEntries(Object.entries(values).filter(([, value]) => typeof value === "string" && value.trim()));
    await call("action", "updateRequest", data.dir, { txtFields: Object.keys(cleaned).length ? cleaned : null });
    message.success("已保存");
    onChanged();
  };

  return (
    <Row gutter={16}>
      <Col span={14}>
        <Space direction="vertical" size={16} style={{ width: "100%" }}>
          <Card size="small" title="代码来源">
            <Typography.Paragraph className="muted">
              代码文档只用这里指定的源码，按文件路径排序后原样排版，不改写、不生成。没有指定时，交付包里不包含代码文档；TXT 的【源程序量】按实际行数统计。
            </Typography.Paragraph>
            <Space.Compact style={{ width: "100%", marginBottom: 8 }}>
              <Input value={codePath} readOnly placeholder="未指定" />
              <Button
                disabled={readOnly || running}
                onClick={async () => {
                  const picked = await call<string | null>("choosePath", "选择这个软件的源码文件夹或文件", codePath || undefined);
                  if (picked) {
                    setCodePath(picked);
                    inspect(picked);
                    saveCode(picked);
                  }
                }}
              >
                选择…
              </Button>
            </Space.Compact>
            <Space wrap>
              <Select
                mode="tags"
                style={{ minWidth: 260 }}
                value={extensions}
                disabled={readOnly || running}
                onChange={(value: string[]) => {
                  setExtensions(value);
                  if (codePath) {
                    saveCode(codePath, value);
                    inspect(codePath, value);
                  }
                }}
                options={[".java", ".kt", ".swift", ".dart", ".js", ".ts", ".vue", ".py", ".go", ".cs"].map((value) => ({ value, label: value }))}
              />
              <Button loading={inspecting} disabled={!codePath} onClick={() => inspect()}>
                统计
              </Button>
              {request.codeSource && (
                <Button danger disabled={readOnly || running} onClick={() => saveCode(null)}>
                  清除
                </Button>
              )}
            </Space>
            {codeInfo && (
              <Alert
                style={{ marginTop: 12 }}
                type={codeInfo.warnings.length ? "warning" : "info"}
                message={`${codeInfo.fileCount} 个文件，共 ${codeInfo.lineCount} 行（非空 ${codeInfo.nonEmptyLines} 行），代码文档约 ${codeInfo.estimatedPages} 页`}
                description={
                  <div className="mono" style={{ maxHeight: 140, overflow: "auto" }}>
                    {codeInfo.files.map((file) => (
                      <div key={file}>{file}</div>
                    ))}
                    {codeInfo.fileCount > codeInfo.files.length && <div>…</div>}
                    {codeInfo.warnings.map((warning) => (
                      <div key={warning} style={{ color: "#d97706" }}>
                        {warning}
                      </div>
                    ))}
                  </div>
                }
              />
            )}
          </Card>
          {!request.codeSource && oldCodeDoc && !readOnly && (
            <Alert
              type="warning"
              showIcon
              message="现有交付包里有代码文档，但这个项目没有指定代码来源"
              description={
                (request as { allowDropCodeDoc?: boolean }).allowDropCodeDoc
                  ? "已确认：下次生成的交付包不含代码文档，旧交付包会先归档。"
                  : "历史项目的代码文档来自旧 skill 的固定正文。请在上面指定这个软件的代码来源；如果确定不需要代码文档，点右边的按钮确认，否则生成交付包时会停下来。"
              }
              action={
                !(request as { allowDropCodeDoc?: boolean }).allowDropCodeDoc && (
                  <Button size="small" onClick={async () => { await call("action", "updateRequest", data.dir, { allowDropCodeDoc: true }); onChanged(); }}>
                    确认不含代码文档
                  </Button>
                )
              }
            />
          )}
          <Collapse
            items={[
              {
                key: "txt",
                label: "TXT 环境字段（只对这个项目生效，留空用设置里的默认值）",
                children: (
                  <Form form={txtForm} layout="vertical" disabled={readOnly || running}>
                    {Object.entries(TXT_FIELD_LABELS).map(([key, label]) => (
                      <Form.Item key={key} name={key} label={label}>
                        <Input placeholder={settings.data?.settings.txtFields[key] || ""} />
                      </Form.Item>
                    ))}
                    <Button onClick={saveTxt}>保存</Button>
                  </Form>
                ),
              },
            ]}
          />
        </Space>
      </Col>
      <Col span={10}>
        <Card
          size="small"
          title="交付包"
          extra={
            !readOnly && (
              <Button type="primary" icon={<BuildOutlined />} disabled={running} onClick={() => call("run", data.dir)}>
                生成 / 更新交付包
              </Button>
            )
          }
        >
          {data.bundleFiles.length ? (
            <>
              <List
                size="small"
                dataSource={data.bundleFiles}
                renderItem={(file) => (
                  <List.Item actions={[<a key="open" onClick={() => call("openPath", `${data.bundleDir}/${file}`)}>打开</a>]}>
                    <Typography.Text>{file}</Typography.Text>
                  </List.Item>
                )}
              />
              <Space style={{ marginTop: 12 }}>
                <Button icon={<FolderOpenOutlined />} onClick={() => call("openPath", data.bundleDir)}>
                  打开交付文件夹
                </Button>
                <Button
                  icon={<FileZipOutlined />}
                  onClick={async () => {
                    const target = await call<string>("zipBundle", data.dir);
                    message.success("已打包");
                    call("showInFolder", target);
                  }}
                >
                  打包 zip
                </Button>
              </Space>
            </>
          ) : (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有交付包" />
          )}
          <Typography.Paragraph className="muted" style={{ marginTop: 12, marginBottom: 0, fontSize: 12 }}>
            溯源：每张截图的线路、模型、生成时间和验收方式记录在项目文件夹的{" "}
            <a onClick={() => call("openPath", `${data.dir}/generation-record.json`)}>generation-record.json</a>
            ，构建时汇总写进 project-manifest.json。
          </Typography.Paragraph>
          {build && (
            <Descriptions size="small" column={1} style={{ marginTop: 16 }} bordered>
              <Descriptions.Item label="生成时间">{formatTime(build.at)}</Descriptions.Item>
              <Descriptions.Item label="PDF">{build.withPdf ? `已生成（指南 ${build.pdfPages ?? "?"} 页）` : "没有 LibreOffice，未生成"}</Descriptions.Item>
              <Descriptions.Item label="代码文档">{build.withCode && build.code ? `${build.code.fileCount} 个文件，${build.code.lineCount} 行` : "未生成（没有代码来源）"}</Descriptions.Item>
            </Descriptions>
          )}
          {build?.warnings?.length ? (
            <Alert style={{ marginTop: 12 }} type="warning" message="构建提醒" description={<ul style={{ margin: 0, paddingLeft: 16 }}>{build.warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>} />
          ) : null}
        </Card>
      </Col>
    </Row>
  );
}
