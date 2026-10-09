import { useEffect, useState } from "react";
import { Alert, App, Button, Card, Checkbox, Collapse, Input, List, Modal, Space, Tag, Typography } from "antd";
import { DeleteOutlined, EditOutlined, MessageOutlined } from "@ant-design/icons";
import { call, formatTime } from "../../api";
import type { FeedbackAction, FeedbackPlan, ProjectDetail } from "../../types";

const ACTION_TYPE: Record<FeedbackAction["type"], { label: string; color: string }> = {
  replan: { label: "重新规划", color: "red" },
  image: { label: "重生截图", color: "blue" },
  text: { label: "重写说明", color: "green" },
  overview: { label: "改封面介绍", color: "cyan" },
  design: { label: "改设计说明", color: "purple" },
};

/**
 * 修改意见：只有一个入口。看到问题就记一条进清单，攒够了点「整理意见」，
 * 软件判断要改哪几张图、哪几段文字，确认后一次改完。
 */
export function FeedbackPanel({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message } = App.useApp();
  const [text, setText] = useState("");
  const [analyzing, setAnalyzing] = useState(false);
  const [plan, setPlan] = useState<FeedbackPlan | null>(null);
  const items = data.state.feedback || [];
  const pending = items.filter((item) => item.status === "pending");
  const done = items.filter((item) => item.status === "done");
  const canAnalyze = Boolean(data.plan);
  const dir = data.dir;

  const add = async () => {
    if (!text.trim()) return;
    try {
      await call("action", "addFeedback", dir, text);
      setText("");
      onChanged();
    } catch (error) {
      message.error((error as Error).message);
    }
  };

  const analyze = async () => {
    setAnalyzing(true);
    try {
      setPlan(await call<FeedbackPlan>("action", "analyzeFeedback", dir));
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setAnalyzing(false);
    }
  };

  return (
    <Card
      size="small"
      style={{ marginBottom: 16 }}
      title={
        <Space>
          <MessageOutlined />
          修改意见
          {pending.length > 0 && <Tag color="blue">{pending.length} 条待处理</Tag>}
        </Space>
      }
      extra={
        <Button type="primary" size="small" disabled={!pending.length || running || !canAnalyze} loading={analyzing} onClick={analyze}>
          整理意见并统一修改{pending.length ? `（${pending.length} 条）` : ""}
        </Button>
      }
    >
      <Space.Compact style={{ width: "100%" }}>
        <Input.TextArea
          value={text}
          onChange={(event) => setText(event.target.value)}
          autoSize={{ minRows: 1, maxRows: 4 }}
          placeholder={canAnalyze ? "例如「图3 按钮改成蓝色」，⌘↩ 加入清单" : "跑出截图后再提修改意见"}
          disabled={!canAnalyze || Boolean(data.state.readOnly)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
              event.preventDefault();
              add();
            }
          }}
        />
        <Button onClick={add} disabled={!text.trim()}>
          加入清单
        </Button>
      </Space.Compact>
      {pending.length > 0 && (
        <List
          className="feedback-list"
          size="small"
          style={{ marginTop: 8 }}
          dataSource={pending}
          renderItem={(item, index) => <PendingItem key={item.id} dir={dir} item={item} index={index} onChanged={onChanged} />}
        />
      )}
      {done.length > 0 && (
        <Collapse
          ghost
          size="small"
          style={{ marginTop: 4 }}
          items={[
            {
              key: "done",
              label: <span className="muted">已处理 {done.length} 条</span>,
              children: (
                <List
                  size="small"
                  dataSource={[...done].reverse()}
                  renderItem={(item) => (
                    <List.Item>
                      <Space direction="vertical" size={0}>
                        <span>{item.text}</span>
                        <span className="muted" style={{ fontSize: 12 }}>
                          {formatTime(item.doneAt)} 已改：{item.appliedAs}
                        </span>
                      </Space>
                    </List.Item>
                  )}
                />
              ),
            },
          ]}
        />
      )}
      <PlanModal dir={dir} plan={plan} pendingTexts={new Map(pending.map((item, index) => [item.id, { n: index + 1, text: item.text }]))} onClose={() => setPlan(null)} onApplied={() => { setPlan(null); onChanged(); }} />
    </Card>
  );
}

function PendingItem({ dir, item, index, onChanged }: { dir: string; item: { id: string; text: string }; index: number; onChanged: () => void }) {
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState(item.text);
  useEffect(() => setValue(item.text), [item.text]);
  return (
    <List.Item
      actions={[
        <Button key="edit" size="small" type="text" icon={<EditOutlined />} onClick={() => setEditing(!editing)} />,
        <Button key="delete" size="small" type="text" danger icon={<DeleteOutlined />} onClick={async () => { await call("action", "removeFeedback", dir, item.id); onChanged(); }} />,
      ]}
    >
      {editing ? (
        <Space.Compact style={{ width: "100%" }}>
          <Input value={value} onChange={(event) => setValue(event.target.value)} />
          <Button
            onClick={async () => {
              await call("action", "editFeedback", dir, item.id, value);
              setEditing(false);
              onChanged();
            }}
          >
            保存
          </Button>
        </Space.Compact>
      ) : (
        <span>
          <span className="muted">{index + 1}.</span> {item.text}
        </span>
      )}
    </List.Item>
  );
}

/** 整理结果：每一项可以取消勾选、改措辞；确认后一次执行。 */
function PlanModal({ dir, plan, pendingTexts, onClose, onApplied }: { dir: string; plan: FeedbackPlan | null; pendingTexts: Map<string, { n: number; text: string }>; onClose: () => void; onApplied: () => void }) {
  const { message } = App.useApp();
  const [actions, setActions] = useState<(FeedbackAction & { checked: boolean })[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    setActions((plan?.actions || []).map((action) => ({ ...action, checked: true })));
  }, [plan]);
  const chosen = actions.filter((action) => action.checked);
  const replan = chosen.some((action) => action.type === "replan");
  const images = replan ? 0 : chosen.filter((action) => action.type === "image").length;
  const texts = replan ? 0 : chosen.filter((action) => action.type === "text").length;
  const extras = chosen.filter((action) => ["overview", "design"].includes(action.type)).map((action) => ACTION_TYPE[action.type].label);
  const summary = replan ? "重新规划：所有截图和说明都会重做（规划完会先停下让你确认）" : [images ? `重生 ${images} 张截图（改过图的屏，说明会按新图重写）` : "", texts ? `重写 ${texts} 屏说明` : "", ...extras].filter(Boolean).join("，");

  const apply = async () => {
    setBusy(true);
    try {
      await call("action", "applyFeedback", dir, { actions: chosen.map(({ checked: _checked, ...action }) => action) });
      message.success("已开始统一修改，进度在页面上方");
      onApplied();
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal
      title="整理结果：确认后统一修改"
      open={Boolean(plan)}
      width={780}
      onCancel={onClose}
      okText="确认，统一修改"
      okButtonProps={{ disabled: !chosen.length }}
      confirmLoading={busy}
      onOk={apply}
    >
      {plan?.summary && <Typography.Paragraph>{plan.summary}</Typography.Paragraph>}
      <Space direction="vertical" style={{ width: "100%" }} size={10}>
        {actions.map((action, index) => (
          <Card key={action.key} size="small" style={{ opacity: action.checked ? 1 : 0.5 }}>
            <div style={{ display: "flex", gap: 12, alignItems: "flex-start" }}>
              <Checkbox checked={action.checked} onChange={(event) => setActions((list) => list.map((item, i) => (i === index ? { ...item, checked: event.target.checked } : item)))} />
              <div style={{ flex: 1, minWidth: 0 }}>
                <Space style={{ marginBottom: 6 }} wrap>
                  <Tag color={ACTION_TYPE[action.type].color}>{ACTION_TYPE[action.type].label}</Tag>
                  <b>{action.targetLabel}</b>
                  <span className="muted" style={{ fontSize: 12 }}>
                    来自：{action.items.map((id) => pendingTexts.get(id)?.n).filter(Boolean).map((n) => `第${n}条`).join("、") || "—"}
                  </span>
                </Space>
                <Input.TextArea
                  autoSize={{ minRows: 1, maxRows: 5 }}
                  value={action.instruction}
                  disabled={!action.checked}
                  onChange={(event) => setActions((list) => list.map((item, i) => (i === index ? { ...item, instruction: event.target.value } : item)))}
                />
              </div>
            </div>
          </Card>
        ))}
        {!actions.length && <Alert type="info" message="没有整理出可以直接执行的修改" />}
        {plan?.questions?.length ? (
          <Alert
            type="warning"
            showIcon
            message="这些意见需要你说得更具体（会留在清单里，改好后再整理）"
            description={
              <ul style={{ margin: 0, paddingLeft: 18 }}>
                {plan.questions.map((question) => (
                  <li key={question.question}>
                    {question.question}
                    <span className="muted">（{question.items.map((id) => pendingTexts.get(id)).filter(Boolean).map((item) => `第${item!.n}条：${item!.text}`).join("；")}）</span>
                  </li>
                ))}
              </ul>
            }
          />
        ) : null}
        {chosen.length > 0 && <Alert type="info" showIcon message={`将会：${summary}。所有修改一次跑完，最后只生成一次交付包。`} />}
      </Space>
    </Modal>
  );
}
