import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import fsp from "node:fs/promises";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { fontRegistryXml, substitutionAttempts, judgePdfFonts, pdfFontNames, rememberWorkingName } from "./fonts.mjs";

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
export const TEMPLATES_DIR = path.resolve(here, "..", "templates");
const libreoffice = require(path.join(TEMPLATES_DIR, "lib", "libreoffice.js"));

function run(command, args, { env, timeoutMs = 10 * 60 * 1000, cwd } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env, cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => (stdout += chunk));
    child.stderr.on("data", (chunk) => (stderr += chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

/** 用当前 Node（Electron 里是 ELECTRON_RUN_AS_NODE）跑模板脚本，异步执行，不卡界面。 */
export async function runTemplate(scriptName, args) {
  const script = path.join(TEMPLATES_DIR, "scripts", scriptName);
  const result = await run(process.execPath, [script, ...args], {
    env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
  });
  if (result.code !== 0) {
    const detail = (result.stderr || result.stdout || "").trim().split("\n").slice(-8).join("\n");
    throw new Error(`${scriptName} 执行失败（退出码 ${result.code ?? result.signal}）：${detail}`);
  }
  return result;
}

let sofficeCache;
/** 找到并确认 LibreOffice 可用；找不到返回 null（构建走无 PDF 模式）。 */
export async function findLibreOffice() {
  if (sofficeCache !== undefined) return sofficeCache;
  const candidate = libreoffice.findSoffice();
  if (!candidate) {
    sofficeCache = null;
    return null;
  }
  const probe = await run(candidate, ["--headless", "--nologo", "--nodefault", "--version"], { timeoutMs: 30_000 }).catch(() => null);
  sofficeCache = probe && probe.code === 0 ? candidate : null;
  return sofficeCache;
}

export function resetLibreOfficeCache() {
  sofficeCache = undefined;
}

let pdfQueue = Promise.resolve();
/**
 * DOCX → PDF。LibreOffice 同时开多个容易出错，这里排队一个个转。
 * fontPairs：这次转换用的字体替换表（写进临时配置目录，不影响平时使用的 LibreOffice）。
 */
export function convertToPdf(docxPath, outDir, { fontPairs = [] } = {}) {
  const job = pdfQueue.then(async () => {
    const soffice = await findLibreOffice();
    if (!soffice) throw new Error("没有找到 LibreOffice");
    const pdfPath = path.join(outDir, `${path.basename(docxPath, path.extname(docxPath))}.pdf`);
    await fsp.rm(pdfPath, { force: true });
    const profile = await fsp.mkdtemp(path.join(os.tmpdir(), "manual-studio-lo-"));
    await fsp.mkdir(path.join(profile, "user"), { recursive: true });
    await fsp.writeFile(path.join(profile, "user", "registrymodifications.xcu"), fontRegistryXml(fontPairs), "utf8");
    const profileUri = `file:///${profile.replace(/\\/g, "/").replace(/^\/+/, "").replace(/ /g, "%20")}`;
    const args = ["--headless", "--nologo", "--nodefault", "--nolockcheck", `-env:UserInstallation=${profileUri}`, "--convert-to", "pdf", "--outdir", outDir, docxPath];
    try {
      for (let attempt = 0; attempt < 2; attempt += 1) {
        const result = await run(soffice, args, { timeoutMs: 5 * 60 * 1000 });
        if (result.code === 0 && fs.existsSync(pdfPath) && fs.statSync(pdfPath).size > 0) return pdfPath;
        if (attempt === 1) throw new Error(`PDF 转换失败：${(result.stderr || result.stdout || "").slice(-400)}`);
      }
    } finally {
      await fsp.rm(profile, { recursive: true, force: true });
    }
    return pdfPath;
  });
  pdfQueue = job.catch(() => {});
  return job;
}

/**
 * 转 PDF 并核对字体：按替换方案依次尝试（中文系统和英文系统里字体名不一样），
 * 第一个核对通过的就用；都不通过时保留最后一次的结果并说明用了什么字体。
 */
export async function convertToPdfChecked(docxPath, outDir, kind, fontPlan) {
  const attempts = substitutionAttempts(kind, fontPlan?.[kind]);
  let last = null;
  for (const attempt of attempts) {
    const pdfPath = await convertToPdf(docxPath, outDir, { fontPairs: attempt.pairs });
    const verdict = judgePdfFonts(await pdfFontNames(pdfPath), attempt);
    last = { pdfPath, ...verdict, intended: attempt.name, mode: fontPlan?.[kind]?.mode || "original" };
    if (verdict.ok) {
      rememberWorkingName(attempt.key, attempt.name);
      return last;
    }
  }
  return last;
}

/** 粗略统计 PDF 页数（LibreOffice 生成的 PDF 页对象不压缩，可以直接数）。 */
export async function countPdfPages(pdfPath) {
  const text = (await fsp.readFile(pdfPath)).toString("latin1");
  const matches = text.match(/\/Type\s*\/Page(?![s\w])/g);
  return matches ? matches.length : null;
}
