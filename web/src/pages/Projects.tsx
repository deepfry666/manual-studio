import { useMemo, useState } from "react";
import { Alert, App, Button, Checkbox, Form, Input, InputNumber, Modal, Radio, Select, Space, Switch, Table, Tag, Tooltip, Typography } from "antd";
import { FolderOpenOutlined, ImportOutlined, PlusOutlined, UnorderedListOutlined } from "@ant-design/icons";
import { call, formatTime } from "../api";
import { GRADE_LABEL, PROJECT_STATUS, STEP_LABELS, STEP_ORDER, navigate, useDebounced, useLoader, useSettings, useStudioEvents } from "../hooks";
import type { ProjectSummary } from "../types";

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

function stepProgress(project: ProjectSummary) {
  const done = STEP_ORDER.filter((step) => ["done", "skipped"].includes(project.steps[step])).length;
  const current = STEP_ORDER.find((step) => !["done", "skipped"].includes(project.steps[step]));
  return { done, current };
}

export function ProjectsPage() {
  const { message, modal } = App.useApp();
  const projects = useLoader(() => call<ProjectSummary[]>("listProjects"));
  const settings = useSettings();
  const reload = useDebounced(projects.reload, 1200);
  useStudioEvents((event) => {
    if (event.type === "project" || event.type === "batch") reload();
  });
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [selected, setSelected] = useState<string[]>([]);
  const [createOpen, setCreateOpen] = useState(false);
  const [csvOpen, setCsvOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);

  const rows = useMemo(() => {
    const list = projects.data || [];
    return list.filter((project) => {
      if (query && !project.name.toLowerCase().includes(query.toLowerCase())) return false;
      if (statusFilter === "all") return true;
      if (statusFilter === "imported") return project.origin === "imported";
      return project.status === statusFilter;
    });
  }, [projects.data, query, statusFilter]);

  const enqueue = async () => {
    const dirs = selected.filter((dir) => !(projects.data || []).find((project) => project.dir === dir)?.readOnly);
    await call("batchEnqueue", dirs);
    message.success(`已加入批量队列：${dirs.length} 个项目`);
    setSelected([]);
    navigate("batch");
  };

  return (
    <div className="page">
      <div className="page-header">
        <h2>项目</h2>
        <Space>
          <Button icon={<ImportOutlined />} onClick={() => setImportOpen(true)}>
            导入历史项目
          </Button>
          <Button icon={<UnorderedListOutlined />} onClick={() => setCsvOpen(true)}>
            批量新建
          </Button>
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setCreateOpen(true)}>
            新建项目
          </Button>
        </Space>
      </div>
      <SetupHint />
      <Space style={{ marginBottom: 12 }} wrap>
        <Input.Search allowClear placeholder="按软件名搜索" style={{ width: 260 }} onChange={(event) => setQuery(event.target.value)} />
        <Select
          value={statusFilter}
          onChange={setStatusFilter}
          style={{ width: 160 }}
          options={[
            { value: "all", label: "全部状态" },
            { value: "done", label: "已完成" },
            { value: "running", label: "运行中" },
            { value: "waiting", label: "等待确认" },
            { value: "needs-attention", label: "需要处理" },
            { value: "idle", label: "未完成" },
            { value: "imported", label: "导入的历史项目" },
          ]}
        />
        {selected.length > 0 && (
          <Button onClick={enqueue} type="primary" ghost>
            把选中的 {selected.length} 个项目加入批量队列
          </Button>
        )}
      </Space>
      <Table<ProjectSummary>
        rowKey="dir"
        loading={projects.loading}
        dataSource={rows}
        size="middle"
        pagination={{ pageSize: 50, showSizeChanger: false, showTotal: (total) => `共 ${total} 个` }}
        rowSelection={{ selectedRowKeys: selected, onChange: (keys) => setSelected(keys as string[]), getCheckboxProps: (record) => ({ disabled: record.readOnly }) }}
        onRow={(record) => ({
          onClick: (event) => {
            // 点复选框只做勾选，不进入详情
            if ((event.target as HTMLElement).closest(".ant-table-selection-column, .ant-checkbox-wrapper")) return;
            navigate("project", record.dir);
          },
          style: { cursor: "pointer" },
        })}
        locale={{ emptyText: "还没有项目。点右上角「新建项目」，或者「导入历史项目」把 skill 做过的项目接进来。" }}
        columns={[
          {
            title: "软件名",
            dataIndex: "name",
            render: (name: string, record) => (
              <Space direction="vertical" size={0}>
                <Typography.Text strong>{name}</Typography.Text>
                <Space size={4}>
                  {record.origin === "imported" && record.grade && <Tag color={GRADE_LABEL[record.grade]?.color}>历史 · {GRADE_LABEL[record.grade]?.label}</Tag>}
                  {!record.hasCodeSource && !record.readOnly && <Tag>未指定代码来源</Tag>}
                </Space>
              </Space>
            ),
          },
          {
            title: "状态",
            dataIndex: "status",
            width: 120,
            render: (status: string) => <Tag color={PROJECT_STATUS[status]?.color}>{PROJECT_STATUS[status]?.label || status}</Tag>,
          },
          {
            title: "进度",
            width: 220,
            render: (_, record) => {
              const { done, current } = stepProgress(record);
              return (
                <Tooltip title={record.lastError || (current ? `下一步：${STEP_LABELS[current]}` : "全部完成")}>
                  <span className="muted">
                    {done}/{STEP_ORDER.length}
                    {current ? ` · ${STEP_LABELS[current]}` : " · 完成"}
                  </span>
                </Tooltip>
              );
            },
          },
          { title: "截图", dataIndex: "screens", width: 70 },
          { title: "最近构建", dataIndex: "lastBuildAt", width: 130, render: (value: string) => formatTime(value) },
          {
            title: "",
            width: 60,
            render: (_, record) => (
              <Tooltip title="在访达中打开">
                <Button
                  type="text"
                  icon={<FolderOpenOutlined />}
                  onClick={(event) => {
                    event.stopPropagation();
                    call("openPath", record.dir);
                  }}
                />
              </Tooltip>
            ),
          },
        ]}
      />
      <CreateProjectModal
        open={createOpen}
        defaultScreens={settings.data?.settings.pipeline.defaultScreenCount || 7}
        defaultPlatform={settings.data?.settings.pipeline.platform || ""}
        defaultExtensions={settings.data?.settings.codeDefaults.extensions || [".java"]}
        onClose={() => setCreateOpen(false)}
        onCreated={(dir, runNow) => {
          setCreateOpen(false);
          projects.reload();
          if (runNow) call("run", dir);
          navigate("project", dir);
        }}
      />
      <CsvModal
        open={csvOpen}
        onClose={() => setCsvOpen(false)}
        onDone={(created, queue) => {
          setCsvOpen(false);
          projects.reload();
          if (queue && created.length) {
            call("batchEnqueue", created).then(() => navigate("batch"));
          }
        }}
      />
      <ImportModal
        open={importOpen}
        onClose={() => setImportOpen(false)}
        onImported={(result) => {
          setImportOpen(false);
          projects.reload();
          modal.info({
            title: "导入完成",
            content: (
              <div>
                <p>导入了 {result.imported.length} 个项目{result.timings ? `，并导入 ${result.timings} 条历史生图耗时记录（用于计算补发线）` : ""}。</p>
                {result.failed.length > 0 && (
                  <>
                    <p>以下项目没有导入：</p>
                    <ul>
                      {result.failed.map((line) => (
                        <li key={line}>{line}</li>
                      ))}
                    </ul>
                  </>
                )}
                <p className="muted">导入只是登记，不会改动这些项目文件夹里的任何文件。</p>
              </div>
            ),
          });
        }}
      />
    </div>
  );
}

function CreateProjectModal({ open, onClose, onCreated, defaultScreens, defaultPlatform, defaultExtensions }: { open: boolean; onClose: () => void; onCreated: (dir: string, runNow: boolean) => void; defaultScreens: number; defaultPlatform: string; defaultExtensions: string[] }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const [busy, setBusy] = useState(false);
  const [codePath, setCodePath] = useState<string>("");

  const submit = async (runNow: boolean) => {
    const values = await form.validateFields();
    setBusy(true);
    try {
      const dir = await call<string>("createProject", {
        softwareName: values.softwareName.trim(),
        versionPolicy: values.versionPolicy,
        screenCount: values.autoCount ? null : values.screenCount,
        emphasis: values.emphasis || "",
        notes: values.notes || "",
        platform: values.platform || "",
        wantDesign: values.wantDesign,
        codeSource: codePath ? { path: codePath, extensions: values.extensions || [".java"] } : null,
      });
      form.resetFields();
      setCodePath("");
      onCreated(dir, runNow);
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title="新建项目"
      open={open}
      onCancel={onClose}
      width={620}
      footer={[
        <Button key="cancel" onClick={onClose}>
          取消
        </Button>,
        <Button key="create" loading={busy} onClick={() => submit(false)}>
          只创建
        </Button>,
        <Button key="run" type="primary" loading={busy} onClick={() => submit(true)}>
          创建并开始
        </Button>,
      ]}
    >
      <Form form={form} layout="vertical" initialValues={{ versionPolicy: "in-name", screenCount: defaultScreens, autoCount: true, wantDesign: false, extensions: defaultExtensions, platform: defaultPlatform }}>
        <Form.Item name="softwareName" label="软件名（含版本号，按原样填写）" rules={[{ required: true, message: "请填写软件名" }]} extra="软件名只用于文件名、文档标题和页眉，截图界面里不会出现。">
          <Input placeholder="例如：云伴日程 V1.0" />
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
        <Form.Item name="platform" label="平台">
          <Select options={[{ value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" }, { value: "Android 手机（原生 Android 界面）", label: "Android 手机" }]} />
        </Form.Item>
        <Form.Item name="versionPolicy" label="版本号处理">
          <Radio.Group
            options={[
              { value: "in-name", label: "版本号是软件名的一部分" },
              { value: "none", label: "没有版本号" },
            ]}
          />
        </Form.Item>
        <Form.Item label="代码来源（可选，用于生成代码文档）" extra="选择这个软件自己的源码文件夹或文件。不指定则不生成代码文档，以后也可以在项目的「交付」里补上。">
          <Space.Compact style={{ width: "100%" }}>
            <Input value={codePath} placeholder="未指定" readOnly />
            <Button
              onClick={async () => {
                const picked = await call<string | null>("choosePath", "选择代码来源");
                if (picked) setCodePath(picked);
              }}
            >
              选择…
            </Button>
            {codePath && <Button onClick={() => setCodePath("")}>清除</Button>}
          </Space.Compact>
        </Form.Item>
        {codePath && (
          <Form.Item name="extensions" label="代码文件类型">
            <Select mode="tags" options={[".java", ".kt", ".swift", ".dart", ".js", ".ts", ".vue", ".py", ".go", ".cs"].map((value) => ({ value, label: value }))} />
          </Form.Item>
        )}
        <Form.Item name="wantDesign" label="附加软件设计说明章节" valuePropName="checked">
          <Switch />
        </Form.Item>
      </Form>
    </Modal>
  );
}

function CsvModal({ open, onClose, onDone }: { open: boolean; onClose: () => void; onDone: (created: string[], queue: boolean) => void }) {
  const { message } = App.useApp();
  const [text, setText] = useState("");
  const [queue, setQueue] = useState(true);
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true);
    try {
      const result = await call<{ created: string[]; errors: string[] }>("createProjectsFromCsv", text, {});
      if (result.errors.length) message.warning(`有 ${result.errors.length} 行没有创建：${result.errors.slice(0, 3).join("；")}`);
      message.success(`已创建 ${result.created.length} 个项目`);
      setText("");
      onDone(result.created, queue);
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <Modal title="批量新建项目" open={open} onCancel={onClose} onOk={submit} okText="创建" confirmLoading={busy} width={680}>
      <Typography.Paragraph className="muted">
        每行一个项目，用逗号分隔：<b>软件名,截图数,重点功能,代码来源路径,版本处理</b>。只有软件名必填，其余可以留空。第一行如果是表头会自动跳过。
      </Typography.Paragraph>
      <Space style={{ marginBottom: 8 }}>
        <Button
          onClick={async () => {
            const content = await call<string | null>("chooseTextFile", "选择 CSV 文件");
            if (content) setText(content);
          }}
        >
          从文件读取…
        </Button>
        <Checkbox checked={queue} onChange={(event) => setQueue(event.target.checked)}>
          创建后直接加入批量队列
        </Checkbox>
      </Space>
      <Input.TextArea rows={12} value={text} onChange={(event) => setText(event.target.value)} placeholder={"软件名,截图数,重点功能,代码来源路径,版本处理\n云伴日程 V1.0,7,日程提醒,,in-name\n快记账本 V1.0,,预算提醒,/Users/me/code/kuaijizhang,"} className="mono" />
    </Modal>
  );
}

function ImportModal({ open, onClose, onImported }: { open: boolean; onClose: () => void; onImported: (result: { imported: string[]; failed: string[]; timings: number }) => void }) {
  const { message } = App.useApp();
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

  return (
    <Modal
      title="导入历史项目"
      open={open}
      onCancel={onClose}
      width={860}
      afterOpenChange={(visible) => visible && !rows && scan()}
      okText={`导入 ${selected.length} 个`}
      confirmLoading={busy}
      onOk={async () => {
        setBusy(true);
        try {
          onImported(await call("importProjects", selected));
          setRows(null);
        } catch (error) {
          message.error((error as Error).message);
        } finally {
          setBusy(false);
        }
      }}
    >
      <Typography.Paragraph className="muted">
        扫描工作区里旧 skill 做过的项目。导入只是在本软件里登记，不复制、不改动项目文件夹。代码文档用的是旧 skill 的固定正文，导入后重建需要另外指定代码来源。
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
      </Space>
      <Table<ScanRow>
        rowKey="dir"
        size="small"
        loading={scanning}
        dataSource={rows || []}
        pagination={{ pageSize: 12, showSizeChanger: false, showTotal: (total) => `共 ${total} 个` }}
        rowSelection={{ selectedRowKeys: selected, onChange: (keys) => setSelected(keys as string[]), getCheckboxProps: (row) => ({ disabled: row.managed }) }}
        columns={[
          { title: "软件名", dataIndex: "name" },
          { title: "状态", dataIndex: "grade", width: 130, render: (grade: string, row) => (row.managed ? <Tag>已导入</Tag> : <Tag color={GRADE_LABEL[grade]?.color}>{GRADE_LABEL[grade]?.label}</Tag>) },
          { title: "截图", dataIndex: "screens", width: 60 },
          { title: "交付包", dataIndex: "hasBundle", width: 80, render: (value: boolean) => (value ? "有" : "—") },
          { title: "修改时间", dataIndex: "mtime", width: 130, render: (value: number) => formatTime(new Date(value).toISOString()) },
        ]}
      />
    </Modal>
  );
}

/** 首次使用：没有可用的生图线路或没有给规划/文案选模型时，提示先去配置。 */
function SetupHint() {
  const settings = useSettings();
  const data = settings.data;
  if (!data) return null;
  const providers = data.settings.providers.filter((provider) => provider.enabled && data.providerKeys[provider.id]);
  const assignments = data.settings.llm.assignments;
  const missing: { text: string; page: string }[] = [];
  if (!providers.length) missing.push({ text: "还没有可用的生图线路（需要启用并填好密钥）", page: "providers" });
  if (!assignments.plan || !assignments.content) missing.push({ text: "还没有给「规划界面」和「撰写说明文字」选择大模型", page: "llm" });
  if (!missing.length) return null;
  return (
    <Alert
      style={{ marginBottom: 12 }}
      type="info"
      showIcon
      message="开始之前先完成配置"
      description={
        <Space direction="vertical" size={2}>
          {missing.map((item) => (
            <span key={item.page}>
              {item.text}，<a onClick={() => navigate(item.page)}>去配置</a>
            </span>
          ))}
          {!assignments.gate && <span className="muted">截图验收没有配置看图模型时，需要人工逐张确认截图里没有软件名。</span>}
        </Space>
      }
    />
  );
}
