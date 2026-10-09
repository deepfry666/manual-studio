import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import fsp from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createCore } from "../core/index.mjs";
import { startMockRelay } from "./helpers/mock-relay.mjs";
import { startMockLlm } from "./helpers/mock-llm.mjs";
import { fontRegistryXml, judgePdfFonts, resolveFontPlan, substitutionAttempts, rememberWorkingName, SUBSTITUTES } from "../core/build/fonts.mjs";
import { detectVersion, formatDuration, codeSourceFor } from "../core/pipeline/runner.mjs";

async function setupCore() {
  const root = await fsp.mkdtemp(path.join(os.tmpdir(), "features-test-"));
  const dataDir = path.join(root, "data");
  const workspace = path.join(root, "workspace");
  await fsp.mkdir(workspace, { recursive: true });
  const relay = await startMockRelay(() => ({ delayMs: 40 }));
  const llm = await startMockLlm();
  const trashed = [];
  const core = await createCore({ dataDir, trashItem: async (target) => {
    trashed.push(target);
    await fsp.rm(target, { recursive: true, force: true });
  } });
  await core.updateSettings({ workspaceDir: workspace, pipeline: { reviewPlanSingle: false } });
  await core.saveProvider({ id: "cpa", preset: "openai-sync", name: "CPA", baseUrl: relay.baseUrl, model: "gpt-image-2.5", apiKey: "sk-image-test" });
  const vendorId = await core.saveVendor({ name: "测试厂商", preset: "custom", baseUrl: llm.baseUrl, apiKey: "sk-llm-test" });
  for (const step of ["plan", "content", "design"]) await core.setAssignment(step, { vendorId, model: "mock-text" });
  await core.setAssignment("gate", { vendorId, model: "mock-vision" });
  return { root, workspace, relay, llm, core, trashed, close: () => Promise.all([relay.close(), llm.close()]) };
}

/** 不跑流程，直接造一个「已有交付包」的项目（导出测试用）。 */
async function fakeBuiltProject(core, name, files) {
  const dir = await core.createProject({ softwareName: name, screenCount: 2 });
  const bundle = path.join(dir, name);
  await fsp.mkdir(bundle, { recursive: true });
  for (const file of files) await fsp.writeFile(path.join(bundle, file), `${name}:${file}`);
  await fsp.writeFile(path.join(bundle, ".DS_Store"), "x");
  await core.internals.projectStore.update(dir, (state) => {
    state.status = "done";
    state.lastBuild = { at: new Date().toISOString(), files };
  });
  return dir;
}

test("修改意见：先攒清单，整理后统一修改，只重生涉及的截图，文字要求传给大模型，留记录", { timeout: 120_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const dir = await ctx.core.createProject({ softwareName: "意见测试 V1.0", screenCount: 3 });
  assert.equal((await ctx.core.run(dir)).status, "done");
  const submitsBefore = ctx.relay.submits().length;
  assert.equal(submitsBefore, 3);

  // 攒清单：同一屏两条、一条改说明、一条改封面、一条说不清
  const add = (text) => ctx.core.actions.addFeedback(dir, text);
  await add("图2 底部按钮改成蓝色");
  await add("图2 再加一个筛选按钮");
  await add("图3 说明多写异常处理");
  await add("封面介绍提一下数据导出");
  const vague = await add("这个不太好看");
  const removable = await add("写错了，删掉这条");
  await ctx.core.actions.removeFeedback(dir, removable.id);

  // 整理
  const plan = await ctx.core.actions.analyzeFeedback(dir);
  const byKey = Object.fromEntries(plan.actions.map((action) => [action.key, action]));
  assert.deepEqual(Object.keys(byKey).sort(), ["image:screen-02", "overview:overview", "text:screen-03"]);
  assert.equal(byKey["image:screen-02"].items.length, 2, "同一屏两条意见合并成一个动作");
  assert.match(byKey["image:screen-02"].instruction, /蓝色.*筛选/);
  assert.equal(byKey["image:screen-02"].targetLabel, "图2「记账首页」");
  assert.equal(plan.questions.length, 1);
  assert.deepEqual(plan.questions[0].items, [vague.id]);
  const feedbackCall = ctx.llm.calls.find((call) => call.step === "feedback");
  assert.match(feedbackCall.user, /图2（screen-02）「记账首页」/);
  assert.doesNotMatch(feedbackCall.user, /写错了/);

  // 统一修改（用户在确认框里改了一下措辞）
  const chosen = plan.actions.map((action) => (action.key === "text:screen-03" ? { ...action, instruction: "多写异常处理和网络中断时的提示" } : action));
  const applied = await ctx.core.actions.applyFeedback(dir, { actions: chosen });
  assert.deepEqual({ images: applied.images, texts: applied.texts }, { images: 1, texts: 2 });
  assert.equal((await ctx.core.run(dir)).status, "done");

  // 只重生了图2
  assert.equal(ctx.relay.submits().length, submitsBefore + 1);
  const prompt2 = fs.readFileSync(path.join(dir, "prompts", "screen-02.md"), "utf8");
  assert.match(prompt2, /Revision applied: .*蓝色/);
  assert.match(prompt2.trimEnd(), /Do NOT render the software name[^\n]*$/, "品牌禁令仍在末尾");
  assert.doesNotMatch(fs.readFileSync(path.join(dir, "prompts", "screen-01.md"), "utf8"), /Revision applied/);

  // 文字要求传给了写说明的大模型，并带上当前正文
  const contentCalls = ctx.llm.calls.filter((call) => call.step === "content");
  const revisionCall = contentCalls.at(-1);
  assert.match(revisionCall.user, /用户修改要求（必须照做）：多写异常处理和网络中断时的提示/);
  assert.match(revisionCall.user, /当前正文（在此基础上按要求修改/);
  assert.match(revisionCall.user, /封面介绍修改要求（必须照做）：封面介绍提一下数据导出/);
  assert.match(revisionCall.user, /【screen-02｜/, "图2 换了图，说明按新图重写");

  // 清单状态和溯源记录
  const project = await ctx.core.getProject(dir);
  const statuses = Object.fromEntries(project.state.feedback.map((item) => [item.text, item.status]));
  assert.deepEqual(statuses, { "图2 底部按钮改成蓝色": "done", "图2 再加一个筛选按钮": "done", "图3 说明多写异常处理": "done", "封面介绍提一下数据导出": "done", "这个不太好看": "pending" });
  assert.equal(project.state.feedbackPlan, null);
  const record = JSON.parse(fs.readFileSync(path.join(dir, "generation-record.json"), "utf8"));
  assert.equal(record.feedback.length, 1);
  assert.equal(record.feedback[0].items.length, 4);
  assert.ok(record.feedback[0].actions.some((action) => action.type === "image" && action.target === "screen-02"));
  assert.ok(record.history.some((event) => event.event === "run" && event.reason === "修改意见"));
  assert.equal(record.screens["screen-02"].source, "generated");

  // 没勾选任何修改时不动
  await assert.rejects(ctx.core.actions.applyFeedback(dir, { actions: [] }), /没有勾选/);
});

test("修改意见：要求整体改风格时展开成每一屏；项目没有规划时不能整理", { timeout: 60_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const empty = await ctx.core.createProject({ softwareName: "未开始项目", screenCount: 2 });
  await ctx.core.actions.addFeedback(empty, "整体颜色淡一点");
  await assert.rejects(ctx.core.actions.analyzeFeedback(empty), /还没有界面规划/);

  const dir = await ctx.core.createProject({ softwareName: "整体测试 V1.0", screenCount: 3 });
  assert.equal((await ctx.core.run(dir, { until: "gate" })).status, "idle");
  await ctx.core.actions.addFeedback(dir, "整体颜色淡一点");
  const plan = await ctx.core.actions.analyzeFeedback(dir);
  assert.deepEqual(plan.actions.map((action) => action.key), ["image:screen-01", "image:screen-02", "image:screen-03"]);
  assert.ok(plan.actions.every((action) => action.instruction === "整体颜色淡一点"));
});

test("批量导出：每个项目一个文件夹（名字是项目名），同名文件夹先提醒，覆盖时旧的进废纸篓", { timeout: 60_000 }, async (t) => {
  const ctx = await setupCore();
  t.after(ctx.close);
  const full = ["甲软件 V1.0指南.docx", "甲软件 V1.0指南.pdf", "甲软件 V1.0指南.txt", "甲软件 V1.0指南_代码-（JAVA）.docx", "甲软件 V1.0指南_代码-（JAVA）.pdf"];
  const a = await fakeBuiltProject(ctx.core, "甲软件 V1.0", full);
  const b = await fakeBuiltProject(ctx.core, "乙软件 V1.0", ["乙软件 V1.0指南.docx", "乙软件 V1.0指南.pdf", "乙软件 V1.0指南.txt"]);
  const notBuilt = await ctx.core.createProject({ softwareName: "丙软件", screenCount: 2 });
  const target = path.join(ctx.root, "导出");

  const first = await ctx.core.exportBundles([a, b, notBuilt], target);
  assert.deepEqual(first.exported.map((item) => item.name).sort(), ["乙软件 V1.0", "甲软件 V1.0"]);
  assert.deepEqual(first.skipped, [{ name: "丙软件", reason: "还没有交付包" }]);
  assert.deepEqual(fs.readdirSync(path.join(target, "甲软件 V1.0")).sort(), [...full].sort());
  assert.equal(fs.readdirSync(path.join(target, "乙软件 V1.0")).length, 3);
  assert.equal(fs.existsSync(path.join(target, "甲软件 V1.0", ".DS_Store")), false);
  assert.ok(fs.existsSync(path.join(a, "甲软件 V1.0", "甲软件 V1.0指南.docx")), "原项目不动");
  assert.equal((await ctx.core.getSettings()).settings.export.lastDir, target);

  // 再导一次：先看计划，提示有同名文件夹
  const plan = await ctx.core.planExport([a, b], target);
  assert.deepEqual(plan.items.map((item) => item.conflict), [true, true]);
  fs.writeFileSync(path.join(target, "乙软件 V1.0", "我的备注.txt"), "keep me");
  const skipped = await ctx.core.exportBundles([a, b], target, { conflict: "skip" });
  assert.equal(skipped.exported.length, 0);
  assert.ok(skipped.skipped.every((item) => item.reason === "目标位置已有同名文件夹"));
  assert.equal(fs.readFileSync(path.join(target, "乙软件 V1.0", "我的备注.txt"), "utf8"), "keep me");

  const overwritten = await ctx.core.exportBundles([b], target, { conflict: "overwrite" });
  assert.equal(overwritten.exported.length, 1);
  assert.deepEqual(ctx.trashed, [path.join(target, "乙软件 V1.0")]);
  assert.equal(fs.existsSync(path.join(target, "乙软件 V1.0", "我的备注.txt")), false);
  assert.equal(fs.readdirSync(path.join(target, "乙软件 V1.0")).length, 3);
});

test("PDF 字体：替换表、核对、原版已安装时不替换、记住能用的字体名", () => {
  const xml = fontRegistryXml([{ from: "新宋体", to: "华文宋体" }]);
  assert.match(xml, /<prop oor:name="Replacement" oor:op="fuse"><value>true<\/value>/);
  assert.match(xml, /ReplaceFont" oor:op="fuse"><value>新宋体<\/value>/);
  assert.match(xml, /SubstituteFont" oor:op="fuse"><value>华文宋体<\/value>/);
  assert.match(xml, /Always" oor:op="fuse"><value>true/);
  assert.doesNotMatch(fontRegistryXml([]), /Replacement/);

  const stsong = { expect: SUBSTITUTES.stsong.expect, alsoAllowed: null };
  assert.equal(judgePdfFonts(["STSong"], stsong).ok, true);
  assert.deepEqual(judgePdfFonts(["ArialUnicodeMS"], stsong), { ok: false, fonts: ["ArialUnicodeMS"], unexpected: ["ArialUnicodeMS"], expectedFound: false });
  assert.equal(judgePdfFonts(["STSong", "YuppyTC-Regular"], stsong).ok, false, "混进别的中文字体也算不对");
  const courier = { expect: SUBSTITUTES.courier.expect, alsoAllowed: SUBSTITUTES.courier.alsoAllowed };
  assert.equal(judgePdfFonts(["CourierNewPSMT", "PingFangSC-Regular"], courier).ok, true);

  return (async () => {
    const missing = await resolveFontPlan({ guide: "pingfang", code: "stsong" }, { families: new Set(["PingFang SC", "STSong"]) });
    assert.equal(missing.guide.mode, "substitute");
    assert.equal(missing.code.label, "华文宋体");
    const installed = await resolveFontPlan({}, { families: new Set(["Microsoft YaHei", "NSimSun"]) });
    assert.equal(installed.guide.mode, "original");
    assert.equal(installed.code.label, "新宋体");
    assert.deepEqual(substitutionAttempts("code", installed.code)[0].pairs, []);
    const bogus = await resolveFontPlan({ guide: "courier" }, { families: new Set() });
    assert.equal(bogus.guide.substitute, "pingfang", "不在可选范围的设置回到默认");

    const attempts = substitutionAttempts("guide", missing.guide);
    assert.deepEqual(attempts.map((attempt) => attempt.name), ["苹方-简", "PingFang SC"]);
    assert.deepEqual(attempts[0].pairs.map((pair) => pair.from), ["Microsoft YaHei", "微软雅黑"]);
    rememberWorkingName("pingfang", "PingFang SC");
    assert.equal(substitutionAttempts("guide", missing.guide)[0].name, "PingFang SC");
    rememberWorkingName("pingfang", "苹方-简");
  })();
});

test("小工具：版本号识别、用时格式、代码来源锁定规则", () => {
  assert.equal(detectVersion("云伴日程 V1.0"), "V1.0");
  assert.equal(detectVersion("掌上游戏辅助器免费 V1.0.0"), "V1.0.0");
  assert.equal(detectVersion("警车驾驶狂飙1.0"), "1.0");
  assert.equal(detectVersion("3D世界贪吃蛇"), null);
  assert.equal(detectVersion("123违章助手速答"), null);
  assert.equal(formatDuration(42_000), "42秒");
  assert.equal(formatDuration(250_000), "4分10秒");
  assert.equal(formatDuration(3_720_000), "1小时2分");

  const settings = { codeSource: { path: "/code/new", extensions: [".kt"] } };
  const fresh = { request: { codeSource: null }, origin: "created" };
  assert.deepEqual(codeSourceFor(fresh, settings), { source: { path: "/code/new", extensions: [".kt"] }, locked: false });
  const built = { request: { codeSource: { path: "/code/old", extensions: [".java"] }, codeSourceLocked: true }, origin: "created" };
  assert.equal(codeSourceFor(built, settings).source.path, "/code/old");
  const legacyBuilt = { request: { codeSource: null }, origin: "created", lastBuild: { at: "x" } };
  assert.equal(codeSourceFor(legacyBuilt, settings).source, null, "以前建好的项目视为已锁定");
  const imported = { request: { codeSource: null }, origin: "imported" };
  assert.equal(codeSourceFor(imported, settings).locked, true);
});
