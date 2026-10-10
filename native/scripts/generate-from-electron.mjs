// 从定档的 Electron 版（../../core）原样取出常量，生成 Swift 源文件，避免手抄出错。
// 用法：node native/scripts/generate-from-electron.mjs <docx 样例解包目录>
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import * as steps from "../../core/pipeline/llm-steps.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "..", "StudioCore", "Sources", "StudioCore");

function raw(text) {
  if (text.includes('"""#')) throw new Error("text contains raw delimiter");
  return `#"""\n${text}\n"""#`;
}

const header = "// 由 native/scripts/generate-from-electron.mjs 从 Electron 版原样生成，不要手改。\n\nimport Foundation\n\n";
let swift = header;
for (const name of ["PLAN_SYSTEM", "GATE_SYSTEM", "CONTENT_SYSTEM", "DESIGN_SYSTEM", "FEEDBACK_SYSTEM", "PROMPT_EDIT_SYSTEM"]) {
  swift += `public let ${name} = ${raw(steps[name])}\n\n`;
}
for (const name of ["PLAN_SCHEMA", "GATE_SCHEMA", "CONTENT_SCHEMA", "DESIGN_SCHEMA", "FEEDBACK_SCHEMA", "PROMPT_EDIT_SCHEMA"]) {
  swift += `public let ${name}: JSON = try! JSON.parse(${raw(JSON.stringify(steps[name], null, 2))})\n\n`;
}
swift += `public let FEEDBACK_TYPES = ${JSON.stringify(steps.FEEDBACK_TYPES)}\n`;
fs.writeFileSync(path.join(out, "Pipeline", "LLMPrompts.generated.swift"), swift);

// docx 固定部件（来自 docx 库的输出）：样式表头尾、主题、编号、设置等
const sample = process.argv[2];
if (sample) {
  const read = (rel) => fs.readFileSync(path.join(sample, rel), "utf8");
  const guideStyles = read("guide/word/styles.xml");
  const split = guideStyles.indexOf("<w:docDefaults>");
  const after = guideStyles.indexOf("</w:docDefaults>") + "</w:docDefaults>".length;
  const parts = {
    contentTypes: read("guide/[Content_Types].xml"),
    rootRels: read("guide/_rels/.rels"),
    appXml: read("guide/docProps/app.xml"),
    customXml: read("guide/docProps/custom.xml"),
    settingsXml: read("guide/word/settings.xml"),
    fontTableXml: read("guide/word/fontTable.xml"),
    footnotesXml: read("guide/word/footnotes.xml"),
    endnotesXml: read("guide/word/endnotes.xml"),
    numberingXml: read("guide/word/numbering.xml"),
    themeXml: read("guide/word/theme/theme1.xml"),
    emptyRels: read("guide/word/_rels/header1.xml.rels"),
    stylesHead: guideStyles.slice(0, split),
    stylesTail: guideStyles.slice(after),
    documentHead: read("guide/word/document.xml").slice(0, read("guide/word/document.xml").indexOf("<w:body>")),
    headerHead: read("guide/word/header1.xml").slice(0, read("guide/word/header1.xml").indexOf("<w:tbl>")),
  };
  for (const name of ["footnotes.xml.rels", "endnotes.xml.rels", "fontTable.xml.rels"]) {
    if (read(`guide/word/_rels/${name}`) !== parts.emptyRels) throw new Error(`${name} differs`);
  }
  if (read("code/word/header1.xml").slice(0, parts.headerHead.length) !== parts.headerHead) throw new Error("code header head differs");
  let docx = header + "/// docx 固定部件（和 Electron 版用的 docx 库输出逐字一致）。\nenum DocxParts {\n";
  for (const [key, value] of Object.entries(parts)) docx += `    static let ${key} = ${raw(value).replace(/\n/g, "\n    ")}\n\n`;
  docx += "}\n";
  fs.writeFileSync(path.join(out, "Build", "DocxParts.generated.swift"), docx);
}
console.log("generated");
