import fsp from "node:fs/promises";
import path from "node:path";
import { projectPaths } from "./pipeline/project.mjs";
import { exists, timestampSlug } from "./util/fsx.mjs";
import { assertSafeSoftwareName } from "./build/build.mjs";

/** 交付包里要导出的文件：说明书 docx/pdf/txt，代码文档 docx/pdf（有代码来源时才有）。 */
const DELIVERY_FILE = /\.(docx|pdf|txt)$/i;

async function bundleFiles(bundleDir) {
  try {
    return (await fsp.readdir(bundleDir, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && !entry.name.startsWith(".") && DELIVERY_FILE.test(entry.name))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

/** 默认的总文件夹名：软著导出-20261009-1930 */
export function defaultGroupName(date = new Date()) {
  const pad = (value) => String(value).padStart(2, "0");
  return `软著导出-${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}-${pad(date.getHours())}${pad(date.getMinutes())}`;
}

/**
 * 实际导出到哪里：多选时在导出位置下面建一个总文件夹（重名就加 -2、-3），单选时直接放在导出位置。
 */
export async function resolveExportRoot(targetDir, groupName) {
  if (!targetDir || !path.isAbsolute(targetDir)) throw new Error("请选择导出位置");
  const name = String(groupName || "").trim();
  if (!name) return { root: targetDir, groupFolder: null };
  assertSafeSoftwareName(name);
  let candidate = name;
  for (let index = 2; await exists(path.join(targetDir, candidate)); index += 1) candidate = `${name}-${index}`;
  return { root: path.join(targetDir, candidate), groupFolder: candidate };
}

/**
 * 导出前先看一遍：每个项目能不能导、导出哪些文件、目标位置有没有同名文件夹。
 * 文件夹名就是项目名（软件名）。
 */
export async function planExport({ dirs, targetDir: baseDir, projectStore, groupName = "" }) {
  const { root: targetDir, groupFolder } = await resolveExportRoot(baseDir, groupName);
  const items = [];
  const names = new Set();
  for (const dir of dirs) {
    const state = await projectStore.read(dir);
    const name = state?.request?.softwareName || path.basename(dir);
    const item = { dir, name, folder: path.join(targetDir, name), files: [], ok: false, reason: null, conflict: false, warnings: [] };
    items.push(item);
    if (!state) {
      item.reason = "项目状态不存在";
      continue;
    }
    try {
      assertSafeSoftwareName(name);
    } catch (error) {
      item.reason = error.message;
      continue;
    }
    if (names.has(name)) {
      item.reason = "这次导出里已经有同名项目";
      continue;
    }
    const bundleDir = projectPaths(dir).bundle(name);
    item.files = await bundleFiles(bundleDir);
    if (!item.files.some((file) => file.endsWith("指南.docx"))) {
      item.reason = "还没有交付包";
      continue;
    }
    if (path.resolve(item.folder) === path.resolve(bundleDir)) {
      item.reason = "导出位置就是这个项目的交付文件夹";
      continue;
    }
    names.add(name);
    item.ok = true;
    item.conflict = await exists(item.folder);
    if (state.status !== "done" && state.origin !== "imported") item.warnings.push("项目还有步骤没完成，导出的是上一次生成的交付包");
    if (Object.values(state.lastBuild?.pdfFonts || {}).some((font) => font && font.ok === false)) item.warnings.push("PDF 字体不对，建议先「重新导出 PDF」");
    if (!item.files.some((file) => file.endsWith(".pdf"))) item.warnings.push("没有 PDF");
  }
  return { targetDir, groupFolder, items };
}

/**
 * 导出：每个项目一个文件夹（名字就是项目名），里面是交付的 5 个或 3 个文件。只复制，不动原项目。
 * groupName 不为空时（多选导出），这些项目文件夹都放进导出位置下的同一个总文件夹。
 * 目标位置已有同名文件夹时按 conflict 处理：skip 跳过；overwrite 把旧文件夹移到废纸篓（没有废纸篓时改名留底）后再导出。
 */
export async function exportBundles({ dirs, targetDir: baseDir, projectStore, conflict = "skip", trashItem = null, groupName = "" }) {
  const plan = await planExport({ dirs, targetDir: baseDir, projectStore, groupName });
  const targetDir = plan.targetDir;
  await fsp.mkdir(targetDir, { recursive: true });
  const exported = [];
  const skipped = [];
  for (const item of plan.items) {
    if (!item.ok) {
      skipped.push({ name: item.name, reason: item.reason });
      continue;
    }
    if (item.conflict) {
      if (conflict !== "overwrite") {
        skipped.push({ name: item.name, reason: "目标位置已有同名文件夹" });
        continue;
      }
      if (trashItem) await trashItem(item.folder);
      else await fsp.rename(item.folder, `${item.folder}-旧-${timestampSlug()}`);
    }
    const bundleDir = projectPaths(item.dir).bundle(item.name);
    const staging = `${item.folder}.导出中-${process.pid}`;
    await fsp.rm(staging, { recursive: true, force: true });
    await fsp.mkdir(staging, { recursive: true });
    try {
      for (const file of item.files) await fsp.copyFile(path.join(bundleDir, file), path.join(staging, file));
      await fsp.rename(staging, item.folder);
    } catch (error) {
      await fsp.rm(staging, { recursive: true, force: true });
      skipped.push({ name: item.name, reason: error.message });
      continue;
    }
    exported.push({ name: item.name, folder: item.folder, files: item.files, warnings: item.warnings });
  }
  // 总文件夹里一个都没导出时，不留下空文件夹
  if (plan.groupFolder && !exported.length) await fsp.rmdir(targetDir).catch(() => {});
  return { targetDir, groupFolder: plan.groupFolder, exported, skipped };
}
