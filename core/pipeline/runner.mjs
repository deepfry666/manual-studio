import fsp from "node:fs/promises";
import path from "node:path";
import crypto from "node:crypto";
import { PIPELINE_STEPS, LLM_STEPS } from "../settings.mjs";
import { secretIds } from "../secrets.mjs";
import { chatJson } from "../llm/client.mjs";
import { projectPaths, readPlan, screenId, appendLog, listAlternates } from "./project.mjs";
import { composeScreenPrompt, ensureBrandBan, BRAND_BAN_BLOCK } from "./compose-prompt.mjs";
import { forbiddenBrandTokens, findBrandHits } from "./brand.mjs";
import {
  PLAN_SCHEMA, PLAN_SYSTEM, planUserPrompt, planCheck,
  GATE_SCHEMA, GATE_SYSTEM, gateUserPrompt, judgeGate,
  CONTENT_SCHEMA, CONTENT_SYSTEM, contentUserPrompt, contentCheck,
  DESIGN_SCHEMA, DESIGN_SYSTEM, designUserPrompt, designCheck,
  FEEDBACK_SCHEMA, FEEDBACK_SYSTEM, feedbackUserPrompt, feedbackCheck,
  PROMPT_EDIT_SCHEMA, PROMPT_EDIT_SYSTEM, promptEditUserPrompt,
} from "./llm-steps.mjs";
import { buildBundle, reexportBundlePdfs } from "../build/build.mjs";
import { resolveFontPlan } from "../build/fonts.mjs";
import { readJson, writeJsonAtomic, writeFileAtomic, sha256, sha256File, hashObject, exists, timestampSlug } from "../util/fsx.mjs";
import { imageToVisionDataUrl } from "../util/vision-image.mjs";
import { updateRecord, readRecord } from "./provenance.mjs";

export const STEP_LABELS = {
  plan: "规划界面",
  prompts: "生成提示词",
  images: "生成截图",
  gate: "截图验收",
  content: "撰写文案",
  design: "设计说明",
  receipt: "审查回执",
  build: "构建交付包",
};

function chineseDate(date = new Date()) {
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

export function normalizedUi(plan) {
  const ui = plan?.uiContract;
  return ui ? { ...ui, ...(ui.visual || {}), palette: ui.palette || ui.visual?.palette } : {};
}

export function planRowHash(screen, ui, platform, targetSize) {
  return hashObject({ screen, ui, platform, target: targetSize });
}

/** 提示词身份：把软件名替换掉再算哈希，改名时不会因此重新生图。 */
export function promptIdentity(prompt, softwareName) {
  return sha256(Buffer.from(String(prompt).split(softwareName).join("{{SOFTWARE}}")));
}

/** 用时显示：4分10秒、1小时2分。 */
export function formatDuration(ms) {
  const seconds = Math.max(0, Math.round((ms || 0) / 1000));
  if (seconds < 60) return `${seconds}秒`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}分${seconds % 60 ? `${seconds % 60}秒` : ""}`;
  return `${Math.floor(minutes / 60)}小时${minutes % 60 ? `${minutes % 60}分` : ""}`;
}

/**
 * 这个项目生成代码文档用哪个代码来源。
 * 代码来源在总设置里设；项目第一次生成交付包时记下当时用的来源（锁定），以后改总设置不影响已完成的项目。
 * 本软件做过交付包的项目、导入的历史项目，都视为已锁定。
 */
export function codeSourceFor(state, settings) {
  const locked = state.request.codeSourceLocked ?? Boolean(state.lastBuild || state.origin === "imported");
  if (locked) return { source: state.request.codeSource?.path ? state.request.codeSource : null, locked: true };
  const global = settings.codeSource;
  const source = global?.path ? { path: global.path, extensions: global.extensions?.length ? global.extensions : [".java"] } : null;
  return { source, locked: false };
}

/** 软件名里有没有版本号（V1.0、1.0.0 这类）。 */
export function detectVersion(softwareName) {
  const match = String(softwareName || "").match(/(?:V|v)\s?\d+(?:\.\d+)*|\d+(?:\.\d+)+/g);
  return match ? match[match.length - 1] : null;
}

async function mapLimit(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  const lanes = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(lanes);
  return results;
}

export function createPipeline({ settingsStore, secrets, gateway, projectStore, llmLog, emit = () => {}, fetchImpl = fetch, visionImage = imageToVisionDataUrl, appVersion = "", statsFile = null }) {
  const running = new Map();

  // ---------------- 实时进度（只在内存里，运行结束就清掉） ----------------
  const progress = new Map();
  function setProgress(projectDir, patch) {
    const current = progress.get(projectDir);
    if (!current) return;
    const next = { ...current, ...patch, updatedAt: Date.now() };
    progress.set(projectDir, next);
    emit({ type: "progress", projectDir, progress: next });
  }
  function setScreenProgress(projectDir, id, patch) {
    const current = progress.get(projectDir);
    if (!current) return;
    setProgress(projectDir, { screens: { ...current.screens, [id]: { ...(current.screens[id] || {}), ...patch } } });
  }
  /** 生图网关的事件（哪条线路、有没有补发）同步到进度里。 */
  function onImageEvent(event) {
    if (!event.projectDir || !event.screenId || !progress.has(event.projectDir)) return;
    if (event.type === "attempt-start") {
      const current = progress.get(event.projectDir).screens[event.screenId] || {};
      setScreenProgress(event.projectDir, event.screenId, { provider: event.providerName, attempts: (current.attempts || 0) + 1, ...(event.role === "hedge" ? { hedged: true } : {}) });
    } else if (event.type === "hedge") {
      setScreenProgress(event.projectDir, event.screenId, { hedged: true });
    }
  }

  // ---------------- 各步骤历史用时（估算剩余时间用） ----------------
  let statsCache = null;
  async function loadStats() {
    if (!statsCache) statsCache = statsFile ? await readJson(statsFile, {}).catch(() => ({})) : {};
    return statsCache;
  }
  async function addStepSamples(samples) {
    const stats = await loadStats();
    for (const [step, ms] of Object.entries(samples)) {
      if (!(ms > 300)) continue;
      stats[step] = [...(stats[step] || []), Math.round(ms)].slice(-30);
    }
    if (statsFile) await writeJsonAtomic(statsFile, stats).catch(() => {});
  }
  async function stepEstimates() {
    const stats = await loadStats();
    const result = {};
    for (const [step, samples] of Object.entries(stats)) {
      if (samples.length < 2) continue;
      const sorted = [...samples].sort((a, b) => a - b);
      result[step] = sorted[Math.floor(sorted.length / 2)];
    }
    return result;
  }

  async function resolveLlm(step) {
    const settings = await settingsStore.get();
    const assignment = settings.llm.assignments?.[step];
    if (!assignment?.vendorId || !assignment?.model) return null;
    const vendor = settings.llm.vendors.find((item) => item.id === assignment.vendorId);
    if (!vendor) return null;
    const apiKey = await secrets.get(secretIds.llmVendor(vendor.id));
    if (!apiKey) return null;
    return { vendor, model: assignment.model, apiKey };
  }

  async function callLlm(step, projectDir, params) {
    const llm = await resolveLlm(step);
    if (!llm) throw new Error(`还没有给「${LLM_STEPS[step]?.label || step}」配置大模型（大模型页面里选择厂商和模型，并填写密钥）`);
    const started = Date.now();
    try {
      const result = await chatJson({ ...params, vendor: llm.vendor, apiKey: llm.apiKey, model: llm.model, fetchImpl });
      await llmLog?.append({ step, projectDir, vendorId: llm.vendor.id, model: llm.model, ok: true, durationMs: Date.now() - started });
      const at = new Date().toISOString();
      await updateRecord(projectDir, (record) => {
        record.llm[step] = { vendor: llm.vendor.name, baseUrl: llm.vendor.baseUrl, model: llm.model, at };
        record.history.push({ at, event: "llm", step, vendor: llm.vendor.name, model: llm.model });
      });
      return result;
    } catch (error) {
      await llmLog?.append({ step, projectDir, vendorId: llm.vendor.id, model: llm.model, ok: false, durationMs: Date.now() - started, errorMessage: String(error.message).slice(0, 300) });
      throw error;
    }
  }

  async function update(projectDir, mutate) {
    const state = await projectStore.update(projectDir, mutate);
    emit({ type: "project", projectDir, status: state.status, steps: state.steps });
    return state;
  }

  async function log(projectDir, message, level = "info") {
    await update(projectDir, (state) => appendLog(state, message, level));
    emit({ type: "log", projectDir, message, level });
  }

  // ---------------- S1 规划 ----------------
  async function stepPlan(ctx) {
    const { projectDir, state, settings } = ctx;
    const request = state.request;
    const platform = request.platform || settings.pipeline.platform;
    const screenCount = request.screenCount || null;
    await log(projectDir, "正在让大模型规划界面…");
    const plan = await callLlm("plan", projectDir, {
      system: PLAN_SYSTEM,
      user: planUserPrompt({ softwareName: request.softwareName, screenCount, emphasis: request.emphasis, notes: request.notes, platform }),
      schema: PLAN_SCHEMA,
      check: (result) => planCheck(result, { softwareName: request.softwareName, screenCount }),
      temperature: 0.8,
      maxTokens: 8000,
    });
    const paths = projectPaths(projectDir);
    const tokens = forbiddenBrandTokens(request.softwareName, request.extraBrandTokens);
    const name = request.softwareName;
    await writeJsonAtomic(paths.profile, {
      softwareName: name,
      versionPolicy: request.versionPolicy,
      domain: plan.profile.domain,
      platform,
      targetUser: plan.profile.targetUser,
      coreFlow: plan.profile.coreFlow,
      screenshotPolicy: "UI 内严禁出现软件名称、App 名称、版本号、名称型 logo 或 wordmark",
    });
    await writeJsonAtomic(paths.featureMap, {
      softwareName: name,
      screenshotCount: plan.screens.length,
      coverageReason: plan.coverageReason,
      features: plan.features.map((feature, index) => ({ id: `feature-${String(index + 1).padStart(2, "0")}`, screenId: feature.screenId, name: feature.name, tier: feature.tier || "core", mandatory: true, screenshot: true })),
    });
    await writeJsonAtomic(paths.screenPlan, {
      softwareName: name,
      screenshotCount: plan.screens.length,
      targetSize: settings.image.targetSize,
      imageRoute: "image-gateway",
      screens: plan.screens.map((screen) => ({ ...screen, image: `screens/${screen.id}.png` })),
    });
    const nav = plan.uiContract.navigation || {};
    await writeJsonAtomic(paths.uiContract, {
      platform,
      viewport: { orientation: "portrait", requestedSize: settings.image.targetSize, safeAreas: "native" },
      visualStyle: plan.uiContract.visualStyle,
      visual: { palette: plan.uiContract.palette, typography: plan.uiContract.typography, radius: plan.uiContract.radius, shadow: plan.uiContract.shadow, density: plan.uiContract.density },
      palette: plan.uiContract.palette,
      typography: plan.uiContract.typography,
      radius: plan.uiContract.radius,
      shadow: plan.uiContract.shadow,
      density: plan.uiContract.density,
      statusBarPolicy: { mode: "consistent", battery: "same style across screens" },
      navigation: { type: nav.type, labels: nav.labels || [], order: nav.labels || [], iconSemantics: nav.iconSemantics || [] },
      forbiddenVisibleBranding: [...tokens, "App name", "name-bearing logo", "wordmark"],
    });
    // 重新规划后界面都变了：人工改过的提示词和说明不再对应，清掉标记让它们按新规划重写
    await update(projectDir, (draft) => {
      for (const id of Object.keys(draft.screens)) draft.screens[id] = { ...draft.screens[id], promptEdited: false, textEdited: false };
      draft.overviewEdited = false;
    });
    await log(projectDir, `规划完成：${plan.screens.length} 屏（${plan.screens.map((screen) => screen.title).join("、")}）`);
    return { status: ctx.reviewPlan ? "review" : "done", screenCountReason: plan.coverageReason };
  }

  // ---------------- S2 提示词 ----------------
  async function stepPrompts(ctx) {
    const { projectDir, state, settings } = ctx;
    const plan = await readPlan(projectDir);
    if (!plan) throw new Error("还没有界面规划");
    const paths = projectPaths(projectDir);
    await fsp.mkdir(paths.prompts, { recursive: true });
    const platform = state.request.platform || settings.pipeline.platform;
    const ui = normalizedUi(plan);
    const screenStates = {};
    for (const screen of plan.screens) {
      const rowHash = planRowHash(screen, ui, platform, settings.image.targetSize);
      const previous = state.screens[screen.id] || {};
      const file = paths.promptFile(screen.id);
      const name = state.request.softwareName;
      const keep = previous.promptEdited && previous.planRowHash === rowHash && (await exists(file));
      let prompt;
      let promptHash;
      if (keep) {
        // 人工改过或历史项目的提示词：原样保留，只把旧软件名换成新名字。
        // 内容没变时沿用原来的哈希，不会因此重新生图。
        const current = await fsp.readFile(file, "utf8");
        const oldName = state.promptsName;
        prompt = oldName && oldName !== name ? current.split(oldName).join(name) : current;
        promptHash = prompt === current && previous.promptHash ? previous.promptHash : promptIdentity(prompt, name);
      } else {
        prompt = composeScreenPrompt({ softwareName: name, platform, targetSize: settings.image.targetSize, ui, screen });
        promptHash = promptIdentity(prompt, name);
      }
      if (!(await exists(file)) || (await fsp.readFile(file, "utf8")) !== prompt) await writeFileAtomic(file, prompt);
      screenStates[screen.id] = { planRowHash: rowHash, promptHash, promptEdited: keep };
    }
    await update(projectDir, (draft) => {
      for (const [id, patch] of Object.entries(screenStates)) draft.screens[id] = { ...(draft.screens[id] || {}), ...patch };
      for (const id of Object.keys(draft.screens)) if (!screenStates[id]) delete draft.screens[id];
      draft.promptsName = draft.request.softwareName;
    });
    return { status: "done" };
  }

  async function generateScreen(ctx, id, { reason } = {}) {
    const { projectDir, state } = ctx;
    const paths = projectPaths(projectDir);
    let prompt;
    if (await exists(paths.promptFile(id))) {
      prompt = await fsp.readFile(paths.promptFile(id), "utf8");
    } else {
      // 历史项目缺这一屏的标准提示词：按规划现拼一份再生成
      const settings = ctx.settings || (await settingsStore.get());
      const plan = await readPlan(projectDir);
      const screen = plan?.screens?.find((item) => item.id === id);
      if (!screen) throw new Error(`${id} 没有提示词，规划里也找不到这一屏`);
      const platform = state.request.platform || settings.pipeline.platform;
      const ui = normalizedUi(plan);
      prompt = composeScreenPrompt({ softwareName: state.request.softwareName, platform, targetSize: settings.image.targetSize, ui, screen });
      await fsp.mkdir(paths.prompts, { recursive: true });
      await writeFileAtomic(paths.promptFile(id), prompt);
      await update(projectDir, (draft) => {
        draft.screens[id] = { ...(draft.screens[id] || {}), promptHash: promptIdentity(prompt, state.request.softwareName), planRowHash: planRowHash(screen, ui, platform, settings.image.targetSize), promptEdited: false };
      });
    }
    emit({ type: "screen", projectDir, screenId: id, status: "generating", reason });
    setScreenProgress(projectDir, id, { status: reason ? "regenerating" : "generating", startedAt: Date.now(), finishedAt: null, provider: null, hedged: false });
    const result = await gateway.generate({
      projectDir,
      projectName: state.request.softwareName,
      screenId: id,
      prompt,
      outputPath: paths.screenFile(id),
      alternatesDir: paths.alternates,
      archiveRoot: paths.archive,
      batchId: ctx.batchId,
      signal: ctx.signal,
    });
    const imageSha = await sha256File(paths.screenFile(id));
    const promptHash = promptIdentity(prompt, state.request.softwareName);
    await update(projectDir, (draft) => {
      const current = draft.screens[id] || {};
      draft.screens[id] = {
        ...current,
        imagePromptHash: promptHash,
        imageSha,
        providerId: result.providerId,
        providerName: result.providerName,
        model: result.model,
        requestSize: result.requestSize,
        width: result.width,
        height: result.height,
        hedged: result.hedged,
        imageWarnings: result.warnings || [],
        generatedAt: new Date().toISOString(),
        gate: null,
        // 截图换了，这一屏的说明要按新截图重写（人工改过的会保留并提醒）
        contentStale: true,
      };
      appendLog(draft, `${id} 已生成（${result.providerName || result.providerId}${result.hedged ? "，触发了超时补发" : ""}，${Math.round((result.durationMs || 0) / 1000)} 秒）`);
    });
    const generatedAt = new Date().toISOString();
    await updateRecord(projectDir, (record) => {
      const entry = { source: "generated", providerId: result.providerId, providerName: result.providerName, model: result.model, requestSize: result.requestSize, width: result.width, height: result.height, hedged: Boolean(result.hedged), attempts: result.attempts, resumed: Boolean(result.resumed), generatedAt, imageSha256: imageSha, promptSha256: sha256(Buffer.from(prompt)), reason: reason || null };
      record.screens[id] = entry;
      record.history.push({ at: generatedAt, event: "screen-generated", screenId: id, ...entry });
    });
    emit({ type: "screen", projectDir, screenId: id, status: "generated" });
    setScreenProgress(projectDir, id, { status: "generated", finishedAt: Date.now(), provider: result.providerName || result.providerId, hedged: Boolean(result.hedged) });
    return result;
  }

  // ---------------- S3 生图 ----------------
  async function stepImages(ctx) {
    const { projectDir } = ctx;
    const state = await projectStore.read(projectDir);
    const paths = projectPaths(projectDir);
    const plan = await readPlan(projectDir);
    const needed = [];
    for (const screen of plan.screens) {
      const current = state.screens[screen.id] || {};
      const file = paths.screenFile(screen.id);
      const forced = ctx.forceScreens?.includes(screen.id);
      if (forced || !(await exists(file)) || (current.imagePromptHash && current.imagePromptHash !== current.promptHash) || (!current.imagePromptHash && state.origin !== "imported")) {
        needed.push(screen.id);
      }
    }
    if (!needed.length) return { status: "done" };
    setProgress(projectDir, { screens: Object.fromEntries(plan.screens.map((screen) => [screen.id, needed.includes(screen.id) ? { status: "waiting" } : { status: "kept" }])) });
    await log(projectDir, `开始生成 ${needed.length} 张截图（同时发出）`);
    const outcomes = await Promise.allSettled(
      needed.map((id) =>
        generateScreen({ ...ctx, state }, id).catch((error) => {
          setScreenProgress(projectDir, id, { status: "failed", finishedAt: Date.now(), error: error.message });
          throw error;
        })
      )
    );
    const failures = outcomes.map((outcome, index) => (outcome.status === "rejected" ? { id: needed[index], message: outcome.reason?.message || String(outcome.reason) } : null)).filter(Boolean);
    if (failures.length) {
      const messages = [...new Set(failures.map((failure) => failure.message))];
      const detail = messages.length === 1 ? `${failures.map((failure) => failure.id).join("、")}：${messages[0]}` : failures.map((failure) => `${failure.id}：${failure.message}`).join("\n");
      throw new Error(`${failures.length} 张截图没有生成成功${failures.length < needed.length ? "（其余已保存）" : ""}：\n${detail}`);
    }
    return { status: "done" };
  }

  // ---------------- S4 品牌验收 ----------------
  async function gateOne(ctx, screen, tokens, tokensHash, llmAvailable) {
    const { projectDir, settings } = ctx;
    const paths = projectPaths(projectDir);
    const limit = settings.image.gateRegenerateLimit ?? 3;
    for (let round = 0; ; round += 1) {
      const state = await projectStore.read(projectDir);
      const file = paths.screenFile(screen.id);
      const sha = await sha256File(file);
      const current = state.screens[screen.id]?.gate;
      if (current && current.sha === sha && current.tokensHash === tokensHash && (current.status === "passed" || current.status === "manual-passed")) {
        setScreenProgress(projectDir, screen.id, { status: "passed" });
        return current;
      }
      if (!llmAvailable) {
        const gate = { status: "needs-manual", sha, tokensHash, method: "manual", checkedAt: new Date().toISOString(), reasons: ["没有配置看图模型，请人工确认截图里没有软件名"] };
        await update(projectDir, (draft) => {
          draft.screens[screen.id] = { ...(draft.screens[screen.id] || {}), gate };
        });
        return gate;
      }
      setScreenProgress(projectDir, screen.id, { status: "checking" });
      const image = await visionImage(file);
      const result = await callLlm("gate", projectDir, {
        system: GATE_SYSTEM,
        user: gateUserPrompt({ softwareName: state.request.softwareName, tokens, screen }),
        images: [image],
        schema: GATE_SCHEMA,
        temperature: 0.1,
        maxTokens: 4000,
      });
      const verdict = judgeGate(result, tokens);
      const gate = {
        status: verdict.passed ? "passed" : "failed",
        method: "vision",
        sha,
        tokensHash,
        reasons: verdict.reasons,
        hits: verdict.hits,
        screenTitle: result.screenTitle || "",
        visibleText: (result.visibleText || []).slice(0, 80),
        inventory: result.inventory,
        warnings: result.warnings || [],
        checkedAt: new Date().toISOString(),
        rounds: round + 1,
      };
      await update(projectDir, (draft) => {
        draft.screens[screen.id] = { ...(draft.screens[screen.id] || {}), gate };
        appendLog(draft, verdict.passed ? `${screen.id} 验收通过` : `${screen.id} 验收不通过：${verdict.reasons.join("；")}`, verdict.passed ? "info" : "warn");
      });
      await updateRecord(projectDir, (record) => {
        record.gate[screen.id] = { status: gate.status, method: "vision", imageSha256: sha, reasons: gate.reasons, checkedAt: gate.checkedAt };
        record.history.push({ at: gate.checkedAt, event: "gate", screenId: screen.id, status: gate.status, method: "vision", reasons: gate.reasons });
      });
      setScreenProgress(projectDir, screen.id, { status: verdict.passed ? "passed" : round >= limit ? "failed" : "regenerating", gateRounds: round + 1 });
      if (verdict.passed) return gate;
      // limit = 每屏最多自动重生几次（设置里的数字），用完还不通过就交给人处理
      if (round >= limit) return gate;
      await generateScreen({ ...ctx, state }, screen.id, { reason: "验收不通过，重新生成" });
    }
  }

  async function stepGate(ctx) {
    const { projectDir } = ctx;
    const state = await projectStore.read(projectDir);
    const plan = await readPlan(projectDir);
    const tokens = forbiddenBrandTokens(state.request.softwareName, state.request.extraBrandTokens);
    const tokensHash = hashObject(tokens);
    const llmAvailable = Boolean(await resolveLlm("gate"));
    const before = progress.get(projectDir)?.screens || {};
    setProgress(projectDir, { screens: Object.fromEntries(plan.screens.map((screen) => [screen.id, { ...(before[screen.id] || {}), status: "waiting-check" }])) });
    const gates = await mapLimit(plan.screens, 4, (screen) => gateOne(ctx, screen, tokens, tokensHash, llmAvailable).catch((error) => ({ status: "error", reasons: [error.message] })));
    const failed = plan.screens.filter((_, index) => gates[index].status === "failed" || gates[index].status === "error");
    const manual = plan.screens.filter((_, index) => gates[index].status === "needs-manual");
    if (failed.length) {
      throw new Error(`以下截图验收没有通过：${failed.map((screen, index) => `${screen.id}（${(gates[plan.screens.indexOf(screen)].reasons || []).join("；")}）`).join("、")}。可以在截图页重生或换成备选图。`);
    }
    if (manual.length) return { status: "review", message: `请在截图页逐张确认（${manual.length} 张），确认界面里没有软件名后继续` };
    return { status: "done" };
  }

  // ---------------- S5 文案 ----------------
  async function stepContent(ctx) {
    const { projectDir, settings } = ctx;
    const state = await projectStore.read(projectDir);
    const plan = await readPlan(projectDir);
    const paths = projectPaths(projectDir);
    const floor = Math.max(300, settings.pipeline.featureTextFloor || 300);
    const existing = await readJson(paths.content, null);
    const existingById = new Map((existing?.screens || []).map((screen, index) => [screen.id || screenId(index), screen]));
    const planHash = hashObject({ profile: plan.profile, titles: plan.screens.map((screen) => screen.title) });
    const inventories = {};
    const targets = [];
    const staleEdited = [];
    const contentHashes = {};
    for (const screen of plan.screens) {
      const gate = state.screens[screen.id]?.gate;
      if (gate?.inventory) inventories[screen.id] = gate.inventory;
      const hash = hashObject({ title: screen.title, contract: screen.textContract, mustShow: screen.mustShow, sampleData: screen.sampleData, inventory: inventories[screen.id] || null });
      contentHashes[screen.id] = hash;
      const old = existingById.get(screen.id);
      const shot = state.screens[screen.id] || {};
      const forced = ctx.forceContent?.includes(screen.id) || Boolean(ctx.contentInstructions?.[screen.id]);
      const unchanged = shot.contentHash ? shot.contentHash === hash : state.origin === "imported";
      const keep = old?.text && !forced && (shot.textEdited || (unchanged && !shot.contentStale));
      if (!keep) targets.push(screen);
      if (keep && shot.textEdited && shot.contentStale) staleEdited.push(screen.id);
    }
    const needOverview = !existing?.cover?.overview || (state.contentPlanHash && state.contentPlanHash !== planHash && !state.overviewEdited) || ctx.forceContent?.includes("overview") || Boolean(ctx.contentInstructions?.overview);
    const instructions = ctx.contentInstructions || {};
    const currentTexts = Object.fromEntries([...existingById.entries()].map(([id, screen]) => [id, screen.text || ""]));
    const written = {};
    let overview = existing?.cover?.overview || "";
    if (targets.length || needOverview) {
      await log(projectDir, `正在撰写 ${targets.length} 屏说明${needOverview ? "和封面介绍" : ""}…`);
      const chunks = [];
      for (let index = 0; index < targets.length; index += 4) chunks.push(targets.slice(index, index + 4));
      if (!chunks.length) chunks.push([]);
      for (let index = 0; index < chunks.length; index += 1) {
        const chunk = chunks[index];
        const wantsOverview = needOverview && index === 0;
        setProgress(projectDir, { detail: targets.length ? `撰写说明：第 ${Math.min(targets.length, index * 4 + 1)}–${Math.min(targets.length, index * 4 + chunk.length)} 屏（共 ${targets.length} 屏）` : "撰写封面介绍" });
        const result = await callLlm("content", projectDir, {
          system: CONTENT_SYSTEM.replace("{floor}", String(floor)),
          user: contentUserPrompt({ softwareName: state.request.softwareName, profile: plan.profile, screens: chunk, inventories, needOverview: wantsOverview, existingOverview: overview, floor, instructions, currentTexts }),
          schema: CONTENT_SCHEMA,
          check: (draft) => contentCheck(draft, { screens: chunk, needOverview: wantsOverview, floor }),
          temperature: 0.7,
          maxTokens: 8000,
        });
        if (wantsOverview) overview = String(result.overview).trim();
        for (const item of result.screens) written[item.id] = item;
      }
    }
    const sameScreens = existing && existing.screens?.length === plan.screens.length && plan.screens.every((screen, index) => (existing.screens[index].id || screenId(index)) === screen.id && existing.screens[index].title);
    const recordStaleWarning = (draft) => {
      draft.warnings = draft.warnings.filter((warning) => !warning.startsWith("截图已更换"));
      if (staleEdited.length) draft.warnings.push(`截图已更换，但这些屏的说明是人工改过的，没有自动重写，请检查是否还和新截图一致：${staleEdited.join("、")}`);
    };
    if (existing && sameScreens && !targets.length && !needOverview) {
      await update(projectDir, (draft) => {
        for (const [id, hash] of Object.entries(contentHashes)) draft.screens[id] = { ...(draft.screens[id] || {}), contentHash: hash, contentStale: staleEdited.includes(id) };
        draft.contentPlanHash = planHash;
        recordStaleWarning(draft);
      });
      return { status: "done" };
    }
    const featureMap = plan.featureMap || {};
    const regenerated = plan.screens.some((screen) => state.screens[screen.id]?.providerId);
    const content = {
      ...(existing || {}),
      softwareName: state.request.softwareName,
      versionPolicy: state.request.versionPolicy,
      ...(state.request.versionPolicy === "separate-metadata" && state.request.applicableVersion ? { applicableVersion: state.request.applicableVersion } : {}),
      createdAt: state.request.createdAt,
      screenshotCount: plan.screens.length,
      screenCountReason: featureMap.coverageReason || existing?.screenCountReason,
      featureTier: 300,
      imageRoute: regenerated || !existing?.imageRoute ? "image-gateway" : existing.imageRoute,
      cover: { ...(existing?.cover || {}), overview },
      screens: plan.screens.map((screen, index) => {
        const old = existingById.get(screen.id) || {};
        const fresh = written[screen.id];
        const shot = state.screens[screen.id] || {};
        const title = (fresh?.title || old.title || screen.title).trim();
        return {
          id: screen.id,
          title,
          caption: `图${index + 1} ${title}`,
          image: `screens/${screen.id}.png`,
          image_size: shot.width ? `${shot.width}x${shot.height}` : old.image_size,
          text_anchor: screen.textContract?.entry || title,
          summary: title,
          text: (fresh?.text || old.text || "").trim(),
        };
      }),
    };
    delete content.screenshotReview;
    await writeJsonAtomic(paths.content, content);
    await update(projectDir, (draft) => {
      for (const [id, hash] of Object.entries(contentHashes)) {
        const keepStale = staleEdited.includes(id);
        draft.screens[id] = { ...(draft.screens[id] || {}), contentHash: hash, contentStale: keepStale, ...(written[id] ? { textEdited: false } : {}) };
      }
      draft.contentPlanHash = planHash;
      recordStaleWarning(draft);
      const missing = plan.screens.filter((screen) => !inventories[screen.id]).map((screen) => screen.id);
      draft.warnings = draft.warnings.filter((warning) => !warning.startsWith("文案未按截图对账"));
      if (missing.length && Object.keys(written).length) draft.warnings.push(`文案未按截图对账：${missing.join("、")}（没有看图模型的抄录结果）`);
    });
    return { status: "done" };
  }

  // ---------------- S6 设计说明 ----------------
  async function stepDesign(ctx) {
    const { projectDir } = ctx;
    const state = await projectStore.read(projectDir);
    const paths = projectPaths(projectDir);
    const content = await readJson(paths.content, null);
    if (!content) throw new Error("还没有文案");
    if (!state.request.wantDesign) {
      if (content.design) {
        delete content.design;
        await writeJsonAtomic(paths.content, content);
      }
      return { status: "skipped" };
    }
    if (content.design?.sections?.length && !ctx.forceDesign && !ctx.designInstruction) return { status: "done" };
    const plan = await readPlan(projectDir);
    await log(projectDir, "正在撰写设计说明…");
    const result = await callLlm("design", projectDir, {
      system: DESIGN_SYSTEM,
      user: designUserPrompt({
        softwareName: state.request.softwareName,
        profile: plan.profile,
        features: plan.featureMap?.features || [],
        screens: plan.screens,
        instruction: ctx.designInstruction,
        current: (content.design?.sections || []).map((section) => `${section.title}\n${section.text}`).join("\n\n"),
      }),
      schema: DESIGN_SCHEMA,
      check: designCheck,
      temperature: 0.6,
      maxTokens: 8000,
    });
    content.design = { sections: result.sections.map((section) => ({ title: section.title.trim(), text: section.text.trim() })) };
    await writeJsonAtomic(paths.content, content);
    return { status: "done" };
  }

  // ---------------- S7 回执 ----------------
  async function stepReceipt(ctx) {
    const { projectDir } = ctx;
    const state = await projectStore.read(projectDir);
    const paths = projectPaths(projectDir);
    const content = await readJson(paths.content, null);
    if (!content) throw new Error("还没有文案");
    const tokensHash = hashObject(forbiddenBrandTokens(state.request.softwareName, state.request.extraBrandTokens));
    const reviewed = [];
    const pending = [];
    for (let index = 0; index < content.screens.length; index += 1) {
      const id = screenId(index);
      const sha = await sha256File(paths.screenFile(id));
      const gate = state.screens[id]?.gate;
      const ok = gate && gate.sha === sha && (gate.status === "passed" || gate.status === "manual-passed") && (gate.tokensHash === tokensHash || gate.method === "imported-receipt");
      if (!ok) pending.push(id);
      reviewed.push({ screenId: id, image: `screens/${id}.png`, sha256: sha });
    }
    if (pending.length) throw new Error(`这些截图还没有通过验收（或验收后图片被替换）：${pending.join("、")}`);
    const review = { status: "passed", reviewedScreens: reviewed };
    const existingReview = content.screenshotReview;
    const sameReview =
      existingReview?.status === "passed" &&
      Array.isArray(existingReview.reviewedScreens) &&
      existingReview.reviewedScreens.length === reviewed.length &&
      reviewed.every((item, index) => {
        const old = existingReview.reviewedScreens[index] || {};
        return old.screenId === item.screenId && old.image === item.image && old.sha256 === item.sha256;
      });
    if (!sameReview) {
      content.screenshotReview = review;
      await writeJsonAtomic(paths.content, content);
    }
    return { status: "done" };
  }

  // ---------------- S8 构建 ----------------
  async function stepBuild(ctx) {
    const { projectDir, settings } = ctx;
    const state = await projectStore.read(projectDir);
    const paths = projectPaths(projectDir);
    const content = await readJson(paths.content, null);
    if (!content?.screenshotReview) throw new Error("没有审查回执，不能构建");
    const currentBundle = paths.bundle(state.request.softwareName);
    const hasCodeDoc = await exists(path.join(currentBundle, `${state.request.softwareName}指南_代码-（JAVA）.docx`));
    const { source: codeSource } = codeSourceFor(state, settings);
    if (!codeSource?.path && hasCodeDoc && !state.request.allowDropCodeDoc) {
      throw new Error("现有交付包里有代码文档，但这个项目没有代码来源，重建后新交付包将不含代码文档（旧交付包会先归档）。请在「交付」里点「改用总设置的代码来源」或「确认不含代码文档」后再继续。");
    }
    if (codeSource?.path && !(await exists(codeSource.path))) throw new Error(`代码来源不存在：${codeSource.path}（在「设置 → 代码来源」里重新选择）`);
    const fontPlan = await resolveFontPlan(settings.pdf);
    content.softwareName = state.request.softwareName;
    content.compileDate = state.request.compileDate || chineseDate();
    content.screens = content.screens.map((screen, index) => ({ ...screen, image: `screens/${screenId(index)}.png` }));
    const txtFields = { ...settings.txtFields, ...(state.request.txtFields || {}) };
    if (state.request.txtFields?.language) txtFields.languageOverride = true;
    const record = await readRecord(projectDir);
    const provenance = {
      builtBy: `软件指南生成器${appVersion ? ` ${appVersion}` : ""}`,
      recordFile: record ? "generation-record.json" : null,
      screens: Object.fromEntries(
        content.screens.map((_, index) => {
          const id = screenId(index);
          const entry = record?.screens?.[id];
          const gate = state.screens[id]?.gate || {};
          return [id, {
            source: entry?.source || (state.origin === "imported" ? "imported-from-skill" : "unknown"),
            provider: entry?.providerName || entry?.providerId || null,
            model: entry?.model || null,
            generatedAt: entry?.generatedAt || null,
            hedged: entry?.hedged || false,
            gate: gate.method || null,
          }];
        })
      ),
      llm: record?.llm || {},
    };
    const result = await buildBundle({
      projectDir,
      provenance,
      softwareName: state.request.softwareName,
      content,
      codeSource,
      fontPlan,
      txtFields,
      excludeDirs: settings.codeDefaults.excludeDirs,
      floor: Math.max(300, settings.pipeline.featureTextFloor || 300),
      extraBrandTokens: state.request.extraBrandTokens,
      stagingRoot: projectStore.stagingRoot,
      onLog: (message) => {
        setProgress(projectDir, { detail: message });
        return log(projectDir, message);
      },
    });
    await update(projectDir, (draft) => {
      draft.lastBuild = { at: new Date().toISOString(), ...result };
      // 记下这次用的代码来源：以后改总设置，已完成的项目不受影响
      draft.request.codeSource = codeSource || null;
      draft.request.codeSourceLocked = true;
      draft.warnings = draft.warnings.filter((warning) => !warning.startsWith("构建："));
      for (const warning of result.warnings) draft.warnings.push(`构建：${warning}`);
      if (!result.withCode) draft.warnings.push("构建：没有代码来源，本次没有生成代码文档（在「设置 → 代码来源」里设置）");
      appendLog(draft, `交付包已生成：${result.files.join("、")}`);
    });
    await updateRecord(projectDir, (record) => {
      record.history.push({ at: new Date().toISOString(), event: "build", files: result.files, withPdf: result.withPdf, withCode: result.withCode, codeLines: result.code?.lineCount || null, codeSource: codeSource?.path || null, codeSha256: result.codeSha256, pdfFonts: result.pdfFonts });
      record.codeSource = codeSource?.path ? { path: codeSource.path, extensions: codeSource.extensions, fileCount: result.code?.fileCount, lineCount: result.code?.lineCount, sha256: result.codeSha256, usedAt: new Date().toISOString() } : null;
    });
    return { status: "done" };
  }

  const STEP_IMPL = { plan: stepPlan, prompts: stepPrompts, images: stepImages, gate: stepGate, content: stepContent, design: stepDesign, receipt: stepReceipt, build: stepBuild };

  async function stepInputHash(step, projectDir, state, settings) {
    const paths = projectPaths(projectDir);
    const request = state.request;
    if (step === "plan") {
      // 不含软件名：改名不应触发重新规划（需要时可以手动强制重新规划）
      return hashObject({ screenCount: request.screenCount, emphasis: request.emphasis, notes: request.notes, platform: request.platform || settings.pipeline.platform });
    }
    if (step === "prompts") {
      const [plan, ui] = await Promise.all([readJson(paths.screenPlan, null), readJson(paths.uiContract, null)]);
      return hashObject({ plan: plan?.screens || null, ui, platform: request.platform || settings.pipeline.platform, target: settings.image.targetSize, edited: Object.fromEntries(Object.entries(state.screens).map(([id, screen]) => [id, Boolean(screen.promptEdited)])) });
    }
    if (step === "build") {
      const content = await readJson(paths.content, null);
      const shas = {};
      for (const [id, screen] of Object.entries(state.screens)) shas[id] = screen.imageSha || screen.gate?.sha;
      return hashObject({ content, shas, code: codeSourceFor(state, settings).source, txt: { ...settings.txtFields, ...(request.txtFields || {}) }, name: request.softwareName, bundle: await exists(paths.bundle(request.softwareName)) });
    }
    return null; // 其余步骤内部自行增量判断
  }

  /**
   * 跑流水线。options：{ from, until, force: [步骤], forceScreens, forceContent, contentInstructions, designInstruction, reviewPlan, batchId, signal, reason }
   */
  async function run(projectDir, options = {}) {
    if (running.has(projectDir)) return running.get(projectDir);
    const controller = new AbortController();
    if (options.signal) options.signal.addEventListener("abort", () => controller.abort(), { once: true });
    const promise = runInner(projectDir, { ...options, signal: controller.signal }).finally(() => running.delete(projectDir));
    promise.cancel = () => controller.abort();
    running.set(projectDir, promise);
    return promise;
  }

  /** 包一层：管理实时进度，结束后记录这次运行用时。 */
  async function runInner(projectDir, options) {
    const startedAt = new Date().toISOString();
    const tracker = { started: Date.now(), steps: {} };
    progress.set(projectDir, { startedAt, started: tracker.started, step: null, stepStarted: null, plannedSteps: [], doneSteps: [], screens: {}, detail: null, reason: options.reason || null });
    emit({ type: "progress", projectDir, progress: progress.get(projectDir) });
    let result;
    try {
      result = await runSteps(projectDir, options, tracker);
    } finally {
      progress.delete(projectDir);
      emit({ type: "progress", projectDir, progress: null });
    }
    if (Object.keys(tracker.steps).length) await recordRun(projectDir, { startedAt, ms: Date.now() - tracker.started, steps: tracker.steps, status: result.status, reason: options.reason || null }).catch(() => {});
    return result;
  }

  async function recordRun(projectDir, entry) {
    const finishedAt = new Date().toISOString();
    const run = { ...entry, finishedAt };
    let firstDone = false;
    const state = await update(projectDir, (draft) => {
      const timing = draft.timing || { totalMs: 0, runs: [] };
      timing.totalMs = (timing.totalMs || 0) + run.ms;
      timing.runs = [...(timing.runs || []), run].slice(-30);
      if (run.status === "done" && !timing.completedAt) {
        timing.completedAt = finishedAt;
        timing.completedMs = timing.totalMs;
        firstDone = true;
      }
      draft.timing = timing;
      appendLog(draft, `本次运行用时 ${formatDuration(run.ms)}${firstDone ? `，项目完成，累计用时 ${formatDuration(timing.totalMs)}` : ""}`);
    });
    await addStepSamples(entry.steps);
    // 生成记录只在本软件确实生成或修改过东西（记录文件已存在）时更新，不在只导入、没改动的历史项目里新建文件
    if (await readRecord(projectDir)) {
      await updateRecord(projectDir, (record) => {
        record.timing = { totalMs: state.timing.totalMs, completedMs: state.timing.completedMs || null, completedAt: state.timing.completedAt || null, runs: state.timing.runs };
        record.history.push({ at: finishedAt, event: "run", status: run.status, ms: run.ms, steps: run.steps, reason: run.reason });
      });
    }
    emit({ type: "run-finished", projectDir, name: state.request.softwareName, status: run.status, ms: run.ms, totalMs: state.timing.totalMs, firstDone });
  }

  async function runSteps(projectDir, options, tracker) {
    const initial = await projectStore.read(projectDir);
    if (!initial) return { status: "failed", error: "项目状态不存在" };
    if (initial.readOnly) return { status: "failed", error: "只读的历史项目（没有文案和截图源文件），不能运行" };
    const settings = await settingsStore.get();
    const batchId = options.batchId || `${path.basename(projectDir)}:${timestampSlug()}`;
    const fromIndex = options.from ? PIPELINE_STEPS.indexOf(options.from) : 0;
    const untilIndex = options.until ? PIPELINE_STEPS.indexOf(options.until) : PIPELINE_STEPS.length - 1;
    const force = new Set(options.force || []);
    setProgress(projectDir, { plannedSteps: PIPELINE_STEPS.slice(fromIndex, untilIndex + 1) });
    await update(projectDir, (state) => {
      state.status = "running";
      state.lastError = null;
    });
    for (let index = fromIndex; index <= untilIndex; index += 1) {
      const step = PIPELINE_STEPS[index];
      if (options.signal?.aborted) {
        await update(projectDir, (state) => {
          state.status = "canceled";
          appendLog(state, "已停止");
        });
        return { status: "canceled" };
      }
      let state = await projectStore.read(projectDir);
      const stepState = state.steps[step] || {};
      if (stepState.status === "review" && !force.has(step)) {
        await update(projectDir, (draft) => {
          draft.status = "waiting";
        });
        return { status: "waiting", step };
      }
      const inputHash = await stepInputHash(step, projectDir, state, settings);
      if (inputHash && stepState.status === "done" && stepState.inputHash === inputHash && !force.has(step)) {
        setProgress(projectDir, { doneSteps: [...(progress.get(projectDir)?.doneSteps || []), step] });
        continue;
      }
      const stepStarted = Date.now();
      setProgress(projectDir, { step, stepStarted, detail: null });
      await update(projectDir, (draft) => {
        draft.steps[step] = { ...draft.steps[step], status: "running", startedAt: new Date().toISOString(), error: null };
      });
      emit({ type: "step", projectDir, step, status: "running" });
      try {
        state = await projectStore.read(projectDir);
        const outcome = await STEP_IMPL[step]({
          projectDir,
          state,
          settings,
          batchId,
          signal: options.signal,
          reviewPlan: options.reviewPlan ?? settings.pipeline.reviewPlanSingle,
          forceScreens: options.forceScreens,
          forceContent: options.forceContent,
          contentInstructions: options.contentInstructions,
          designInstruction: options.designInstruction,
          forceDesign: force.has("design"),
        });
        tracker.steps[step] = (tracker.steps[step] || 0) + (Date.now() - stepStarted);
        setProgress(projectDir, { doneSteps: [...(progress.get(projectDir)?.doneSteps || []), step], detail: null });
        const finalHash = await stepInputHash(step, projectDir, await projectStore.read(projectDir), settings);
        await update(projectDir, (draft) => {
          draft.steps[step] = { status: outcome.status, inputHash: finalHash, finishedAt: new Date().toISOString(), message: outcome.message || null };
          if (outcome.screenCountReason) draft.screenCountReason = outcome.screenCountReason;
        });
        emit({ type: "step", projectDir, step, status: outcome.status });
        if (outcome.status === "review") {
          await update(projectDir, (draft) => {
            draft.status = "waiting";
            appendLog(draft, outcome.message || `「${STEP_LABELS[step]}」等待确认`);
          });
          return { status: "waiting", step };
        }
      } catch (error) {
        tracker.steps[step] = (tracker.steps[step] || 0) + (Date.now() - stepStarted);
        const canceled = options.signal?.aborted;
        await update(projectDir, (draft) => {
          draft.steps[step] = { ...draft.steps[step], status: canceled ? "pending" : "failed", error: error.message, finishedAt: new Date().toISOString() };
          draft.status = canceled ? "canceled" : "needs-attention";
          draft.lastError = canceled ? null : `${STEP_LABELS[step]}：${error.message}`;
          appendLog(draft, canceled ? "已停止" : `${STEP_LABELS[step]}失败：${error.message}`, canceled ? "info" : "error");
        });
        emit({ type: "step", projectDir, step, status: "failed", error: error.message });
        return { status: canceled ? "canceled" : "failed", step, error: error.message };
      }
    }
    const final = await projectStore.read(projectDir);
    const allDone = PIPELINE_STEPS.every((step) => ["done", "skipped"].includes(final.steps[step]?.status));
    await update(projectDir, (draft) => {
      draft.status = allDone ? "done" : "idle";
    });
    return { status: allDone ? "done" : "idle" };
  }

  // ---------------- 编辑操作 ----------------
  async function markDirty(projectDir, steps) {
    await update(projectDir, (state) => {
      for (const step of steps) if (state.steps[step]) state.steps[step] = { ...state.steps[step], status: "pending", inputHash: null };
      if (state.status === "done") state.status = "idle";
    });
  }

  function assertScreenId(id) {
    if (!/^screen-\d{2}$/.test(String(id))) throw new Error(`截图编号不合法：${id}`);
  }
  const applying = new Set();
  function assertIdle(projectDir) {
    if (running.has(projectDir)) throw new Error("项目正在运行，先停止再修改");
  }

  const actions = {
    async confirmPlan(projectDir) {
      await update(projectDir, (state) => {
        state.steps.plan = { ...state.steps.plan, status: "done" };
        appendLog(state, "规划已确认");
      });
      return run(projectDir, { from: "prompts" });
    },
    async savePlanScreen(projectDir, id, patch) {
      assertScreenId(id);
      assertIdle(projectDir);
      const paths = projectPaths(projectDir);
      const plan = await readJson(paths.screenPlan, null);
      // 兼容历史格式：数组 / { screens } / { flow }，行里用 id 或 screenId
      const rows = Array.isArray(plan) ? plan : plan?.screens || plan?.flow;
      const index = Number(String(id).replace("screen-", "")) - 1;
      const screen = Array.isArray(rows) ? rows.find((item) => item && (item.id === id || item.screenId === id)) || (rows[index] && typeof rows[index] === "object" ? rows[index] : null) : null;
      if (!screen) throw new Error("规划文件里找不到这一屏，可以直接编辑这一屏的提示词");
      const allowed = ["title", "pageType", "activeTab", "mustShow", "sampleData", "visualBrief", "textContract"];
      for (const key of allowed) if (patch[key] !== undefined) screen[key] = patch[key];
      await writeJsonAtomic(paths.screenPlan, plan);
      await markDirty(projectDir, ["prompts"]);
    },
    async savePrompt(projectDir, id, prompt) {
      assertScreenId(id);
      assertIdle(projectDir);
      const paths = projectPaths(projectDir);
      await writeFileAtomic(paths.promptFile(id), ensureBrandBan(prompt));
      await update(projectDir, (state) => {
        state.screens[id] = { ...(state.screens[id] || {}), promptEdited: true };
      });
      await markDirty(projectDir, ["prompts"]);
    },
    async regenerateScreen(projectDir, id) {
      assertScreenId(id);
      return run(projectDir, { from: "images", forceScreens: [id] });
    },
    async useAlternate(projectDir, id, file) {
      assertScreenId(id);
      assertIdle(projectDir);
      const paths = projectPaths(projectDir);
      const alternates = await listAlternates(projectDir, id);
      if (!alternates.some((item) => item.file === file)) throw new Error("备选图不存在");
      const target = paths.screenFile(id);
      if (await exists(target)) {
        const archiveDir = path.join(paths.archive, `screens-${timestampSlug()}`);
        await fsp.mkdir(archiveDir, { recursive: true });
        await fsp.copyFile(target, path.join(archiveDir, `${id}.png`));
      }
      await fsp.copyFile(file, target);
      await fsp.rm(file, { force: true });
      const sha = await sha256File(target);
      await update(projectDir, (state) => {
        const current = state.screens[id] || {};
        state.screens[id] = { ...current, imageSha: sha, imagePromptHash: current.promptHash, gate: null, generatedAt: new Date().toISOString(), fromAlternate: true, contentStale: true };
        appendLog(state, `${id} 已换成备选图`);
      });
      await updateRecord(projectDir, (record) => {
        const at = new Date().toISOString();
        const providerId = path.basename(file, ".png").split("-").slice(6).join("-") || null;
        record.screens[id] = { source: "alternate", providerId, alternateFile: path.basename(file), imageSha256: sha, generatedAt: at };
        record.history.push({ at, event: "alternate-used", screenId: id, providerId, alternateFile: path.basename(file) });
      });
      await markDirty(projectDir, ["gate", "content", "receipt", "build"]);
    },
    async manualGate(projectDir, id, passed) {
      assertScreenId(id);
      assertIdle(projectDir);
      const paths = projectPaths(projectDir);
      const state = await projectStore.read(projectDir);
      const sha = await sha256File(paths.screenFile(id));
      await updateRecord(projectDir, (record) => {
        const at = new Date().toISOString();
        record.gate[id] = { status: passed ? "manual-passed" : "failed", method: "manual", imageSha256: sha, checkedAt: at };
        record.history.push({ at, event: "gate", screenId: id, status: passed ? "manual-passed" : "failed", method: "manual" });
      });
      const tokensHash = hashObject(forbiddenBrandTokens(state.request.softwareName, state.request.extraBrandTokens));
      await update(projectDir, (draft) => {
        const previous = draft.screens[id]?.gate || {};
        draft.screens[id] = {
          ...(draft.screens[id] || {}),
          gate: passed
            ? { ...previous, status: "manual-passed", method: previous.method === "vision" ? "vision+manual" : "manual", sha, tokensHash, checkedAt: new Date().toISOString(), reasons: [] }
            : { ...previous, status: "failed", method: "manual", sha, tokensHash, checkedAt: new Date().toISOString(), reasons: ["人工判定有软件名或不合格"] },
        };
        appendLog(draft, `${id} 人工${passed ? "确认通过" : "判定不合格"}`);
        if (draft.steps.gate?.status === "review" || draft.steps.gate?.status === "failed") draft.steps.gate = { ...draft.steps.gate, status: "pending" };
      });
    },
    async saveContent(projectDir, { overview, screens }) {
      assertIdle(projectDir);
      const paths = projectPaths(projectDir);
      const content = await readJson(paths.content, null);
      if (!content) throw new Error("还没有文案");
      if (typeof overview === "string") content.cover.overview = overview;
      const editedIds = [];
      for (const patch of screens || []) {
        const index = content.screens.findIndex((screen) => screen.id === patch.id);
        if (index < 0) continue;
        if (typeof patch.title === "string") {
          content.screens[index].title = patch.title.trim();
          content.screens[index].caption = `图${index + 1} ${patch.title.trim()}`;
        }
        if (typeof patch.text === "string") content.screens[index].text = patch.text;
        editedIds.push(patch.id);
      }
      delete content.screenshotReview;
      await writeJsonAtomic(paths.content, content);
      await update(projectDir, (state) => {
        for (const id of editedIds) state.screens[id] = { ...(state.screens[id] || {}), textEdited: true, contentStale: false };
        if (editedIds.length) state.warnings = state.warnings.filter((warning) => !warning.startsWith("截图已更换"));
        if (typeof overview === "string") state.overviewEdited = true;
      });
      await markDirty(projectDir, ["receipt", "build"]);
    },
    async rewriteContent(projectDir, ids) {
      for (const id of ids) if (id !== "overview") assertScreenId(id);
      await update(projectDir, (state) => {
        for (const id of ids) if (state.screens[id]) state.screens[id].textEdited = false;
        if (ids.includes("overview")) state.overviewEdited = false;
      });
      return run(projectDir, { from: "content", forceContent: ids });
    },
    async updateRequest(projectDir, patch) {
      assertIdle(projectDir);
      const state = await projectStore.read(projectDir);
      const before = state.request;
      const next = { ...before, ...patch };
      // 版本号不用人选：按软件名自动判断（历史项目里单独填适用版本的保持不变）
      if (patch.softwareName !== undefined && before.versionPolicy !== "separate-metadata") next.versionPolicy = detectVersion(patch.softwareName) ? "in-name" : "none";
      const dirty = new Set();
      const changed = (key) => patch[key] !== undefined && JSON.stringify(patch[key]) !== JSON.stringify(before[key] ?? null);
      if (patch.softwareName !== undefined && patch.softwareName !== before.softwareName) {
        const paths = projectPaths(projectDir);
        const oldBundle = paths.bundle(before.softwareName);
        if (await exists(oldBundle)) {
          await fsp.mkdir(paths.archive, { recursive: true });
          await fsp.rename(oldBundle, path.join(paths.archive, `${before.softwareName}-交付-${timestampSlug()}`));
        }
        ["prompts", "gate", "receipt", "build"].forEach((step) => dirty.add(step));
      }
      if (["screenCount", "emphasis", "notes", "platform"].some((key) => changed(key) && (patch[key] || null) !== (before[key] || null))) ["plan", "prompts", "images", "gate", "content", "receipt", "build"].forEach((step) => dirty.add(step));
      if (changed("wantDesign") && Boolean(patch.wantDesign) !== Boolean(before.wantDesign)) ["design", "receipt", "build"].forEach((step) => dirty.add(step));
      if (["codeSource", "codeSourceLocked", "txtFields", "compileDate", "versionPolicy", "applicableVersion", "allowDropCodeDoc"].some(changed)) dirty.add("build");
      if (changed("extraBrandTokens")) ["gate", "receipt", "build"].forEach((step) => dirty.add(step));
      await update(projectDir, (draft) => {
        draft.request = next;
        appendLog(draft, "项目设置已更新");
      });
      await markDirty(projectDir, [...dirty]);
      return projectStore.read(projectDir);
    },

    /** 历史项目没有代码来源时：改用总设置里的代码来源（下次生成交付包时生效）。 */
    async useGlobalCodeSource(projectDir) {
      assertIdle(projectDir);
      const settings = await settingsStore.get();
      if (!settings.codeSource?.path) throw new Error("总设置里还没有代码来源，先到「设置 → 代码来源」里选择");
      return actions.updateRequest(projectDir, { codeSource: { path: settings.codeSource.path, extensions: settings.codeSource.extensions?.length ? settings.codeSource.extensions : [".java"] }, codeSourceLocked: true });
    },

    /** 只重新导出交付包里的 PDF（修正字体），Word、TXT 和截图都不动。 */
    async reexportPdfs(projectDir) {
      assertIdle(projectDir);
      const job = (async () => {
        const state = await projectStore.read(projectDir);
        if (!state) throw new Error("项目不存在");
        const settings = await settingsStore.get();
        const fontPlan = await resolveFontPlan(settings.pdf);
        const result = await reexportBundlePdfs({ projectDir, softwareName: state.request.softwareName, stagingRoot: projectStore.stagingRoot, fontPlan, onLog: (message) => log(projectDir, message) });
        await update(projectDir, (draft) => {
          if (draft.lastBuild) {
            draft.lastBuild = { ...draft.lastBuild, pdfFonts: { ...(draft.lastBuild.pdfFonts || {}), ...result.pdfFonts }, warnings: [...(draft.lastBuild.warnings || []).filter((warning) => !warning.includes("PDF 字体不对")), ...result.warnings] };
          }
          draft.pdfReexportedAt = new Date().toISOString();
          appendLog(draft, `已重新导出 PDF：${result.files.join("、")}${result.warnings.length ? `（${result.warnings.join("；")}）` : ""}`, result.warnings.length ? "warn" : "info");
        });
        await updateRecord(projectDir, (record) => {
          record.history.push({ at: new Date().toISOString(), event: "pdf-reexported", files: result.files, pdfFonts: result.pdfFonts });
        });
        return result;
      })();
      job.cancel = () => {};
      running.set(projectDir, job);
      emit({ type: "project", projectDir, status: "running" });
      try {
        return await job;
      } finally {
        running.delete(projectDir);
        emit({ type: "project", projectDir });
      }
    },

    // ---------------- 修改意见：先攒清单，再整理，确认后统一修改 ----------------
    async addFeedback(projectDir, text) {
      const value = String(text || "").trim();
      if (!value) throw new Error("修改意见是空的");
      const item = { id: crypto.randomBytes(4).toString("hex"), text: value, at: new Date().toISOString(), status: "pending" };
      await update(projectDir, (draft) => {
        draft.feedback = [...(draft.feedback || []), item];
        draft.feedbackPlan = null;
      });
      return item;
    },
    async editFeedback(projectDir, id, text) {
      const value = String(text || "").trim();
      if (!value) throw new Error("修改意见是空的");
      await update(projectDir, (draft) => {
        draft.feedback = (draft.feedback || []).map((item) => (item.id === id && item.status === "pending" ? { ...item, text: value } : item));
        draft.feedbackPlan = null;
      });
    },
    async removeFeedback(projectDir, id) {
      await update(projectDir, (draft) => {
        draft.feedback = (draft.feedback || []).filter((item) => item.id !== id);
        draft.feedbackPlan = null;
      });
    },

    /** 把清单里所有未处理的意见一起交给大模型，整理成「改哪几张图、重写哪几段文字」。 */
    async analyzeFeedback(projectDir) {
      const state = await projectStore.read(projectDir);
      if (!state) throw new Error("项目不存在");
      if (state.readOnly) throw new Error("只读的历史项目不能修改");
      const items = (state.feedback || []).filter((item) => item.status === "pending");
      if (!items.length) throw new Error("清单里没有待处理的修改意见");
      const plan = await readPlan(projectDir);
      if (!plan) throw new Error("还没有界面规划，先运行一次再提修改意见");
      const content = await readJson(projectPaths(projectDir).content, null);
      const contentById = new Map((content?.screens || []).map((screen, index) => [screen.id || screenId(index), screen]));
      const screens = plan.screens.map((screen, index) => ({
        figure: `图${index + 1}`,
        id: screen.id,
        title: contentById.get(screen.id)?.title || screen.title,
        inventory: (state.screens[screen.id]?.gate?.inventory || "").slice(0, 260),
        visual: String(screen.visualBrief || "").slice(0, 260),
        text: String(contentById.get(screen.id)?.text || "").slice(0, 80),
      }));
      const screenIds = screens.map((screen) => screen.id);
      const result = await callLlm("plan", projectDir, {
        system: FEEDBACK_SYSTEM,
        user: feedbackUserPrompt({ softwareName: state.request.softwareName, screens, overview: String(content?.cover?.overview || "").slice(0, 200), hasDesign: Boolean(content?.design?.sections?.length), items }),
        schema: FEEDBACK_SCHEMA,
        check: (draft) => feedbackCheck(draft, { screenIds, itemCount: items.length }),
        temperature: 0.2,
        maxTokens: 4000,
      });
      const toIds = (indexes) => [...new Set((indexes || []).map((index) => items[index - 1]?.id).filter(Boolean))];
      const labelOf = (target) => {
        if (target === "overview") return "封面介绍";
        if (target === "design") return "设计说明";
        if (target === "all") return "全部";
        const index = screenIds.indexOf(target);
        return index >= 0 ? `图${index + 1}「${screens[index].title}」` : target;
      };
      // 整理结果再规范一遍：「全部截图」展开成每一屏；同一屏同一类型合并；有重新规划时其余截图/说明动作并进去
      const merged = new Map();
      for (const action of result.actions) {
        const targets = action.type === "image" && action.target === "all" ? screenIds : [action.type === "overview" ? "overview" : action.type === "design" ? "design" : action.type === "replan" ? "all" : action.target];
        for (const target of targets) {
          const key = `${action.type}:${target}`;
          const previous = merged.get(key);
          merged.set(
            key,
            previous
              ? { ...previous, instruction: `${previous.instruction}；${action.instruction.trim()}`, items: [...new Set([...previous.items, ...toIds(action.items)])] }
              : { key, type: action.type, target, targetLabel: labelOf(target), instruction: action.instruction.trim(), items: toIds(action.items) }
          );
        }
      }
      let actionsList = [...merged.values()];
      const replan = actionsList.find((action) => action.type === "replan");
      if (replan) {
        const others = actionsList.filter((action) => action !== replan && ["image", "text"].includes(action.type));
        replan.items = [...new Set([...replan.items, ...others.flatMap((action) => action.items)])];
        if (others.length) replan.instruction = `${replan.instruction}；${others.map((action) => `${action.targetLabel}：${action.instruction}`).join("；")}`;
        actionsList = actionsList.filter((action) => !others.includes(action));
      }
      const order = { replan: 0, image: 1, text: 2, overview: 3, design: 4 };
      actionsList.sort((a, b) => order[a.type] - order[b.type] || String(a.target).localeCompare(String(b.target)));
      const feedbackPlan = {
        createdAt: new Date().toISOString(),
        summary: result.summary,
        itemIds: items.map((item) => item.id),
        actions: actionsList,
        questions: result.questions.map((question) => ({ question: question.question, items: toIds(question.items) })).filter((question) => question.question.trim()),
      };
      await update(projectDir, (draft) => {
        draft.feedbackPlan = feedbackPlan;
      });
      return feedbackPlan;
    },

    /**
     * 按确认后的动作统一修改：先改好所有要重生截图的提示词，再一次运行
     * （截图同时生成、一起验收、一起重写说明、只构建一次）。actions 是界面上勾选、改过措辞后的动作。
     */
    async applyFeedback(projectDir, { actions: chosen = [] } = {}) {
      assertIdle(projectDir);
      if (applying.has(projectDir)) throw new Error("正在处理上一次的修改");
      applying.add(projectDir);
      try {
        const state = await projectStore.read(projectDir);
        const plan = await readPlan(projectDir);
        if (!plan) throw new Error("还没有界面规划");
        const screenIds = plan.screens.map((screen) => screen.id);
        const actionsList = (chosen || [])
          .filter((action) => action && ["image", "text", "overview", "design", "replan"].includes(action.type) && String(action.instruction || "").trim())
          .map((action) => ({ ...action, instruction: String(action.instruction).trim(), items: Array.isArray(action.items) ? action.items : [] }));
        for (const action of actionsList) {
          if (["image", "text"].includes(action.type) && !screenIds.includes(action.target)) throw new Error(`找不到这一屏：${action.target}`);
        }
        if (!actionsList.length) throw new Error("没有勾选任何修改");
        const replan = actionsList.find((action) => action.type === "replan");
        const imageActions = replan ? [] : actionsList.filter((action) => action.type === "image");
        const textActions = replan ? [] : actionsList.filter((action) => action.type === "text");
        const overview = actionsList.find((action) => action.type === "overview");
        const design = actionsList.find((action) => action.type === "design");
        if (design && !state.request.wantDesign) throw new Error("这个项目没有开启「设计说明」章节，先在概览里打开");

        // 1. 改写要重生的截图的提示词（几张同时改）
        const paths = projectPaths(projectDir);
        const tokens = forbiddenBrandTokens(state.request.softwareName, state.request.extraBrandTokens);
        const withoutNameLines = (text) => text.split("\n").filter((line) => !line.startsWith("Project context exact software name:") && !line.includes(BRAND_BAN_BLOCK)).join("\n");
        const settings = await settingsStore.get();
        const edited = await mapLimit(imageActions, 3, async (action) => {
          let current = await fsp.readFile(paths.promptFile(action.target), "utf8").catch(() => null);
          if (!current) {
            const screen = plan.screens.find((item) => item.id === action.target);
            current = composeScreenPrompt({ softwareName: state.request.softwareName, platform: state.request.platform || settings.pipeline.platform, targetSize: settings.image.targetSize, ui: normalizedUi(plan), screen });
          }
          const result = await callLlm("plan", projectDir, {
            system: PROMPT_EDIT_SYSTEM,
            user: promptEditUserPrompt({ prompt: current, instruction: action.instruction }),
            schema: PROMPT_EDIT_SCHEMA,
            check: (draft) => {
              const hits = findBrandHits(withoutNameLines(String(draft.prompt || "")), tokens);
              return hits.length ? [`新提示词里出现了软件名/品牌词：${hits.join("、")}，界面上不能出现，请去掉`] : [];
            },
            temperature: 0.3,
            maxTokens: 6000,
          });
          return { id: action.target, prompt: ensureBrandBan(result.prompt) };
        });
        await fsp.mkdir(paths.prompts, { recursive: true });
        for (const item of edited) await writeFileAtomic(paths.promptFile(item.id), item.prompt);

        // 2. 记下这次处理了哪些意见
        const appliedItemIds = [...new Set(actionsList.flatMap((action) => action.items))];
        const at = new Date().toISOString();
        const summary = actionsList.map((action) => `${action.targetLabel || action.target}：${action.instruction}`).join("；");
        await update(projectDir, (draft) => {
          for (const item of edited) {
            draft.screens[item.id] = { ...(draft.screens[item.id] || {}), promptEdited: true, promptHash: promptIdentity(item.prompt, draft.request.softwareName) };
          }
          for (const action of textActions) if (draft.screens[action.target]) draft.screens[action.target].textEdited = false;
          if (overview) draft.overviewEdited = false;
          if (replan) draft.request.notes = [draft.request.notes, `修改意见：${replan.instruction}`].filter(Boolean).join("\n");
          const applied = new Set(appliedItemIds);
          draft.feedback = (draft.feedback || []).map((item) => (applied.has(item.id) && item.status === "pending" ? { ...item, status: "done", doneAt: at, appliedAs: summary } : item));
          draft.feedbackPlan = null;
          appendLog(draft, `按修改意见统一修改：${summary}`);
        });
        const texts = (state.feedback || []).filter((item) => appliedItemIds.includes(item.id)).map((item) => ({ id: item.id, text: item.text }));
        await updateRecord(projectDir, (record) => {
          const entry = { at, items: texts, actions: actionsList.map((action) => ({ type: action.type, target: action.target, instruction: action.instruction })) };
          record.feedback = [...(record.feedback || []), entry].slice(-100);
          record.history.push({ event: "feedback", ...entry });
        });

        // 3. 一次运行完成所有修改
        const contentInstructions = Object.fromEntries([...textActions.map((action) => [action.target, action.instruction]), ...(overview ? [["overview", overview.instruction]] : [])]);
        const from = replan ? "plan" : imageActions.length ? "prompts" : textActions.length || overview ? "content" : "design";
        run(projectDir, {
          from,
          force: [...(replan ? ["plan"] : []), ...(design ? ["design"] : [])],
          forceScreens: imageActions.map((action) => action.target),
          contentInstructions,
          designInstruction: design?.instruction,
          reason: "修改意见",
        }).catch((error) => emit({ type: "log", projectDir, level: "error", message: error.message }));
        return { started: true, images: imageActions.length, texts: textActions.length + (overview ? 1 : 0), design: Boolean(design), replan: Boolean(replan), appliedItems: appliedItemIds.length };
      } finally {
        applying.delete(projectDir);
      }
    },
  };

  /**
   * 导入的历史项目：沿用原有提示词、截图和验收回执，算好各步骤的输入哈希，
   * 避免第一次运行时把已有截图当成「过期」而重新生成。
   */
  async function adoptImported(projectDir) {
    const settings = await settingsStore.get();
    const paths = projectPaths(projectDir);
    const plan = await readPlan(projectDir);
    let state = await projectStore.read(projectDir);
    const platform = state.request.platform || settings.pipeline.platform;
    if (plan) {
      const ui = normalizedUi(plan);
      const patches = {};
      for (const screen of plan.screens) {
        const promptFile = paths.promptFile(screen.id);
        const prompt = (await exists(promptFile)) ? await fsp.readFile(promptFile, "utf8") : null;
        const identity = prompt ? promptIdentity(prompt, state.request.softwareName) : null;
        patches[screen.id] = { planRowHash: planRowHash(screen, ui, platform, settings.image.targetSize), promptHash: identity, imagePromptHash: identity, promptEdited: Boolean(prompt) };
      }
      await update(projectDir, (draft) => {
        for (const [id, patch] of Object.entries(patches)) draft.screens[id] = { ...(draft.screens[id] || {}), ...patch };
        draft.promptsName = draft.request.softwareName;
      });
    }
    state = await projectStore.read(projectDir);
    const hashes = {};
    for (const step of ["plan", "prompts", "build"]) {
      if (state.steps[step]?.status === "done") hashes[step] = await stepInputHash(step, projectDir, state, settings);
    }
    await update(projectDir, (draft) => {
      for (const [step, hash] of Object.entries(hashes)) draft.steps[step] = { ...draft.steps[step], inputHash: hash };
    });
  }

  return {
    run,
    adoptImported,
    cancel(projectDir) {
      running.get(projectDir)?.cancel?.();
    },
    isRunning: (projectDir) => running.has(projectDir),
    getProgress: (projectDir) => progress.get(projectDir) || null,
    onImageEvent,
    stepEstimates,
    runningProjects: () => [...running.keys()],
    actions,
    resolveLlm,
  };
}
