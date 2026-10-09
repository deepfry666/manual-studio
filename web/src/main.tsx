import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ConfigProvider, App as AntApp } from "antd";
import zhCN from "antd/locale/zh_CN";
import { App } from "./App";
import { appleTheme, useSystemDark } from "./theme";
import "./styles.css";

function Root() {
  // 浅色/深色跟随系统设置
  const dark = useSystemDark();
  return (
    <ConfigProvider locale={zhCN} theme={appleTheme(dark)}>
      <AntApp>
        <App />
      </AntApp>
    </ConfigProvider>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Root />
  </StrictMode>
);
