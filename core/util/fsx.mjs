import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";

export async function exists(target) {
  try {
    await fsp.access(target);
    return true;
  } catch {
    return false;
  }
}

export async function readJson(file, fallback = undefined) {
  try {
    return JSON.parse(await fsp.readFile(file, "utf8"));
  } catch (error) {
    if (error && error.code === "ENOENT" && fallback !== undefined) return fallback;
    if (error instanceof SyntaxError) throw new Error(`JSON 文件损坏：${file}（${error.message}）`);
    throw error;
  }
}

/** 先写临时文件再改名，进程中途崩溃也不会留下半截文件。 */
export async function writeFileAtomic(file, data, options = {}) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${crypto.randomBytes(4).toString("hex")}.tmp`;
  await fsp.writeFile(temp, data, { mode: options.mode });
  await fsp.rename(temp, file);
}

export async function writeJsonAtomic(file, value, options = {}) {
  await writeFileAtomic(file, `${JSON.stringify(value, null, 2)}\n`, options);
}

export function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

export async function sha256File(file) {
  return sha256(await fsp.readFile(file));
}

export function hashObject(value) {
  return sha256(Buffer.from(stableStringify(value)));
}

export function stableStringify(value) {
  if (Array.isArray(value)) return `[${value.map(stableStringify).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .filter((key) => value[key] !== undefined)
      .map((key) => `${JSON.stringify(key)}:${stableStringify(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

export async function appendJsonLine(file, value) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  await fsp.appendFile(file, `${JSON.stringify(value)}\n`, "utf8");
}

export function readJsonLinesSync(file) {
  let text;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
  const rows = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      // 跳过崩溃时写了一半的行
    }
  }
  return rows;
}

export function timestampSlug(date = new Date()) {
  return date.toISOString().replace(/[:.]/g, "-");
}

/** 把同一个 key 的异步操作串起来执行，避免并发写同一个文件。 */
export function createSerialQueue() {
  let tail = Promise.resolve();
  return (operation) => {
    const result = tail.then(operation, operation);
    tail = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  };
}

export function isInside(parent, candidate) {
  const relative = path.relative(path.resolve(parent), path.resolve(candidate));
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}
