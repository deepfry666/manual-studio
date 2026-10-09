import { Tabs } from "antd";
import { navigate } from "../hooks";
import { ProvidersPage } from "./Providers";
import { LlmPage } from "./Llm";
import { CallsPage } from "./Calls";

/** 生图线路、大模型、调用记录放在一起：都是「生成用到的服务」，和软件本身的设置分开。 */
export function ModelsPage({ tab }: { tab?: string }) {
  const active = ["providers", "llm", "calls"].includes(tab || "") ? (tab as string) : "providers";
  return (
    <div className="page">
      <div className="page-header">
        <h2>模型与线路</h2>
      </div>
      <Tabs
        activeKey={active}
        onChange={(key) => navigate("models", key)}
        destroyOnHidden
        items={[
          { key: "providers", label: "生图线路", children: <div className="embedded"><ProvidersPage /></div> },
          { key: "llm", label: "大模型", children: <div className="embedded"><LlmPage /></div> },
          { key: "calls", label: "调用记录", children: <div className="embedded"><CallsPage /></div> },
        ]}
      />
    </div>
  );
}
