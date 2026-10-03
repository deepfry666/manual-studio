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
  return /pixel sizes? (?:are|is) not supported|not support(?:ed)? pixel|不支持像素|size must be one of|invalid (?:image )?size|must be (?:auto or )?one of/i.test(
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
