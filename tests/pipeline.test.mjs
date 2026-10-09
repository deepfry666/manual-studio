import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import JSZip from "jszip";
import { createCore } from "../core/index.mjs";
import { startMockRelay } from "./helpers/mock-relay.mjs";
import { startMockLlm } from "./helpers/mock-llm.mjs";
import { findLibreOffice } from "../core/build/runtime.mjs";

async function setupCore({ gateBrandOnce = [], gateBrandAlways = [] } = {}) {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "pipeline-test-"));
  const dataDir = path.join(root, "data");
  const workspace = path.join(root, "workspace");
  await fsp.mkdir(workspace, { recursive: true });
  const relay = await startMockRelay(() => ({ delayMs: 80 }));
  const llm = await startMockLlm({ gateBrandOnce, gateBrandAlways });
  const events = [];
  const core = await createCore({ dataDir, onEvent: (event) => events.forEach((listener) => listener(event)) });
  await core.updateSettings({ workspaceDir: workspace, pipeline: { reviewPlanSingle: false } });
  await core.saveProvider({ id: "cpa", preset: "openai-sync", name: "CPA", baseUrl: relay.baseUrl, model: "gpt-image-2.5", apiKey: "sk-image-test" });
  const vendorId = await core.saveVendor({ name: "测试厂商", preset: "custom", baseUrl: llm.baseUrl, apiKey: "sk-llm-test" });
  for (const step of ["plan", "content", "design"]) await core.setAssignment(step, { vendorId, model: "mock-text" });
  await core.setAssignment("gate", { vendorId, model: "mock-vision" });
  return { root, dataDir, workspace, relay, llm, core, events, close: () => Promise.all([relay.close(), llm.close()]) };
}

async function writeJavaSource(dir) {
  await fsp.mkdir(path.join(dir, "src", "app"), { recursive: true });
  await fsp.writeFile(path.join(dir, "src", "app", "B.java"), "package app;\n\npublic class B {\n  int b() { return 2; }\n}\n");
  await fsp.writeFile(path.join(dir, "src", "app", "A.java"), "package app;\npublic class A {\n  int a() { return 1; }\n}");
  await fsp.writeFile(path.join(dir, "README.md"), "not code");
}

test("端到端：新建项目一路跑到交付包（含代码来源、设计说明、PDF）", { timeout: 180_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const codeDir = path.join(ctx.root, "code");
  await writeJavaSource(codeDir);
  // 代码来源在总设置里设一次
  await ctx.core.updateSettings({ codeSource: { path: codeDir, extensions: [".java"] } });
  const dir = await ctx.core.createProject({ softwareName: "测试记账本 V1.0", screenCount: 3, emphasis: "预算提醒", wantDesign: true });
  const progressEvents = [];
  ctx.events.push((event) => event.type === "progress" && event.projectDir === dir && event.progress && progressEvents.push(event.progress));
  const result = await ctx.core.run(dir);
  const project = await ctx.core.getProject(dir);
  assert.equal(result.status, "done", JSON.stringify({ result, error: project.state.lastError, log: project.state.log.slice(-5) }));

  // 截图并发生成，提示词末尾有品牌禁令
  assert.equal(ctx.relay.submits().length, 3);
  const prompt = fs.readFileSync(path.join(dir, "prompts", "screen-01.md"), "utf8");
  assert.match(prompt, /Do NOT render the software name/);
  assert.match(prompt, /Project context exact software name: 测试记账本 V1\.0/);

  // 看图验收带了图片
  assert.ok(ctx.llm.calls.filter((call) => call.step === "gate").every((call) => call.hasImage));

  // 交付包
  const withPdf = Boolean(await findLibreOffice());
  const bundle = path.join(dir, "测试记账本 V1.0");
  const expected = ["测试记账本 V1.0指南.docx", "测试记账本 V1.0指南.txt", "测试记账本 V1.0指南_代码-（JAVA）.docx"];
  if (withPdf) expected.push("测试记账本 V1.0指南.pdf", "测试记账本 V1.0指南_代码-（JAVA）.pdf");
  assert.deepEqual(fs.readdirSync(bundle).sort(), expected.sort());

  // TXT：环境字段与旧模板一致，源程序量是代码来源的真实行数（A.java 4 行 + B.java 5 行）
  const txt = fs.readFileSync(path.join(bundle, "测试记账本 V1.0指南.txt"), "utf8");
  assert.match(txt, /^【开发的硬件环境】CPU类型：Intel英特尔酷睿i5-4590\r\n/);
  assert.match(txt, /【源程序量】9行\r\n/);
  assert.match(txt, /【编程语言】JAVA/);

  // 代码文档只来自代码来源（A 在 B 前，不含 README）
  const codeZip = await JSZip.loadAsync(fs.readFileSync(path.join(bundle, "测试记账本 V1.0指南_代码-（JAVA）.docx")));
  const codeXml = await codeZip.file("word/document.xml").async("string");
  assert.ok(codeXml.indexOf("public class A") < codeXml.indexOf("public class B"));
  assert.doesNotMatch(codeXml, /not code|CensusController|getPipeNetworkStatistics/);

  // 指南 Word：截图行不跨页（cantSplit），有设计说明
  const guideZip = await JSZip.loadAsync(fs.readFileSync(path.join(bundle, "测试记账本 V1.0指南.docx")));
  const guideXml = await guideZip.file("word/document.xml").async("string");
  assert.equal((guideXml.match(/<w:cantSplit\/>/g) || []).length, 3);
  assert.match(guideXml, /软件基本处理流程/);

  // 回执和 manifest
  const content = JSON.parse(fs.readFileSync(path.join(dir, "content.json"), "utf8"));
  assert.equal(content.screenshotReview.reviewedScreens.length, 3);
  assert.equal(content.imageRoute, "image-gateway");
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "project-manifest.json"), "utf8"));
  assert.equal(manifest.codeDocument, "from-code-source");
  assert.equal(manifest.codeSource.lineCount, 9);

  // 项目文件夹里没有本软件的隐藏状态文件
  assert.equal(fs.existsSync(path.join(dir, ".studio")), false);

  // 溯源：项目文件夹里有生成记录，manifest 里有每屏来源和用到的大模型
  const record = JSON.parse(fs.readFileSync(path.join(dir, "generation-record.json"), "utf8"));
  assert.equal(record.screens["screen-01"].providerName, "CPA");
  assert.equal(record.screens["screen-01"].model, "gpt-image-2.5");
  assert.match(record.screens["screen-01"].imageSha256, /^[a-f0-9]{64}$/);
  assert.equal(record.gate["screen-01"].method, "vision");
  assert.equal(record.llm.plan.model, "mock-text");
  assert.equal(record.llm.gate.model, "mock-vision");
  assert.ok(record.history.some((event) => event.event === "build"));
  assert.equal(manifest.provenance.screens["screen-02"].provider, "CPA");
  assert.equal(manifest.provenance.screens["screen-02"].gate, "vision");
  assert.match(manifest.provenance.builtBy, /软件指南生成器 \d/);

  // 版本号自动识别
  assert.equal(project.state.request.versionPolicy, "in-name");

  // PDF 字体：没有原版字体时换成固定字体，转完核对通过
  if (withPdf) {
    assert.equal(manifest.pdfFonts.guide.ok, true, JSON.stringify(manifest.pdfFonts));
    assert.equal(manifest.pdfFonts.code.ok, true, JSON.stringify(manifest.pdfFonts));
    assert.ok(!project.state.lastBuild.warnings.some((warning) => warning.includes("字体不对")));
  }

  // 用时：项目状态和生成记录里都有，每步也有
  assert.ok(project.state.timing.totalMs > 0);
  assert.equal(project.state.timing.completedMs, project.state.timing.totalMs);
  assert.ok(project.state.timing.runs[0].steps.images > 0);
  const recordAfter = JSON.parse(fs.readFileSync(path.join(dir, "generation-record.json"), "utf8"));
  assert.equal(recordAfter.timing.totalMs, project.state.timing.totalMs);
  assert.ok(recordAfter.history.some((event) => event.event === "run" && event.status === "done"));
  assert.equal(recordAfter.codeSource.lineCount, 9);
  assert.match(recordAfter.codeSource.sha256, /^[a-f0-9]{64}$/);
  const listed = (await ctx.core.listProjects()).find((row) => row.dir === dir);
  assert.equal(listed.timing.completedMs, project.state.timing.totalMs);

  // 实时进度：运行中能看到当前步骤和每张图的状态，结束后清掉
  assert.ok(progressEvents.some((item) => item.step === "images" && Object.values(item.screens).some((screen) => screen.status === "generating")));
  assert.ok(progressEvents.some((item) => item.step === "gate"));
  assert.equal(ctx.core.getProgress(dir), null);

  // 改了总设置里的代码来源：已完成的项目不重建，仍然用原来的代码来源
  const otherCode = path.join(ctx.root, "other-code");
  await fsp.mkdir(otherCode, { recursive: true });
  await fsp.writeFile(path.join(otherCode, "C.java"), "class C {}\n");
  await ctx.core.updateSettings({ codeSource: { path: otherCode, extensions: [".java"] } });
  assert.equal((await ctx.core.getProject(dir)).codeSource.source.path, codeDir);

  // 再跑一次：什么都不变，不重新生图、不重新调大模型、不重建
  const llmCallsBefore = ctx.llm.calls.length;
  const builtAt = project.state.lastBuild.at;
  const second = await ctx.core.run(dir);
  assert.equal(second.status, "done");
  assert.equal(ctx.relay.submits().length, 3);
  assert.equal(ctx.llm.calls.length, llmCallsBefore);
  assert.equal((await ctx.core.getProject(dir)).state.lastBuild.at, builtAt);
});

test("没有代码来源时只出指南，不生成代码文档", { timeout: 120_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "无代码测试 V1.0", screenCount: 2 });
  const result = await ctx.core.run(dir);
  assert.equal(result.status, "done");
  const files = fs.readdirSync(path.join(dir, "无代码测试 V1.0"));
  assert.ok(files.every((name) => !name.includes("_代码-（JAVA）")), files.join(","));
  const txt = fs.readFileSync(path.join(dir, "无代码测试 V1.0", "无代码测试 V1.0指南.txt"), "utf8");
  assert.match(txt, /【源程序量】\r\n/);
  const project = await ctx.core.getProject(dir);
  assert.ok(project.state.warnings.some((warning) => warning.includes("没有代码来源")));
  // 只重新导出 PDF（修正字体）：Word 不动，旧 PDF 归档，核对通过
  if (await findLibreOffice()) {
    const docx = path.join(dir, "无代码测试 V1.0", "无代码测试 V1.0指南.docx");
    const docxBefore = fs.readFileSync(docx);
    const reexport = await ctx.core.reexportPdfs([dir]);
    assert.deepEqual(reexport.failed, []);
    assert.deepEqual(fs.readFileSync(docx), docxBefore);
    const archived = fs.readdirSync(path.join(dir, "archive")).filter((name) => name.startsWith("无代码测试 V1.0-PDF-"));
    assert.equal(archived.length, 1);
    const after = await ctx.core.getProject(dir);
    assert.equal(after.state.lastBuild.pdfFonts.guide.ok, true);
    const record = JSON.parse(fs.readFileSync(path.join(dir, "generation-record.json"), "utf8"));
    assert.ok(record.history.some((event) => event.event === "pdf-reexported"));
  }
  // 没有版本号的名字也能自动识别
  const plain = await ctx.core.createProject({ softwareName: "随手记账", screenCount: 2 });
  assert.equal((await ctx.core.getProject(plain)).state.request.versionPolicy, "none");
});

test("截图里出现软件名：验收不通过，自动重生后通过", { timeout: 120_000 }, async (t) => {
  const ctx = await setupCore({ gateBrandOnce: ["新增账单"] });
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "测试记账本 V1.0", screenCount: 3 });
  const result = await ctx.core.run(dir, { until: "gate" });
  assert.notEqual(result.status, "failed");
  assert.equal(ctx.relay.submits().length, 4, "第 3 屏重生了一次");
  const project = await ctx.core.getProject(dir);
  assert.equal(project.state.screens["screen-03"].gate.status, "passed");
});

test("改文案后只重建交付包；单屏重生只重生这一屏", { timeout: 180_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "编辑测试 V1.0", screenCount: 3 });
  assert.equal((await ctx.core.run(dir)).status, "done");
  const submits = ctx.relay.submits().length;
  const edited = "这是人工修改后的说明文字。".repeat(30);
  await ctx.core.actions.saveContent(dir, { screens: [{ id: "screen-02", text: edited }] });
  assert.equal((await ctx.core.run(dir)).status, "done");
  assert.equal(ctx.relay.submits().length, submits, "改文案不重新生图");
  const content = JSON.parse(fs.readFileSync(path.join(dir, "content.json"), "utf8"));
  assert.equal(content.screens[1].text, edited);

  await ctx.core.actions.regenerateScreen(dir, "screen-01");
  assert.equal(ctx.relay.submits().length, submits + 1);
  const project = await ctx.core.getProject(dir);
  assert.equal(project.state.status, "done");
  const after = JSON.parse(fs.readFileSync(path.join(dir, "content.json"), "utf8"));
  assert.equal(after.screens[1].text, edited, "人工改过的文案不被覆盖");
  assert.ok(fs.readdirSync(path.join(dir, "archive")).some((name) => name.startsWith("screens-")), "旧截图已归档");
});

test("改软件名：不重新规划、不重新生图，重新验收后重建，文件夹一起改名", { timeout: 180_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "旧名字 V1.0", screenCount: 2 });
  assert.equal((await ctx.core.run(dir)).status, "done");
  const submits = ctx.relay.submits().length;
  const planCalls = ctx.llm.calls.filter((call) => call.step === "plan").length;
  const newDir = await ctx.core.renameSoftware(dir, "新名字 V2.0");
  assert.equal(path.basename(newDir), "新名字 V2.0");
  assert.equal((await ctx.core.run(newDir)).status, "done");
  assert.equal(ctx.relay.submits().length, submits);
  assert.equal(ctx.llm.calls.filter((call) => call.step === "plan").length, planCalls);
  assert.ok(fs.existsSync(path.join(newDir, "新名字 V2.0", "新名字 V2.0指南.docx")));
  assert.ok(!fs.existsSync(path.join(newDir, "旧名字 V1.0")), "旧名字的交付包已归档");
});

test("导入历史项目：沿用截图和回执，重建时不重新生图", { timeout: 180_000 }, async (t) => {
  const source = path.join(os.homedir(), "Desktop", "软件指南生成", "心云购电商广告运营平台 V1.0");
  if (!fs.existsSync(source)) {
    t.skip("本机没有这个历史项目");
    return;
  }
  const ctx = await setupCore();
  t.after(ctx.close);
  const copy = path.join(ctx.workspace, "心云购电商广告运营平台 V1.0");
  await fsp.cp(source, copy, { recursive: true });
  const before = fs.readdirSync(copy).sort();
  const scan = await ctx.core.scanWorkspace(ctx.workspace);
  assert.equal(scan.length, 1);
  assert.equal(scan[0].grade, "ready");
  const imported = await ctx.core.importProjects([copy]);
  assert.deepEqual(imported.imported, [copy]);
  assert.deepEqual(fs.readdirSync(copy).sort(), before, "导入不往项目里写文件");
  const project = await ctx.core.getProject(copy);
  assert.ok(project.state.warnings.some((warning) => warning.includes("固定正文")));
  // 什么都不改直接「检查并更新」：不重写任何文件、不重建
  const snapshot = () => fs.readdirSync(copy, { recursive: true }).filter((name) => !String(name).includes("archive")).map((name) => {
    const full = path.join(copy, String(name));
    const stat = fs.statSync(full);
    return stat.isFile() ? `${name}|${stat.size}|${stat.mtimeMs}` : null;
  }).filter(Boolean).sort().join("\n");
  const beforeRun = snapshot();
  const idle = await ctx.core.run(copy);
  assert.equal(idle.status, "done");
  assert.equal(snapshot(), beforeRun, "历史项目没有变化时，一个文件都不改");

  // 改了编制日期需要重建：现有交付包有代码文档但没有代码来源 → 先停下来要求确认
  await ctx.core.actions.updateRequest(copy, { compileDate: "2026年10月3日" });
  const blocked = await ctx.core.run(copy);
  assert.equal(blocked.status, "failed");
  assert.match(blocked.error, /确认不含代码文档/);
  assert.ok(fs.readdirSync(path.join(copy, "心云购电商广告运营平台 V1.0")).some((name) => name.includes("_代码-（JAVA）")), "停下来时旧交付包原样保留");
  await ctx.core.actions.updateRequest(copy, { allowDropCodeDoc: true });
  const result = await ctx.core.run(copy);
  const after = await ctx.core.getProject(copy);
  assert.equal(result.status, "done", after.state.lastError || "");
  assert.equal(ctx.relay.submits().length, 0, "不重新生图");
  assert.equal(ctx.llm.calls.length, 0, "不调用大模型");
  const bundle = fs.readdirSync(path.join(copy, "心云购电商广告运营平台 V1.0"));
  assert.ok(bundle.every((name) => !name.includes("_代码-（JAVA）")));
  assert.ok(fs.readdirSync(path.join(copy, "archive")).some((name) => name.includes("-交付-")), "旧交付包已归档");
});

test("重生截图后，这一屏的说明按新截图重写；人工改过的保留并提醒", { timeout: 180_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "重写测试 V1.0", screenCount: 3 });
  assert.equal((await ctx.core.run(dir)).status, "done");
  const before = JSON.parse(fs.readFileSync(path.join(dir, "content.json"), "utf8"));
  const edited = "人工改过的第三屏说明。".repeat(30);
  await ctx.core.actions.saveContent(dir, { screens: [{ id: "screen-03", text: edited }] });
  await ctx.core.actions.regenerateScreen(dir, "screen-02");
  await ctx.core.actions.regenerateScreen(dir, "screen-03");
  const after = JSON.parse(fs.readFileSync(path.join(dir, "content.json"), "utf8"));
  assert.notEqual(after.screens[1].text, before.screens[1].text, "第二屏说明已按新截图重写");
  assert.equal(after.screens[2].text, edited, "人工改过的第三屏保留");
  const project = await ctx.core.getProject(dir);
  assert.ok(project.state.warnings.some((warning) => warning.includes("截图已更换") && warning.includes("screen-03")));
});

test("历史项目改名：不重新生图，只重新验收，提示词里的旧名字换成新名字", { timeout: 180_000 }, async (t) => {
  const source = path.join(os.homedir(), "Desktop", "软件指南生成", "心云购电商广告运营平台 V1.0");
  if (!fs.existsSync(source)) {
    t.skip("本机没有这个历史项目");
    return;
  }
  const ctx = await setupCore();
  t.after(ctx.close);
  const copy = path.join(ctx.workspace, "心云购电商广告运营平台 V1.0");
  await fsp.cp(source, copy, { recursive: true });
  await ctx.core.importProjects([copy]);
  const newDir = await ctx.core.renameSoftware(copy, "云购运营助手 V2.0");
  await ctx.core.actions.updateRequest(newDir, { allowDropCodeDoc: true });
  const result = await ctx.core.run(newDir);
  const project = await ctx.core.getProject(newDir);
  assert.equal(result.status, "done", project.state.lastError || "");
  assert.equal(ctx.relay.submits().length, 0, "改名不重新生图");
  assert.equal(ctx.llm.calls.filter((call) => call.step === "gate").length, 7, "按新名字重新验收 7 张");
  assert.equal(ctx.llm.calls.filter((call) => call.step === "plan" || call.step === "content").length, 0);
  const prompt = fs.readFileSync(path.join(newDir, "prompts", "screen-02.md"), "utf8");
  assert.match(prompt, /云购运营助手 V2\.0/);
  assert.doesNotMatch(prompt, /心云购电商广告运营平台 V1\.0/);
  assert.ok(fs.existsSync(path.join(newDir, "云购运营助手 V2.0", "云购运营助手 V2.0指南.docx")));
});

test("验收一直不通过：按设置的次数自动重生，用完后停下交给人处理", { timeout: 120_000 }, async (t) => {
  const ctx = await setupCore({ gateBrandAlways: ["新增账单"] });
  t.after(ctx.close);
  await ctx.core.updateSettings({ image: { gateRegenerateLimit: 2 } });
  const dir = await ctx.core.createProject({ softwareName: "重生上限 V1.0", screenCount: 3 });
  const result = await ctx.core.run(dir);
  assert.equal(result.status, "failed");
  assert.equal(result.step, "gate");
  assert.equal(ctx.relay.submits().filter((submit) => submit.prompt.includes("新增账单")).length, 3, "首次生成 1 次 + 自动重生 2 次");
  const project = await ctx.core.getProject(dir);
  assert.equal(project.state.screens["screen-03"].gate.status, "failed");
  assert.match(project.state.lastError, /screen-03/);
});
