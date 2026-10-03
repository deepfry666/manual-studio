import fsp from "node:fs/promises";
import path from "node:path";
import { runTemplate, convertToPdf, findLibreOffice, countPdfPages } from "./runtime.mjs";
import { validateDelivery, expectedBundleFiles } from "./validate.mjs";
import { collectCodeSource, languageLabelFor } from "../code-source.mjs";
import { projectPaths } from "../pipeline/project.mjs";
import { readJson, writeJsonAtomic, timestampSlug, exists } from "../util/fsx.mjs";

export function assertSafeSoftwareName(name) {
  const value = String(name || "");
  if (!value.trim()) throw new Error("软件名为空");
  if (/[\/\\:\u0000]/.test(value) || value === "." || value === ".." || value.startsWith(".")) {
    throw new Error(`软件名不能包含 / \\ : 或以点开头：${value}`);
  }
}

function buildManifest({ softwareName, content, withPdf, withCode, code, codeSource, provenance }) {
  const artifacts = {};
  for (const [role, file] of Object.entries(expectedBundleFiles(softwareName, { withCode, withPdf }))) {
    artifacts[role] = `${softwareName}/${file}`;
  }
  const manifest = {
    softwareName,
    versionPolicy: content.versionPolicy || "in-name",
    screenshotCount: content.screens.length,
    imageRoute: content.imageRoute || "image-gateway",
    pdfMode: withPdf ? "complete" : "complete-no-pdf",
    codeDocument: withCode ? "from-code-source" : "not-generated",
    createdAt: content.createdAt || new Date().toISOString().slice(0, 10),
    builtAt: new Date().toISOString(),
    builtBy: "软件指南生成器",
    artifacts,
  };
  if (content.screenCountReason) manifest.screenCountReason = content.screenCountReason;
  if (content.featureTier) manifest.featureTier = content.featureTier;
  if (content.screenshotReview) manifest.screenshotReview = content.screenshotReview;
  if (withCode && code) manifest.codeSource = { path: codeSource.path, extensions: code.extensions, fileCount: code.fileCount, lineCount: code.lineCount };
  if (provenance) manifest.provenance = provenance;
  return manifest;
}

function buildRegionIndex({ softwareName, content, regionFill, withPdf, withCode, code }) {
  const date = content.compileDate || content.createdAt || "";
  const regions = {
    "document.meta": { label: "文档元信息", softwareName, version: content.versionPolicy === "none" ? "" : softwareName, compileDate: date, summary: "软件名、版本、编制日期与输出路径" },
    "header.default": { label: "页眉", summary: "左侧软件名，右侧页码域" },
    "cover.title": { label: "封面标题", summary: `${softwareName} 用户手册` },
    "cover.metadata": { label: "封面元信息", summary: `编制时间：${date}` },
    "cover.overview": { label: "封面软件介绍", summary: String(content.cover.overview).slice(0, 40) },
    ...regionFill,
    "artifact.txt.main-function": { label: "TXT 主要功能段", summary: "取自 cover.overview，插入【软件的主要功能】之后" },
  };
  if (withCode) regions["artifact.docx.code"] = { label: "代码 Word", summary: `代码来源 ${code.fileCount} 个文件，共 ${code.lineCount} 行` };
  if (withPdf) {
    regions["artifact.pdf.guide"] = { label: "指南 PDF", summary: "由指南 Word 导出" };
    if (withCode) regions["artifact.pdf.code"] = { label: "代码 PDF", summary: "由代码 Word 导出" };
  }
  return { softwareName, regions };
}

async function copyScreens(projectDir, stagingDir, content) {
  await fsp.mkdir(path.join(stagingDir, "screens"), { recursive: true });
  for (const screen of content.screens) {
    await fsp.copyFile(path.join(projectDir, screen.image), path.join(stagingDir, screen.image));
  }
}

async function pruneBundleArchives(archiveRoot, softwareName, keep = 3) {
  let entries;
  try {
    entries = await fsp.readdir(archiveRoot);
  } catch {
    return;
  }
  const bundles = entries.filter((name) => name.startsWith(`${softwareName}-交付-`)).sort().reverse();
  for (const name of bundles.slice(keep)) await fsp.rm(path.join(archiveRoot, name), { recursive: true, force: true });
}

/**
 * S8 构建：先在 staging 生成并校验，全部通过后才替换正式交付包（旧的先归档）。
 */
async function moveDir(from, to) {
  try {
    await fsp.rename(from, to);
  } catch (error) {
    if (error.code !== "EXDEV") throw error;
    await fsp.cp(from, to, { recursive: true });
    await fsp.rm(from, { recursive: true, force: true });
  }
}

export async function buildBundle({ projectDir, softwareName, content, codeSource, txtFields, excludeDirs, floor = 300, extraBrandTokens = [], stagingRoot, provenance, onLog = () => {} }) {
  assertSafeSoftwareName(softwareName);
  const paths = projectPaths(projectDir);
  const stamp = timestampSlug();
  const staging = path.join(stagingRoot || path.join(projectDir, ".staging"), `${path.basename(projectDir)}-${stamp}`);
  const stagingBundle = path.join(staging, softwareName);
  await fsp.mkdir(path.join(staging, "tmp"), { recursive: true });
  await copyScreens(projectDir, staging, content);
  const stagedContentPath = path.join(staging, "content.json");
  await writeJsonAtomic(stagedContentPath, content);

  onLog("生成指南 Word");
  const regionFillPath = path.join(staging, "tmp", "region-fill.json");
  await runTemplate("create-guide-docx.js", ["--project", staging, "--software", softwareName, "--content", stagedContentPath, "--region-out", regionFillPath]);
  const regionFill = await readJson(regionFillPath, {});

  const soffice = await findLibreOffice();
  const withPdf = Boolean(soffice);
  if (withPdf) {
    onLog("导出指南 PDF");
    await convertToPdf(path.join(stagingBundle, `${softwareName}指南.docx`), stagingBundle);
  } else {
    onLog("没有找到 LibreOffice，本次不生成 PDF");
  }

  let code = null;
  if (codeSource?.path) {
    onLog("读取代码来源");
    code = await collectCodeSource(codeSource, { excludeDirs });
    await fsp.writeFile(path.join(staging, "tmp", "code-body.txt"), code.body, "utf8");
    onLog(`生成代码 Word（${code.fileCount} 个文件，${code.lineCount} 行）`);
    await runTemplate("create-code-docx.js", ["--project", staging, "--software", softwareName, "--body-file", path.join(staging, "tmp", "code-body.txt")]);
    if (withPdf) {
      onLog("导出代码 PDF");
      await convertToPdf(path.join(stagingBundle, `${softwareName}指南_代码-（JAVA）.docx`), stagingBundle);
    }
  }

  onLog("生成 TXT");
  const fields = { ...txtFields };
  if (code && !txtFields?.languageOverride) {
    const label = languageLabelFor(code.extensions);
    if (label) fields.language = label === "Java" ? "JAVA" : label;
  }
  const fieldsFile = path.join(staging, "tmp", "txt-fields.json");
  await fsp.writeFile(fieldsFile, JSON.stringify(fields), "utf8");
  const overviewFile = path.join(staging, "tmp", "cover-overview.txt");
  await fsp.writeFile(overviewFile, String(content.cover.overview), "utf8");
  await runTemplate("create-guide-txt.js", ["--project", staging, "--software", softwareName, "--overview-file", overviewFile, "--fields-file", fieldsFile, "--source-lines", String(code ? code.lineCount : 0)]);

  onLog("校验交付包");
  const withCode = Boolean(code);
  const { errors, warnings } = await validateDelivery({ projectDir: staging, bundleDir: stagingBundle, softwareName, content, withCode, withPdf, extraBrandTokens, floor });
  if (code?.warnings?.length) warnings.push(...code.warnings);
  if (errors.length) {
    const error = new Error(`交付校验没有通过（正式交付包未改动，诊断文件在 ${staging}）：\n- ${errors.join("\n- ")}`);
    error.validationErrors = errors;
    throw error;
  }

  const manifest = buildManifest({ softwareName, content, withPdf, withCode, code, codeSource, provenance });
  const regionIndex = buildRegionIndex({ softwareName, content, regionFill, withPdf, withCode, code });

  onLog("替换正式交付包");
  const finalBundle = paths.bundle(softwareName);
  if (await exists(finalBundle)) {
    await fsp.mkdir(paths.archive, { recursive: true });
    await fsp.rename(finalBundle, path.join(paths.archive, `${softwareName}-交付-${stamp}`));
    await pruneBundleArchives(paths.archive, softwareName);
  }
  await moveDir(stagingBundle, finalBundle);
  await writeJsonAtomic(paths.content, content);
  await writeJsonAtomic(paths.manifest, manifest);
  await writeJsonAtomic(paths.regionIndex, regionIndex);
  await fsp.rm(staging, { recursive: true, force: true });

  const pdfPages = withPdf ? await countPdfPages(path.join(finalBundle, `${softwareName}指南.pdf`)).catch(() => null) : null;
  return {
    bundleDir: finalBundle,
    files: Object.values(expectedBundleFiles(softwareName, { withCode, withPdf })),
    withPdf,
    withCode,
    code: code ? { fileCount: code.fileCount, lineCount: code.lineCount, estimatedPages: code.estimatedPages } : null,
    pdfPages,
    warnings,
  };
}
