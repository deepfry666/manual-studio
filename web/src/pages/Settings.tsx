import { useEffect, useState } from "react";
import { App, Button, Input, InputNumber, Select, Space, Switch, Table, Tabs, Tag } from "antd";
import { call, formatTime } from "../api";
import { GRADE_LABEL, navigate, useLoader, useSettings } from "../hooks";
import { PathText, Row, Section, Status } from "../ui";
import type { FontStatus, Settings } from "../types";

const TXT_LABELS: Record<string, string> = {
  devHardware: "开发的硬件环境",
  runHardware: "运行的硬件环境",
  devOs: "开发操作系统",
  devTools: "开发环境 / 开发工具",
  runPlatform: "运行平台 / 操作系统",
  runSupport: "运行支撑环境 / 支持软件",
  language: "编程语言",
};

const CODE_EXTENSIONS = [".java", ".kt", ".swift", ".dart", ".js", ".ts", ".vue", ".py", ".go", ".cs"];
const PLATFORMS = [
  { value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" },
  { value: "Android 手机（原生 Android 界面）", label: "Android 手机" },
];

export function SettingsPage({ tab }: { tab?: string }) {
  const active = ["general", "code", "pdf", "import", "txt"].includes(tab || "") ? (tab as string) : "general";
  return (
    <div className="page" style={{ maxWidth: 860 }}>
      <div className="page-header">
        <h2>设置</h2>
      </div>
      <Tabs
        activeKey={active}
        onChange={(key) => navigate("settings", key)}
        items={[
          { key: "general", label: "通用", children: <GeneralSettings /> },
          { key: "code", label: "代码来源", children: <CodeSourceSettings /> },
          { key: "pdf", label: "PDF 与字体", children: <PdfSettings /> },
          { key: "txt", label: "TXT 字段", children: <TxtSettings /> },
          { key: "import", label: "导入历史项目", children: <ImportPanel /> },
        ]}
      />
    </div>
  );
}

/** 改了就保存（macOS 设置没有「保存」按钮）。 */
function useSave() {
  const settings = useSettings();
  const { message } = App.useApp();
  const save = async (patch: Record<string, unknown>) => {
    try {
      await call("updateSettings", patch);
      settings.reload();
    } catch (error) {
      message.error((error as Error).message);
    }
  };
  return { settings, data: settings.data?.settings as Settings | undefined, save };
}

function GeneralSettings() {
  const { data, save } = useSave();
  const libre = useLoader(() => call<{ path: string | null }>("libreOfficeStatus"));
  const info = useLoader(() => call<{ version: string; dataDir: string }>("appInfo"));
  if (!data) return null;
  const pipeline = data.pipeline;
  return (
    <>
      <Section title="位置">
        <Row label="项目存放位置" info="新建的项目都放在这里，和以前 skill 用的是同一个文件夹。">
          <PathText path={data.workspaceDir} />
          <Button
            size="small"
            onClick={async () => {
              const dir = await call<string | null>("chooseDirectory", "选择项目存放位置", data.workspaceDir);
              if (dir) save({ workspaceDir: dir });
            }}
          >
            更改…
          </Button>
        </Row>
        <Row label="软件数据" info="设置、加密的密钥、调用记录和项目状态。">
          <PathText path={info.data?.dataDir} />
        </Row>
      </Section>

      <Section title="生成">
        <Row label="规划确认" hint="规划完先停下，让我检查后再继续">
          <Switch checked={pipeline.reviewPlanSingle} onChange={(value) => save({ pipeline: { reviewPlanSingle: value } })} />
        </Row>
        <Row label="批量同时处理" info="比如 50 个项目设 3：3 个同时跑，跑完一个补一个。生图总并发由生图线路控制，调大这里不会把线路挤爆。">
          <InputNumber min={1} max={8} value={pipeline.batchConcurrency} onChange={(value) => value && save({ pipeline: { batchConcurrency: value } })} addonAfter="个项目" style={{ width: 130 }} />
        </Row>
        <Row label="默认屏数">
          <InputNumber min={2} max={15} value={pipeline.defaultScreenCount} onChange={(value) => value && save({ pipeline: { defaultScreenCount: value } })} addonAfter="屏" style={{ width: 110 }} />
        </Row>
        <Row label="默认平台">
          <Select value={pipeline.platform} options={PLATFORMS} onChange={(value) => save({ pipeline: { platform: value } })} style={{ width: 260 }} />
        </Row>
        <Row label="每屏说明最少字数" info="按普通字符串长度计。排版模板要求至少 300。">
          <InputNumber min={300} max={1000} value={pipeline.featureTextFloor} onChange={(value) => value && save({ pipeline: { featureTextFloor: value } })} style={{ width: 110 }} />
        </Row>
      </Section>

      <Section title="PDF">
        <Row label="LibreOffice" info={libre.data?.path || "没有找到 LibreOffice，交付包里不会有 PDF"}>
          {libre.loading ? <Status tone="idle">检测中</Status> : libre.data?.path ? <Status tone="ok">已就绪</Status> : <Status tone="error">未找到</Status>}
          <Button size="small" type="text" onClick={libre.reload}>
            重新检测
          </Button>
        </Row>
      </Section>
    </>
  );
}

interface CodeInfo {
  fileCount: number;
  lineCount: number;
  nonEmptyLines: number;
  estimatedPages: number;
  warnings: string[];
}

function CodeSourceSettings() {
  const { data, save } = useSave();
  const [info, setInfo] = useState<CodeInfo | null>(null);
  const source = data?.codeSource || { path: "", extensions: [".java"] };
  useEffect(() => {
    if (!source.path) return setInfo(null);
    call<CodeInfo>("inspectCodeSource", { path: source.path, extensions: source.extensions }).then(setInfo, () => setInfo(null));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [source.path, JSON.stringify(source.extensions)]);
  if (!data) return null;
  return (
    <>
      <Section title="代码来源" footer="所有项目共用。项目第一次生成交付包时会记下当时的来源，之后修改不影响已完成的项目。">
        <Row label="源码" info="文件夹或单个文件。按文件路径排序后原样排版，不改写、不生成。不设置时交付包只有说明书 3 个文件。">
          <PathText path={source.path} />
          <Button
            size="small"
            onClick={async () => {
              const picked = await call<string | null>("choosePath", "选择源码文件夹或文件", source.path || undefined);
              if (picked) save({ codeSource: { ...source, path: picked } });
            }}
          >
            选择…
          </Button>
          {source.path && (
            <Button size="small" type="text" danger onClick={() => save({ codeSource: { ...source, path: "" } })}>
              清除
            </Button>
          )}
        </Row>
        <Row label="文件类型">
          <Select mode="tags" value={source.extensions} onChange={(value: string[]) => save({ codeSource: { ...source, extensions: value } })} options={CODE_EXTENSIONS.map((value) => ({ value, label: value }))} style={{ width: 300 }} />
        </Row>
        <Row label="跳过的文件夹">
          <Select mode="tags" maxTagCount="responsive" value={data.codeDefaults.excludeDirs} onChange={(value: string[]) => save({ codeDefaults: { excludeDirs: value } })} style={{ width: 300 }} />
        </Row>
      </Section>
      {info && (
        <Section title="统计">
          <Row label="文件">{info.fileCount} 个</Row>
          <Row label="行数">{info.lineCount.toLocaleString()} 行</Row>
          <Row label="代码文档" info="按新宋体 9 号字估算，用替代字体时页数会有出入。">约 {info.estimatedPages} 页</Row>
          {info.warnings.length > 0 && <Row label="提醒" hint={info.warnings.join("；")} />}
        </Section>
      )}
    </>
  );
}

function PdfSettings() {
  const { save } = useSave();
  const fonts = useLoader(() => call<FontStatus>("fontStatus"));
  const { message } = App.useApp();
  const [installing, setInstalling] = useState(false);
  const docs = fonts.data?.docs || {};
  return (
    <>
      <Section
        title="字体"
        extra={
          <Button size="small" type="text" onClick={fonts.reload}>
            重新检测
          </Button>
        }
        footer="没装原版字体时固定换成下面的系统字体，转完自动核对 PDF 里实际用的字体。"
      >
        {Object.entries(docs).map(([kind, doc]) => (
          <Row key={kind} label={doc.label} hint={`模板字体：${doc.original}`}>
            {doc.installed ? (
              <Status tone="ok">使用原版</Status>
            ) : (
              <>
                <Status tone="warn">未安装原版，改用</Status>
                <Select
                  value={doc.choice}
                  options={doc.choices.map((choice) => ({ ...choice, label: choice.label.replace(/（.*）/, "") }))}
                  onChange={async (value) => {
                    await save({ pdf: { [kind]: value } });
                    fonts.reload();
                  }}
                  style={{ width: 150 }}
                />
              </>
            )}
          </Row>
        ))}
      </Section>
      <Section title="原版字体">
        <Row label="安装字体文件" info="微软雅黑 msyh.ttc、msyhbd.ttc，新宋体在 simsun.ttc 里，Windows 的 C:\Windows\Fonts 里都有。微软商业字体，软件不能自带。装好后 PDF 和 Word 完全一致（包括代码文档页数）。">
          <Button
            size="small"
            loading={installing}
            onClick={async () => {
              setInstalling(true);
              try {
                const result = await call<{ installed: string[]; skipped: string[] } | null>("installFonts");
                if (!result) return;
                if (result.installed.length) message.success(`已安装 ${result.installed.length} 个字体`);
                if (result.skipped.length) message.warning(result.skipped.join("；"));
                fonts.reload();
              } finally {
                setInstalling(false);
              }
            }}
          >
            选择文件…
          </Button>
        </Row>
        <Row label="已做好的项目" hint="在历史项目里勾选，点「重新导出 PDF」">
          <Button size="small" onClick={() => navigate("projects")}>
            前往
          </Button>
        </Row>
      </Section>
    </>
  );
}

function TxtSettings() {
  const { data, save } = useSave();
  const [draft, setDraft] = useState<Record<string, string>>({});
  useEffect(() => {
    if (data) setDraft(data.txtFields);
  }, [data]);
  if (!data) return null;
  return (
    <Section title="TXT 环境字段" footer="默认值和旧 skill 模板一致。【源程序量】按代码来源的实际行数统计；有代码来源时【编程语言】自动判断。">
      {Object.entries(TXT_LABELS).map(([key, label]) => (
        <Row key={key} label={label}>
          <Input
            value={draft[key] ?? ""}
            onChange={(event) => setDraft({ ...draft, [key]: event.target.value })}
            onBlur={() => draft[key] !== data.txtFields[key] && save({ txtFields: { [key]: draft[key] } })}
            style={{ width: 340 }}
          />
        </Row>
      ))}
    </Section>
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
        title: `导入了 ${result.imported.length} 个项目`,
        content: result.failed.length ? (
          <ul style={{ paddingLeft: 18 }}>
            {result.failed.map((line) => (
              <li key={line}>{line}</li>
            ))}
          </ul>
        ) : (
          "只是登记，没有改动项目文件夹里的任何文件。"
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
      <div className="mac-section-head" style={{ paddingInline: 0 }}>
        <span>工作区里旧 skill 做过的项目（只登记，不改动文件）</span>
        <Space>
          <Button
            size="small"
            onClick={async () => {
              const dir = await call<string | null>("chooseDirectory", "选择要扫描的文件夹");
              if (dir) scan(dir);
            }}
          >
            换个文件夹…
          </Button>
          <Button size="small" type="primary" loading={busy} disabled={!selected.length} onClick={importSelected}>
            导入 {selected.length} 个
          </Button>
        </Space>
      </div>
      <Table<ScanRow>
        rowKey="dir"
        size="small"
        loading={scanning}
        dataSource={rows || []}
        pagination={{ pageSize: 12, showSizeChanger: false, showTotal: (total) => `共 ${total} 个` }}
        rowSelection={{ selectedRowKeys: selected, onChange: (keys) => setSelected(keys as string[]), getCheckboxProps: (row) => ({ disabled: row.managed }) }}
        columns={[
          { title: "软件名", dataIndex: "name", ellipsis: true },
          { title: "状态", dataIndex: "grade", width: 120, render: (grade: string, row) => (row.managed ? <Tag>已导入</Tag> : <Tag color={GRADE_LABEL[grade]?.color}>{GRADE_LABEL[grade]?.label}</Tag>) },
          { title: "截图", dataIndex: "screens", width: 60 },
          { title: "修改时间", dataIndex: "mtime", width: 120, render: (value: number) => formatTime(new Date(value).toISOString()) },
        ]}
      />
    </div>
  );
}
