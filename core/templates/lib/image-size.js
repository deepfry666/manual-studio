"use strict";

const fs = require("fs");

/**
 * 读取 PNG / JPEG 的像素尺寸，不依赖任何第三方库。
 * docx 包不会自己解析图片尺寸，插图时必须按真实比例算高，避免拉伸。
 *
 * @param {string} filePath
 * @returns {{width:number, height:number, type:"png"|"jpg"}}
 */
function readImageSize(filePath) {
  const buf = fs.readFileSync(filePath);

  // PNG: 8 字节签名 + IHDR(宽4/高4 大端) 位于偏移 16/20
  const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buf.length >= 24 && buf.subarray(0, 8).equals(PNG_SIG)) {
    return {
      width: buf.readUInt32BE(16),
      height: buf.readUInt32BE(20),
      type: "png",
    };
  }

  // JPEG: 遍历段，找 SOF0/1/2 等帧标记读高/宽
  if (buf.length >= 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    let offset = 2;
    while (offset < buf.length) {
      if (buf[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      const marker = buf[offset + 1];
      // SOF0..SOF3, SOF5..SOF7, SOF9..SOF11, SOF13..SOF15 都带尺寸
      const isSOF =
        (marker >= 0xc0 && marker <= 0xc3) ||
        (marker >= 0xc5 && marker <= 0xc7) ||
        (marker >= 0xc9 && marker <= 0xcb) ||
        (marker >= 0xcd && marker <= 0xcf);
      if (isSOF) {
        const height = buf.readUInt16BE(offset + 5);
        const width = buf.readUInt16BE(offset + 7);
        return { width, height, type: "jpg" };
      }
      // 跳过本段：段长在 marker 后 2 字节
      const segLen = buf.readUInt16BE(offset + 2);
      offset += 2 + segLen;
    }
  }

  throw new Error(`无法解析图片尺寸（仅支持 PNG/JPEG）: ${filePath}`);
}

/**
 * 判断 docx ImageRun 需要的 type 字段。
 * @param {"png"|"jpg"} type
 * @returns {"png"|"jpg"}
 */
function imageRunType(type) {
  return type === "jpg" ? "jpg" : "png";
}

module.exports = { readImageSize, imageRunType };
