import zlib from "node:zlib";
import os from "node:os";
import path from "node:path";
import fsp from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const MAX_EDGE = 8192;
const MAX_PIXELS = 40_000_000;

export function detectImageType(buffer) {
  if (buffer.length >= 8 && buffer.subarray(0, 8).equals(PNG_SIGNATURE)) return "png";
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) return "jpeg";
  if (buffer.length >= 12 && buffer.toString("ascii", 0, 4) === "RIFF" && buffer.toString("ascii", 8, 12) === "WEBP") return "webp";
  if (buffer.length >= 6 && buffer.toString("ascii", 0, 3) === "GIF") return "gif";
  return null;
}

/** 非 PNG 用 macOS 自带的 sips 转成 PNG。Electron 里会改用 nativeImage（见 electron/image-tools.mjs）。 */
export async function convertToPngWithSips(buffer, type) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "manual-studio-img-"));
  try {
    const source = path.join(dir, `source.${type === "jpeg" ? "jpg" : type}`);
    const output = path.join(dir, "out.png");
    await fsp.writeFile(source, buffer);
    await execFileAsync("/usr/bin/sips", ["-s", "format", "png", source, "--out", output], { timeout: 30_000 });
    return await fsp.readFile(output);
  } finally {
    await fsp.rm(dir, { recursive: true, force: true });
  }
}

let crcTable = null;
function crc32(buffer) {
  if (!crcTable) {
    crcTable = new Uint32Array(256);
    for (let n = 0; n < 256; n += 1) {
      let c = n;
      for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      crcTable[n] = c >>> 0;
    }
  }
  let crc = 0xffffffff;
  for (const byte of buffer) crc = crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}

function unfilter(raw, width, height, bpp) {
  const stride = width * bpp;
  if (raw.length !== (stride + 1) * height) throw new Error("PNG 像素数据长度不符");
  const pixels = Buffer.alloc(stride * height);
  let input = 0;
  for (let y = 0; y < height; y += 1) {
    const filter = raw[input++];
    if (filter > 4) throw new Error(`不支持的 PNG 滤波类型 ${filter}`);
    const row = y * stride;
    for (let x = 0; x < stride; x += 1) {
      const value = raw[input++];
      const left = x >= bpp ? pixels[row + x - bpp] : 0;
      const up = y > 0 ? pixels[row - stride + x] : 0;
      const upLeft = y > 0 && x >= bpp ? pixels[row - stride + x - bpp] : 0;
      let decoded = value;
      if (filter === 1) decoded += left;
      else if (filter === 2) decoded += up;
      else if (filter === 3) decoded += Math.floor((left + up) / 2);
      else if (filter === 4) decoded += paeth(left, up, upLeft);
      pixels[row + x] = decoded & 0xff;
    }
  }
  return pixels;
}

/** 解析 PNG 并做空白检测（逻辑来自旧 skill 的校验器）。 */
export function inspectPng(buffer) {
  if (buffer.length < 33 || !buffer.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error("不是有效的 PNG 文件");
  let offset = 8;
  let width = 0;
  let height = 0;
  let bitDepth = 0;
  let colorType = 0;
  let interlace = 0;
  let palette = null;
  let sawEnd = false;
  const idat = [];
  while (offset + 12 <= buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > buffer.length) throw new Error("PNG 文件被截断");
    const typeBuffer = buffer.subarray(offset + 4, offset + 8);
    const type = typeBuffer.toString("ascii");
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (crc32(Buffer.concat([typeBuffer, data])) !== buffer.readUInt32BE(offset + 8 + length)) {
      throw new Error(`PNG ${type} 块校验失败`);
    }
    if (type === "IHDR") {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
      if (!width || !height) throw new Error("PNG 宽或高为 0");
      if (width > MAX_EDGE || height > MAX_EDGE || width * height > MAX_PIXELS) {
        throw new Error(`PNG 尺寸过大：${width}x${height}`);
      }
    } else if (type === "PLTE") {
      palette = data;
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      sawEnd = true;
      break;
    }
    offset = end;
  }
  if (!width || !idat.length || !sawEnd) throw new Error("PNG 缺少必要的数据块");

  let blank = null;
  const bppByType = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
  const bpp = bppByType[colorType];
  if (bitDepth === 8 && interlace === 0 && bpp) {
    const raw = zlib.inflateSync(Buffer.concat(idat), { maxOutputLength: (width * bpp + 1) * height });
    const pixels = unfilter(raw, width, height, bpp);
    const min = [255, 255, 255];
    const max = [0, 0, 0];
    let visible = 0;
    const step = Math.max(1, Math.floor((width * height) / 200_000));
    for (let index = 0; index < width * height; index += step) {
      const pos = index * bpp;
      let rgb;
      let alpha = 255;
      if (colorType === 0 || colorType === 4) {
        rgb = [pixels[pos], pixels[pos], pixels[pos]];
        if (colorType === 4) alpha = pixels[pos + 1];
      } else if (colorType === 2 || colorType === 6) {
        rgb = [pixels[pos], pixels[pos + 1], pixels[pos + 2]];
        if (colorType === 6) alpha = pixels[pos + 3];
      } else if (palette) {
        const p = pixels[pos] * 3;
        rgb = [palette[p] || 0, palette[p + 1] || 0, palette[p + 2] || 0];
      } else {
        continue;
      }
      if (alpha <= 8) continue;
      visible += 1;
      for (let c = 0; c < 3; c += 1) {
        if (rgb[c] < min[c]) min[c] = rgb[c];
        if (rgb[c] > max[c]) max[c] = rgb[c];
      }
    }
    blank = visible === 0 || (max[0] - min[0] <= 3 && max[1] - min[1] <= 3 && max[2] - min[2] <= 3);
  }
  return { width, height, blank };
}

/**
 * 技术验收：能解码、不是空白、是竖屏手机界面比例。
 * 返回 { ok, png, width, height, warnings, reason }。
 */
export async function checkScreenImage(buffer, { toPng = convertToPngWithSips } = {}) {
  const type = detectImageType(buffer);
  if (!type) return { ok: false, reason: "返回的不是图片" };
  let png = buffer;
  try {
    if (type !== "png") png = await toPng(buffer, type);
  } catch (error) {
    return { ok: false, reason: `图片无法转换为 PNG：${error.message}` };
  }
  let info;
  try {
    info = inspectPng(png);
  } catch (error) {
    return { ok: false, reason: `图片无法解码：${error.message}` };
  }
  const warnings = [];
  if (info.blank) return { ok: false, reason: "图片是空白的", ...info };
  const aspect = info.height / info.width;
  if (aspect < 1.5 || aspect > 2.7) {
    return { ok: false, reason: `不是竖屏手机界面比例（${info.width}x${info.height}）`, ...info };
  }
  if (aspect < 1.8 || aspect > 2.4) warnings.push(`宽高比 ${aspect.toFixed(2)} 偏离常见手机长屏`);
  if (info.width < 500) warnings.push(`宽度只有 ${info.width}px，清晰度可能不够`);
  return { ok: true, png, width: info.width, height: info.height, warnings };
}
