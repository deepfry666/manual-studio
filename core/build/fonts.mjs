import os from "node:os";
import path from "node:path";
import fsp from "node:fs/promises";
import { spawn } from "node:child_process";

/**
 * PDF 字体。模板（不改）里说明书用「微软雅黑」，代码文档用「新宋体」。
 * 这两个字体 macOS 没有自带，LibreOffice 找不到时会随便抓一个中文字体顶上（实测有圆体、娃娃体、魏碑……每次都不一样）。
 * 这里的做法：本机装了原版字体就用原版；没装就强制换成一个固定的系统字体，保证每次转出来一样，转完再核对 PDF 里实际用的字体。
 */
export const DOC_FONTS = {
  guide: { label: "说明书", original: "微软雅黑", replace: ["Microsoft YaHei", "微软雅黑"], families: ["Microsoft YaHei", "微软雅黑"], expect: /^MicrosoftYaHei/ },
  code: { label: "代码文档", original: "新宋体", replace: ["新宋体", "NSimSun"], families: ["NSimSun", "新宋体"], expect: /^NSimSun$/ },
};

/** names：LibreOffice 里能认出的名字（系统语言是中文时要用中文名），按顺序尝试。 */
export const SUBSTITUTES = {
  pingfang: { label: "苹方（推荐）", names: ["苹方-简", "PingFang SC"], expect: /^PingFangSC-/ },
  heiti: { label: "黑体-简", names: ["黑体-简", "Heiti SC"], expect: /^STHeitiSC-/ },
  stsong: { label: "华文宋体（推荐，最接近新宋体）", names: ["华文宋体", "STSong"], expect: /^STSong$/ },
  songti: { label: "宋体-简", names: ["宋体-简", "Songti SC"], expect: /^STSongti-SC-/ },
  courier: { label: "Courier New（等宽，中文用苹方）", names: ["Courier New"], expect: /^CourierNew/, alsoAllowed: /^PingFangSC-/ },
};

export const DEFAULT_PDF_FONTS = { guide: "pingfang", code: "stsong" };
export const SUBSTITUTE_CHOICES = { guide: ["pingfang", "heiti"], code: ["stsong", "songti", "courier"] };

function runQuiet(command, args, timeoutMs = 15_000) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "ignore"] });
    let out = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => (out += chunk));
    child.on("error", () => {
      clearTimeout(timer);
      resolve(null);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve(code === 0 ? out : null);
    });
  });
}

let familiesCache = null;
/** 本机已安装的字体族名（只在 macOS 上能查；查不到返回 null）。 */
export async function installedFontFamilies({ refresh = false } = {}) {
  if (process.platform !== "darwin") return null;
  if (familiesCache && !refresh && Date.now() - familiesCache.at < 60_000) return familiesCache.set;
  const out = await runQuiet("osascript", ["-l", "JavaScript", "-e", 'ObjC.import("AppKit"); ObjC.deepUnwrap($.NSFontManager.sharedFontManager.availableFontFamilies).join("\\n")']);
  if (out === null) return null;
  const set = new Set(out.split("\n").map((line) => line.trim()).filter(Boolean));
  familiesCache = { at: Date.now(), set };
  return set;
}

/** 每种文档这次用什么字体：原版（已安装）或替代字体。 */
export async function resolveFontPlan(pdfSettings = {}, { families } = {}) {
  const installed = families === undefined ? await installedFontFamilies() : families;
  const plan = {};
  for (const [kind, doc] of Object.entries(DOC_FONTS)) {
    const hasOriginal = installed ? doc.families.some((name) => installed.has(name)) : false;
    const key = SUBSTITUTES[pdfSettings[kind]] && SUBSTITUTE_CHOICES[kind].includes(pdfSettings[kind]) ? pdfSettings[kind] : DEFAULT_PDF_FONTS[kind];
    plan[kind] = hasOriginal ? { kind, mode: "original", label: doc.original } : { kind, mode: "substitute", substitute: key, label: SUBSTITUTES[key].label.replace(/（.*$/, "") };
  }
  return plan;
}

/** LibreOffice 配置里的「替换表」：只在这次转换用的临时配置目录里生效，不影响你平时用的 LibreOffice。 */
export function fontRegistryXml(pairs) {
  const escape = (value) => String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  const nodes = pairs.map(
    (pair, index) =>
      `<item oor:path="/org.openoffice.Office.Common/Font/Substitution/FontPairs"><node oor:name="_${index}" oor:op="replace">` +
      `<prop oor:name="Always" oor:op="fuse"><value>true</value></prop>` +
      `<prop oor:name="OnScreenOnly" oor:op="fuse"><value>false</value></prop>` +
      `<prop oor:name="ReplaceFont" oor:op="fuse"><value>${escape(pair.from)}</value></prop>` +
      `<prop oor:name="SubstituteFont" oor:op="fuse"><value>${escape(pair.to)}</value></prop>` +
      `</node></item>`
  );
  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    pairs.length ? '<item oor:path="/org.openoffice.Office.Common/Font/Substitution"><prop oor:name="Replacement" oor:op="fuse"><value>true</value></prop></item>' : "",
    ...nodes,
    "</oor:items>",
    "",
  ].join("\n");
}

/** 这份文档要尝试的替换方案（原版字体已安装时只有一个「不替换」方案）。 */
export function substitutionAttempts(kind, planEntry) {
  const doc = DOC_FONTS[kind];
  if (!planEntry || planEntry.mode === "original") return [{ pairs: [], expect: doc.expect, alsoAllowed: null, name: doc.original }];
  const substitute = SUBSTITUTES[planEntry.substitute];
  const remembered = workingNames.get(planEntry.substitute);
  const names = remembered ? [remembered, ...substitute.names.filter((name) => name !== remembered)] : substitute.names;
  return names.map((name) => ({ pairs: doc.replace.map((from) => ({ from, to: name })), expect: substitute.expect, alsoAllowed: substitute.alsoAllowed || null, name, key: planEntry.substitute }));
}

const workingNames = new Map();
export function rememberWorkingName(key, name) {
  if (key) workingNames.set(key, name);
}

/** PDF 里实际嵌入的字体名（去掉 ABCDEF+ 子集前缀）。 */
export async function pdfFontNames(pdfPath) {
  const text = (await fsp.readFile(pdfPath)).toString("latin1");
  const names = new Set();
  for (const match of text.matchAll(/\/BaseFont\s*\/([A-Za-z0-9+#_.-]+)/g)) names.add(match[1].replace(/^[A-Z]{6}\+/, ""));
  return [...names].sort();
}

/** 核对：必须用到预期字体；除了它（和允许的补字字体）以外不能出现别的字体。 */
export function judgePdfFonts(fonts, attempt) {
  const expected = fonts.filter((name) => attempt.expect.test(name));
  const unexpected = fonts.filter((name) => !attempt.expect.test(name) && !(attempt.alsoAllowed && attempt.alsoAllowed.test(name)));
  return { ok: expected.length > 0 && unexpected.length === 0, fonts, unexpected, expectedFound: expected.length > 0 };
}

export function userFontsDir() {
  return path.join(os.homedir(), "Library", "Fonts");
}

/** 把用户选的字体文件装到「当前用户」的字体文件夹（不需要管理员权限）。 */
export async function installFontFiles(files, targetDir = userFontsDir()) {
  await fsp.mkdir(targetDir, { recursive: true });
  const installed = [];
  const skipped = [];
  for (const file of files) {
    const name = path.basename(file);
    if (!/\.(ttf|ttc|otf)$/i.test(name)) {
      skipped.push(`${name}：不是字体文件（只支持 .ttf / .ttc / .otf）`);
      continue;
    }
    const target = path.join(targetDir, name);
    try {
      await fsp.copyFile(file, target);
      installed.push(name);
    } catch (error) {
      skipped.push(`${name}：${error.message}`);
    }
  }
  familiesCache = null;
  return { installed, skipped, targetDir };
}
