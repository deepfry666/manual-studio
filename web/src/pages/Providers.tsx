import { useEffect, useState } from "react";
import { Alert, App, Button, Col, Form, Input, InputNumber, Modal, Radio, Row, Select, Space, Switch, Table, Tag, Tooltip, Typography } from "antd";
import { ArrowDownOutlined, ArrowUpOutlined, DeleteOutlined, EditOutlined, ExperimentOutlined, ImportOutlined, PlusOutlined, ThunderboltOutlined } from "@ant-design/icons";
import { call, formatSeconds } from "../api";
import { useDebounced, useLoader, useSettings, useStudioEvents } from "../hooks";
import { Row as MacRow, Section } from "../ui";
import type { ImageProvider, ProviderStatus, SettingsBundle } from "../types";

export function ProvidersPage() {
  const { message, modal } = App.useApp();
  const settings = useSettings();
  const statuses = useLoader(() => call<Record<string, ProviderStatus>>("providerStatuses"));
  const refreshStatuses = useDebounced(statuses.reload, 800);
  useStudioEvents((event) => {
    if (event.type === "call") refreshStatuses();
  });
  const [editing, setEditing] = useState<Partial<ImageProvider> | null>(null);
  const [probe, setProbe] = useState<{ id: string; report: Record<string, unknown> | null; busy: boolean } | null>(null);

  if (!settings.data) return <div className="page" />;
  const bundle = settings.data;
  const providers = bundle.settings.providers;

  const reloadAll = () => {
    settings.reload();
    statuses.reload();
  };
  const move = async (index: number, delta: number) => {
    const ids = providers.map((provider) => provider.id);
    const [item] = ids.splice(index, 1);
    ids.splice(index + delta, 0, item);
    await call("reorderProviders", ids);
    reloadAll();
  };
  const toggle = async (provider: ImageProvider, enabled: boolean) => {
    await call("saveProvider", { ...provider, enabled });
    reloadAll();
  };
  const runProbe = async (provider: ImageProvider, realImage: boolean) => {
    setProbe({ id: provider.id, report: null, busy: true });
    try {
      const report = await call<Record<string, unknown>>("probeProvider", provider.id, { realImage });
      setProbe({ id: provider.id, report, busy: false });
      reloadAll();
    } catch (error) {
      setProbe(null);
      message.error((error as Error).message);
    }
  };

  return (
    <div className="page">
      <div className="page-header">
        <h2>生图线路</h2>
        <Space>
          <Button
            icon={<ImportOutlined />}
            onClick={async () => {
              try {
                const result = await call<{ imported: string[]; skipped: string[] }>("importLegacyProviders");
                modal.info({
                  title: "已从旧 skill 导入线路",
                  content: (
                    <div>
                      <p>导入：{result.imported.join("、") || "无"}</p>
                      {result.skipped.length > 0 && <p className="muted">跳过：{result.skipped.join("；")}</p>}
                      <p className="muted">只读取了 ~/.codex/software-manual-image-providers.json，没有修改它；密钥已加密保存在本软件里。</p>
                    </div>
                  ),
                });
                reloadAll();
              } catch (error) {
                message.error((error as Error).message);
              }
            }}
          >
            从旧 skill 导入
          </Button>
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setEditing({ preset: "openai-sync" })}>
            添加线路
          </Button>
        </Space>
      </div>

      

      <Table<ImageProvider>
        rowKey="id"
        size="middle"
        pagination={false}
        dataSource={providers}
        locale={{ emptyText: "还没有线路。点「添加线路」，或者「从旧 skill 导入」。" }}
        columns={[
          {
            title: "顺序",
            width: 90,
            render: (_, __, index) => (
              <Space size={0}>
                <Button type="text" size="small" icon={<ArrowUpOutlined />} disabled={index === 0} onClick={() => move(index, -1)} />
                <Button type="text" size="small" icon={<ArrowDownOutlined />} disabled={index === providers.length - 1} onClick={() => move(index, 1)} />
              </Space>
            ),
          },
          {
            title: "线路",
            render: (_, provider) => (
              <Space direction="vertical" size={0}>
                <Space>
                  <Typography.Text strong>{provider.name}</Typography.Text>
                  {!bundle.providerKeys[provider.id] && <Tag color="red">没有密钥</Tag>}
                </Space>
                <span className="muted mono">
                  {provider.model} · {bundle.presets.image[provider.preset]?.protocol === "async" ? "异步" : "同步"} · {provider.sizeMode === "ratio" ? "比例" : provider.pixelSize}
                </span>
              </Space>
            ),
          },
          {
            title: "状态",
            width: 200,
            render: (_, provider) => {
              const status = statuses.data?.[provider.id];
              if (!provider.enabled) return <Tag>已停用</Tag>;
              if (status?.unavailable)
                return (
                  <Space direction="vertical" size={2}>
                    <Tag color="orange">{status.unavailable.split("：")[0]}</Tag>
                    <Typography.Text className="muted" style={{ fontSize: 12 }}>
                      {status.unavailable}
                    </Typography.Text>
                    <a
                      onClick={async () => {
                        await call("resetProviderHealth", provider.id);
                        reloadAll();
                      }}
                    >
                      手动恢复
                    </a>
                  </Space>
                );
              return <Tag color="green">可用</Tag>;
            },
          },
          {
            title: <Tooltip title="最近 50 次成功调用">耗时 P50 / P90</Tooltip>,
            width: 150,
            render: (_, provider) => {
              const status = statuses.data?.[provider.id];
              return <span className="stat-number">{status?.p50 ? `${formatSeconds(status.p50)} / ${formatSeconds(status.p90)}` : "—"}</span>;
            },
          },
          {
            title: "成功率",
            width: 90,
            render: (_, provider) => {
              const status = statuses.data?.[provider.id];
              return status?.successRate !== null && status?.successRate !== undefined ? <span className="stat-number">{Math.round(status.successRate * 100)}%</span> : "—";
            },
          },
          {
            title: <Tooltip title="超过这个时间还没出图就补发到另一条线路；有 5 次以上历史后按实际耗时自动计算">补发线</Tooltip>,
            width: 90,
            render: (_, provider) => <span className="stat-number">{formatSeconds(statuses.data?.[provider.id]?.hedgeThresholdSec)}</span>,
          },
          { title: "并发", dataIndex: "concurrency", width: 60 },
          { title: "启用", width: 70, render: (_, provider) => <Switch size="small" checked={provider.enabled} onChange={(value) => toggle(provider, value)} /> },
          {
            title: "",
            width: 150,
            render: (_, provider) => (
              <Space size={0}>
                <Tooltip title="测试连通性（免费）">
                  <Button type="text" icon={<ExperimentOutlined />} onClick={() => runProbe(provider, false)} />
                </Tooltip>
                <Tooltip title="真实生成一张测速（会扣一张图的费用）">
                  <Button
                    type="text"
                    icon={<ThunderboltOutlined />}
                    onClick={() =>
                      modal.confirm({
                        title: "真实生成一张测速？",
                        content: "会扣这条线路一张低质量图的费用，结果会计入耗时统计，测速成功也会解除冷却和熔断。",
                        onOk: () => runProbe(provider, true),
                      })
                    }
                  />
                </Tooltip>
                <Button type="text" icon={<EditOutlined />} onClick={() => setEditing(provider)} />
                <Button
                  type="text"
                  danger
                  icon={<DeleteOutlined />}
                  onClick={() =>
                    modal.confirm({
                      title: `删除线路「${provider.name}」？`,
                      content: "密钥也会一起删除。",
                      okButtonProps: { danger: true },
                      onOk: async () => {
                        await call("deleteProvider", provider.id);
                        reloadAll();
                      },
                    })
                  }
                />
              </Space>
            ),
          },
        ]}
      />

      <StrategyCard bundle={bundle} onSaved={reloadAll} />

      <ProviderModal bundle={bundle} value={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); reloadAll(); }} />

      <Modal open={Boolean(probe)} onCancel={() => setProbe(null)} footer={null} title="测试结果" width={640}>
        {probe?.busy && <Typography.Paragraph>测试中…真实生图通常需要 15–90 秒。</Typography.Paragraph>}
        {probe?.report && <ProbeReport report={probe.report} />}
      </Modal>
    </div>
  );
}

function ProbeReport({ report }: { report: Record<string, unknown> }) {
  const image = report.image as { ok: boolean; durationMs?: number; requestSize?: string; width?: number; height?: number; reason?: string; dataUrl?: string } | null;
  const models = report.models as string[] | null;
  return (
    <Space direction="vertical" style={{ width: "100%" }}>
      {report.modelsError ? (
        <Alert type="warning" message={`模型列表读取失败：${report.modelsError}`} description="有些中转站不提供模型列表，不影响生图。" />
      ) : (
        <Alert type={report.hasModel === false ? "warning" : "success"} message={report.hasModel === false ? "密钥可用，但模型列表里没有这个模型名，请核对" : `密钥可用${models?.length ? `，共 ${models.length} 个模型` : ""}`} />
      )}
      {report.sizeSwitched ? <Alert type="info" message={`这条线路不收像素尺寸，已自动改为比例 ${report.sizeSwitched}`} /> : null}
      {image && (image.ok ? <Alert type="success" message={`出图成功：${Math.round((image.durationMs || 0) / 1000)} 秒，发送尺寸 ${image.requestSize}，返回 ${image.width}×${image.height}`} /> : <Alert type="error" message={`出图失败：${image.reason}`} />)}
      {image?.dataUrl && <img src={image.dataUrl} style={{ maxHeight: 360, display: "block", margin: "0 auto", borderRadius: 8 }} />}
    </Space>
  );
}

/** 生图策略：系统设置样式，改了就保存。 */
function StrategyCard({ bundle, onSaved }: { bundle: SettingsBundle; onSaved: () => void }) {
  const { message } = App.useApp();
  const image = bundle.settings.image;
  const [size, setSize] = useState(image.targetSize);
  useEffect(() => setSize(image.targetSize), [image.targetSize]);
  const save = async (patch: Record<string, unknown>) => {
    try {
      await call("updateSettings", { image: patch });
      onSaved();
    } catch (error) {
      message.error((error as Error).message);
    }
  };
  const hedge = image.hedge;
  return (
    <div style={{ marginTop: 24 }}>
      <Section title="生图">
        <MacRow label="目标尺寸" info="只收比例的线路会自动换成最接近的比例（864x1824 → 1:2）。">
          <Input value={size} onChange={(event) => setSize(event.target.value)} onBlur={() => size !== image.targetSize && save({ targetSize: size })} style={{ width: 130 }} />
        </MacRow>
        <MacRow label="质量">
          <Select value={image.quality} onChange={(value) => save({ quality: value })} options={[{ value: "low", label: "low" }, { value: "medium", label: "medium" }, { value: "high", label: "high" }]} style={{ width: 130 }} />
        </MacRow>
        <MacRow label="全局并发上限" info="所有项目加起来同时生成的图片数。">
          <InputNumber min={1} max={50} value={image.globalConcurrency} onChange={(value) => value && save({ globalConcurrency: value })} addonAfter="张" style={{ width: 110 }} />
        </MacRow>
        <MacRow label="每屏最多尝试">
          <InputNumber min={1} max={10} value={image.maxAttemptsPerScreen} onChange={(value) => value && save({ maxAttemptsPerScreen: value })} addonAfter="次" style={{ width: 110 }} />
        </MacRow>
        <MacRow label="验收不通过时最多重生">
          <InputNumber min={1} max={6} value={image.gateRegenerateLimit} onChange={(value) => value && save({ gateRegenerateLimit: value })} addonAfter="次" style={{ width: 110 }} />
        </MacRow>
        <MacRow label="满载时分流" info="首选线路并发满了，直接发给同一画风组还有空位的线路，不排队。关闭则严格按顺序排队。">
          <Switch checked={image.spillover} onChange={(value) => save({ spillover: value })} />
        </MacRow>
      </Section>
      <Section title="超时补发" footer="某张图超过补发线还没回来，向另一条线路再发一次，先出图的用。">
        <MacRow label="开启补发">
          <Switch checked={hedge.enabled} onChange={(value) => save({ hedge: { enabled: value } })} />
        </MacRow>
        <MacRow label="补发线" info="取这条线路最近 50 次耗时的百分位，限制在上下限之间。">
          <InputNumber min={50} max={99} value={hedge.percentile} onChange={(value) => value && save({ hedge: { percentile: value } })} addonAfter="%" style={{ width: 96 }} />
          <InputNumber min={5} max={600} value={hedge.minSec} onChange={(value) => value && save({ hedge: { minSec: value } })} addonBefore="最少" addonAfter="秒" style={{ width: 150 }} />
          <InputNumber min={10} max={900} value={hedge.maxSec} onChange={(value) => value && save({ hedge: { maxSec: value } })} addonBefore="最多" addonAfter="秒" style={{ width: 150 }} />
        </MacRow>
        <MacRow label="每次运行最多补发" hint="0 等于关闭">
          <InputNumber min={0} max={100} value={hedge.maxPerBatch} onChange={(value) => value !== null && save({ hedge: { maxPerBatch: value } })} addonAfter="张" style={{ width: 110 }} />
        </MacRow>
        <MacRow label="允许补发到不同模型" info="关闭时只补发到「画风组」相同的线路，画风和其他屏保持一致。">
          <Switch checked={hedge.allowCrossModel} onChange={(value) => save({ hedge: { allowCrossModel: value } })} />
        </MacRow>
      </Section>
    </div>
  );
}

function ProviderModal({ bundle, value, onClose, onSaved }: { bundle: SettingsBundle; value: Partial<ImageProvider> | null; onClose: () => void; onSaved: () => void }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const [busy, setBusy] = useState(false);
  const isNew = !value?.id;
  const presetKey = Form.useWatch("preset", form) || value?.preset || "openai-sync";

  useEffect(() => {
    if (!value) return;
    const preset = bundle.presets.image[value.preset || "openai-sync"];
    form.resetFields();
    form.setFieldsValue({
      name: "",
      enabled: true,
      sizeMode: preset.sizeMode,
      pixelSize: preset.pixelSize,
      ratios: preset.ratios,
      quality: "low",
      concurrency: preset.concurrency,
      hardTimeoutSec: preset.hardTimeoutSec,
      hedgeDefaultSec: preset.hedgeDefaultSec,
      ...value,
      mappingText: value.mapping ? JSON.stringify(value.mapping, null, 2) : JSON.stringify(preset.mapping, null, 2),
      apiKey: "",
    });
  }, [value, bundle, form]);

  const applyPreset = (key: string) => {
    const preset = bundle.presets.image[key];
    form.setFieldsValue({ sizeMode: preset.sizeMode, pixelSize: preset.pixelSize, ratios: preset.ratios, concurrency: preset.concurrency, hardTimeoutSec: preset.hardTimeoutSec, hedgeDefaultSec: preset.hedgeDefaultSec, mappingText: JSON.stringify(preset.mapping, null, 2) });
  };

  const save = async () => {
    const values = await form.validateFields();
    let mapping = null;
    if (values.preset === "custom") {
      try {
        mapping = JSON.parse(values.mappingText);
      } catch {
        message.error("自定义映射不是有效的 JSON");
        return;
      }
    }
    setBusy(true);
    try {
      const { mappingText: _ignored, ...rest } = values;
      await call("saveProvider", { ...value, ...rest, mapping, apiKey: values.apiKey || undefined });
      onSaved();
    } catch (error) {
      message.error((error as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal title={isNew ? "添加生图线路" : `编辑线路：${value?.name}`} open={Boolean(value)} onCancel={onClose} onOk={save} confirmLoading={busy} width={720} destroyOnHidden>
      <Form form={form} layout="vertical">
        <Form.Item name="preset" label="类型">
          <Radio.Group onChange={(event) => applyPreset(event.target.value)} options={Object.entries(bundle.presets.image).map(([key, preset]) => ({ value: key, label: preset.label }))} optionType="button" />
        </Form.Item>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="name" label="名称" rules={[{ required: true }]}>
              <Input placeholder="例如：CPA 2.5" />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="apiKey" label="密钥" extra={!isNew && bundle.providerKeys[value!.id!] ? "已保存，留空表示不修改" : "加密保存在本机"}>
              <Input.Password placeholder={!isNew && bundle.providerKeys[value!.id!] ? "••••••••" : "sk-..."} autoComplete="off" />
            </Form.Item>
          </Col>
        </Row>
        <Form.Item name="baseUrl" label="接口地址（通常以 /v1 结尾）" rules={[{ required: true }]}>
          <Input placeholder="https://example.com/v1" />
        </Form.Item>
        <Row gutter={12}>
          <Col span={12}>
            <Form.Item name="model" label="模型名" rules={[{ required: true }]}>
              <Input placeholder="gpt-image-2.5" />
            </Form.Item>
          </Col>
          <Col span={12}>
            <Form.Item name="modelGroup" label="画风组" extra="同组的线路之间可以互相补发；留空等于模型名">
              <Input placeholder="gpt-image-2.5" />
            </Form.Item>
          </Col>
        </Row>
        <Row gutter={12}>
          <Col span={8}>
            <Form.Item name="sizeMode" label="尺寸方式">
              <Radio.Group options={[{ value: "pixel", label: "像素" }, { value: "ratio", label: "比例" }]} />
            </Form.Item>
          </Col>
          <Col span={16}>
            <Form.Item noStyle shouldUpdate={(prev, next) => prev.sizeMode !== next.sizeMode}>
              {({ getFieldValue }) =>
                getFieldValue("sizeMode") === "ratio" ? (
                  <Form.Item name="ratios" label="支持的比例（自动选最接近目标尺寸的）">
                    <Select mode="tags" />
                  </Form.Item>
                ) : (
                  <Form.Item name="pixelSize" label="像素尺寸">
                    <Input />
                  </Form.Item>
                )
              }
            </Form.Item>
          </Col>
        </Row>
        <Row gutter={12}>
          <Col span={8}>
            <Form.Item name="concurrency" label="这条线路的并发数">
              <InputNumber min={1} max={30} />
            </Form.Item>
          </Col>
          <Col span={8}>
            <Form.Item name="hardTimeoutSec" label="单张最长等待" extra="超时后换线路；异步任务转后台继续查">
              <InputNumber min={20} max={1800} addonAfter="秒" />
            </Form.Item>
          </Col>
          <Col span={8}>
            <Form.Item name="hedgeDefaultSec" label="默认补发线" extra="历史不足 5 次时使用">
              <InputNumber min={5} max={600} addonAfter="秒" />
            </Form.Item>
          </Col>
        </Row>
        {presetKey === "custom" && (
          <>
            <Alert type="info" style={{ marginBottom: 12 }} message="自定义映射：请求体里的 $model、$prompt、$size、$quality 会被替换；有 polling 字段就按异步任务处理。" />
            <Form.Item name="mappingText" label="声明式映射（JSON）">
              <Input.TextArea rows={12} className="mono" />
            </Form.Item>
          </>
        )}
      </Form>
    </Modal>
  );
}
