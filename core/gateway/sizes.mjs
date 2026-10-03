export function parsePixelSize(value) {
  const match = String(value || "").trim().match(/^(\d+)\s*[x×*]\s*(\d+)$/i);
  if (!match) return null;
  const width = Number(match[1]);
  const height = Number(match[2]);
  return width > 0 && height > 0 ? { width, height } : null;
}

export function parseRatio(value) {
  const match = String(value || "").trim().match(/^(\d+(?:\.\d+)?)\s*:\s*(\d+(?:\.\d+)?)$/);
  if (!match) return null;
  const width = Number(match[1]);
  const height = Number(match[2]);
  return width > 0 && height > 0 ? { width, height } : null;
}

/** 在线路支持的比例里，按对数距离选最接近目标的一个（864x1824 → 1:2）。 */
export function nearestRatio(target, ratios) {
  const goal = Math.log(target.width / target.height);
  let best = null;
  let bestDistance = Infinity;
  for (const ratio of ratios) {
    const parsed = parseRatio(ratio);
    if (!parsed) continue;
    const distance = Math.abs(Math.log(parsed.width / parsed.height) - goal);
    if (distance < bestDistance) {
      best = ratio;
      bestDistance = distance;
    }
  }
  return best;
}

/** 从「pixel sizes are not supported; must be auto or one of 1:1, 16:9 …」这类报错里取出允许的比例。 */
export function parseAllowedRatios(message) {
  const text = String(message || "");
  if (!/ratio|比例|pixel|像素|size|尺寸/i.test(text)) return [];
  const found = text.match(/\b\d{1,2}:\d{1,2}\b/g) || [];
  return [...new Set(found)];
}

export function looksLikeUnsupportedPixelSize(message) {
  return /pixel sizes? (?:are|is) not supported|not support(?:ed)? pixel|不支持像素|size must be one of|invalid (?:image )?size|must be (?:auto or )?one of|invalid value: '\d+x\d+'|supported (?:sizes|values) (?:are|is)/i.test(
    String(message || "")
  );
}

/**
 * 根据线路配置决定实际发送的尺寸。
 * 返回 { mode: "pixel", size: "864x1824" } 或 { mode: "ratio", size: "1:2" }。
 */
export function resolveRequestSize(provider, targetSize) {
  const target = parsePixelSize(targetSize) || { width: 864, height: 1824 };
  if (provider.sizeMode === "ratio") {
    const ratios = Array.isArray(provider.ratios) && provider.ratios.length ? provider.ratios : ["9:16"];
    return { mode: "ratio", size: nearestRatio(target, ratios) || ratios[0] };
  }
  const pixel = parsePixelSize(provider.pixelSize) || target;
  return { mode: "pixel", size: `${pixel.width}x${pixel.height}` };
}

/** 从报错里取允许的像素尺寸，例如 OpenAI 官方的 '1024x1536'。 */
export function parseAllowedPixelSizes(message) {
  const found = String(message || "").match(/\b\d{3,4}x\d{3,4}\b/g) || [];
  return [...new Set(found)];
}

/**
 * 线路报尺寸不支持时，算出该改用的尺寸：
 * - 报错里列了像素尺寸 → 选宽高比最接近的那个；
 * - 报错里列了比例 → 选最接近的比例；
 * - 只说不支持像素、没列选项 → 用线路配置里的比例表；
 * - 都没有 → 返回 null，不改配置，当普通失败处理。
 */
export function sizeFallback(error, provider, targetSize, currentSize) {
  const target = parsePixelSize(targetSize) || { width: 864, height: 1824 };
  const pixels = parseAllowedPixelSizes(error.message).filter((size) => size !== currentSize);
  if (pixels.length) {
    const goal = Math.log(target.width / target.height);
    const best = pixels
      .map((size) => ({ size, parsed: parsePixelSize(size) }))
      .sort((a, b) => Math.abs(Math.log(a.parsed.width / a.parsed.height) - goal) - Math.abs(Math.log(b.parsed.width / b.parsed.height) - goal))[0];
    return { spec: { mode: "pixel", size: best.size }, patch: { sizeMode: "pixel", pixelSize: best.size } };
  }
  const ratios = (error.allowedRatios || []).length >= 2 ? error.allowedRatios : null;
  if (ratios) return { spec: { mode: "ratio", size: nearestRatio(target, ratios) }, patch: { sizeMode: "ratio", ratios } };
  if (/pixel sizes? (?:are|is) not supported|不支持像素/i.test(error.message) && provider.ratios?.length) {
    return { spec: { mode: "ratio", size: nearestRatio(target, provider.ratios) }, patch: { sizeMode: "ratio" } };
  }
  return null;
}
