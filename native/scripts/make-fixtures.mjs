// 用定档的 Electron 版代码生成「标准答案」，Swift 测试逐项比对（native/StudioCore/Tests/StudioCoreTests/Fixtures/electron.json）。
// 用法：node native/scripts/make-fixtures.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import JSZip from "jszip";
import Ajv from "ajv";
import { stableStringify, hashObject } from "../../core/util/fsx.mjs";
import { forbiddenBrandTokens, findBrandHits, baseSoftwareName, textLength } from "../../core/pipeline/brand.mjs";
import { composeScreenPrompt, ensureBrandBan } from "../../core/pipeline/compose-prompt.mjs";
import * as sizeFns from "../../core/gateway/sizes.mjs";
import { APIMART_RATIOS, OPENAI_COMMON_RATIOS } from "../../core/gateway/presets.mjs";
const sizes = { ...sizeFns, APIMART_RATIOS, OPENAI_COMMON_RATIOS };
import { readPath, fillTemplate, parseRetryAfter, classifyHttpError } from "../../core/gateway/adapter.mjs";
import { extractJson } from "../../core/llm/client.mjs";
import * as steps from "../../core/pipeline/llm-steps.mjs";
import { formatDuration, detectVersion, promptIdentity, planRowHash, normalizedUi, codeSourceFor } from "../../core/pipeline/runner.mjs";
import { parseBatchList } from "../../core/batch.mjs";
import { fontRegistryXml, substitutionAttempts, judgePdfFonts, resolveFontPlan } from "../../core/build/fonts.mjs";
import { expectedBundleFiles } from "../../core/build/validate.mjs";
import { languageLabelFor, collectCodeSource } from "../../core/code-source.mjs";
import { newState, readPlan, projectKey } from "../../core/pipeline/project.mjs";
import { percentile } from "../../core/log/call-log.mjs";
import { makePng } from "../../tests/helpers/png.mjs";
import { defaultSettings, deepMerge, sanitizeSettings } from "../../core/settings.mjs";
import { redact } from "../../core/secrets.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", "..");
const out = {};

// ---------- JSON ----------
const jsonValues = [
  { a: 1, b: [1, 2, { c: "x" }], e: [], f: {}, g: null, h: true },
  { z: 0.1, y: 1e21, x: 1e-7, w: 123.456, v: -0.5, u: 1728500000000.123, t: 5e-324, s: 1e20, r: 0.000001, q: 1.5e-6 },
  { "中文键": "中文值\n换行\t制表\u0001控制\"引号\\反斜杠/斜杠", emoji: "😀👍", ls: "  " },
  { b: 2, a: 1, "Z": 3, "_": 4, "中": 5, "aa": 6, "A": 7 },
  [1, "two", null, false, [], {}],
  "plain",
  42,
];
out.json = jsonValues.map((value) => ({ input: JSON.stringify(value), stringify: JSON.stringify(value), pretty: JSON.stringify(value, null, 2), stable: stableStringify(value), hash: hashObject(value) }));
out.numbers = [0, -0, 1, -1, 0.1, 0.5, 1.5, 100, 1e15, 1e16, 1e20, 1e21, 1e22, 1e-6, 1e-7, 1.23e-10, 123456789.123, 2 ** 53, 0.30000000000000004, 1728500000000.123, 85, 33.5, 1/3].map((n) => ({ value: n, text: String(n) }));
out.percentile = [[[1, 2, 3, 4], 50], [[10, 20, 30], 85], [[5], 90], [[3, 1, 2, 10, 7], 90]].map(([values, p]) => ({ values, p, result: percentile(values, p) }));

// ---------- 品牌词 ----------
const names = ["测试记账本 V1.0", "云伴日程 V1.0", "掌上违章助手V2.3.1", "AI 口播数字人 V1.0", "Car手机车辆投屏 V1.0", "SYNXURE应用平台（iOS 端）V1.0", "UU游戏辅助器+V1.0", "电梯宝APPV1.0", "  空格 v3.2  ", "无版本"];
out.brand = names.map((name) => ({ name, tokens: forbiddenBrandTokens(name, ["额外词", " x ", "品牌"]), base: baseSoftwareName(name), hits: findBrandHits(["首页 测试记账本v1.0 标题", "ＡＩ口播", "UU游戏 辅助器"], forbiddenBrandTokens(name)), len: textLength(` ${name}😀 `) }));

// ---------- 提示词 ----------
const ui = { visualStyle: "clean light finance app", palette: { primary: "#2563EB", background: "#F5F7FB", surface: "#FFFFFF", text: "#172033", muted: "" }, typography: "system sans", radius: "12px", shadow: "subtle", density: "comfortable", navigation: { type: "bottom-tabs", labels: ["首页", "明细", "", "我的"], iconSemantics: ["home", "list", "person"] } };
const screenA = { id: "screen-01", title: "记账首页", pageType: "dashboard", activeTab: "首页", mustShow: ["汇总卡片", "分类列表"], sampleData: ["本月支出 ¥3,280", 12], visualBrief: "A clean home screen with summary card." };
const screenB = { id: "screen-02", title: "新增账单", mustShow: [], sampleData: [], activeTab: null };
const screenC = { id: "screen-03", title: "设置", visualBrief: "" };
out.prompts = [
  { softwareName: "测试记账本 V1.0", platform: "iPhone 16 Pro Max / iOS 26", targetSize: "864x1824", ui, screen: screenA },
  { softwareName: "测试记账本 V1.0", platform: "Android 手机（原生 Android 界面）", targetSize: "864x1824", ui, screen: screenB },
  { softwareName: "名字", platform: "iPhone", targetSize: "1:2", ui: {}, screen: screenC },
  { softwareName: "名字", platform: "iPhone", targetSize: "864x1824", ui: { navigation: { type: "stack", labels: ["a"] }, palette: {} }, screen: screenA },
].map((input) => ({ ...input, output: composeScreenPrompt(input) }));
out.ensureBan = ["hello", `hello\n\n${"Do NOT render the software name, App name, version string, name-bearing logo, wordmark, or recognizable project-name branding anywhere in the UI."}\nmore  \n\n`, ""].map((input) => ({ input, output: ensureBrandBan(input) }));
out.normalizedUi = [{ uiContract: { a: 1, visual: { palette: { p: 1 }, typography: "t" } } }, { uiContract: { palette: { x: 1 }, visual: { palette: { y: 2 } } } }, { uiContract: null }, { uiContract: { palette: null } }].map((plan) => ({ plan, output: normalizedUi(plan) }));
out.planRowHash = [{ screen: screenA, ui: normalizedUi({ uiContract: ui }), platform: "iPhone", target: "864x1824" }].map((input) => ({ ...input, hash: planRowHash(input.screen, input.ui, input.platform, input.target) }));
out.promptIdentity = [["abc 名字 def 名字", "名字"], ["no name", "x"]].map(([prompt, name]) => ({ prompt, name, hash: promptIdentity(prompt, name) }));

// ---------- 尺寸 ----------
out.sizes = {
  nearest: [[{ width: 864, height: 1824 }, sizes.APIMART_RATIOS], [{ width: 864, height: 1824 }, sizes.OPENAI_COMMON_RATIOS], [{ width: 1, height: 1 }, ["2:3", "1:1"]]].map(([target, ratios]) => ({ target, ratios, result: sizes.nearestRatio(target, ratios) })),
  allowedRatios: ["pixel sizes are not supported; must be auto or one of 1:1, 16:9, 9:16, 1:2", "比例必须是1:2或者2:1", "size 123:45 bad", "random 1:2"].map((message) => ({ message, result: sizes.parseAllowedRatios(message) })),
  unsupported: ["Pixel sizes are not supported", "invalid value: '864x1824'", "size must be one of", "ok"].map((message) => ({ message, result: sizes.looksLikeUnsupportedPixelSize(message) })),
  pixelSizes: ["Invalid size '864x1824'. Supported sizes are 1024x1024, 1024x1536, 1536x1024", "大小1024x1536无效"].map((message) => ({ message, result: sizes.parseAllowedPixelSizes(message) })),
  resolve: [{ sizeMode: "ratio", ratios: sizes.APIMART_RATIOS }, { sizeMode: "pixel", pixelSize: "864x1824" }, { sizeMode: "pixel", pixelSize: "bad" }, { sizeMode: "ratio", ratios: [] }].map((provider) => ({ provider, result: sizes.resolveRequestSize(provider, "864x1824") })),
  fallback: [
    { message: "Invalid size '864x1824'. Supported sizes are 1024x1024, 1024x1536, 1536x1024", allowedRatios: [], provider: { ratios: [] }, current: "864x1824" },
    { message: "must be one of 1:1, 2:3, 9:16", allowedRatios: ["1:1", "2:3", "9:16"], provider: { ratios: [] }, current: "864x1824" },
    { message: "Pixel sizes are not supported", allowedRatios: [], provider: { ratios: sizes.APIMART_RATIOS }, current: "864x1824" },
    { message: "unknown", allowedRatios: [], provider: { ratios: [] }, current: "864x1824" },
  ].map((input) => ({ ...input, result: sizes.sizeFallback({ message: input.message, allowedRatios: input.allowedRatios }, input.provider, "864x1824", input.current) })),
};

// ---------- 接口适配 ----------
const sample = { data: [{ task_id: "t1", url: ["u1", "u2"] }, { task_id: 7 }], meta: { status: "completed", result: { images: [{ url: "x" }] } } };
out.readPath = ["$.data[0].task_id", "$.data[*]", "$.data[1].task_id", "$.meta.result.images[*]", "$.meta.status", "$", "$.missing.x", "$.data[*].task_id", "$.data[5]"].map((expr) => ({ expr, result: readPath(sample, expr) === undefined ? "__undefined__" : readPath(sample, expr) }));
out.sample = sample;
const template = { model: "$model", prompt: "$prompt", size: "$size", quality: "$quality", n: 1, path: "/tasks/$taskId?x=$model", list: ["$model", "$missing"], empty: "$missing", nested: { q: "$quality" } };
out.fillTemplate = [{ model: "m", prompt: "p", size: "1:2", quality: "low", taskId: "t%201" }, { model: "m", prompt: "p", size: "1:2" }].map((context) => ({ context, result: fillTemplate(template, context) }));
out.template = template;
out.retryAfter = ["reset_seconds: 120", "try again in 48m20s", "1h2m3s", "rate limit, retry after 15 minutes", "nothing"].map((message) => ({ message, result: parseRetryAfter(null, message) ?? null }));
out.classify = [[401, ""], [429, "slow down"], [400, "credential_quota exceeded reset_seconds=60"], [400, "pixel sizes are not supported; must be one of 1:1, 2:3"], [404, "not found"], [400, "model gpt-x not found"], [400, "content_policy violation"], [502, "bad gateway"], [409, ""], [400, "bad request"]].map(([status, message]) => ({ status, message, result: classifyHttpError(status, message) }));
out.redact = [["Bearer abcdefgh12345 sk-abcdefghij and secretvalue123", ["secretvalue123"]], ["key=sk-short", []], ["xsk-abcdefghij", []]].map(([text, secrets]) => ({ text, secrets, result: redact(text, secrets) }));

// ---------- 大模型输出 ----------
out.extractJson = ['{"a":1}', '<think>xx {"b":2}</think>```json\n{"a":2}\n```', 'prefix {"a":3} suffix', "```\n{\"a\":4}\n```", "not json"].map((text) => { try { return { text, result: extractJson(text) }; } catch (error) { return { text, error: error.message }; } });

// ---------- 各步骤提示词与校验 ----------
out.steps = {
  planUser: [{ softwareName: "测试 V1.0", screenCount: 7, emphasis: "预算", notes: "", platform: "iPhone" }, { softwareName: "测试", screenCount: null, emphasis: "", notes: "补充", platform: "Android" }].map((input) => ({ input, output: steps.planUserPrompt(input) })),
  planCheck: [
    { plan: { screens: [{ id: "screen-01", title: "首页", visualBrief: "测试记账本 brand", mustShow: ["a"], sampleData: [] }, { id: "screen-3", title: "首页" }], uiContract: { navigation: { labels: ["测试记账本"] } } }, softwareName: "测试记账本 V1.0", screenCount: 3 },
    { plan: { screens: [{ id: "screen-01", title: "a" }] }, softwareName: "x", screenCount: null },
  ].map((input) => ({ ...input, output: steps.planCheck(input.plan, input) })),
  gateUser: [{ softwareName: "测试 V1.0", tokens: ["测试 V1.0", "V1.0", "测试"], screen: { title: "首页", mustShow: ["a", "b"] } }, { softwareName: "x", tokens: [], screen: null }].map((input) => ({ input, output: steps.gateUserPrompt(input) })),
  judgeGate: [
    { result: { brandFound: true, brandEvidence: "", visibleText: ["测试记账本"], screenTitle: "", singleScreen: false, portraitApp: false }, tokens: ["测试记账本"] },
    { result: { brandFound: false, visibleText: ["ok"], singleScreen: true, portraitApp: true }, tokens: ["x"] },
  ].map((input) => ({ ...input, output: steps.judgeGate(input.result, input.tokens) })),
  contentUser: [
    { softwareName: "测试", profile: { domain: "记账", targetUser: "", coreFlow: "a-b" }, screens: [screenA, { id: "screen-02", title: "二", textContract: null }], inventories: { "screen-01": "界面内容" }, needOverview: true, existingOverview: "旧介绍", floor: 300, instructions: { overview: "改短", "screen-02": "多写" }, currentTexts: { "screen-02": "原文" } },
    { softwareName: "测试", profile: null, screens: [{ id: "screen-01", title: "一", textContract: { entry: "e", action: "a", feedback: "f", exception: "x", exit: "o" }, mustShow: ["m"], sampleData: ["s"] }], inventories: {}, needOverview: false, existingOverview: "", floor: 320 },
  ].map((input) => ({ input, output: steps.contentUserPrompt(input) })),
  contentCheck: [
    { result: { overview: "短 图1", screens: [{ id: "screen-01", text: "太短 图2 虚构" }, { id: "screen-03", text: "x".repeat(400) }] }, screens: [{ id: "screen-01" }, { id: "screen-02" }], needOverview: true, floor: 300 },
  ].map((input) => ({ ...input, output: steps.contentCheck(input.result, input) })),
  designUser: [{ softwareName: "测试", profile: { domain: "d" }, features: [{ name: "f1" }, { name: "f2" }], screens: [screenA, screenB], instruction: "改", current: "当前" }, { softwareName: "测试", profile: null, features: [], screens: [], instruction: "", current: "" }].map((input) => ({ input, output: steps.designUserPrompt(input) })),
  designCheck: [{ sections: [{ title: "a", text: "图3 内容" }, { title: "b", text: "ok" }] }].map((result) => ({ result, output: steps.designCheck(result) })),
  feedbackUser: [{ softwareName: "测试", screens: [{ figure: "图1", id: "screen-01", title: "首页", inventory: "画面", visual: "v", text: "说明" }, { figure: "图2", id: "screen-02", title: "二", inventory: "", visual: "plan", text: "" }, { figure: "图3", id: "screen-03", title: "三", inventory: "", visual: "", text: "" }], overview: "", hasDesign: false, items: [{ text: "意见A" }, { text: "意见B" }] }].map((input) => ({ input, output: steps.feedbackUserPrompt(input) })),
  feedbackCheck: [{ result: { actions: [{ type: "image", target: "screen-09", items: [1] }, { type: "text", target: "all", items: [] }, { type: "image", target: "screen-09", items: [] }], questions: [{ question: "q", items: [3] }] }, screenIds: ["screen-01", "screen-02"], itemCount: 4 }].map((input) => ({ ...input, output: steps.feedbackCheck(input.result, input) })),
  promptEdit: [{ prompt: "line1\nline2", instruction: "改蓝色" }].map((input) => ({ input, output: steps.promptEditUserPrompt(input) })),
};

// ---------- Schema 校验（和 ajv 的报错一致） ----------
const ajv = new Ajv({ allErrors: true, strict: false });
const describe = (errors) => (errors || []).slice(0, 12).map((error) => `${error.instancePath || "(根)"} ${error.message}`).join("；");
const schemaCases = [
  [steps.PLAN_SCHEMA, { profile: { domain: "x" }, coverageReason: "ab", features: [], uiContract: { visualStyle: 1, palette: {}, typography: "", navigation: { type: "x", labels: "a" } }, screens: [{ id: "bad", title: "一", pageType: "", mustShow: ["a"], sampleData: [], textContract: {}, visualBrief: "short", activeTab: 3 }] }],
  [steps.GATE_SCHEMA, { singleScreen: "yes", portraitApp: true, brandFound: false, visibleText: [1], inventory: "短", warnings: [] }],
  [steps.FEEDBACK_SCHEMA, { summary: "", actions: [{ type: "other", target: "x", instruction: "a", items: [1.5] }], questions: [{ question: "q" }] }],
  [steps.CONTENT_SCHEMA, { screens: [{ id: "screen-01", title: "t", text: "x" }] }],
  [steps.DESIGN_SCHEMA, { sections: [{ title: "t", text: "短" }] }],
];
out.schema = schemaCases.map(([schema, value]) => {
  const validate = ajv.compile(schema);
  const ok = validate(value);
  return { schema, value, ok, errors: ok ? "" : describe(validate.errors) };
});

// ---------- 小工具 ----------
out.formatDuration = [0, 499, 500, 59_400, 59_600, 60_000, 250_000, 3_600_000, 3_720_000, 7_260_000, 5_000_000].map((ms) => ({ ms, text: formatDuration(ms) }));
out.detectVersion = ["测试 V1.0", "abc v2", "x1.2.3y", "无", "V 1.0", "a 1.0 b V2.0"].map((name) => ({ name, result: detectVersion(name) }));
out.batchList = ["软件名,截图数\n云伴日程 V1.0\n快记账本 V1.0,7,预算提醒\n\n\"引号,名字\",abc,\"重点\"\"功能\",备注\n掌上\t5\t重点\t/path/code\n中文，逗号，3", "﻿name\nA,0,x,~/a\nB, 12屏"].map((text) => ({ text, rows: parseBatchList(text) }));
out.fontRegistry = [[], [{ from: "Microsoft YaHei", to: "苹方-简" }, { from: "a&<b>\"", to: "c" }]].map((pairs) => ({ pairs, xml: fontRegistryXml(pairs) }));
out.fontPlan = await Promise.all([[{ guide: "pingfang", code: "stsong" }, ["PingFang SC"]], [{ guide: "heiti", code: "courier" }, ["Microsoft YaHei"]], [{ guide: "bad", code: "pingfang" }, ["NSimSun"]]].map(async ([pdf, families]) => ({ pdf, families, plan: await resolveFontPlan(pdf, { families: new Set(families) }) })));
out.fontAttempts = [["guide", { mode: "substitute", substitute: "pingfang" }], ["code", { mode: "original" }], ["code", { mode: "substitute", substitute: "courier" }]].map(([kind, entry]) => ({ kind, entry, attempts: substitutionAttempts(kind, entry).map((attempt) => ({ ...attempt, expect: attempt.expect.source, alsoAllowed: attempt.alsoAllowed ? attempt.alsoAllowed.source : null })) }));
out.judgeFonts = [[["PingFangSC-Regular", "PingFangSC-Semibold"], "pingfang"], [["PingFangSC-Regular", "Arial"], "pingfang"], [["CourierNewPSMT", "PingFangSC-Regular"], "courier"], [[], "stsong"]].map(([fonts, key]) => { const attempt = substitutionAttempts(key === "courier" || key === "stsong" ? "code" : "guide", { mode: "substitute", substitute: key })[0]; return { fonts, key, result: judgePdfFonts(fonts, attempt) }; });
out.bundleFiles = [[true, true], [false, true], [true, false], [false, false]].map(([withCode, withPdf]) => ({ withCode, withPdf, files: expectedBundleFiles("名 V1.0", { withCode, withPdf }) }));
out.languageLabel = [[".java"], [".kt", ".java", ".KT"], [".txt"], [".ts", ".tsx", ".vue"]].map((extensions) => ({ extensions, label: languageLabelFor(extensions) }));
const sortNames = ["b.java", "A.java", "a.java", "_x.java", "10.java", "9.java", "Z.java", "中文.java", "a-b.java", "a_b.java", "ab.java", "B.java", "é.java", "e.java"];
out.localeSort = { input: sortNames, sorted: [...sortNames].sort((a, b) => a.localeCompare(b, "en")) };
out.projectKey = ["/Users/x/Desktop/软件指南生成/测试 V1.0", "/tmp/a"].map((dir) => ({ dir, key: projectKey(dir) }));
const stateSample = newState({ softwareName: "测试 V1.0", screenCount: 5, emphasis: "e", wantDesign: 1, extraBrandTokens: ["x"], createdAt: "2026-01-01" });
out.newState = stateSample;
out.codeSourceFor = [
  [{ request: { codeSource: { path: "/a", extensions: [".kt"], extra: 1 } }, lastBuild: { at: "x" } }, { codeSource: { path: "/g", extensions: [] } }],
  [{ request: {}, origin: "created" }, { codeSource: { path: "/g", extensions: [] } }],
  [{ request: { codeSourceLocked: false, codeSource: { path: "/a" } }, origin: "imported" }, { codeSource: { path: "", extensions: [".java"] } }],
  [{ request: { codeSourceLocked: null }, origin: "imported" }, { codeSource: { path: "/g", extensions: [".java"] } }],
].map(([state, settings]) => ({ state, settings, result: codeSourceFor(state, settings) }));

// 设置：深合并、空值换回默认
const storedSettings = { image: { globalConcurrency: null, hedge: { minSec: "" } }, pipeline: { batchConcurrency: 5 }, txtFields: { devOs: "macOS" }, codeDefaults: { extensions: [".kt"] } };
out.settings = { stored: storedSettings, merged: sanitizeSettings(deepMerge(defaultSettings(), storedSettings)) };

// ---------- 代码来源 ----------
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "fixtures-"));
const codeDir = path.join(tmp, "code");
fs.mkdirSync(path.join(codeDir, "src", "app"), { recursive: true });
fs.mkdirSync(path.join(codeDir, "build"), { recursive: true });
fs.writeFileSync(path.join(codeDir, "src", "app", "B.java"), "﻿package app;\r\n\r\npublic class B {}\r\n");
fs.writeFileSync(path.join(codeDir, "src", "app", "a.java"), "class a {}");
fs.writeFileSync(path.join(codeDir, "src", "app", "Bin.java"), Buffer.from([1, 0, 2]));
fs.writeFileSync(path.join(codeDir, "build", "Gen.java"), "generated");
fs.writeFileSync(path.join(codeDir, "src", "Main.java"), "line1\nline2\n\n\n");
const code = await collectCodeSource({ path: codeDir, extensions: ["java"] }, { excludeDirs: ["build"] });
out.code = { files: { "src/app/B.java": "﻿package app;\r\n\r\npublic class B {}\r\n", "src/app/a.java": "class a {}", "build/Gen.java": "generated", "src/Main.java": "line1\nline2\n\n\n" }, binary: "src/app/Bin.java", result: { files: code.files, lineCount: code.lineCount, nonEmptyLines: code.nonEmptyLines, body: code.body, sha256: code.sha256, warnings: code.warnings.map((w) => w.replace(codeDir, "<root>")), estimatedPages: code.estimatedPages } };

// ---------- 规划文件（历史格式） ----------
const planDir = path.join(tmp, "plan");
fs.mkdirSync(planDir, { recursive: true });
fs.writeFileSync(path.join(planDir, "screen-plan.json"), JSON.stringify({ flow: ["首页", { screenId: "screen-02", name: "列表" }, { purpose: "设置" }], extra: 1 }));
fs.writeFileSync(path.join(planDir, "ui-contract.json"), JSON.stringify({ visual: { palette: { primary: "#000" } } }));
out.readPlan = await readPlan(planDir);

// ---------- Word 和 TXT ----------
const docDir = path.join(tmp, "doc");
fs.mkdirSync(path.join(docDir, "screens"), { recursive: true });
const pngs = [makePng(60, 126, { seed: 1 }), makePng(60, 126, { seed: 2 })];
pngs.forEach((png, index) => fs.writeFileSync(path.join(docDir, "screens", `screen-0${index + 1}.png`), png));
const long = "进入页面后，用户可以查看数据并操作 & <标签> \"引号\" 'x'。".repeat(12);
const content = { softwareName: "测试's & <软件> V1.0", versionPolicy: "separate-metadata", applicableVersion: "V1.0", compileDate: "2026年10月9日", screenshotCount: 2, cover: { overview: "第一段介绍\r\n\n  第二段介绍  \n" }, screens: [{ id: "screen-01", title: " 首页 ", caption: "图1 首页", image: "screens/screen-01.png", text: `${long}\n第二段`, image_size: "864x1824" }, { id: "screen-02", title: "设置", caption: "图2 设置", image: "screens/screen-02.png", text: long, summary: "摘要" }], design: { sections: [{ title: " 软件基本处理流程 ", text: " 流程说明\n第二段 " }, { title: "数据结构设计", text: "数据说明" }] } };
fs.writeFileSync(path.join(docDir, "content.json"), JSON.stringify(content));
const software = content.softwareName;
const regionFile = path.join(tmp, "region.json");
execFileSync(process.execPath, [path.join(root, "core/templates/scripts/create-guide-docx.js"), "--project", docDir, "--software", software, "--content", path.join(docDir, "content.json"), "--region-out", regionFile]);
const codeBody = "package app;\n\tint a = 1; // <x> & 'y'\n\n  end\u0001\n";
fs.writeFileSync(path.join(tmp, "code.txt"), codeBody);
execFileSync(process.execPath, [path.join(root, "core/templates/scripts/create-code-docx.js"), "--project", docDir, "--software", software, "--body-file", path.join(tmp, "code.txt")]);
fs.writeFileSync(path.join(tmp, "fields.json"), JSON.stringify({ devOs: "macOS 26", language: "Swift", languageOverride: true }));
fs.writeFileSync(path.join(tmp, "overview.txt"), content.cover.overview);
execFileSync(process.execPath, [path.join(root, "core/templates/scripts/create-guide-txt.js"), "--project", docDir, "--software", software, "--overview-file", path.join(tmp, "overview.txt"), "--fields-file", path.join(tmp, "fields.json"), "--source-lines", "123"]);
async function parts(file) {
  const zip = await JSZip.loadAsync(fs.readFileSync(file));
  const result = { names: Object.keys(zip.files) };
  for (const name of Object.keys(zip.files)) if (/\.(xml|rels)$/.test(name) && name !== "docProps/core.xml") result[name] = await zip.file(name).async("string");
  return result;
}
out.docx = {
  pngs: pngs.map((png) => png.toString("base64")),
  content,
  software,
  codeBody,
  guide: await parts(path.join(docDir, software, `${software}指南.docx`)),
  code: await parts(path.join(docDir, software, `${software}指南_代码-（JAVA）.docx`)),
  region: JSON.parse(fs.readFileSync(regionFile, "utf8")),
  txt: fs.readFileSync(path.join(docDir, software, `${software}指南.txt`), "utf8"),
};
fs.rmSync(tmp, { recursive: true, force: true });

fs.writeFileSync(path.join(here, "..", "StudioCore", "Tests", "StudioCoreTests", "Fixtures", "electron.json"), JSON.stringify(out, null, 1));
console.log("fixtures written");
