import { App, Button, Space, Table, Tag, Typography } from "antd";
import { CaretRightOutlined, PauseOutlined } from "@ant-design/icons";
import { basename, call, formatTime } from "../api";
import { navigate, useLoader, useStudioEvents } from "../hooks";
import type { BatchItem } from "../types";

const STATUS: Record<BatchItem["status"], { label: string; color: string }> = {
  queued: { label: "排队中", color: "default" },
  running: { label: "运行中", color: "processing" },
  done: { label: "完成", color: "success" },
  failed: { label: "失败", color: "error" },
  "needs-attention": { label: "等待处理", color: "warning" },
  paused: { label: "已暂停", color: "default" },
};

export function BatchPage() {
  const { message } = App.useApp();
  const queue = useLoader(() => call<{ items: BatchItem[]; paused: boolean }>("batchList"));
  useStudioEvents((event) => {
    if (event.type === "batch") queue.setData({ items: event.items as BatchItem[], paused: Boolean(event.paused) });
  });
  const items = queue.data?.items || [];
  const counts = items.reduce<Record<string, number>>((acc, item) => ({ ...acc, [item.status]: (acc[item.status] || 0) + 1 }), {});

  return (
    <div className="page">
      <div className="page-header">
        <h2>批量队列</h2>
        <Space>
          {queue.data?.paused ? (
            <Button type="primary" icon={<CaretRightOutlined />} onClick={() => call("batchResume")}>
              继续
            </Button>
          ) : (
            <Button icon={<PauseOutlined />} onClick={() => call("batchPause")}>
              暂停全部
            </Button>
          )}
          <Button
            onClick={async () => {
              await call("batchClearFinished");
              message.success("已清除完成的项目");
            }}
          >
            清除已完成
          </Button>
        </Space>
      </div>
      <Typography.Paragraph className="muted">
        批量项目跳过「规划确认」，直接跑到交付包。项目并发数在「设置」里调整；生图并发由「生图线路」控制。软件中途关闭，下次打开会自动续跑。
        {items.length > 0 && ` 共 ${items.length} 个：完成 ${counts.done || 0}，运行中 ${counts.running || 0}，排队 ${counts.queued || 0}，需处理 ${(counts.failed || 0) + (counts["needs-attention"] || 0)}。`}
      </Typography.Paragraph>
      <Table<BatchItem>
        rowKey="id"
        size="middle"
        loading={queue.loading}
        dataSource={items}
        pagination={{ pageSize: 50, showSizeChanger: false }}
        locale={{ emptyText: "队列是空的。在「项目」页勾选项目后点「加入批量队列」，或者用「批量新建」。" }}
        columns={[
          { title: "项目", dataIndex: "projectDir", render: (dir: string) => <a onClick={() => navigate("project", dir)}>{basename(dir)}</a> },
          { title: "状态", dataIndex: "status", width: 110, render: (status: BatchItem["status"]) => <Tag color={STATUS[status]?.color}>{STATUS[status]?.label}</Tag> },
          { title: "说明", dataIndex: "error", render: (error: string | null) => (error ? <Typography.Text type="danger" ellipsis={{ tooltip: error }} style={{ maxWidth: 420 }}>{error}</Typography.Text> : null) },
          { title: "开始", dataIndex: "startedAt", width: 120, render: formatTime },
          { title: "结束", dataIndex: "finishedAt", width: 120, render: formatTime },
          {
            title: "",
            width: 140,
            render: (_, item) => (
              <Space>
                {["failed", "needs-attention", "paused"].includes(item.status) && (
                  <Button size="small" onClick={() => call("batchRetry", item.id)}>
                    重试
                  </Button>
                )}
                <Button size="small" type="text" danger onClick={() => call("batchRemove", item.id)}>
                  移除
                </Button>
              </Space>
            ),
          },
        ]}
      />
    </div>
  );
}
