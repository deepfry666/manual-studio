import { useState } from "react";
import { App, Button, Card, Col, Descriptions, Dropdown, Empty, Image, Input, Modal, Row, Space, Tag, Tooltip, Typography } from "antd";
import { CheckOutlined, CloseOutlined, MoreOutlined, ReloadOutlined, SwapOutlined } from "@ant-design/icons";
import { assetUrl, call, formatTime } from "../../api";
import type { GateInfo, ProjectDetail } from "../../types";

type ScreenItem = ProjectDetail["screens"][number];

function gateTag(gate?: GateInfo | null) {
  if (!gate) return <Tag>未验收</Tag>;
  const map: Record<string, { color: string; label: string }> = {
    passed: { color: "green", label: gate.method === "imported-receipt" ? "沿用历史回执" : "验收通过" },
    "manual-passed": { color: "green", label: "人工确认通过" },
    failed: { color: "red", label: "验收不通过" },
    "needs-manual": { color: "orange", label: "待人工确认" },
    error: { color: "red", label: "验收出错" },
  };
  const entry = map[gate.status] || { color: "default", label: gate.status };
  return <Tag color={entry.color}>{entry.label}</Tag>;
}

export function ScreensTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message, modal } = App.useApp();
  const [preview, setPreview] = useState<ScreenItem | null>(null);
  const [promptEdit, setPromptEdit] = useState<ScreenItem | null>(null);
  const [alternates, setAlternates] = useState<ScreenItem | null>(null);
  const readOnly = Boolean(data.state.readOnly);

  if (!data.screens.length) {
    return <Empty description={readOnly ? "这个历史项目没有截图源文件" : "规划完成后会在这里显示截图"} />;
  }

  const regenerate = (screen: ScreenItem) =>
    modal.confirm({
      title: `重新生成 ${screen.id}？`,
      content: "会花一张图的费用。旧图会先归档，新图生成后自动验收，文案会按新截图重写这一屏（人工改过的除外）。",
      okText: "重新生成",
      onOk: () => call("action", "regenerateScreen", data.dir, screen.id),
    });

  const manual = async (screen: ScreenItem, passed: boolean) => {
    await call("action", "manualGate", data.dir, screen.id, passed);
    const remaining = data.screens.filter((item) => item.id !== screen.id && !["passed", "manual-passed"].includes(item.state.gate?.status || ""));
    if (passed && remaining.length === 0) {
      message.success("全部截图已确认，继续生成文案和交付包");
      await call("run", data.dir);
    } else {
      message.success(passed ? `已确认没有软件名${remaining.length ? `，还剩 ${remaining.length} 张` : ""}` : "已标记为不合格，可以重生或换备选图");
    }
    onChanged();
  };

  return (
    <>
      <div className="screen-grid">
        {data.screens.map((screen) => {
          const gate = screen.state.gate;
          const warnings = [...(screen.state.imageWarnings || []), ...(gate?.warnings || [])];
          return (
            <Card
              key={screen.id}
              size="small"
              className="screen-card"
              cover={screen.file ? <img src={assetUrl(screen.file, screen.mtime)} alt={screen.id} onClick={() => setPreview(screen)} style={{ cursor: "zoom-in" }} /> : <div className="screen-placeholder">{running ? "生成中…" : "未生成"}</div>}
              actions={
                readOnly
                  ? undefined
                  : [
                      <Tooltip key="regen" title="重新生成这一屏">
                        <Button type="text" size="small" icon={<ReloadOutlined />} disabled={running} onClick={() => regenerate(screen)} />
                      </Tooltip>,
                      <Tooltip key="alt" title={screen.alternates.length ? `备选图 ${screen.alternates.length} 张` : "没有备选图"}>
                        <Button type="text" size="small" icon={<SwapOutlined />} disabled={running || !screen.alternates.length} onClick={() => setAlternates(screen)}>
                          {screen.alternates.length || ""}
                        </Button>
                      </Tooltip>,
                      <Dropdown
                        key="more"
                        trigger={["click"]}
                        menu={{
                          items: [
                            { key: "prompt", label: "查看 / 编辑提示词" },
                            { key: "pass", label: "人工确认：没有软件名", icon: <CheckOutlined /> },
                            { key: "fail", label: "人工判定：不合格", icon: <CloseOutlined /> },
                          ],
                          onClick: ({ key }) => {
                            if (key === "prompt") setPromptEdit(screen);
                            if (key === "pass") manual(screen, true);
                            if (key === "fail") manual(screen, false);
                          },
                        }}
                      >
                        <Button type="text" size="small" icon={<MoreOutlined />} disabled={running} />
                      </Dropdown>,
                    ]
              }
            >
              <Space direction="vertical" size={4} style={{ width: "100%" }}>
                <Space size={4} wrap>
                  <Typography.Text strong>{screen.plan?.title || screen.id}</Typography.Text>
                  <span className="muted mono">{screen.id}</span>
                </Space>
                <Space size={4} wrap>
                  {gateTag(gate)}
                  {screen.state.providerName && <Tag>{screen.state.providerName}</Tag>}
                  {screen.state.hedged && <Tag color="blue">补发胜出</Tag>}
                  {screen.state.promptEdited && data.state.origin !== "imported" && <Tag color="purple">提示词已改</Tag>}
                </Space>
                {(gate?.status === "failed" || gate?.status === "error") && <Typography.Text type="danger" style={{ fontSize: 12 }}>{(gate.reasons || []).join("；")}</Typography.Text>}
                {gate?.status === "needs-manual" && (
                  <Space>
                    <Button size="small" type="primary" onClick={() => manual(screen, true)}>
                      没有软件名，通过
                    </Button>
                    <Button size="small" danger onClick={() => manual(screen, false)}>
                      不合格
                    </Button>
                  </Space>
                )}
                {warnings.length > 0 && (
                  <Tooltip title={<ul style={{ margin: 0, paddingLeft: 16 }}>{warnings.map((warning) => <li key={warning}>{warning}</li>)}</ul>}>
                    <Typography.Text type="warning" style={{ fontSize: 12 }}>
                      {warnings.length} 条提醒
                    </Typography.Text>
                  </Tooltip>
                )}
              </Space>
            </Card>
          );
        })}
      </div>

      <Modal open={Boolean(preview)} onCancel={() => setPreview(null)} footer={null} width={980} title={preview ? `${preview.id} · ${preview.plan?.title || ""}` : ""}>
        {preview && (
          <Row gutter={20}>
            <Col span={10}>
              <img className="preview-img" src={assetUrl(preview.file, preview.mtime)} alt={preview.id} />
            </Col>
            <Col span={14}>
              <Descriptions size="small" column={1} bordered>
                <Descriptions.Item label="验收">{gateTag(preview.state.gate)}</Descriptions.Item>
                <Descriptions.Item label="线路">{preview.state.providerName || "—"} {preview.state.model ? `（${preview.state.model}）` : ""}</Descriptions.Item>
                <Descriptions.Item label="尺寸">{preview.state.width ? `${preview.state.width}×${preview.state.height}` : "—"}</Descriptions.Item>
                <Descriptions.Item label="生成时间">{formatTime(preview.state.generatedAt)}</Descriptions.Item>
              </Descriptions>
              {preview.state.gate?.inventory && (
                <>
                  <Typography.Title level={5} style={{ marginTop: 16 }}>
                    看图模型抄录的界面内容
                  </Typography.Title>
                  <Typography.Paragraph>{preview.state.gate.inventory}</Typography.Paragraph>
                </>
              )}
              {preview.state.gate?.visibleText?.length ? (
                <Typography.Paragraph className="muted" style={{ fontSize: 12 }}>
                  可见文字：{preview.state.gate.visibleText.join(" · ")}
                </Typography.Paragraph>
              ) : null}
            </Col>
          </Row>
        )}
      </Modal>

      <PromptModal
        screen={promptEdit}
        onClose={() => setPromptEdit(null)}
        onSave={async (text) => {
          await call("action", "savePrompt", data.dir, promptEdit!.id, text);
          message.success("提示词已保存，下次运行时会重新生成这一屏");
          setPromptEdit(null);
          onChanged();
        }}
      />

      <Modal open={Boolean(alternates)} onCancel={() => setAlternates(null)} footer={null} width={760} title={alternates ? `${alternates.id} 的备选图` : ""}>
        <Typography.Paragraph className="muted">补发时输掉的异步任务出图后会存在这里，不会白花钱。换上后需要重新验收。</Typography.Paragraph>
        <Space wrap size={16}>
          {alternates?.alternates.map((item) => (
            <Space key={item.file} direction="vertical" align="center">
              <Image className="alternate-thumb" src={assetUrl(item.file)} width={120} />
              <Button
                size="small"
                onClick={async () => {
                  await call("action", "useAlternate", data.dir, alternates.id, item.file);
                  message.success("已替换，旧图已归档");
                  setAlternates(null);
                  onChanged();
                }}
              >
                用这张
              </Button>
            </Space>
          ))}
        </Space>
      </Modal>
    </>
  );
}

function PromptModal({ screen, onClose, onSave }: { screen: ScreenItem | null; onClose: () => void; onSave: (text: string) => void }) {
  const [text, setText] = useState("");
  return (
    <Modal title={screen ? `${screen.id} 的生图提示词` : ""} open={Boolean(screen)} width={820} onCancel={onClose} onOk={() => onSave(text)} okText="保存" afterOpenChange={(open) => open && screen && setText(screen.prompt)}>
      <Typography.Paragraph className="muted">末尾的「不要渲染软件名」禁令由程序自动保留，删掉也会被加回去。</Typography.Paragraph>
      <Input.TextArea rows={18} value={text} onChange={(event) => setText(event.target.value)} className="mono" />
    </Modal>
  );
}
