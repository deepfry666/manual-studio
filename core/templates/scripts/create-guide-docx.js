#!/usr/bin/env node
"use strict";

/**
 * create-guide-docx.js —— 主指南 Word 排版脚本（确定性，零创作）。
 *
 * 输入：一份 AI 产出的 content.json，结构见 references/content-schema.json。
 * 输出：内层交付夹 {project}/{software}/{software}指南.docx，严格遵循
 *       references/word-format.md 的固定样式（全部常量集中在 lib/guide-constants.js）。
 *
 * 关键不变量（与 validate-delivery-artifacts.js 对齐）：
 *   - DOCX 正文 XML 与页眉都含精确软件名；仅 separate-metadata 模式出现“适用版本”。
 *   - 内嵌图片数 = screens 数（1..screenshotCount），每张 图N 只在图注里出现一次，
 *     右栏文字绝不含“图N ”字样（否则 /图N[^<]{0,40}/ 会匹配两次而校验失败）。
 *   - 每屏独占一页（节前插分页），最后一节后不留空白页/空段落。
 *
 * 用法：
 *   node create-guide-docx.js --project <外层项目夹> --software <软件名> --content <content.json>
 *
 * 可选：
 *   --region-out <file>   把本次生成填充的 region 片段写成 JSON（供 build.js 合并进 region-index）
 */

const fs = require("fs");
const path = require("path");
const {
  AlignmentType,
  BorderStyle,
  Document,
  Header,
  ImageRun,
  Packer,
  PageNumber,
  PageOrientation,
  Paragraph,
  ShadingType,
  Table,
  TableCell,
  TableRow,
  TextRun,
  VerticalAlign,
  WidthType,
} = require("docx");

const C = require("../lib/guide-constants");
const { readImageSize, imageRunType } = require("../lib/image-size");

// ---------- 参数解析 ----------
function usage() {
  console.error(
    "Usage: node create-guide-docx.js --project <dir> --software <name> --content <content.json> [--region-out <file>]"
  );
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === "--project") args.project = argv[++i];
    else if (key === "--software") args.software = argv[++i];
    else if (key === "--content") args.content = argv[++i];
    else if (key === "--region-out") args.regionOut = argv[++i];
    else if (key === "--help" || key === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${key}`);
  }
  return args;
}

// ---------- 内容校验 ----------
function countTextLength(text) {
  return String(text || "").trim().length;
}

/**
 * 入口校验 content.json。硬错误 -> 抛异常退出。
 * @returns {object} 规范化后的内容对象
 */
function validateContent(content, software) {
  const errors = [];

  if (!content || typeof content !== "object") {
    throw new Error("content.json 不是合法对象");
  }
  if (content.softwareName && content.softwareName !== software) {
    errors.push(
      `content.softwareName(${content.softwareName}) 与 --software(${software}) 不一致`
    );
  }
  const cover = content.cover || {};
  if (typeof cover.overview !== "string" || cover.overview.trim() === "") {
    errors.push("cover.overview 缺失或为空（AI 必填的封面介绍）");
  }
  if (/适用版本/.test(JSON.stringify(content)) && content.versionPolicy !== "separate-metadata") {
    errors.push('versionPolicy 非 separate-metadata 时，内容中不得出现“适用版本”');
  }

  const screens = Array.isArray(content.screens) ? content.screens : [];
  if (screens.length < 1) {
    errors.push("screens 至少需要 1 屏");
  }
  if (
    Number.isInteger(content.screenshotCount) &&
    content.screenshotCount !== screens.length
  ) {
    errors.push(
      `screenshotCount(${content.screenshotCount}) 与 screens 数量(${screens.length}) 不一致`
    );
  }

  const floor = C.FEATURE_TEXT_FLOOR;
  const seenCaptions = new Set();

  screens.forEach((s, idx) => {
    const n = idx + 1;
    const where = `screen-${String(n).padStart(2, "0")}`;
    if (!s || typeof s !== "object") {
      errors.push(`${where} 不是对象`);
      return;
    }
    if (typeof s.title !== "string" || s.title.trim() === "") {
      errors.push(`${where}.title 缺失`);
    }
    if (typeof s.text !== "string" || s.text.trim() === "") {
      errors.push(`${where}.text 缺失`);
    }
    if (typeof s.image !== "string" || s.image.trim() === "") {
      errors.push(`${where}.image 路径缺失`);
    }
    // 图注：必须恰好以“图N ”开头，且全局唯一
    const expectedPrefix = `图${n}`;
    const caption = typeof s.caption === "string" ? s.caption.trim() : "";
    if (!caption.startsWith(expectedPrefix)) {
      errors.push(`${where}.caption 必须以“${expectedPrefix}”开头，实际：${caption || "<空>"}`);
    }
    if (seenCaptions.has(caption)) {
      errors.push(`图注重复：${caption}`);
    }
    seenCaptions.add(caption);
    // 右栏文字不得含“图N ”，否则 validator 的 /图N[^<]{0,40}/ 会匹配两次
    for (let k = 1; k <= screens.length; k += 1) {
      const reuse = new RegExp(`图${k}(?![0-9])`);
      if (reuse.test(s.text)) {
        errors.push(`${where}.text 含“图${k}”字样，会与图注重复触发校验失败；请改写右栏文字`);
        break;
      }
    }
    // 固定 300 字符地板是交付硬约束。
    const chars = countTextLength(s.text);
    if (chars < floor) {
      errors.push(`${where}.text 仅 ${chars} 个字符，低于固定 300 字符地板 ${floor}`);
    }
  });

  let design = null;
  if (content.design !== undefined && content.design !== null) {
    if (
      !content.design ||
      typeof content.design !== "object" ||
      Array.isArray(content.design) ||
      !Array.isArray(content.design.sections) ||
      content.design.sections.length === 0
    ) {
      errors.push("design 必须包含非空 sections 数组");
    } else {
      design = {
        sections: content.design.sections.map((section, index) => {
          const where = `design.sections[${index}]`;
          const title = typeof section?.title === "string" ? section.title.trim() : "";
          const text = typeof section?.text === "string" ? section.text.trim() : "";
          if (!title) errors.push(`${where}.title 缺失`);
          if (!text) errors.push(`${where}.text 缺失`);
          if (/图\d+(?!\d)/.test(`${title}\n${text}`)) {
            errors.push(`${where} 不得使用“图N”字样，以免与截图图注冲突`);
          }
          return { title, text };
        }),
      };
    }
  }

  if (errors.length) {
    throw new Error("content.json 校验失败：\n- " + errors.join("\n- "));
  }
  return { screens, cover, design, tier: C.DEFAULT_FEATURE_TIER };
}

// ---------- 通用样式 run ----------
function run(text, opts = {}) {
  return new TextRun({
    text,
    font: opts.font || C.FONT_CJK,
    size: opts.size || C.SIZE_BODY,
    color: opts.color || C.COLOR_BODY,
    bold: !!opts.bold,
  });
}

// ---------- 页眉：左软件名，右“第 X 页”页码域 ----------
function buildHeader(software) {
  // 用两格无边框表格实现真正的左右贴边
  const noBorder = { style: BorderStyle.NONE, size: 0, color: "FFFFFF" };
  const borders = { top: noBorder, bottom: noBorder, left: noBorder, right: noBorder };
  return new Header({
    children: [
      new Table({
        width: { size: C.USABLE_WIDTH, type: WidthType.DXA },
        borders: { ...borders, insideHorizontal: noBorder, insideVertical: noBorder },
        rows: [
          new TableRow({
            children: [
              new TableCell({
                borders,
                width: { size: Math.round(C.USABLE_WIDTH / 2), type: WidthType.DXA },
                children: [
                  new Paragraph({
                    alignment: AlignmentType.LEFT,
                    spacing: { before: 0, after: 0 },
                    children: [
                      run(software, { size: C.SIZE_HEADER, color: C.COLOR_META }),
                    ],
                  }),
                ],
              }),
              new TableCell({
                borders,
                width: { size: Math.round(C.USABLE_WIDTH / 2), type: WidthType.DXA },
                children: [
                  new Paragraph({
                    alignment: AlignmentType.RIGHT,
                    spacing: { before: 0, after: 0 },
                    children: [
                      run("第 ", { size: C.SIZE_HEADER, color: C.COLOR_META }),
                      new TextRun({
                        children: [PageNumber.CURRENT],
                        font: C.FONT_CJK,
                        size: C.SIZE_HEADER,
                        color: C.COLOR_META,
                      }),
                      run(" 页", { size: C.SIZE_HEADER, color: C.COLOR_META }),
                    ],
                  }),
                ],
              }),
            ],
          }),
        ],
      }),
    ],
  });
}

// ---------- 封面 ----------
function buildCover(software, content) {
  const children = [];
  // 标题：{软件名} 用户手册
  children.push(
    new Paragraph({
      alignment: AlignmentType.CENTER,
      spacing: { before: 480, after: 240 },
      children: [
        run(`${software} 用户手册`, {
          bold: true,
          size: C.SIZE_COVER_TITLE,
          color: C.COLOR_TITLE,
        }),
      ],
    })
  );
  // 编制时间
  const date = content.compileDate || content.createdAtCn || defaultCnDate();
  children.push(
    new Paragraph({
      alignment: AlignmentType.CENTER,
      spacing: { before: 0, after: 80 },
      children: [run(`编制时间：${date}`, { size: C.SIZE_COVER_META, color: C.COLOR_META })],
    })
  );
  // 可选：仅 separate-metadata 时输出适用版本
  if (content.versionPolicy === "separate-metadata" && content.applicableVersion) {
    children.push(
      new Paragraph({
        alignment: AlignmentType.CENTER,
        spacing: { before: 0, after: 80 },
        children: [
          run(`适用版本：${content.applicableVersion}`, {
            size: C.SIZE_COVER_META,
            color: C.COLOR_META,
          }),
        ],
      })
    );
  }
  // 封面介绍段落（可多段，按换行拆）
  const overviewParas = String(content.cover.overview)
    .replace(/\r\n/g, "\n")
    .split(/\n+/)
    .map((p) => p.trim())
    .filter(Boolean);
  overviewParas.forEach((p, i) => {
    children.push(
      new Paragraph({
        alignment: AlignmentType.JUSTIFIED,
        spacing: {
          before: i === 0 ? 240 : 0,
          after: C.AFTER_BODY,
          line: C.LINE_OVERVIEW,
        },
        children: [run(p, { color: C.COLOR_BODY })],
      })
    );
  });
  return children;
}

function defaultCnDate() {
  // 仅作兜底；正常应由 content 显式提供，避免 Date.now 不确定性
  const d = new Date();
  return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`;
}

// ---------- 单屏区块（左图右文表格 + 节前分页） ----------
function buildScreenSection(software, screen, index, project, regionFill) {
  const n = index + 1;
  const id = `screen-${String(n).padStart(2, "0")}`;

  // 解析图片真实尺寸，按受控宽算高，绝不拉伸
  const imageAbs = path.isAbsolute(screen.image)
    ? screen.image
    : path.join(project, screen.image);
  if (!fs.existsSync(imageAbs)) {
    throw new Error(`${id} 截图不存在：${imageAbs}`);
  }
  const { width: srcW, height: srcH, type } = readImageSize(imageAbs);
  const drawW = C.IMAGE_WIDTH_PX;
  const drawH = Math.round((srcH / srcW) * drawW);

  const imageRun = new ImageRun({
    type: imageRunType(type),
    data: fs.readFileSync(imageAbs),
    transformation: { width: drawW, height: drawH },
  });

  const caption = screen.caption.trim();

  // 左列：截图 + 唯一图注
  const leftCell = new TableCell({
    verticalAlign: VerticalAlign.CENTER,
    width: { size: C.COL_IMAGE_WIDTH, type: WidthType.DXA },
    margins: {
      top: C.CELL_MARGIN_TB,
      bottom: C.CELL_MARGIN_TB,
      left: C.CELL_MARGIN_LR,
      right: C.CELL_MARGIN_LR,
    },
    children: [
      new Paragraph({
        alignment: AlignmentType.CENTER,
        spacing: { before: 0, after: 0 },
        children: [imageRun],
      }),
      new Paragraph({
        alignment: AlignmentType.CENTER,
        spacing: { before: C.BEFORE_CAPTION, after: C.AFTER_CAPTION },
        children: [run(caption, { size: C.SIZE_CAPTION, color: C.COLOR_CAPTION })],
      }),
    ],
  });

  // 右列：功能标题（首行）+ 功能文字（不含任何图注）
  const textParas = String(screen.text)
    .replace(/\r\n/g, "\n")
    .split(/\n+/)
    .map((p) => p.trim())
    .filter(Boolean);

  const rightChildren = [
    new Paragraph({
      alignment: AlignmentType.LEFT,
      spacing: { before: 0, after: C.AFTER_FEATURE_TITLE },
      children: [
        run(screen.title.trim(), {
          bold: true,
          size: C.SIZE_FEATURE_TITLE,
          color: C.COLOR_TITLE,
        }),
      ],
    }),
    ...textParas.map(
      (p) =>
        new Paragraph({
          alignment: AlignmentType.JUSTIFIED,
          spacing: { before: 0, after: C.AFTER_BODY, line: C.LINE_BODY },
          children: [run(p, { color: C.COLOR_BODY })],
        })
    ),
  ];

  const rightCell = new TableCell({
    verticalAlign: VerticalAlign.TOP,
    width: { size: C.COL_TEXT_WIDTH, type: WidthType.DXA },
    margins: {
      top: C.CELL_MARGIN_TB,
      bottom: C.CELL_MARGIN_TB,
      left: C.CELL_MARGIN_LR,
      right: C.CELL_MARGIN_LR,
    },
    children: rightChildren,
  });

  const border = {
    style: BorderStyle.SINGLE,
    size: C.TABLE_BORDER_SIZE,
    color: C.COLOR_TABLE_BORDER,
  };
  const table = new Table({
    width: { size: C.USABLE_WIDTH, type: WidthType.DXA },
    borders: {
      top: border,
      bottom: border,
      left: border,
      right: border,
      insideHorizontal: border,
      insideVertical: border,
    },
    // 软件指南生成器补丁：整行不跨页，防止「图N」图注单独掉到下一页。
    rows: [new TableRow({ cantSplit: true, children: [leftCell, rightCell] })],
  });

  // 填 region 片段（供 build.js 合并）
  regionFill[id] = {
    label: screen.title.trim(),
    caption,
    image: screen.image,
    image_size: screen.image_size || `${srcW}x${srcH}`,
    text_anchor: screen.text_anchor || screen.title.trim(),
    summary: screen.summary || caption,
  };

  // 第 2 屏起，节前插分页符，保证每屏独占一页且尾部不留空白
  const para = new Paragraph({
    pageBreakBefore: n > 1,
    spacing: { before: 0, after: 0 },
    children: [],
  });

  return [para, table];
}

function buildDesignSections(design, regionFill) {
  if (!design || !Array.isArray(design.sections) || !design.sections.length) return [];
  const children = [];
  design.sections.forEach((section, index) => {
    const id = `design.section-${String(index + 1).padStart(2, "0")}`;
    children.push(
      new Paragraph({
        pageBreakBefore: index === 0,
        alignment: AlignmentType.LEFT,
        spacing: { before: 0, after: C.AFTER_FEATURE_TITLE },
        children: [
          run(section.title, {
            bold: true,
            size: C.SIZE_FEATURE_TITLE,
            color: C.COLOR_TITLE,
          }),
        ],
      })
    );
    const paragraphs = section.text
      .replace(/\r\n/g, "\n")
      .split(/\n+/)
      .map((value) => value.trim())
      .filter(Boolean);
    for (const paragraph of paragraphs) {
      children.push(
        new Paragraph({
          alignment: AlignmentType.JUSTIFIED,
          spacing: { before: 0, after: C.AFTER_BODY, line: C.LINE_BODY },
          children: [run(paragraph, { color: C.COLOR_BODY })],
        })
      );
    }
    regionFill[id] = {
      label: section.title,
      summary: section.text.slice(0, 80),
    };
  });
  return children;
}

// ---------- 文档组装 ----------
function buildDocument(software, content, project, regionFill) {
  const coverChildren = buildCover(software, content);
  const screenChildren = [];
  content.screens.forEach((screen, idx) => {
    screenChildren.push(...buildScreenSection(software, screen, idx, project, regionFill));
  });
  const designChildren = buildDesignSections(content.design, regionFill);

  return new Document({
    styles: {
      default: {
        document: {
          run: { font: C.FONT_CJK, size: C.SIZE_BODY, color: C.COLOR_BODY },
          paragraph: {
            alignment: AlignmentType.JUSTIFIED,
            spacing: { after: C.AFTER_BODY, line: C.LINE_BODY },
          },
        },
      },
    },
    sections: [
      {
        properties: {
          page: {
            size: {
              width: C.PAGE_WIDTH,
              height: C.PAGE_HEIGHT,
              orientation: PageOrientation.PORTRAIT,
            },
            margin: {
              top: C.MARGIN_TOP,
              right: C.MARGIN_RIGHT,
              bottom: C.MARGIN_BOTTOM,
              left: C.MARGIN_LEFT,
              header: C.MARGIN_HEADER,
              footer: C.MARGIN_FOOTER,
            },
          },
        },
        headers: { default: buildHeader(software) },
        children: [...coverChildren, ...screenChildren, ...designChildren],
      },
    ],
  });
}

// ---------- 主流程 ----------
async function main() {
  let args;
  try {
    args = parseArgs(process.argv);
  } catch (err) {
    console.error(err.message);
    usage();
    process.exit(2);
  }
  if (args.help || !args.project || !args.software || !args.content) {
    usage();
    process.exit(args.help ? 0 : 2);
  }

  try {
    const project = path.resolve(args.project);
    const software = args.software;
    const contentRaw = fs.readFileSync(path.resolve(args.content), "utf8");
    const content = JSON.parse(contentRaw);

    const normalized = validateContent(content, software);
    content.screens = normalized.screens;
    content.design = normalized.design;

    const regionFill = {};
    const doc = buildDocument(software, content, project, regionFill);

    const deliveryDir = path.join(project, software);
    fs.mkdirSync(deliveryDir, { recursive: true });
    const outDocx = path.join(deliveryDir, `${software}${C.GUIDE_SUFFIX}.docx`);
    const buffer = await Packer.toBuffer(doc);
    fs.writeFileSync(outDocx, buffer);
    console.log(`Guide DOCX created: ${outDocx}`);

    if (args.regionOut) {
      fs.writeFileSync(
        path.resolve(args.regionOut),
        JSON.stringify(regionFill, null, 2),
        "utf8"
      );
      console.log(`Region fragments written: ${path.resolve(args.regionOut)}`);
    }
  } catch (err) {
    console.error(err.message || err);
    process.exit(1);
  }
}

main();
