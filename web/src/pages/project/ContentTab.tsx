import { useEffect, useMemo, useState } from "react";
import { App, Button, Card, Empty, Input, Space, Tag, Typography } from "antd";
import { call } from "../../api";
import { useSettings } from "../../hooks";
import type { ProjectDetail } from "../../types";

function Count({ text, floor }: { text: string; floor: number }) {
  const length = text.trim().length;
  return <span className={length >= floor ? "char-count-ok" : "char-count-bad"}>{length} / {floor}</span>;
}

export function ContentTab({ data, running, onChanged }: { data: ProjectDetail; running: boolean; onChanged: () => void }) {
  const { message, modal } = App.useApp();
  const content = data.content;
  const [overview, setOverview] = useState("");
  const [screens, setScreens] = useState<Record<string, { title: string; text: string }>>({});
  const [saving, setSaving] = useState(false);
  const readOnly = Boolean(data.state.readOnly);
  const settings = useSettings();
  const FLOOR = settings.data?.settings.pipeline.featureTextFloor || 300;
  // 只有文案真的变了才重置输入框，避免后台刷新冲掉还没保存的修改
  const contentKey = useMemo(() => JSON.stringify(content ? { o: content.cover.overview, s: content.screens.map((screen) => [screen.id, screen.title, screen.text]) } : null), [content]);

  useEffect(() => {
    if (!content) return;
    setOverview(content.cover.overview);
    setScreens(Object.fromEntries(content.screens.map((screen) => [screen.id, { title: screen.title, text: screen.text }])));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [contentKey]);

  const dirty = useMemo(() => {
    if (!content) return false;
    if (overview !== content.cover.overview) return true;
    return content.screens.some((screen) => screens[screen.id]?.title !== screen.title || screens[screen.id]?.text !== screen.text);
  }, [content, overview, screens]);

  if (!content) return <Empty description="截图验收后会在这里生成说明文字" />;

  const save = async (rebuild = false) => {
    const short = Object.entries(screens).filter(([, value]) => value.text.trim().length < FLOOR);
    if (short.length) {
      message.error(`${short.map(([id]) => id).join("、")} 的说明不足 ${FLOOR} 个字符`);
      return;
    }
    if (/图\s*\d/.test(overview) || Object.values(screens).some((value) => /图\s*\d/.test(value.text))) {
      message.error("正文里不能出现「图N」字样，图注会自动生成");
      return;
    }
    setSaving(true);
    try {
      await call("action", "saveContent", data.dir, {
        overview: overview !== content.cover.overview ? overview : undefined,
        screens: content.screens.filter((screen) => screens[screen.id]?.title !== screen.title || screens[screen.id]?.text !== screen.text).map((screen) => ({ id: screen.id, ...screens[screen.id] })),
      });
      if (rebuild) {
        await call("run", data.dir);
        message.success("已保存，正在更新交付包");
      } else {
        message.success("已保存。点「保存并更新交付包」或「继续运行」重建交付包。");
      }
      onChanged();
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setSaving(false);
    }
  };

  const rewrite = (ids: string[], label: string) =>
    modal.confirm({
      title: `让大模型重写${label}？`,
      content: "会覆盖当前内容（包括人工改过的部分）。",
      onOk: () => call("action", "rewriteContent", data.dir, ids),
    });

  return (
    <Space direction="vertical" size={16} style={{ width: "100%" }}>
      {!readOnly && (
        <Space>
          <Button disabled={!dirty || running} loading={saving} onClick={() => save(false)}>
            保存修改
          </Button>
          <Button type="primary" disabled={!dirty || running} loading={saving} onClick={() => save(true)}>
            保存并更新交付包
          </Button>
          {dirty && <Typography.Text type="warning">有未保存的修改</Typography.Text>}
        </Space>
      )}
      <Card size="small" title="封面介绍（也会写进 TXT 的【软件的主要功能】）" extra={!readOnly && <Button size="small" disabled={running} onClick={() => rewrite(["overview"], "封面介绍")}>重写</Button>}>
        <Input.TextArea autoSize={{ minRows: 3, maxRows: 8 }} value={overview} disabled={readOnly} onChange={(event) => setOverview(event.target.value)} />
        <div className="muted" style={{ marginTop: 4 }}>{overview.trim().length} 字</div>
      </Card>
      {content.screens.map((screen, index) => {
        const value = screens[screen.id] || { title: screen.title, text: screen.text };
        const edited = data.state.screens[screen.id]?.textEdited;
        return (
          <Card
            key={screen.id}
            size="small"
            title={
              <Space>
                <span>图{index + 1}</span>
                <Input size="small" style={{ width: 200 }} value={value.title} disabled={readOnly} onChange={(event) => setScreens((all) => ({ ...all, [screen.id]: { ...value, title: event.target.value } }))} />
                {edited && <Tag color="purple">人工改过</Tag>}
              </Space>
            }
            extra={
              <Space>
                <Count text={value.text} floor={FLOOR} />
                {!readOnly && <Button size="small" disabled={running} onClick={() => rewrite([screen.id], ` ${screen.id} 的说明`)}>重写</Button>}
              </Space>
            }
          >
            <Input.TextArea autoSize={{ minRows: 4, maxRows: 14 }} value={value.text} disabled={readOnly} onChange={(event) => setScreens((all) => ({ ...all, [screen.id]: { ...value, text: event.target.value } }))} />
          </Card>
        );
      })}
      {content.design?.sections?.length ? (
        <Card size="small" title="设计说明">
          {content.design.sections.map((section) => (
            <div key={section.title} style={{ marginBottom: 12 }}>
              <Typography.Text strong>{section.title}</Typography.Text>
              <Typography.Paragraph style={{ whiteSpace: "pre-wrap", marginTop: 4 }}>{section.text}</Typography.Paragraph>
            </div>
          ))}
        </Card>
      ) : null}
    </Space>
  );
}
