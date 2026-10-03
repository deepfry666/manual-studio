import { useEffect, useState } from "react";
import { Alert, App, AutoComplete, Button, Card, Col, Form, Input, Modal, Radio, Row, Select, Space, Switch, Table, Tag, Typography } from "antd";
import { DeleteOutlined, EditOutlined, PlusOutlined, SyncOutlined } from "@ant-design/icons";
import { call } from "../api";
import { useSettings } from "../hooks";
import type { LlmVendor, SettingsBundle } from "../types";

export function LlmPage() {
  const { message, modal } = App.useApp();
  const settings = useSettings();
  const [editing, setEditing] = useState<Partial<LlmVendor> | null>(null);
  if (!settings.data) return <div className="page" />;
  const bundle = settings.data;
  const vendors = bundle.settings.llm.vendors;

  return (
    <div className="page">
      <div className="page-header">
        <h2>大模型</h2>
        <Button type="primary" icon={<PlusOutlined />} onClick={() => setEditing({ preset: "deepseek" })}>
          添加厂商
        </Button>
      </div>
      <Typography.Paragraph className="muted">
        所有厂商都按 OpenAI 兼容接口调用。每个步骤可以选不同厂商和模型；「截图验收」需要能看图的模型（DeepSeek 目前没有看图模型，可以用 OpenAI 或智谱的 GLM-V 系列）。不配看图模型时，截图改为人工逐张确认。
      </Typography.Paragraph>
      <Table<LlmVendor>
        rowKey="id"
        size="middle"
        pagination={false}
        dataSource={vendors}
        locale={{ emptyText: "还没有大模型厂商，点「添加厂商」" }}
        columns={[
          {
            title: "厂商",
            render: (_, vendor) => (
              <Space direction="vertical" size={0}>
                <Space>
                  <Typography.Text strong>{vendor.name}</Typography.Text>
                  <Tag>{bundle.presets.llm[vendor.preset]?.label || vendor.preset}</Tag>
                  {!bundle.vendorKeys[vendor.id] && <Tag color="red">没有密钥</Tag>}
                </Space>
                <span className="muted mono">{vendor.baseUrl}</span>
              </Space>
            ),
          },
          { title: "已获取的模型", render: (_, vendor) => <span className="muted">{vendor.models?.length ? `${vendor.models.length} 个` : "—"}</span>, width: 120 },
          {
            title: "",
            width: 200,
            render: (_, vendor) => (
              <Space>
                <Button
                  size="small"
                  icon={<SyncOutlined />}
                  onClick={async () => {
                    try {
                      const models = await call<string[]>("fetchVendorModels", vendor.id);
                      message.success(`获取到 ${models.length} 个模型`);
                      settings.reload();
                    } catch (error) {
                      message.error(`获取失败：${(error as Error).message}（可以直接手动填写模型名）`);
                    }
                  }}
                >
                  获取模型
                </Button>
                <Button size="small" type="text" icon={<EditOutlined />} onClick={() => setEditing(vendor)} />
                <Button
                  size="small"
                  type="text"
                  danger
                  icon={<DeleteOutlined />}
                  onClick={() =>
                    modal.confirm({
                      title: `删除「${vendor.name}」？`,
                      content: "用到它的步骤会被清空。",
                      okButtonProps: { danger: true },
                      onOk: async () => {
                        await call("deleteVendor", vendor.id);
                        settings.reload();
                      },
                    })
                  }
                />
              </Space>
            ),
          },
        ]}
      />
      <Card title="各步骤使用的模型" size="small" style={{ marginTop: 20 }}>
        {Object.entries(bundle.llmSteps).map(([step, info]) => (
          <AssignmentRow key={step} step={step} label={info.label} needsVision={info.needsVision} bundle={bundle} onSaved={settings.reload} />
        ))}
      </Card>
      <VendorModal bundle={bundle} value={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); settings.reload(); }} />
    </div>
  );
}

function AssignmentRow({ step, label, needsVision, bundle, onSaved }: { step: string; label: string; needsVision: boolean; bundle: SettingsBundle; onSaved: () => void }) {
  const { message } = App.useApp();
  const current = bundle.settings.llm.assignments[step];
  const [vendorId, setVendorId] = useState<string | undefined>(current?.vendorId);
  const [model, setModel] = useState<string>(current?.model || "");
  const [testing, setTesting] = useState(false);
  useEffect(() => {
    setVendorId(current?.vendorId);
    setModel(current?.model || "");
  }, [current?.vendorId, current?.model]);
  const vendor = bundle.settings.llm.vendors.find((item) => item.id === vendorId);
  const suggestions = [...new Set([...(vendor?.models || []), ...(vendor ? bundle.presets.llm[vendor.preset]?.suggestedModels || [] : [])])];
  const deepseekVision = needsVision && vendor?.preset === "deepseek";

  return (
    <Row gutter={12} align="middle" style={{ marginBottom: 12 }}>
      <Col span={5}>
        <Space direction="vertical" size={0}>
          <Typography.Text strong>{label}</Typography.Text>
          {needsVision && <span className="muted" style={{ fontSize: 12 }}>需要看图模型</span>}
        </Space>
      </Col>
      <Col span={6}>
        <Select allowClear style={{ width: "100%" }} placeholder="选择厂商" value={vendorId} onChange={(value) => setVendorId(value)} options={bundle.settings.llm.vendors.map((item) => ({ value: item.id, label: item.name }))} />
      </Col>
      <Col span={7}>
        <AutoComplete style={{ width: "100%" }} placeholder="模型名" value={model} onChange={setModel} options={suggestions.map((value) => ({ value }))} filterOption={(input, option) => String(option?.value).toLowerCase().includes(input.toLowerCase())} />
      </Col>
      <Col span={6}>
        <Space>
          <Button
            type="primary"
            onClick={async () => {
              await call("setAssignment", step, vendorId && model ? { vendorId, model } : null);
              message.success(`「${label}」已保存`);
              onSaved();
            }}
          >
            保存
          </Button>
          <Button
            loading={testing}
            disabled={!vendorId || !model}
            onClick={async () => {
              setTesting(true);
              try {
                const result = await call<{ reply: string; ms: number }>("testVendor", vendorId, model, { vision: needsVision });
                message.success(`可用（${result.ms} 毫秒）：${result.reply}`);
              } catch (error) {
                message.error((error as Error).message);
              } finally {
                setTesting(false);
              }
            }}
          >
            测试
          </Button>
        </Space>
      </Col>
      {deepseekVision && (
        <Col span={24} style={{ marginTop: 6 }}>
          <Alert type="warning" showIcon message="DeepSeek 目前没有看图模型，这一步建议改用 OpenAI 或智谱的看图模型" />
        </Col>
      )}
    </Row>
  );
}

function VendorModal({ bundle, value, onClose, onSaved }: { bundle: SettingsBundle; value: Partial<LlmVendor> | null; onClose: () => void; onSaved: () => void }) {
  const { message } = App.useApp();
  const [form] = Form.useForm();
  const [busy, setBusy] = useState(false);
  const isNew = !value?.id;
  useEffect(() => {
    if (!value) return;
    const preset = bundle.presets.llm[value.preset || "deepseek"];
    form.resetFields();
    form.setFieldsValue({ name: preset.label, baseUrl: preset.baseUrl, jsonMode: preset.jsonMode, ...value, apiKey: "" });
  }, [value, bundle, form]);
  return (
    <Modal
      title={isNew ? "添加大模型厂商" : `编辑：${value?.name}`}
      open={Boolean(value)}
      onCancel={onClose}
      confirmLoading={busy}
      destroyOnHidden
      onOk={async () => {
        const values = await form.validateFields();
        setBusy(true);
        try {
          await call("saveVendor", { ...value, ...values, apiKey: values.apiKey || undefined });
          onSaved();
        } catch (error) {
          message.error((error as Error).message);
        } finally {
          setBusy(false);
        }
      }}
    >
      <Form form={form} layout="vertical">
        <Form.Item name="preset" label="厂商">
          <Radio.Group
            optionType="button"
            options={Object.entries(bundle.presets.llm).map(([key, preset]) => ({ value: key, label: preset.label }))}
            onChange={(event) => {
              const preset = bundle.presets.llm[event.target.value];
              form.setFieldsValue({ name: preset.label, baseUrl: preset.baseUrl, jsonMode: preset.jsonMode });
            }}
          />
        </Form.Item>
        <Form.Item name="name" label="名称" rules={[{ required: true }]}>
          <Input />
        </Form.Item>
        <Form.Item name="baseUrl" label="接口地址" rules={[{ required: true }]}>
          <Input placeholder="https://.../v1" />
        </Form.Item>
        <Form.Item name="apiKey" label="密钥" extra={!isNew && bundle.vendorKeys[value!.id!] ? "已保存，留空表示不修改" : "加密保存在本机"}>
          <Input.Password autoComplete="off" />
        </Form.Item>
        <Form.Item name="jsonMode" label="要求返回 JSON 格式（不支持的模型会自动降级）" valuePropName="checked">
          <Switch />
        </Form.Item>
      </Form>
    </Modal>
  );
}
