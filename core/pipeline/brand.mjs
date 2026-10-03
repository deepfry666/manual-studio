const VERSION_PATTERN = /(?:V|v)?\d+(?:\.\d+)+/g;

/** 禁词与旧 skill 校验器一致：完整软件名、版本号、去掉版本后的名称，外加用户手动添加的词。 */
export function forbiddenBrandTokens(softwareName, extraTokens = []) {
  const tokens = new Set();
  const name = String(softwareName || "").trim();
  if (name) tokens.add(name);
  for (const version of name.match(VERSION_PATTERN) || []) tokens.add(version);
  const base = name.replace(VERSION_PATTERN, "").replace(/[\s._\-+]+$/g, "").trim();
  if (base.length >= 2) tokens.add(base);
  for (const token of extraTokens) {
    const value = String(token || "").trim();
    if (value.length >= 2) tokens.add(value);
  }
  return [...tokens].filter((token) => token.length >= 2);
}

export function baseSoftwareName(softwareName) {
  return String(softwareName || "").replace(VERSION_PATTERN, "").replace(/[\s._\-+]+$/g, "").trim();
}

function normalize(text) {
  return String(text || "")
    .normalize("NFKC")
    .toLowerCase()
    .replace(/\s+/g, "");
}

export function findBrandHits(texts, tokens) {
  const haystack = normalize(Array.isArray(texts) ? texts.join("\n") : texts);
  return tokens.filter((token) => haystack.includes(normalize(token)));
}

/** 正文字数按普通字符串长度计（不是只数汉字），与旧 skill 一致。 */
export function textLength(text) {
  return String(text || "").trim().length;
}

export function hasFigureReference(text) {
  return /图\s*\d+/.test(String(text || ""));
}

export function mentionsFictional(text) {
  return /虚构|虚拟的软件|示例软件|假想/.test(String(text || ""));
}
