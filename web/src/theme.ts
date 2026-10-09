import { useEffect, useState } from "react";
import { theme, type ThemeConfig } from "antd";

/**
 * 按 macOS 27（Liquid Glass 修订版）的规则配的主题：
 * - 玻璃只用在导航和控件层（侧边栏、工具栏按钮），内容（卡片、列表）保持实色；
 * - 侧边栏是浮起来的圆角面板，按钮是胶囊形，圆角更大、内外同心；
 * - 正文 14px（比系统默认 13pt 大一号，看着更舒服），容器内边距收紧，比例协调；
 * - 颜色用系统色（systemBlue / systemGreen …），浅色/深色跟随系统。
 */
const APPLE = {
  light: {
    accent: "#007AFF",
    green: "#34C759",
    orange: "#FF9500",
    red: "#FF3B30",
    label: "rgba(0, 0, 0, 0.88)",
    secondary: "rgba(60, 60, 67, 0.62)",
    tertiary: "rgba(60, 60, 67, 0.3)",
    separator: "rgba(60, 60, 67, 0.13)",
    content: "#F2F2F5",
    box: "#FFFFFF",
    fill: "rgba(120, 120, 128, 0.12)",
    selection: "rgba(120, 120, 128, 0.16)",
    focus: "rgba(0, 122, 255, 0.28)",
  },
  dark: {
    accent: "#0A84FF",
    green: "#30D158",
    orange: "#FF9F0A",
    red: "#FF453A",
    label: "rgba(255, 255, 255, 0.92)",
    secondary: "rgba(235, 235, 245, 0.6)",
    tertiary: "rgba(235, 235, 245, 0.3)",
    separator: "rgba(84, 84, 88, 0.6)",
    content: "#161618",
    box: "#242426",
    fill: "rgba(120, 120, 128, 0.24)",
    selection: "rgba(120, 120, 128, 0.32)",
    focus: "rgba(10, 132, 255, 0.4)",
  },
};

export const FONT_FAMILY = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif';

export function useSystemDark() {
  const query = typeof window !== "undefined" ? window.matchMedia("(prefers-color-scheme: dark)") : null;
  const [dark, setDark] = useState(Boolean(query?.matches));
  useEffect(() => {
    if (!query) return;
    const handler = (event: MediaQueryListEvent) => setDark(event.matches);
    query.addEventListener("change", handler);
    return () => query.removeEventListener("change", handler);
  }, [query]);
  useEffect(() => {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
  }, [dark]);
  return dark;
}

export function appleTheme(dark: boolean): ThemeConfig {
  const c = dark ? APPLE.dark : APPLE.light;
  const softShadow = dark ? "0 10px 32px rgba(0, 0, 0, 0.45)" : "0 10px 32px rgba(0, 0, 0, 0.12), 0 0 0 0.5px rgba(0, 0, 0, 0.06)";
  return {
    algorithm: dark ? theme.darkAlgorithm : theme.defaultAlgorithm,
    token: {
      colorPrimary: c.accent,
      colorInfo: c.accent,
      colorLink: c.accent,
      colorSuccess: c.green,
      colorWarning: c.orange,
      colorError: c.red,
      colorText: c.label,
      colorTextSecondary: c.secondary,
      colorTextTertiary: c.secondary,
      colorTextQuaternary: c.tertiary,
      colorTextDescription: c.secondary,
      colorBorder: dark ? "rgba(235, 235, 245, 0.16)" : "rgba(60, 60, 67, 0.18)",
      colorBorderSecondary: c.separator,
      colorSplit: c.separator,
      colorBgLayout: c.content,
      colorBgContainer: c.box,
      colorBgElevated: dark ? "#2C2C2E" : "#FFFFFF",
      colorFillSecondary: c.fill,
      fontFamily: FONT_FAMILY,
      fontSize: 14,
      fontSizeSM: 12,
      fontSizeLG: 15,
      fontSizeHeading2: 24,
      fontWeightStrong: 600,
      lineHeight: 1.5,
      borderRadius: 10,
      borderRadiusSM: 7,
      borderRadiusLG: 16,
      borderRadiusXS: 5,
      controlHeight: 32,
      controlHeightSM: 26,
      controlHeightLG: 38,
      padding: 14,
      paddingLG: 18,
      margin: 14,
      marginLG: 18,
      boxShadow: softShadow,
      boxShadowSecondary: softShadow,
      motionDurationMid: "0.18s",
      motionDurationSlow: "0.24s",
      wireframe: false,
    },
    components: {
      Layout: { siderBg: "transparent", bodyBg: c.content },
      Menu: {
        itemBg: "transparent",
        itemColor: c.label,
        itemHoverBg: c.fill,
        itemSelectedBg: c.selection,
        itemSelectedColor: c.label,
        itemActiveBg: c.selection,
        itemHeight: 36,
        itemMarginBlock: 2,
        itemMarginInline: 8,
        itemBorderRadius: 10,
        iconSize: 16,
        activeBarBorderWidth: 0,
      },
      // 胶囊按钮
      Button: {
        borderRadius: 16,
        borderRadiusSM: 13,
        borderRadiusLG: 19,
        fontWeight: 500,
        primaryShadow: "none",
        defaultShadow: "none",
        dangerShadow: "none",
        paddingInline: 16,
        paddingInlineSM: 12,
        defaultBg: dark ? "rgba(120, 120, 128, 0.24)" : "rgba(120, 120, 128, 0.1)",
        defaultBorderColor: "transparent",
        defaultHoverBg: dark ? "rgba(120, 120, 128, 0.32)" : "rgba(120, 120, 128, 0.16)",
        defaultHoverBorderColor: "transparent",
        defaultActiveBg: dark ? "rgba(120, 120, 128, 0.4)" : "rgba(120, 120, 128, 0.22)",
        defaultActiveBorderColor: "transparent",
      },
      Card: { headerFontSize: 15, headerFontSizeSM: 15, headerHeight: 48, headerHeightSM: 46, headerBg: "transparent", bodyPadding: 18, bodyPaddingSM: 16, headerPadding: 18, headerPaddingSM: 16 },
      Table: {
        headerBg: "transparent",
        headerColor: c.secondary,
        headerSplitColor: "transparent",
        borderColor: c.separator,
        rowHoverBg: dark ? "rgba(255, 255, 255, 0.04)" : "rgba(0, 0, 0, 0.022)",
        rowSelectedBg: dark ? "rgba(10, 132, 255, 0.18)" : "rgba(0, 122, 255, 0.08)",
        rowSelectedHoverBg: dark ? "rgba(10, 132, 255, 0.24)" : "rgba(0, 122, 255, 0.12)",
        cellPaddingBlock: 11,
        cellPaddingInline: 14,
        cellPaddingBlockMD: 10,
        cellPaddingInlineMD: 14,
        cellPaddingBlockSM: 7,
        headerBorderRadius: 16,
      },
      Tabs: { inkBarColor: "transparent", itemSelectedColor: c.label, itemColor: c.secondary, itemHoverColor: c.label, horizontalMargin: "0 0 16px 0" },
      Segmented: { trackBg: c.fill, itemSelectedBg: dark ? "#636366" : "#FFFFFF", itemColor: c.label, itemSelectedColor: c.label, trackPadding: 3, borderRadius: 16, borderRadiusSM: 13 },
      Input: { activeShadow: `0 0 0 3px ${c.focus}`, paddingInline: 12, borderRadius: 10 },
      InputNumber: { activeShadow: `0 0 0 3px ${c.focus}`, borderRadius: 10 },
      Select: { optionSelectedBg: c.selection, activeOutlineColor: c.focus, borderRadius: 10, optionHeight: 34 },
      Modal: { titleFontSize: 17, borderRadiusLG: 22, contentBg: dark ? "#2C2C2E" : "#FFFFFF", headerBg: "transparent" },
      Tag: { defaultBg: c.fill, defaultColor: c.label, borderRadiusSM: 999 },
      Progress: { defaultColor: c.accent, remainingColor: c.fill, lineBorderRadius: 999 },
      Alert: { withDescriptionPadding: "14px 18px", borderRadiusLG: 14 },
      Breadcrumb: { linkColor: c.secondary, lastItemColor: c.label, separatorColor: c.tertiary },
      Switch: { trackHeight: 22, handleSize: 18, trackMinWidth: 40 },
      Checkbox: { borderRadiusSM: 5 },
      Descriptions: { labelBg: "transparent" },
      Collapse: { headerBg: "transparent", contentBg: "transparent" },
    },
  };
}
