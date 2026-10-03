import fsp from "node:fs/promises";
import path from "node:path";
import JSZip from "jszip";
import { inspectPng } from "../gateway/image-check.mjs";
import { sha256 } from "../util/fsx.mjs";
import { countPdfPages } from "./runtime.mjs";
import { forbiddenBrandTokens, findBrandHits, textLength, hasFigureReference } from "../pipeline/brand.mjs";

export const GUIDE_SUFFIX = "指南";
export const CODE_SUFFIX = "指南_代码-（JAVA）";

export function expectedBundleFiles(name, { withCode, withPdf }) {
  const files = { guideDocx: `${name}${GUIDE_SUFFIX}.docx`, guideTxt: `${name}${GUIDE_SUFFIX}.txt` };
  if (withPdf) files.guidePdf = `${name}${GUIDE_SUFFIX}.pdf`;
  if (withCode) {
    files.codeDocx = `${name}${CODE_SUFFIX}.docx`;
    if (withPdf) files.codePdf = `${name}${CODE_SUFFIX}.pdf`;
  }
  return files;
}

function xmlEscape(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

async function inspectDocx(file) {
  const zip = await JSZip.loadAsync(await fsp.readFile(file));
  const entries = Object.keys(zip.files);
  const xmlEntries = entries.filter((entry) => entry.startsWith("word/") && entry.endsWith(".xml"));
  const texts = await Promise.all(xmlEntries.map((entry) => zip.file(entry).async("string")));
  return {
    xml: texts.join("\n"),
    headerXml: texts.filter((_, index) => xmlEntries[index].startsWith("word/header")).join("\n"),
    mediaCount: entries.filter((entry) => entry.startsWith("word/media/") && !zip.files[entry].dir).length,
  };
}

/**
 * 交付校验（在 staging 里跑，通过后才替换正式交付包）。
 * 返回 { errors, warnings }。
 */
export async function validateDelivery({ projectDir, bundleDir, softwareName, content, withCode, withPdf, extraBrandTokens = [], floor = 300 }) {
  const errors = [];
  const warnings = [];
  const fail = (message) => errors.push(message);
  const screens = content.screens || [];

  // 交付包文件：必须恰好是这几个
  const expected = expectedBundleFiles(softwareName, { withCode, withPdf });
  let actual = [];
  try {
    actual = (await fsp.readdir(bundleDir)).filter((name) => !name.startsWith("."));
  } catch {
    fail("交付文件夹不存在");
  }
  const expectedNames = Object.values(expected).sort();
  if (JSON.stringify(actual.sort()) !== JSON.stringify(expectedNames)) {
    fail(`交付文件夹应恰好包含：${expectedNames.join("、")}；实际：${actual.join("、") || "（空）"}`);
  }
  for (const name of expectedNames) {
    try {
      const stat = await fsp.stat(path.join(bundleDir, name));
      if (!stat.size) fail(`${name} 是空文件`);
    } catch {
      fail(`缺少 ${name}`);
    }
  }

  // 截图：数量、能解码、不是空白、回执哈希一致
  const review = content.screenshotReview?.reviewedScreens || [];
  if (content.screenshotReview?.status !== "passed" || review.length !== screens.length) {
    fail("截图审查回执缺失或不完整");
  }
  for (let index = 0; index < screens.length; index += 1) {
    const id = `screen-${String(index + 1).padStart(2, "0")}`;
    const imagePath = path.join(projectDir, screens[index].image || `screens/${id}.png`);
    let buffer;
    try {
      buffer = await fsp.readFile(imagePath);
    } catch {
      fail(`缺少截图 ${id}`);
      continue;
    }
    try {
      const info = inspectPng(buffer);
      if (info.blank) fail(`${id} 是空白图`);
    } catch (error) {
      fail(`${id} 无法解码：${error.message}`);
    }
    const receipt = review.find((item) => item.screenId === id);
    if (!receipt || receipt.sha256 !== sha256(buffer)) fail(`${id} 的审查回执和当前截图不一致，需要重新验收`);
  }

  // 文案
  const tokens = forbiddenBrandTokens(softwareName, extraBrandTokens);
  if (hasFigureReference(content.cover?.overview)) fail("封面介绍里出现了「图N」");
  screens.forEach((screen, index) => {
    const n = index + 1;
    if (!String(screen.caption || "").startsWith(`图${n}`)) fail(`第 ${n} 屏图注必须以「图${n}」开头`);
    if (textLength(screen.text) < floor) fail(`第 ${n} 屏说明只有 ${textLength(screen.text)} 个字符，低于 ${floor}`);
    if (hasFigureReference(screen.text)) fail(`第 ${n} 屏说明里出现了「图N」`);
  });
  const captionHits = findBrandHits(screens.map((screen) => screen.title), tokens.filter((token) => token !== softwareName));
  if (captionHits.length) warnings.push(`界面标题里含有软件名片段：${captionHits.join("、")}`);

  // 指南 Word
  if (expected.guideDocx) {
    try {
      const docx = await inspectDocx(path.join(bundleDir, expected.guideDocx));
      if (!docx.xml.includes(xmlEscape(softwareName))) fail("指南 Word 里没有完整软件名");
      if (!docx.headerXml.includes(xmlEscape(softwareName))) fail("指南 Word 页眉里没有完整软件名");
      if (docx.mediaCount !== screens.length) fail(`指南 Word 嵌入了 ${docx.mediaCount} 张图，应为 ${screens.length} 张`);
      for (let n = 1; n <= screens.length; n += 1) {
        const count = (docx.xml.match(new RegExp(`图${n}(?![0-9])[^<]{0,40}`, "g")) || []).length;
        if (count !== 1) fail(`指南 Word 里「图${n}」出现了 ${count} 次，应恰好 1 次`);
      }
    } catch (error) {
      fail(`指南 Word 无法读取：${error.message}`);
    }
  }

  // 代码 Word
  if (expected.codeDocx) {
    try {
      const docx = await inspectDocx(path.join(bundleDir, expected.codeDocx));
      if (!docx.xml.includes(xmlEscape(softwareName))) fail("代码 Word 里没有完整软件名");
      if (/PAGE|instrText|fldChar/.test(docx.headerXml)) fail("代码 Word 页眉不应包含页码域（模板约定）");
    } catch (error) {
      fail(`代码 Word 无法读取：${error.message}`);
    }
  }

  // TXT
  try {
    const txt = await fsp.readFile(path.join(bundleDir, expected.guideTxt), "utf8");
    if (!txt.includes("【软件的主要功能】")) fail("TXT 缺少【软件的主要功能】");
    const overviewHead = String(content.cover?.overview || "").trim().split(/\n+/)[0].slice(0, 20);
    if (overviewHead && !txt.includes(overviewHead)) fail("TXT 里的主要功能和封面介绍不一致");
    if (/【源程序量】\r?\n/.test(txt) && withCode) fail("TXT 源程序量为空");
  } catch {
    // 缺文件已在上面报过
  }

  // PDF：有效文件；指南页数检查「图注掉页」问题
  for (const key of ["guidePdf", "codePdf"]) {
    if (!expected[key]) continue;
    const file = path.join(bundleDir, expected[key]);
    try {
      const head = (await fsp.readFile(file)).subarray(0, 5).toString("latin1");
      if (head !== "%PDF-") fail(`${expected[key]} 不是有效的 PDF`);
    } catch {
      // 缺文件已报
    }
  }
  if (expected.guidePdf) {
    const pages = await countPdfPages(path.join(bundleDir, expected.guidePdf)).catch(() => null);
    const designPages = content.design?.sections?.length ? 1 : 0;
    if (pages && pages > screens.length + 1 + designPages + (designPages ? content.design.sections.length : 0)) {
      warnings.push(`指南 PDF 有 ${pages} 页，比预期多，可能有截图块跨页，请打开 PDF 检查`);
    }
  }

  return { errors, warnings };
}
