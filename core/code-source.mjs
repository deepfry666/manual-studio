import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

const MAX_FILES = 5000;
const MAX_TOTAL_BYTES = 30 * 1024 * 1024;

/**
 * 读取项目指定的代码来源，按相对路径排序后原样拼接。
 * 不改写、不替换、不生成任何代码；只统一换行符，并跳过二进制文件。
 */
export async function collectCodeSource(source, { excludeDirs = [] } = {}) {
  if (!source?.path) return null;
  const root = path.resolve(source.path);
  const extensions = (source.extensions?.length ? source.extensions : [".java"]).map((ext) => (ext.startsWith(".") ? ext : `.${ext}`).toLowerCase());
  const exclude = new Set(excludeDirs);
  let stat;
  try {
    stat = await fsp.stat(root);
  } catch {
    throw new Error(`代码来源不存在：${root}`);
  }
  const files = [];
  const warnings = [];
  if (stat.isFile()) {
    files.push(root);
  } else {
    const walk = async (dir) => {
      const entries = (await fsp.readdir(dir, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name, "en"));
      for (const entry of entries) {
        if (entry.name.startsWith(".")) continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
          if (!exclude.has(entry.name)) await walk(full);
        } else if (entry.isFile() && extensions.includes(path.extname(entry.name).toLowerCase())) {
          files.push(full);
          if (files.length > MAX_FILES) throw new Error(`代码文件超过 ${MAX_FILES} 个，请缩小代码来源范围`);
        }
      }
    };
    await walk(root);
  }
  if (!files.length) throw new Error(`代码来源里没有找到 ${extensions.join("、")} 文件`);

  const parts = [];
  const included = [];
  let bytes = 0;
  for (const file of files) {
    const buffer = await fsp.readFile(file);
    if (buffer.includes(0)) {
      warnings.push(`跳过二进制文件：${path.relative(stat.isFile() ? path.dirname(root) : root, file)}`);
      continue;
    }
    bytes += buffer.length;
    if (bytes > MAX_TOTAL_BYTES) throw new Error("代码总量超过 30MB，请缩小代码来源范围");
    let text = buffer.toString("utf8").replace(/^﻿/, "").replace(/\r\n?/g, "\n");
    if (!text.endsWith("\n")) text += "\n";
    parts.push(text);
    included.push(stat.isFile() ? path.basename(file) : path.relative(root, file));
  }
  const body = parts.join("").replace(/\n+$/, "\n");
  const lines = body.endsWith("\n") ? body.slice(0, -1).split("\n") : body.split("\n");
  const lineCount = lines.length;
  const nonEmptyLines = lines.filter((line) => line.trim()).length;
  return {
    root,
    extensions,
    files: included,
    fileCount: included.length,
    lineCount,
    nonEmptyLines,
    bytes,
    body,
    // 代码正文指纹：写进生成记录，可以核对交付包里的代码文档用的是哪一版代码
    sha256: crypto.createHash("sha256").update(body).digest("hex"),
    warnings,
    // 现有代码文档格式（新宋体 9pt、A4）实测每页约 45 行，只作页数估算
    estimatedPages: Math.ceil(lineCount / 45),
  };
}

export function languageLabelFor(extensions = []) {
  const map = { ".java": "JAVA", ".kt": "Kotlin", ".swift": "Swift", ".m": "Objective-C", ".dart": "Dart", ".js": "JavaScript", ".ts": "TypeScript", ".tsx": "TypeScript", ".py": "Python", ".go": "Go", ".cs": "C#", ".cpp": "C++", ".c": "C", ".php": "PHP", ".vue": "Vue" };
  const labels = [...new Set(extensions.map((ext) => map[ext.toLowerCase()]).filter(Boolean))];
  return labels.join("、");
}
