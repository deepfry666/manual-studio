/**
 * S2：由程序把共享 UI 约束 + 单屏计划拼成生图提示词。
 * 末尾的品牌禁令段固定追加，界面上不能编辑。
 */
export const BRAND_BAN_BLOCK =
  "Do NOT render the software name, App name, version string, name-bearing logo, wordmark, or recognizable project-name branding anywhere in the UI.";

function isAndroid(platform) {
  return /android|安卓/i.test(platform || "");
}

function paletteText(palette = {}) {
  return Object.entries(palette)
    .filter(([, value]) => typeof value === "string" && value)
    .map(([key, value]) => `${key} ${value}`)
    .join(", ");
}

function navigationSentence(ui, screen) {
  const nav = ui?.navigation || {};
  const labels = Array.isArray(nav.labels) ? nav.labels.filter(Boolean) : [];
  if (!labels.length || /none|stack/i.test(nav.type || "") || !screen.activeTab) {
    return labels.length ? "Hide the bottom tab bar on this screen; use a native top navigation bar with a back control where appropriate." : "";
  }
  const icons = Array.isArray(nav.iconSemantics) && nav.iconSemantics.length ? ` (icons: ${nav.iconSemantics.join(", ")})` : "";
  return `Show bottom tabs exactly ${labels.join("、")} in that order with ${screen.activeTab} active and matching line icons${icons}.`;
}

export function composeScreenPrompt({ softwareName, platform, targetSize, ui, screen }) {
  const android = isAndroid(platform);
  const device = android ? "native Android" : "native iOS";
  const statusBar = android
    ? "Use one consistent Android status bar with the same time and battery style on every screen."
    : "Use one fixed iOS status bar at 9:41 with the same signal, Wi-Fi and icon-only battery style on every screen.";
  const visual = [
    ui?.visualStyle ? `Visual style: ${ui.visualStyle}.` : "",
    ui?.palette ? `Palette: ${paletteText(ui.palette)}.` : "",
    ui?.typography ? `Typography: ${ui.typography}.` : "",
    ui?.radius ? `Corner radius: ${ui.radius}.` : "",
    ui?.shadow ? `Shadow: ${ui.shadow}.` : "",
    ui?.density ? `Density: ${ui.density}.` : "",
  ]
    .filter(Boolean)
    .join(" ");

  const lines = [
    "Use case: ui-mockup",
    "Asset type: Chinese software manual screenshot",
    `Create exactly one complete ${device} portrait app viewport as a PNG, no physical phone frame, no bezel, no collage, no multi-screen layout. Use ${platform} around ${targetSize}. ${statusBar} ${visual}`.trim(),
    "",
    `Screen: ${screen.title}. Page type: ${screen.pageType || "app screen"}. ${screen.visualBrief || ""}`.trim(),
    screen.mustShow?.length ? `Must show: ${screen.mustShow.join("; ")}.` : "",
    screen.sampleData?.length ? `Use these exact sample values where they appear: ${screen.sampleData.join("; ")}. Keep figures consistent with the other screens.` : "",
    navigationSentence(ui, screen),
    "All interface text must be natural Simplified Chinese with correct characters.",
    "",
    `Project context exact software name: ${softwareName}. Use it only as context and never show it in the UI. No app name, version, logo, wordmark, physical phone shell, ${android ? "iOS status bar" : "Android navigation"}, or watermark.`,
    "",
    BRAND_BAN_BLOCK,
  ];
  return lines.filter((line, index, all) => line !== "" || (all[index - 1] !== "" && index > 0)).join("\n").trim() + "\n";
}

/** 用户在界面上编辑提示词后，保证禁令段仍在末尾。 */
export function ensureBrandBan(prompt) {
  const text = String(prompt || "").replace(BRAND_BAN_BLOCK, "").trimEnd();
  return `${text}\n\n${BRAND_BAN_BLOCK}\n`;
}
