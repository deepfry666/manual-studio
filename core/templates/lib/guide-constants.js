"use strict";

/**
 * 共享布局常量 —— 全部来自 references/word-format.md 的固定样式规范。
 * create-guide-docx.js 与任何排版相关逻辑都从这里取值，保证不同项目零漂移。
 *
 * 单位换算（docx 包）：
 *   - 字号 size：half-points（半磅）。11pt -> 22，9pt -> 18，14pt -> 28，22pt -> 44。
 *   - 行距 line：twips/240 表示倍数。1.0 倍 = 240，1.25 倍 = 300，1.3 倍 = 312。
 *   - 段距 before/after：twips。1pt = 20 twips。6pt -> 120，8pt -> 160，4pt -> 80。
 *   - 页面/边距：twips。1cm = 567 twips（精确 566.93，取整 567）。
 *   - 表格边框/单元格边距：边距用 twips；边框 size 用 1/8 pt（eighths）。0.5pt -> 4。
 */

// 文件名后缀（与 validator / 现有脚本保持字节一致）
const GUIDE_SUFFIX = "指南";
const CODE_SUFFIX = "指南_代码-（JAVA）";

// 字体
const FONT_CJK = "Microsoft YaHei"; // 默认中文字体
const FONT_CJK_FALLBACK = "SimSun"; // 仅当 YaHei 不可用时
const FONT_LATIN = "Arial"; // 默认西文字体

// 颜色（hex，不带 #，docx 要求）
const COLOR_BODY = "1F2933"; // 正文 / 封面介绍 / 表格文本
const COLOR_TITLE = "111827"; // 封面标题 / 功能标题
const COLOR_META = "4B5563"; // 封面元信息 / 页眉
const COLOR_CAPTION = "6B7280"; // 图注
const COLOR_TABLE_BORDER = "D1D5DB"; // 表格边框
const COLOR_ACCENT = "2563EB"; // 可选强调色（默认不用）

// 字号（half-points）
const SIZE_BODY = 22; // 11pt
const SIZE_COVER_TITLE = 44; // 22pt
const SIZE_COVER_META = 22; // 11pt
const SIZE_HEADER = 18; // 9pt
const SIZE_FEATURE_TITLE = 28; // 14pt
const SIZE_CAPTION = 18; // 9pt

// 行距（line, 240 基准）
const LINE_BODY = 300; // 1.25 倍
const LINE_OVERVIEW = 312; // 1.3 倍

// 段距（twips）
const AFTER_BODY = 120; // 6pt
const AFTER_FEATURE_TITLE = 160; // 8pt
const BEFORE_CAPTION = 80; // 4pt
const AFTER_CAPTION = 0;

// 页面（A4 纵向，twips）—— docx 也内置 PageSize.A4，但显式给值更稳
const CM = 567; // 1cm 的 twips
const PAGE_WIDTH = Math.round(21.0 * CM); // A4 宽 21cm
const PAGE_HEIGHT = Math.round(29.7 * CM); // A4 高 29.7cm
const MARGIN_TOP = Math.round(2.2 * CM);
const MARGIN_BOTTOM = Math.round(2.0 * CM);
const MARGIN_LEFT = Math.round(2.0 * CM);
const MARGIN_RIGHT = Math.round(2.0 * CM);
const MARGIN_HEADER = 720; // 页眉距顶
const MARGIN_FOOTER = 720;

// 可用正文宽度（表格总宽参照）
const USABLE_WIDTH = PAGE_WIDTH - MARGIN_LEFT - MARGIN_RIGHT;

// 两列表格列宽 —— 近似 48/52（左图右文）
const COL_IMAGE_WIDTH = Math.round(USABLE_WIDTH * 0.48);
const COL_TEXT_WIDTH = USABLE_WIDTH - COL_IMAGE_WIDTH;

// 表格边框（0.5pt -> 4 eighths）
const TABLE_BORDER_SIZE = 4;

// 表格单元格内边距（twips）：上下 0.12cm，左右 0.16cm
const CELL_MARGIN_TB = Math.round(0.12 * CM);
const CELL_MARGIN_LR = Math.round(0.16 * CM);

// 截图在 Word 中的受控宽度（px）。只锁宽，按原图比例算高。
const IMAGE_WIDTH_PX = 320; // 落在 word-format 要求的 300–340 区间中部
const SOURCE_IMAGE_SIZE_DEFAULT = "862x1825"; // 默认锁定的长屏手机竖屏尺寸

// 功能文字固定 300 字档
const DEFAULT_FEATURE_TIER = 300;
const FEATURE_TEXT_FLOOR = 300;

module.exports = {
  GUIDE_SUFFIX,
  CODE_SUFFIX,
  FONT_CJK,
  FONT_CJK_FALLBACK,
  FONT_LATIN,
  COLOR_BODY,
  COLOR_TITLE,
  COLOR_META,
  COLOR_CAPTION,
  COLOR_TABLE_BORDER,
  COLOR_ACCENT,
  SIZE_BODY,
  SIZE_COVER_TITLE,
  SIZE_COVER_META,
  SIZE_HEADER,
  SIZE_FEATURE_TITLE,
  SIZE_CAPTION,
  LINE_BODY,
  LINE_OVERVIEW,
  AFTER_BODY,
  AFTER_FEATURE_TITLE,
  BEFORE_CAPTION,
  AFTER_CAPTION,
  CM,
  PAGE_WIDTH,
  PAGE_HEIGHT,
  MARGIN_TOP,
  MARGIN_BOTTOM,
  MARGIN_LEFT,
  MARGIN_RIGHT,
  MARGIN_HEADER,
  MARGIN_FOOTER,
  USABLE_WIDTH,
  COL_IMAGE_WIDTH,
  COL_TEXT_WIDTH,
  TABLE_BORDER_SIZE,
  CELL_MARGIN_TB,
  CELL_MARGIN_LR,
  IMAGE_WIDTH_PX,
  SOURCE_IMAGE_SIZE_DEFAULT,
  DEFAULT_FEATURE_TIER,
  FEATURE_TEXT_FLOOR,
};
