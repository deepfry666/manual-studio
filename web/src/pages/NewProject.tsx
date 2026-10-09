import { useMemo, useState } from "react";
import { App, Button, Input, InputNumber, Segmented, Select, Space, Switch } from "antd";
import { call, detectVersion } from "../api";
import { navigate, useSettings } from "../hooks";
import { Page, PathText, Row, Section } from "../ui";

const PLATFORMS = [
  { value: "iPhone 16 Pro Max / iOS 26", label: "iPhone 16 Pro Max / iOS 26" },
  { value: "Android 手机（原生 Android 界面）", label: "Android 手机" },
];

export function NewProjectPage() {
  const [mode, setMode] = useState<"single" | "batch">("single");
  const settings = useSettings();
  const data = settings.data?.settings;
  return (
    <Page
      title="新建项目"
      bar={
        <Segmented
          className="page-tabs"
          value={mode}
          onChange={(value) => setMode(value as "single" | "batch")}
          options={[
            { value: "single", label: "单个项目" },
            { value: "batch", label: "批量新建" },
          ]}
        />
      }
    >
      {data && (mode === "single" ? <SingleForm defaultScreens={data.pipeline.defaultScreenCount} defaultPlatform={data.pipeline.platform} codePath={data.codeSource?.path} /> : <BatchForm defaultScreens={data.pipeline.defaultScreenCount} defaultPlatform={data.pipeline.platform} concurrency={data.pipeline.batchConcurrency} codePath={data.codeSource?.path} />)}
    </Page>
  );
}

function CodeSourceRow({ path }: { path?: string }) {
  return (
    <Row label="代码来源" info="在「设置 → 代码来源」里统一设置，所有项目共用。没有代码来源时交付包只有说明书 3 个文件。">
      <PathText path={path} empty="未设置（只出说明书）" />
      <Button size="small" type="text" onClick={() => navigate("settings", "code")}>
        更改
      </Button>
    </Row>
  );
}

function SingleForm({ defaultScreens, defaultPlatform, codePath }: { defaultScreens: number; defaultPlatform: string; codePath?: string }) {
  const { message } = App.useApp();
  const [name, setName] = useState("");
  // 默认固定屏数（设置里的「默认截图数」，默认 7），也可以改成让大模型按功能决定
  const [autoCount, setAutoCount] = useState(false);
  const [screenCount, setScreenCount] = useState(defaultScreens);
  const [emphasis, setEmphasis] = useState("");
  const [notes, setNotes] = useState("");
  const [platform, setPlatform] = useState(defaultPlatform);
  const [wantDesign, setWantDesign] = useState(false);
  const [busy, setBusy] = useState(false);
  const version = detectVersion(name);

  const submit = async (runNow: boolean) => {
    if (!name.trim()) return message.warning("请填写软件名");
    setBusy(true);
    try {
      const dir = await call<string>("createProject", { softwareName: name.trim(), screenCount: autoCount ? null : screenCount, emphasis, notes, platform, wantDesign });
      if (runNow) call("run", dir);
      navigate("project", dir);
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="mac-columns">
      <Section title="基本信息">
        <Row label="软件名" hint={name.trim() ? (version ? `识别到版本号 ${version}` : "没有版本号") : "含版本号，按原样填写"} info="只用于文件名、文档标题和页眉，截图里不会出现软件名和版本号。">
          <Input value={name} onChange={(event) => setName(event.target.value)} placeholder="例如：云伴日程 V1.0" autoFocus style={{ width: 340 }} onPressEnter={() => submit(true)} />
        </Row>
        <Row label="截图数">
          <Segmented
            value={autoCount ? "auto" : "fixed"}
            onChange={(value) => setAutoCount(value === "auto")}
            options={[
              { value: "fixed", label: "固定" },
              { value: "auto", label: "按功能决定" },
            ]}
          />
          {!autoCount && <InputNumber min={2} max={15} value={screenCount} onChange={(value) => setScreenCount(Number(value) || defaultScreens)} addonAfter="屏" style={{ width: 100 }} />}
        </Row>
        <Row label="重点功能">
          <Input value={emphasis} onChange={(event) => setEmphasis(event.target.value)} placeholder="可选，例如：违章查询、在线缴费" style={{ width: 340 }} />
        </Row>
        <Row label="补充说明">
          <Input.TextArea value={notes} onChange={(event) => setNotes(event.target.value)} placeholder="可选，目标用户、风格偏好等" autoSize={{ minRows: 1, maxRows: 4 }} style={{ width: 340 }} />
        </Row>
      </Section>
      <Section title="生成选项">
        <Row label="平台">
          <Select value={platform} onChange={setPlatform} options={PLATFORMS} style={{ width: 260 }} />
        </Row>
        <Row label="设计说明章节">
          <Switch checked={wantDesign} onChange={setWantDesign} />
        </Row>
        <CodeSourceRow path={codePath} />
      </Section>
      </div>
      <Space style={{ width: "100%", justifyContent: "flex-end" }}>
        <Button loading={busy} onClick={() => submit(false)}>
          只创建
        </Button>
        <Button type="primary" loading={busy} onClick={() => submit(true)}>
          创建并开始
        </Button>
      </Space>
    </>
  );
}

function BatchForm({ defaultScreens, defaultPlatform, concurrency, codePath }: { defaultScreens: number; defaultPlatform: string; concurrency: number; codePath?: string }) {
  const { message, modal } = App.useApp();
  const [text, setText] = useState("");
  const [autoCount, setAutoCount] = useState(false);
  const [screenCount, setScreenCount] = useState(defaultScreens);
  const [platform, setPlatform] = useState(defaultPlatform);
  const [wantDesign, setWantDesign] = useState(false);
  const [startNow, setStartNow] = useState(true);
  const [busy, setBusy] = useState(false);
  const count = useMemo(() => text.split(/\r?\n/).filter((line) => line.trim() && !/^(软件名|名称|name)[,，\t]/i.test(line.trim())).length, [text]);

  const submit = async () => {
    setBusy(true);
    try {
      const result = await call<{ created: string[]; errors: string[] }>("createProjectsFromList", text, { screenCount: autoCount ? null : screenCount, platform, wantDesign });
      if (startNow && result.created.length) await call("batchEnqueue", result.created);
      setText("");
      if (result.errors.length) {
        modal.warning({
          title: `创建了 ${result.created.length} 个，${result.errors.length} 个没有创建`,
          content: (
            <ul style={{ paddingLeft: 18, maxHeight: 300, overflow: "auto" }}>
              {result.errors.map((line) => (
                <li key={line}>{line}</li>
              ))}
            </ul>
          ),
          onOk: () => navigate("projects"),
        });
      } else {
        message.success(`已创建 ${result.created.length} 个项目`);
        navigate("projects");
      }
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <div className="mac-columns">
      <Section
        title={`软件名（每行一个，已填 ${count} 个）`}
        extra={
          <Button
            size="small"
            type="text"
            onClick={async () => {
              const content = await call<string | null>("chooseTextFile", "选择 CSV 或文本文件");
              if (content) setText(content);
            }}
          >
            从文件读取…
          </Button>
        }
        footer="也可以在名字后面用逗号带上：截图数,重点功能,补充说明"
      >
        <div style={{ padding: 4 }}>
          <Input.TextArea variant="borderless" rows={10} value={text} onChange={(event) => setText(event.target.value)} placeholder={"云伴日程 V1.0\n快记账本 V1.0,7,预算提醒\n掌上违章助手 V1.0"} />
        </div>
      </Section>
      <Section title="生成选项">
        <Row label="截图数" hint="没在列表里写截图数的项目">
          <Segmented
            value={autoCount ? "auto" : "fixed"}
            onChange={(value) => setAutoCount(value === "auto")}
            options={[
              { value: "fixed", label: "固定" },
              { value: "auto", label: "按功能决定" },
            ]}
          />
          {!autoCount && <InputNumber min={2} max={15} value={screenCount} onChange={(value) => setScreenCount(Number(value) || defaultScreens)} addonAfter="屏" style={{ width: 100 }} />}
        </Row>
        <Row label="平台">
          <Select value={platform} onChange={setPlatform} options={PLATFORMS} style={{ width: 260 }} />
        </Row>
        <Row label="设计说明章节">
          <Switch checked={wantDesign} onChange={setWantDesign} />
        </Row>
        <CodeSourceRow path={codePath} />
        <Row label="创建后直接开始" hint={`每次同时处理 ${concurrency} 个，不停下确认规划`}>
          <Switch checked={startNow} onChange={setStartNow} />
        </Row>
      </Section>
      </div>
      <Space style={{ width: "100%", justifyContent: "flex-end" }}>
        <Button type="primary" loading={busy} disabled={!count} onClick={submit}>
          创建 {count || ""} 个项目
        </Button>
      </Space>
    </>
  );
}
