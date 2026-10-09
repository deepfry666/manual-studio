import { useEffect, useMemo, useState } from "react";
import { Alert, App, Button, Card, Col, Collapse, Descriptions, Empty, Form, Input, List, Row, Space, Tag, Typography } from "antd";
import { BuildOutlined, FilePdfOutlined, FileZipOutlined, FolderOpenOutlined } from "@ant-design/icons";
import { call, formatTime } from "../../api";
import { navigate, useSettings } from "../../hooks";
import type { ProjectDetail } from "../../types";

const TXT_FIELD_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发该软件的操作系统",
  devTools: "软件开发环境/开发工具",
  runPlatform: "该软件的运行平台/操作系统",
  runSupport: "软件运行支撑环境/支持软件",
  language: "编程语言（留空按代码来源自动判断）",
};

const FONT_DOC: Record<string, string> = { guide: "说明书 PDF", code: "代码文档 PDF" };

export function DeliveryTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message, modal } = App.useApp();
  const settings = useSettings();
  const request = data.state.request;
  const [txtForm] = Form.useForm();
  const [reexporting, setReexporting] = useState(false);
  const readOnly = Boolean(data.state.readOnly);
  const build = data.state.lastBuild;
  const code = data.codeSource;

  const txtKey = useMemo(() => JSON.stringify(request.txtFields), [request.txtFields]);
  useEffect(() => {
    txtForm.resetFields();
    txtForm.setFieldsValue(request.txtFields || {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [txtKey, txtForm]);
  const oldCodeDoc = data.bundleFiles.some((file) => file.includes("_代码-（JAVA）"));
  const changedSinceLock = code.locked && code.global && code.source?.path !== code.global.path;

  const saveTxt = async () => {
    const values = await txtForm.validateFields();
    const cleaned = Object.fromEntries(Object.entries(values).filter(([, value]) => typeof value === "string" && value.trim()));
    await call("action", "updateRequest", data.dir, { txtFields: Object.keys(cleaned).length ? cleaned : null });
    message.success("已保存");
    onChanged();
  };

  const reexport = () =>
    modal.confirm({
      title: "只重新导出 PDF？",
      content: "用交付包里现有的 Word 重新转 PDF（按「设置 → PDF 与字体」），Word、TXT 和截图都不动，旧 PDF 移到项目的 archive 文件夹。",
      okText: "重新导出",
      onOk: async () => {
        setReexporting(true);
        try {
          await call("reexportPdfs", [data.dir]);
          message.info("已开始重新导出 PDF");
        } finally {
          setReexporting(false);
        }
      },
    });

  return (
    <Row gutter={16}>
      <Col span={14}>
        <Space direction="vertical" size={16} style={{ width: "100%" }}>
          <Card size="small" title="代码来源" extra={<a onClick={() => navigate("settings", "code")}>在设置里修改</a>}>
            {code.source ? (
              <Space direction="vertical" size={4}>
                <span className="mono">{code.source.path}</span>
                <span className="muted">
                  {code.source.extensions.join(" ")} ·{" "}
                  {code.locked ? "第一次生成交付包时已记下，以后改设置不影响这个项目" : "来自总设置；第一次生成交付包时会记下来"}
                </span>
                {changedSinceLock && (
                  <Alert type="info" showIcon message={`总设置里的代码来源已改为 ${code.global?.path}，这个项目已完成，仍用原来的代码文档`} />
                )}
              </Space>
            ) : code.locked ? (
              <Typography.Text className="muted">这个项目没有代码来源，交付包里没有代码文档。</Typography.Text>
            ) : (
              <Typography.Text className="muted">
                总设置里还没有代码来源，交付包只有说明书 3 个文件。<a onClick={() => navigate("settings", "code")}>去设置</a>
              </Typography.Text>
            )}
          </Card>
          {!code.source && oldCodeDoc && !readOnly && (
            <Alert
              type="warning"
              showIcon
              message="现有交付包里有代码文档，但这个项目没有代码来源"
              description={
                request.allowDropCodeDoc
                  ? "已确认：下次生成的交付包不含代码文档，旧交付包会先归档。"
                  : "历史项目的代码文档来自旧 skill 的固定正文。如果这个项目需要重新生成交付包，请选择：改用总设置里的代码来源，或者确认不含代码文档；不选的话生成交付包时会停下来。只是导出或重新导出 PDF 不受影响。"
              }
              action={
                !request.allowDropCodeDoc && (
                  <Space direction="vertical">
                    <Button
                      size="small"
                      disabled={!code.global || running}
                      onClick={async () => {
                        try {
                          await call("action", "useGlobalCodeSource", data.dir);
                          onChanged();
                        } catch (error) {
                          message.error((error as Error).message);
                        }
                      }}
                    >
                      改用总设置的代码来源
                    </Button>
                    <Button size="small" disabled={running} onClick={async () => { await call("action", "updateRequest", data.dir, { allowDropCodeDoc: true }); onChanged(); }}>
                      确认不含代码文档
                    </Button>
                  </Space>
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
              <Space style={{ marginTop: 12 }} wrap>
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
                <Button icon={<FilePdfOutlined />} loading={reexporting} disabled={running} onClick={reexport}>
                  重新导出 PDF
                </Button>
              </Space>
            </>
          ) : (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有交付包" />
          )}
          <Typography.Paragraph className="muted" style={{ marginTop: 12, marginBottom: 0, fontSize: 12 }}>
            溯源：每张截图的线路、模型、生成时间、验收方式、代码来源、修改意见和每次运行的用时，都记录在项目文件夹的{" "}
            <a onClick={() => call("openPath", `${data.dir}/generation-record.json`)}>generation-record.json</a>
            ，构建时汇总写进 project-manifest.json。
          </Typography.Paragraph>
          {build && (
            <Descriptions size="small" column={1} style={{ marginTop: 16 }} bordered>
              <Descriptions.Item label="生成时间">{formatTime(build.at)}</Descriptions.Item>
              <Descriptions.Item label="PDF">{build.withPdf ? `已生成（指南 ${build.pdfPages ?? "?"} 页）` : "没有 LibreOffice，未生成"}</Descriptions.Item>
              {build.pdfFonts &&
                Object.entries(build.pdfFonts).map(([kind, font]) => (
                  <Descriptions.Item key={kind} label={`${FONT_DOC[kind] || kind}字体`}>
                    {font.ok ? <Tag color="green">{font.intended}</Tag> : <Tag color="orange">不对：{font.fonts.join("、") || "未识别"}</Tag>}
                    {font.ok && font.mode === "substitute" && <span className="muted">（代替原版）</span>}
                  </Descriptions.Item>
                ))}
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
