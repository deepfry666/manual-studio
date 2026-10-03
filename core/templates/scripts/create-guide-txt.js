#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const GUIDE_SUFFIX = "\u6307\u5357";
// 软件指南生成器补丁：环境字段可配置（默认值与原模板一致），源程序量按代码来源实际行数填写。
const DEFAULT_FIELDS = {
  devHardware: "CPU\u7c7b\u578b\uff1aIntel\u82f1\u7279\u5c14\u9177\u777fi5-4590",
  runHardware: "\u5b89\u5353\u673a\uff0c8\u6838\u5904\u7406\u5668\uff0cROM 64GB",
  devOs: "Windows Server 2012\u4ee5\u4e0a",
  devTools: "Visual Studio2010",
  runPlatform: "Android\u64cd\u4f5c\u7cfb\u7edf5.0\u7248\u4ee5\u4e0a",
  runSupport: " Android Studio + Java jdk + Android SDK",
  language: "JAVA",
};

function buildTemplate(fields, sourceLines) {
  const f = { ...DEFAULT_FIELDS, ...fields };
  return [
    `\u3010\u5f00\u53d1\u7684\u786c\u4ef6\u73af\u5883\u3011${f.devHardware}`,
    `\u3010\u8fd0\u884c\u7684\u786c\u4ef6\u73af\u5883\u3011${f.runHardware}`,
    `\u3010\u5f00\u53d1\u8be5\u8f6f\u4ef6\u7684\u64cd\u4f5c\u7cfb\u7edf\u3011${f.devOs}`,
    `\u3010\u8f6f\u4ef6\u5f00\u53d1\u73af\u5883/\u5f00\u53d1\u5de5\u5177\u3011${f.devTools}`,
    `\u3010\u8be5\u8f6f\u4ef6\u7684\u8fd0\u884c\u5e73\u53f0/\u64cd\u4f5c\u7cfb\u7edf\u3011${f.runPlatform}`,
    `\u3010\u8f6f\u4ef6\u8fd0\u884c\u652f\u6491\u73af\u5883/\u652f\u6301\u8f6f\u4ef6\u3011${f.runSupport}`,
    `\u3010\u7f16\u7a0b\u8bed\u8a00\u3011${f.language}`,
    `\u3010\u6e90\u7a0b\u5e8f\u91cf\u3011${sourceLines ? `${sourceLines}\u884c` : ""}`,
    "\u3010\u8f6f\u4ef6\u7684\u4e3b\u8981\u529f\u80fd\u3011",
  ].join("\r\n");
}

function usage() {
  console.error("Usage: node create-guide-txt.js --project <dir> --software <name> (--overview <text> | --overview-file <file>)");
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === "--project") args.project = argv[++i];
    else if (key === "--software") args.software = argv[++i];
    else if (key === "--overview") args.overview = argv[++i];
    else if (key === "--overview-file") args.overviewFile = argv[++i];
    else if (key === "--fields-file") args.fieldsFile = argv[++i];
    else if (key === "--source-lines") args.sourceLines = Number(argv[++i]) || 0;
    else if (key === "--help" || key === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${key}`);
  }
  return args;
}

function readOverview(args) {
  if (args.overviewFile) return fs.readFileSync(path.resolve(args.overviewFile), "utf8");
  if (typeof args.overview === "string") return args.overview;
  return "";
}

function formatOverview(text) {
  return text
    .replace(/\r\n/g, "\n")
    .split(/\n+/)
    .map((paragraph) => paragraph.trim())
    .filter(Boolean)
    .join("\r\n");
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv);
  } catch (err) {
    console.error(err.message);
    usage();
    process.exit(2);
  }
  if (args.help || !args.project || !args.software || (!args.overview && !args.overviewFile)) {
    usage();
    process.exit(args.help ? 0 : 2);
  }

  const project = path.resolve(args.project);
  const deliveryDir = path.join(project, args.software);
  fs.mkdirSync(deliveryDir, { recursive: true });
  const overview = formatOverview(readOverview(args));
  const output = path.join(deliveryDir, `${args.software}${GUIDE_SUFFIX}.txt`);
  const fields = args.fieldsFile ? JSON.parse(fs.readFileSync(path.resolve(args.fieldsFile), "utf8")) : {};
  fs.writeFileSync(output, `${buildTemplate(fields, args.sourceLines)}\r\n${overview}\r\n`, "utf8");
  console.log(`TXT created: ${output}`);
}

main();
