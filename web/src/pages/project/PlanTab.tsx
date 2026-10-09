import { useState } from "react";
import { App, Button, Card, Descriptions, Empty, Form, Input, Modal, Select, Space, Table, Tag, Typography } from "antd";
import { call } from "../../api";
import type { PlanScreen, ProjectDetail } from "../../types";

export function PlanTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message, modal } = App.useApp();
  const [editing, setEditing] = useState<PlanScreen | null>(null);
  const plan = data.plan;
  const waiting = data.state.steps.plan?.status === "review";
  const readOnly = Boolean(data.state.readOnly);

  if (!plan) {
    return (
      <Empty description="还没有界面规划">
        {!readOnly && (
          <Button type="primary" disabled={running} onClick={() => call("run", data.dir, { until: "plan", reviewPlan: true })}>
            开始规划
          </Button>
        )}
      </Empty>
    );
  }

  const replan = () =>
    modal.confirm({
      title: "重新规划？",
      content: "会让大模型重新设计全部界面，之后所有截图都要重新生成，文案也会重写（人工改过的除外）。",
      okText: "重新规划",
      onOk: () => call("run", data.dir, { from: "plan", force: ["plan"], reviewPlan: true }),
    });

  return (
    <Space direction="vertical" size={16} style={{ width: "100%" }}>
      <Card
        size="small"
        title="规划概要"
        extra={
          <Space>
            {waiting && (
              <Button type="primary" disabled={running} onClick={() => call("action", "confirmPlan", data.dir)}>
                确认规划，开始生图
              </Button>
            )}
            {!readOnly && (
              <Button disabled={running} onClick={replan}>
                重新规划
              </Button>
            )}
          </Space>
        }
      >
        <Descriptions size="small" column={1}>
          <Descriptions.Item label="领域">{plan.profile?.domain || "—"}</Descriptions.Item>
          <Descriptions.Item label="目标用户">{plan.profile?.targetUser || "—"}</Descriptions.Item>
          <Descriptions.Item label="核心流程">{plan.profile?.coreFlow || "—"}</Descriptions.Item>
          <Descriptions.Item label="屏数理由">{plan.featureMap?.coverageReason || "—"}</Descriptions.Item>
        </Descriptions>
      </Card>
      {data.state.origin === "imported" && (
        <span className="muted">历史项目：编辑某一屏会按新格式重写它的提示词并重新生图。</span>
      )}
      <Table<PlanScreen>
        rowKey="id"
        size="small"
        pagination={false}
        dataSource={plan.screens}
        columns={[
          { title: "屏", dataIndex: "id", width: 90, render: (id: string) => <span className="mono">{id}</span> },
          { title: "界面标题", dataIndex: "title", width: 160 },
          { title: "应包含", dataIndex: "mustShow", render: (items: string[] = []) => items.map((item) => <Tag key={item}>{item}</Tag>) },
          { title: "示例数据", dataIndex: "sampleData", render: (items: string[] = []) => <Typography.Text className="muted">{items.join("；")}</Typography.Text> },
          {
            title: "",
            width: 80,
            render: (_, screen) => (
              <Button size="small" disabled={running || readOnly} onClick={() => setEditing(screen)}>
                编辑
              </Button>
            ),
          },
        ]}
      />
      <PlanScreenModal
        screen={editing}
        onClose={() => setEditing(null)}
        onSave={async (patch) => {
          try {
            await call("action", "savePlanScreen", data.dir, editing!.id, patch);
            message.success("已保存。这一屏的提示词会更新，下次运行时重新生成这张截图。");
            setEditing(null);
            onChanged();
          } catch (error) {
            message.error((error as Error).message);
          }
        }}
      />
    </Space>
  );
}

function PlanScreenModal({ screen, onClose, onSave }: { screen: PlanScreen | null; onClose: () => void; onSave: (patch: Partial<PlanScreen>) => void }) {
  const [form] = Form.useForm();
  return (
    <Modal
      title={screen ? `编辑 ${screen.id}` : ""}
      open={Boolean(screen)}
      width={720}
      onCancel={onClose}
      onOk={async () => onSave(await form.validateFields())}
      destroyOnHidden
      afterOpenChange={(open) => open && screen && form.setFieldsValue(screen)}
    >
      <Form form={form} layout="vertical" preserve={false}>
        <Form.Item name="title" label="界面标题（也是图注）" rules={[{ required: true }]}>
          <Input maxLength={20} />
        </Form.Item>
        <Form.Item name="mustShow" label="应包含的内容">
          <Select mode="tags" />
        </Form.Item>
        <Form.Item name="sampleData" label="示例数据（截图里的具体数值）">
          <Select mode="tags" />
        </Form.Item>
        <Form.Item name="activeTab" label="底部导航选中项（留空表示隐藏底部导航）">
          <Input allowClear />
        </Form.Item>
        <Form.Item name="visualBrief" label="画面描述（英文，给生图模型看）">
          <Input.TextArea rows={6} />
        </Form.Item>
        <Space.Compact block>
          <Form.Item name={["textContract", "entry"]} label="入口" style={{ flex: 1 }}>
            <Input />
          </Form.Item>
          <Form.Item name={["textContract", "action"]} label="操作" style={{ flex: 1 }}>
            <Input />
          </Form.Item>
        </Space.Compact>
        <Space.Compact block>
          <Form.Item name={["textContract", "feedback"]} label="反馈" style={{ flex: 1 }}>
            <Input />
          </Form.Item>
          <Form.Item name={["textContract", "exception"]} label="异常" style={{ flex: 1 }}>
            <Input />
          </Form.Item>
          <Form.Item name={["textContract", "exit"]} label="去向" style={{ flex: 1 }}>
            <Input />
          </Form.Item>
        </Space.Compact>
      </Form>
    </Modal>
  );
}
