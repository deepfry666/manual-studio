import { useEffect, useMemo, useState } from "react";
import { Alert, App, Button, Dropdown, Input, InputNumber, Modal, Progress, Radio, Select, Space, Table, Tag, Tooltip, Typography } from "antd";
import { CaretRightOutlined, EllipsisOutlined, ExportOutlined, FolderOpenOutlined, PauseOutlined } from "@ant-design/icons";
import { call, formatDuration, formatTime } from "../api";
import { GRADE_LABEL, PROJECT_STATUS, STEP_LABELS, STEP_ORDER, navigate, useDebounced, useLoader, useSettings, useStudioEvents } from "../hooks";
import type { BatchItem, ExportItem, ProjectSummary } from "../types";
import { Page } from "../ui";

const QUEUE_LABEL: Record<string, { label: string; color: string }> = {
  queued: { label: "排队中", color: "default" },
  paused: { label: "已暂停", color: "default" },
};

/** 每秒刷新一次，用来显示「已用时」。 */
function useNow(active: boolean) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [active]);
  return now;
}

function stepSummary(project: ProjectSummary) {
  const done = STEP_ORDER.filter((step) => ["done", "skipped"].includes(project.steps[step])).length;
  const current = STEP_ORDER.find((step) => !["done", "skipped"].includes(project.steps[step]));
  return { done, current };
}

function livePercent(project: ProjectSummary) {
  const live = project.progress;
  if (!live?.step) return 2;
  const index = STEP_ORDER.indexOf(live.step);
  const inside = live.screens && ["images", "gate"].includes(live.step) ? live.screens.finished / Math.max(1, live.screens.total) : 0.3;
  return Math.max(2, Math.min(99, Math.round(((index + inside) / STEP_ORDER.length) * 100)));
}

export function ProjectsPage() {
  const { message, modal } = App.useApp();
  const projects = useLoader(() => call<ProjectSummary[]>("listProjects"));
  const queue = useLoader(() => call<{ items: BatchItem[]; paused: boolean }>("batchList"));
  const settings = useSettings();
  const reload = useDebounced(projects.reload, 800);
  const [pdfJob, setPdfJob] = useState<{ index: number; total: number; current: string | null } | null>(null);
  useStudioEvents((event) => {
    if (["project", "progress", "run-finished"].includes(event.type)) reload();
    if (event.type === "batch") {
      queue.setData({ items: event.items as BatchItem[], paused: Boolean(event.paused) });
      reload();
    }
    if (event.type === "pdf-reexport") setPdfJob(event.current ? { index: Number(event.index), total: Number(event.total), current: String(event.current) } : null);
    if (event.type === "pdf-reexport-done") {
      const failed = (event.failed as string[]) || [];
      const done = (event.done as { warnings: string[] }[]) || [];
      const fontWarnings = done.filter((item) => item.warnings?.length).length;
      if (failed.length || fontWarnings) {
        modal.warning({
          title: `重新导出 PDF：成功 ${done.length} 个${failed.length ? `，失败 ${failed.length} 个` : ""}`,
          content: (
            <div>
              {fontWarnings > 0 && <p>{fontWarnings} 个项目转出来的字体仍然不对，可以在「设置 → PDF 与字体」里换一个替代字体再试。</p>}
              <ul style={{ paddingLeft: 18, maxHeight: 260, overflow: "auto" }}>
                {failed.map((line) => (
                  <li key={line}>{line}</li>
                ))}
              </ul>
            </div>
          ),
        });
      } else message.success(`已重新导出 ${done.length} 个项目的 PDF`);
      reload();
    }
    if (event.type === "run-finished" && event.status === "done") message.success(`「${event.name}」完成，本次用时 ${formatDuration(Number(event.ms))}`);
  });
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [selected, setSelected] = useState<string[]>([]);
  const [exportDirs, setExportDirs] = useState<string[] | null>(null);
  const anyRunning = (projects.data || []).some((project) => project.status === "running");
  const now = useNow(anyRunning);

  const list = projects.data || [];
  const rows = useMemo(() => {
    return list.filter((project) => {
      if (query && !project.name.toLowerCase().includes(query.toLowerCase())) return false;
      if (statusFilter === "all") return true;
      if (statusFilter === "imported") return project.origin === "imported";
      if (statusFilter === "queued") return project.queue?.status === "queued";
      if (statusFilter === "font") return project.pdfFontProblem;
      return project.status === statusFilter;
    });
  }, [list, query, statusFilter]);
  const byDir = new Map(list.map((project) => [project.dir, project]));
  const selectedRows = selected.map((dir) => byDir.get(dir)).filter(Boolean) as ProjectSummary[];

  const start = async () => {
    const dirs = selectedRows.filter((project) => !project.readOnly && project.status !== "running").map((project) => project.dir);
    if (!dirs.length) return message.info("选中的项目都在运行或是只读的");
    await call("batchEnqueue", dirs);
    message.success(`已开始：${dirs.length} 个项目，每次同时处理 ${settings.data?.settings.pipeline.batchConcurrency || 3} 个`);
    setSelected([]);
  };

  const reexportPdf = (dirs: string[]) => {
    const targets = dirs.filter((dir) => byDir.get(dir)?.hasBundle && byDir.get(dir)?.status !== "running");
    if (!targets.length) return message.info("选中的项目没有交付包，或者正在运行");
    modal.confirm({
      title: `重新导出 ${targets.length} 个项目的 PDF？`,
      content: "只用交付包里现有的 Word 重新转 PDF（修正字体），Word、TXT 和截图都不动；旧 PDF 移到项目的 archive 文件夹。每个项目大约 10–40 秒，一个个来。",
      okText: "开始",
      onOk: async () => {
        await call("reexportPdfs", targets);
        setSelected([]);
      },
    });
  };

  return (
    <Page
      title="历史项目"
      bar={
        <>
          <Input.Search allowClear placeholder="按软件名搜索" style={{ width: 240 }} onChange={(event) => setQuery(event.target.value)} />
          <Select
            value={statusFilter}
            onChange={setStatusFilter}
            style={{ width: 150 }}
            options={[
              { value: "all", label: "全部状态" },
              { value: "running", label: "运行中" },
              { value: "queued", label: "排队中" },
              { value: "done", label: "已完成" },
              { value: "waiting", label: "等待确认" },
              { value: "needs-attention", label: "需要处理" },
              { value: "idle", label: "未完成" },
              { value: "font", label: "PDF 字体不对" },
              { value: "imported", label: "导入的历史项目" },
              { value: "readonly", label: "只读" },
            ]}
          />
        </>
      }
      actions={
        selected.length > 0 ? (
          <>
            <span className="muted">已选 {selected.length} 个</span>
            <Button icon={<CaretRightOutlined />} onClick={start}>
              开始处理
            </Button>
            <Button icon={<ExportOutlined />} onClick={() => setExportDirs(selected)}>
              导出…
            </Button>
            <Dropdown
              trigger={["click"]}
              menu={{
                items: [
                  { key: "pdf", label: "重新导出 PDF" },
                  ...(selectedRows.some((project) => project.queue && project.queue.status !== "running") ? [{ key: "dequeue", label: "移出队列" }] : []),
                  { key: "clear", label: "取消选择" },
                ],
                onClick: async ({ key }) => {
                  if (key === "pdf") reexportPdf(selected);
                  if (key === "dequeue") {
                    await call("batchRemoveProjects", selected);
                    message.success("已移出队列");
                  }
                  if (key === "clear") setSelected([]);
                },
              }}
            >
              <Button icon={<EllipsisOutlined />} />
            </Dropdown>
          </>
        ) : (
          <Button
            icon={<ExportOutlined />}
            onClick={() => {
              const dirs = list.filter((project) => project.hasBundle && project.status !== "missing" && (project.status === "done" || project.origin === "imported")).map((project) => project.dir);
              if (!dirs.length) return message.info("还没有已完成的项目");
              setExportDirs(dirs);
            }}
          >
            导出全部已完成
          </Button>
        )
      }
    >
      <SetupHint />
      <QueueBar queue={queue.data} concurrency={settings.data?.settings.pipeline.batchConcurrency || 3} onConcurrency={async (value) => {
        await call("updateSettings", { pipeline: { batchConcurrency: value } });
        settings.reload();
      }} />
      {pdfJob && (
        <Alert style={{ marginBottom: 12 }} type="info" showIcon message={`正在重新导出 PDF：${pdfJob.index + 1}/${pdfJob.total}（${byDir.get(pdfJob.current || "")?.name || ""}）`} />
      )}
      <Table<ProjectSummary>
        rowKey="dir"
        loading={projects.loading}
        dataSource={rows}
        size="middle"
        pagination={{ pageSize: 50, showSizeChanger: false, showTotal: (total) => `共 ${total} 个` }}
        rowSelection={{ selectedRowKeys: selected, onChange: (keys) => setSelected(keys as string[]), preserveSelectedRowKeys: true }}
        onRow={(record) => ({
          onClick: (event) => {
            if ((event.target as HTMLElement).closest(".ant-table-selection-column, .ant-checkbox-wrapper, button, a")) return;
            navigate("project", record.dir);
          },
          style: { cursor: "pointer" },
        })}
        locale={{ emptyText: "还没有项目。在左边「新建项目」里创建；以前用 skill 做过的项目可以在「设置 → 导入历史项目」里接进来。" }}
        columns={[
          {
            title: "软件名",
            dataIndex: "name",
            render: (name: string, record) => (
              <Space direction="vertical" size={2}>
                <Typography.Text strong>{name}</Typography.Text>
                {((record.origin === "imported" && record.grade) || record.feedbackPending > 0 || record.pdfFontProblem) && (
                  <Space size={4} wrap>
                    {record.origin === "imported" && record.grade && <Tag color={GRADE_LABEL[record.grade]?.color}>历史 · {GRADE_LABEL[record.grade]?.label}</Tag>}
                    {record.feedbackPending > 0 && <Tag color="blue">{record.feedbackPending} 条修改意见待处理</Tag>}
                    {record.pdfFontProblem && <Tag color="orange">PDF 字体不对</Tag>}
                  </Space>
                )}
              </Space>
            ),
          },
          {
            title: "状态",
            dataIndex: "status",
            width: 120,
            render: (status: string, record) => {
              if (status !== "running" && record.queue && QUEUE_LABEL[record.queue.status]) {
                const info = QUEUE_LABEL[record.queue.status];
                return <Tag color={info.color}>{info.label}{record.queue.position ? ` #${record.queue.position}` : ""}</Tag>;
              }
              return <Tag color={PROJECT_STATUS[status]?.color}>{PROJECT_STATUS[status]?.label || status}</Tag>;
            },
          },
          {
            title: "进度",
            width: 260,
            render: (_, record) => {
              if (record.readOnly) return <span className="muted">只有交付包，没有源文件</span>;
              const live = record.progress;
              if (record.status === "running" && live) {
                const screens = live.screens && ["images", "gate"].includes(live.step || "") ? ` ${live.screens.finished}/${live.screens.total}` : "";
                return (
                  <div>
                    <Progress percent={livePercent(record)} size="small" showInfo={false} status="active" />
                    <span className="muted" style={{ fontSize: 12 }}>
                      {live.step ? STEP_LABELS[live.step] : "准备中"}
                      {screens} · 已用 {formatDuration(now - live.started)}
                    </span>
                  </div>
                );
              }
              const { done, current } = stepSummary(record);
              return (
                <Tooltip title={record.lastError || record.queue?.error || (current ? `下一步：${STEP_LABELS[current]}` : "全部完成")}>
                  <span className="muted">
                    {done}/{STEP_ORDER.length}
                    {current ? ` · ${STEP_LABELS[current]}` : " · 完成"}
                  </span>
                </Tooltip>
              );
            },
          },
          {
            title: "用时",
            width: 110,
            render: (_, record) => {
              const timing = record.timing;
              if (!timing) return <span className="muted">—</span>;
              const main = timing.completedMs ?? timing.totalMs;
              return (
                <Tooltip title={`${timing.completedMs ? `完成用时 ${formatDuration(timing.completedMs)}` : "还没完成"}；累计 ${formatDuration(timing.totalMs)}${timing.lastMs ? `；最近一次运行 ${formatDuration(timing.lastMs)}` : ""}`}>
                  <span className="stat-number">{formatDuration(main)}</span>
                </Tooltip>
              );
            },
          },
          {
            title: "交付",
            width: 90,
            render: (_, record) => (record.bundleFiles ? `${record.bundleFiles} 个文件` : record.hasBundle ? "有" : <span className="muted">—</span>),
          },
          { title: "最近构建", dataIndex: "lastBuildAt", width: 120, render: (value: string) => formatTime(value) },
          {
            title: "",
            width: 50,
            render: (_, record) => (
              <Tooltip title="在访达中打开">
                <Button type="text" icon={<FolderOpenOutlined />} onClick={() => call("openPath", record.dir)} />
              </Tooltip>
            ),
          },
        ]}
      />
      <ExportModal dirs={exportDirs} lastDir={settings.data?.settings.export?.lastDir || ""} onClose={() => setExportDirs(null)} onDone={() => { setExportDirs(null); setSelected([]); settings.reload(); }} />
    </Page>
  );
}

function QueueBar({ queue, concurrency, onConcurrency }: { queue: { items: BatchItem[]; paused: boolean } | null; concurrency: number; onConcurrency: (value: number) => void }) {
  const items = queue?.items || [];
  const counts = items.reduce<Record<string, number>>((acc, item) => ({ ...acc, [item.status]: (acc[item.status] || 0) + 1 }), {});
  const unfinished = (counts.running || 0) + (counts.queued || 0) + (counts.paused || 0);
  if (!items.length) return null;
  return (
    <div className="queue-bar">
      <Typography.Text strong>批量处理</Typography.Text>
      <span>
        运行中 <b>{counts.running || 0}</b> · 排队 <b>{counts.queued || 0}</b> · 完成 <b>{counts.done || 0}</b>
        {(counts.failed || 0) + (counts["needs-attention"] || 0) > 0 && (
          <Typography.Text type="danger"> · 需处理 {(counts.failed || 0) + (counts["needs-attention"] || 0)}</Typography.Text>
        )}
        {counts.paused ? ` · 已暂停 ${counts.paused}` : ""}
      </span>
      <Space size={6}>
        同时处理
        <InputNumber size="small" min={1} max={8} value={concurrency} onChange={(value) => value && onConcurrency(Number(value))} style={{ width: 60 }} />
        个项目
      </Space>
      <Space style={{ marginLeft: "auto" }}>
        {queue?.paused ? (
          <Button size="small" type="primary" icon={<CaretRightOutlined />} onClick={() => call("batchResume")}>
            继续
          </Button>
        ) : (
          unfinished > 0 && (
            <Button size="small" icon={<PauseOutlined />} onClick={() => call("batchPause")}>
              暂停全部
            </Button>
          )
        )}
        <Button size="small" type="text" onClick={() => call("batchClearFinished")}>
          清除已完成的记录
        </Button>
      </Space>
    </div>
  );
}

function ExportModal({ dirs, lastDir, onClose, onDone }: { dirs: string[] | null; lastDir: string; onClose: () => void; onDone: () => void }) {
  const { message, modal } = App.useApp();
  const [target, setTarget] = useState("");
  const [items, setItems] = useState<ExportItem[] | null>(null);
  const [conflict, setConflict] = useState<"skip" | "overwrite" | null>(null);
  const [busy, setBusy] = useState(false);
  // 多选时放进同一个总文件夹
  const [groupName, setGroupName] = useState("");
  const [resolvedRoot, setResolvedRoot] = useState("");
  const open = Boolean(dirs);
  const multiple = (dirs?.length || 0) > 1;

  const inspect = async (dir: string, group = groupName) => {
    if (!dirs || !dir) return;
    setBusy(true);
    try {
      const plan = await call<{ items: ExportItem[]; targetDir: string }>("planExport", dirs, dir, { groupName: multiple ? group : "" });
      setItems(plan.items);
      setResolvedRoot(plan.targetDir);
      setConflict(null);
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };
  useEffect(() => {
    if (!open) return;
    setTarget(lastDir);
    setItems(null);
    setConflict(null);
    setResolvedRoot("");
    (async () => {
      const name = (dirs?.length || 0) > 1 ? await call<string>("defaultExportGroupName") : "";
      setGroupName(name);
      if (lastDir) inspect(lastDir, name);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const ready = (items || []).filter((item) => item.ok);
  const conflicts = ready.filter((item) => item.conflict);
  const skippedUp = (items || []).filter((item) => !item.ok);

  const run = async () => {
    if (!dirs) return;
    setBusy(true);
    try {
      const result = await call<{ exported: { name: string }[]; skipped: { name: string; reason: string }[]; targetDir: string }>("exportBundles", dirs, target, { conflict: conflict || "skip", groupName: multiple ? groupName : "" });
      onDone();
      modal.success({
        title: `已导出 ${result.exported.length} 个项目`,
        content: (
          <div>
            <p className="mono">{result.targetDir}</p>
            {result.skipped.length > 0 && (
              <>
                <p>跳过 {result.skipped.length} 个：</p>
                <ul style={{ paddingLeft: 18, maxHeight: 220, overflow: "auto" }}>
                  {result.skipped.map((item) => (
                    <li key={item.name}>
                      {item.name}：{item.reason}
                    </li>
                  ))}
                </ul>
              </>
            )}
          </div>
        ),
        okText: "在访达中打开",
        onOk: () => call("openPath", result.targetDir).catch(() => {}),
        closable: true,
      });
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title={`导出交付包（${dirs?.length || 0} 个项目）`}
      open={open}
      width={760}
      onCancel={onClose}
      okText={ready.length ? `导出 ${conflict === "skip" ? ready.length - conflicts.length : ready.length} 个` : "导出"}
      okButtonProps={{ disabled: !target || !ready.length || (multiple && !groupName.trim()) || (conflicts.length > 0 && !conflict) || (conflict === "skip" && ready.length === conflicts.length) }}
      confirmLoading={busy}
      onOk={run}
    >
      <Typography.Paragraph className="muted">每个项目一个文件夹（名字是项目名）{multiple ? "，多选时都放进同一个总文件夹" : ""}。只复制，不改动原项目。</Typography.Paragraph>
      <Space.Compact style={{ width: "100%", marginBottom: 12 }}>
        <Input value={target} readOnly placeholder="选择导出到哪里" />
        <Button
          onClick={async () => {
            const dir = await call<string | null>("chooseDirectory", "选择导出位置", target || undefined);
            if (dir) {
              setTarget(dir);
              inspect(dir);
            }
          }}
        >
          选择…
        </Button>
      </Space.Compact>
      {multiple && (
        <div style={{ marginBottom: 12 }}>
          <Typography.Text>总文件夹名</Typography.Text>
          <Input
            style={{ marginTop: 6 }}
            value={groupName}
            onChange={(event) => setGroupName(event.target.value)}
            onBlur={() => target && inspect(target)}
            onPressEnter={() => target && inspect(target)}
          />
          {resolvedRoot && (
            <Typography.Text className="muted mono" style={{ display: "block", marginTop: 6 }}>
              将导出到：{resolvedRoot}
            </Typography.Text>
          )}
        </div>
      )}
      {conflicts.length > 0 && (
        <Alert
          style={{ marginBottom: 12 }}
          type="warning"
          showIcon
          message={`导出位置已经有 ${conflicts.length} 个同名文件夹：${conflicts.slice(0, 5).map((item) => item.name).join("、")}${conflicts.length > 5 ? " 等" : ""}`}
          description={
            <Radio.Group value={conflict} onChange={(event) => setConflict(event.target.value)}>
              <Space direction="vertical">
                <Radio value="skip">跳过这些项目，已有的文件夹不动</Radio>
                <Radio value="overwrite">覆盖：已有的文件夹先移到废纸篓，再导出新的</Radio>
              </Space>
            </Radio.Group>
          }
        />
      )}
      {items && (
        <Table<ExportItem>
          rowKey="dir"
          size="small"
          dataSource={items}
          pagination={{ pageSize: 8, showSizeChanger: false }}
          columns={[
            { title: "项目", dataIndex: "name" },
            { title: "文件", width: 70, render: (_, item) => (item.ok ? item.files.length : "—") },
            {
              title: "",
              width: 300,
              render: (_, item) =>
                !item.ok ? (
                  <Tag>跳过：{item.reason}</Tag>
                ) : (
                  <Space size={4} wrap>
                    {item.conflict ? <Tag color="orange">已有同名文件夹</Tag> : <Tag color="green">可导出</Tag>}
                    {item.warnings.map((warning) => (
                      <Tooltip key={warning} title={warning}>
                        <Tag color="gold">{warning.length > 14 ? `${warning.slice(0, 14)}…` : warning}</Tag>
                      </Tooltip>
                    ))}
                  </Space>
                ),
            },
          ]}
        />
      )}
      {items && skippedUp.length > 0 && <Typography.Text className="muted">{skippedUp.length} 个项目不会导出（见上表）。</Typography.Text>}
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
  const missing: { text: string; page: string; tab: string }[] = [];
  if (!providers.length) missing.push({ text: "还没有可用的生图线路（需要启用并填好密钥）", page: "models", tab: "providers" });
  if (!assignments.plan || !assignments.content) missing.push({ text: "还没有给「规划界面」和「撰写说明文字」选择大模型", page: "models", tab: "llm" });
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
            <span key={item.tab}>
              {item.text}，<a onClick={() => navigate(item.page, item.tab)}>去配置</a>
            </span>
          ))}
          {!assignments.gate && <span className="muted">截图验收没有配置看图模型时，需要人工逐张确认截图里没有软件名。</span>}
        </Space>
      }
    />
  );
}
