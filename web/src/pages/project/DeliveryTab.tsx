import { useEffect, useState } from "react";
import { App, Button, Col, Empty, Input, Row as GridRow, Space } from "antd";
import { BuildOutlined, FilePdfOutlined, FileZipOutlined, FolderOpenOutlined } from "@ant-design/icons";
import { call, formatTime } from "../../api";
import { navigate, useSettings } from "../../hooks";
import { PathText, Row, Section, Status } from "../../ui";
import type { ProjectDetail } from "../../types";

const TXT_FIELD_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发操作系统",
  devTools: "开发环境 / 开发工具",
  runPlatform: "运行平台 / 操作系统",
  runSupport: "运行支撑环境 / 支持软件",
  language: "编程语言",
};

const FONT_DOC: Record<string, string> = { guide: "说明书 PDF", code: "代码文档 PDF" };

export function DeliveryTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message, modal } = App.useApp();
  const settings = useSettings();
  const request = data.state.request;
  const readOnly = Boolean(data.state.readOnly);
  const build = data.state.lastBuild;
  const code = data.codeSource;
  const oldCodeDoc = data.bundleFiles.some((file) => file.includes("_代码-（JAVA）"));
  const [txt, setTxt] = useState<Record<string, string>>({});
  useEffect(() => setTxt(request.txtFields || {}), [request.txtFields]);

  const saveTxt = async (key: string) => {
    const next = { ...(request.txtFields || {}), [key]: txt[key] || "" };
    const cleaned = Object.fromEntries(Object.entries(next).filter(([, value]) => typeof value === "string" && value.trim()));
    if (JSON.stringify(cleaned) === JSON.stringify(request.txtFields || {})) return;
    await call("action", "updateRequest", data.dir, { txtFields: Object.keys(cleaned).length ? cleaned : null });
    onChanged();
  };

  const reexport = () =>
    modal.confirm({
      title: "只重新导出 PDF？",
      content: "Word、TXT 和截图都不动，旧 PDF 移到项目的 archive 文件夹。",
      okText: "重新导出",
      onOk: async () => {
        await call("reexportPdfs", [data.dir]);
        message.info("已开始重新导出 PDF");
      },
    });

  return (
    <GridRow gutter={20}>
      <Col span={13}>
        <Section
          title="交付文件"
          extra={
            !readOnly && (
              <Button size="small" type="primary" icon={<BuildOutlined />} disabled={running} onClick={() => call("run", data.dir)}>
                生成 / 更新
              </Button>
            )
          }
          footer={
            <span>
              来源和每次修改都记在 <a onClick={() => call("openPath", `${data.dir}/generation-record.json`)}>generation-record.json</a>
            </span>
          }
        >
          {data.bundleFiles.length ? (
            data.bundleFiles.map((file) => (
              <Row key={file} label={<span className="ellipsis-line">{file}</span>}>
                <Button size="small" type="text" onClick={() => call("openPath", `${data.bundleDir}/${file}`)}>
                  打开
                </Button>
              </Row>
            ))
          ) : (
            <Empty image={Empty.PRESENTED_IMAGE_SIMPLE} description="还没有交付包" style={{ padding: 16 }} />
          )}
        </Section>
        {data.bundleFiles.length > 0 && (
          <Space wrap style={{ marginBottom: 22 }}>
            <Button icon={<FolderOpenOutlined />} onClick={() => call("openPath", data.bundleDir)}>
              打开文件夹
            </Button>
            <Button
              icon={<FileZipOutlined />}
              onClick={async () => {
                const target = await call<string>("zipBundle", data.dir);
                call("showInFolder", target);
              }}
            >
              打包 zip
            </Button>
            <Button icon={<FilePdfOutlined />} disabled={running} onClick={reexport}>
              重新导出 PDF
            </Button>
          </Space>
        )}
        {build && (
          <Section title="上次生成">
            <Row label="时间">{formatTime(build.at)}</Row>
            <Row label="PDF">{build.withPdf ? `说明书 ${build.pdfPages ?? "?"} 页` : <Status tone="warn">未生成（没有 LibreOffice）</Status>}</Row>
            {build.pdfFonts &&
              Object.entries(build.pdfFonts).map(([kind, font]) => (
                <Row key={kind} label={`${FONT_DOC[kind] || kind}字体`} info={font.fonts.join("、")}>
                  {font.ok ? <Status tone="ok">{font.intended}{font.mode === "substitute" ? "（替代）" : ""}</Status> : <Status tone="error">字体不对</Status>}
                </Row>
              ))}
            <Row label="代码文档">{build.withCode && build.code ? `${build.code.fileCount} 个文件，${build.code.lineCount.toLocaleString()} 行` : "没有"}</Row>
            {build.warnings?.length > 0 && <Row label="提醒" hint={build.warnings.join("；")} />}
          </Section>
        )}
      </Col>
      <Col span={11}>
        <Section title="代码来源" extra={<Button size="small" type="text" onClick={() => navigate("settings", "code")}>设置</Button>}>
          <Row label="源码" info={code.locked ? "第一次生成交付包时已记下，以后改设置不影响这个项目。" : "来自设置；第一次生成交付包时记下来。"}>
            <PathText path={code.source?.path} empty="没有" />
          </Row>
          {!code.source && oldCodeDoc && !readOnly && !request.allowDropCodeDoc && (
            <Row label="旧代码文档" hint="重新生成交付包前要选一个">
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
                用设置里的
              </Button>
              <Button size="small" type="text" disabled={running} onClick={async () => { await call("action", "updateRequest", data.dir, { allowDropCodeDoc: true }); onChanged(); }}>
                不要代码文档
              </Button>
            </Row>
          )}
        </Section>
        <Section title="TXT 字段" footer="只对这个项目生效，留空用设置里的默认值。">
          {Object.entries(TXT_FIELD_LABELS).map(([key, label]) => (
            <Row key={key} label={label}>
              <Input
                size="small"
                value={txt[key] ?? ""}
                placeholder={settings.data?.settings.txtFields[key] || ""}
                disabled={readOnly || running}
                onChange={(event) => setTxt({ ...txt, [key]: event.target.value })}
                onBlur={() => saveTxt(key)}
                style={{ width: 220 }}
              />
            </Row>
          ))}
        </Section>
      </Col>
    </GridRow>
  );
}
