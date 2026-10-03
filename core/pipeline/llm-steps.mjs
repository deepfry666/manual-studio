import { forbiddenBrandTokens, findBrandHits, textLength, hasFigureReference, mentionsFictional } from "./brand.mjs";

// ---------------- S1 规划 ----------------

export const PLAN_SCHEMA = {
  type: "object",
  required: ["profile", "coverageReason", "features", "uiContract", "screens"],
  properties: {
    profile: {
      type: "object",
      required: ["domain", "targetUser", "coreFlow"],
      properties: { domain: { type: "string", minLength: 2 }, targetUser: { type: "string", minLength: 2 }, coreFlow: { type: "string", minLength: 2 } },
    },
    coverageReason: { type: "string", minLength: 4 },
    features: {
      type: "array",
      minItems: 1,
      items: { type: "object", required: ["name", "screenId"], properties: { name: { type: "string" }, screenId: { type: "string" }, tier: { type: "string" } } },
    },
    uiContract: {
      type: "object",
      required: ["visualStyle", "palette", "typography", "navigation"],
      properties: {
        visualStyle: { type: "string" },
        palette: { type: "object", required: ["primary", "background", "surface", "text"] },
        typography: { type: "string" },
        radius: { type: "string" },
        shadow: { type: "string" },
        density: { type: "string" },
        navigation: {
          type: "object",
          required: ["type", "labels"],
          properties: { type: { type: "string" }, labels: { type: "array", items: { type: "string" } }, iconSemantics: { type: "array", items: { type: "string" } } },
        },
      },
    },
    screens: {
      type: "array",
      minItems: 1,
      items: {
        type: "object",
        required: ["id", "title", "pageType", "mustShow", "sampleData", "textContract", "visualBrief"],
        properties: {
          id: { type: "string", pattern: "^screen-\\d{2}$" },
          title: { type: "string", minLength: 2, maxLength: 20 },
          pageType: { type: "string" },
          activeTab: { type: ["string", "null"] },
          mustShow: { type: "array", minItems: 3, items: { type: "string" } },
          sampleData: { type: "array", minItems: 2, items: { type: "string" } },
          textContract: {
            type: "object",
            required: ["entry", "action", "feedback", "exception", "exit"],
            properties: { entry: { type: "string" }, action: { type: "string" }, feedback: { type: "string" }, exception: { type: "string" }, exit: { type: "string" } },
          },
          visualBrief: { type: "string", minLength: 120 },
        },
      },
    },
  },
};

export const PLAN_SYSTEM = `你是资深移动产品经理兼 UI 设计师，负责为中文《软件用户手册》规划手机 App 界面截图。
要求：
1. 根据软件名和用户要求推断合理的领域、目标用户和核心流程，界面必须是这个领域专属的，不要做成能套用到别的产品上的通用模板，也不要七个都是仪表盘变体。
2. 常见领域覆盖参考：
   - 计算/计数：输入、执行、结果、历史、设置
   - 记账：录入、分类、账单列表、统计、预算/提醒、导出
   - 决定/随机/抽签：选项编辑、执行、结果、历史、模板、设置
   - 学习/训练：课程/首页、任务、练习、进度、笔记/收藏、我的
   - 健康/运动：总览、记录录入、计划、趋势、提醒、我的
   - 库存：物品列表、出入库、扫码/搜索、盘点、预警、设置
   - 日程：日历、新建事件、提醒、任务列表、视图切换、设置
   - 识别/文档/翻译：拍摄/导入、识别、可编辑结果、历史、导出分享
   - 地图/出行：搜索、路线/行程、详情、收藏/历史、设置
   - 客户/会员/订单：总览、列表/搜索、详情、新增/编辑、统计、导出/设置
   - 游戏：开始/主菜单、关卡/模式选择、对局进行中、结算、排行/成就、商店/角色、设置
3. 屏数优先按用户指定；未指定时以 7 屏为兜底，按功能覆盖增减（5–10 屏），并在 coverageReason 里说明理由。7 屏兜底顺序：入口/引导 → 主页总览 → 核心设置或输入 → 核心操作或查询 → 记录或列表 → 详情/结果/回执 → 我的/设置/收尾。
4. 每屏有独立的状态、操作、反馈和目的，顺序可导航、可信。界面标签简短，示例数据具体且属于该领域；同一对象在不同屏的数值必须一致。
5. 截图界面里绝对不能出现软件名、App 名、版本号、名称型 logo 或 wordmark；导航标签、页面标题、示例数据里都不要包含软件名或其中可识别的品牌词。设置页、我的页不要出现「关于本软件」「当前版本」「检查更新」这类会显示版本号的条目。
6. title 是界面中文名（用于图注，如「运营总览首页」），2–12 个字，各屏不重复。
7. visualBrief 用英文写给生图模型（120–260 个英文单词），描述该屏的具体布局、组件、状态和需要出现的中文界面文字（中文原样写在英文句子里），要具体到卡片、按钮、数值。
8. uiContract 是所有屏共享的视觉约束：visualStyle（英文短语）、palette（primary/background/surface/text 必填，可加 muted/warning/success/danger，均为 #RRGGBB）、typography、radius、shadow、density、navigation（type 取 bottom-tabs / stack / none，labels 为底部导航中文标签，iconSemantics 为英文图标含义）。
9. textContract 用中文写：entry 从哪里进入、action 主要操作、feedback 成功反馈、exception 异常处理、exit 下一步/返回。`;

export function planUserPrompt({ softwareName, screenCount, emphasis, notes, platform }) {
  return [
    `软件名（仅作上下文，界面里不能显示）：${softwareName}`,
    `平台：${platform}`,
    screenCount ? `截图屏数：必须正好 ${screenCount} 屏` : "截图屏数：未指定，按功能覆盖决定（默认 7 屏）",
    emphasis ? `用户强调的功能：${emphasis}` : "",
    notes ? `补充说明：${notes}` : "",
    "",
    "输出 JSON 结构：",
    `{"profile":{"domain":"","targetUser":"","coreFlow":"A—B—C"},"coverageReason":"","features":[{"name":"","screenId":"screen-01","tier":"core"}],"uiContract":{"visualStyle":"","palette":{"primary":"#2563EB","background":"#F5F7FB","surface":"#FFFFFF","text":"#172033"},"typography":"","radius":"","shadow":"","density":"","navigation":{"type":"bottom-tabs","labels":[],"iconSemantics":[]}},"screens":[{"id":"screen-01","title":"","pageType":"","activeTab":null,"mustShow":[],"sampleData":[],"textContract":{"entry":"","action":"","feedback":"","exception":"","exit":""},"visualBrief":""}]}`,
  ]
    .filter(Boolean)
    .join("\n");
}

export function planCheck(plan, { softwareName, screenCount }) {
  const problems = [];
  const screens = plan.screens || [];
  if (screenCount && screens.length !== screenCount) problems.push(`screens 必须正好 ${screenCount} 屏，现在是 ${screens.length} 屏`);
  if (!screenCount && (screens.length < 4 || screens.length > 12)) problems.push(`屏数 ${screens.length} 不合理，应在 5–10 之间`);
  screens.forEach((screen, index) => {
    const expected = `screen-${String(index + 1).padStart(2, "0")}`;
    if (screen.id !== expected) problems.push(`第 ${index + 1} 屏 id 应为 ${expected}`);
  });
  const titles = screens.map((screen) => screen.title);
  if (new Set(titles).size !== titles.length) problems.push("各屏 title 不能重复");
  const tokens = forbiddenBrandTokens(softwareName);
  const visibleFields = [
    ...(plan.uiContract?.navigation?.labels || []),
    ...screens.flatMap((screen) => [screen.title, ...(screen.mustShow || []), ...(screen.sampleData || [])]),
  ];
  const hits = findBrandHits(visibleFields, tokens);
  if (hits.length) problems.push(`界面文字里出现了软件名/品牌词：${hits.join("、")}，请换成不含软件名的说法`);
  return problems;
}

// ---------------- S4 截图品牌验收（看图模型） ----------------

export const GATE_SCHEMA = {
  type: "object",
  required: ["singleScreen", "portraitApp", "brandFound", "visibleText", "inventory", "warnings"],
  properties: {
    singleScreen: { type: "boolean" },
    portraitApp: { type: "boolean" },
    brandFound: { type: "boolean" },
    brandEvidence: { type: "string" },
    screenTitle: { type: "string" },
    visibleText: { type: "array", items: { type: "string" } },
    inventory: { type: "string", minLength: 20 },
    warnings: { type: "array", items: { type: "string" } },
  },
};

export const GATE_SYSTEM = `你是严格的移动 App 截图验收员。逐字查看截图，回答：
- singleScreen：是否只有一个完整的手机界面（不是拼图、不是多屏、不是设计稿合集）。
- portraitApp：是否是竖屏 App 界面本身（不是带实体手机外壳/边框的效果图、不是海报）。
- brandFound：界面里是否出现了下面列出的任何禁词，或者明显表示这些禁词的 logo / wordmark / 艺术字。只看图上真实可见的内容，看不清的不要猜。
- brandEvidence：如果 brandFound 为 true，写出看到的文字和位置。
- screenTitle：界面顶部标题。
- visibleText：图上所有清晰可读的文字，逐条原样抄录（最多 80 条）。
- inventory：用中文详细描述这个界面上可见的区域、控件、数据和状态（谁在哪、显示了什么数值），供后续写说明文字用，200–500 字。
- warnings：非阻断的问题，例如中文乱码或错字、文字重叠截断、出现安卓导航栏（要求 iPhone 时）、实体手机外壳、内容过于稀疏、和其他屏风格明显不一致、日期过旧等。没有就给空数组。`;

export function gateUserPrompt({ softwareName, tokens, screen }) {
  return [
    `软件名：${softwareName}`,
    `禁词（界面里任何一个都不能出现）：${tokens.join("、")}`,
    screen ? `这张图计划是「${screen.title}」，应包含：${(screen.mustShow || []).join("、")}` : "",
    "按要求输出 JSON：{\"singleScreen\":true,\"portraitApp\":true,\"brandFound\":false,\"brandEvidence\":\"\",\"screenTitle\":\"\",\"visibleText\":[],\"inventory\":\"\",\"warnings\":[]}",
  ]
    .filter(Boolean)
    .join("\n");
}

/** 程序复核：看图模型说没有，但抄录的文字里含禁词，也判失败。 */
export function judgeGate(result, tokens) {
  const hits = findBrandHits([...(result.visibleText || []), result.screenTitle || ""], tokens);
  const reasons = [];
  if (result.brandFound) reasons.push(`看图模型发现品牌文字：${result.brandEvidence || "未说明"}`);
  if (hits.length) reasons.push(`界面文字包含禁词：${hits.join("、")}`);
  if (result.singleScreen === false) reasons.push("不是单个完整界面");
  if (result.portraitApp === false) reasons.push("不是竖屏 App 界面（可能带手机外壳或是海报）");
  return { passed: reasons.length === 0, reasons, hits };
}

// ---------------- S5 文案 ----------------

export const CONTENT_SCHEMA = {
  type: "object",
  required: ["screens"],
  properties: {
    overview: { type: "string" },
    screens: {
      type: "array",
      items: { type: "object", required: ["id", "title", "text"], properties: { id: { type: "string" }, title: { type: "string" }, text: { type: "string" } } },
    },
  },
};

export const CONTENT_SYSTEM = `你是中文软件用户手册撰写专家，为手机 App 的《用户手册》写正文。
规则：
1. 封面介绍 overview：180–300 个字符，说明软件定位、目标用户、核心模块和整体使用流程，领域专属；禁止「进入软件、查看首页、执行核心操作、整理记录、查看统计到管理个人设置」这类通用骨架句。
2. 每屏功能说明 text：至少 {floor} 个字符（按普通字符串长度计，不是只数汉字），建议 330–450 个字符；描述该屏可见的数据、控件、操作步骤、反馈与校验、异常处理、与下一界面或返回的衔接。必须与截图实际内容一致（以「截图实际内容」为准，计划里有但截图没有的不要写）。
3. 各屏正文独立，不要套话复用，不要写同样的结尾。
4. 任何地方都不要出现「图1」「图2」这类「图+数字」字样。
5. 不要说这是虚构、示例或假想的软件；不要提到截图、AI、生成。
6. 简体中文，可分 1–3 段（用换行分隔）。title 用计划里的界面标题，除非截图标题明显不同。`;

export function contentUserPrompt({ softwareName, profile, screens, inventories, needOverview, existingOverview, floor }) {
  const blocks = screens.map((screen) => {
    const inventory = inventories[screen.id];
    return [
      `【${screen.id}｜${screen.title}】`,
      `计划：入口=${screen.textContract?.entry}；操作=${screen.textContract?.action}；反馈=${screen.textContract?.feedback}；异常=${screen.textContract?.exception}；去向=${screen.textContract?.exit}`,
      `应包含：${(screen.mustShow || []).join("、")}`,
      `示例数据：${(screen.sampleData || []).join("、")}`,
      inventory ? `截图实际内容：${inventory}` : "截图实际内容：（未做看图对账，按计划写，避免写过细的数值）",
    ].join("\n");
  });
  return [
    `软件名：${softwareName}`,
    `领域：${profile?.domain || ""}；目标用户：${profile?.targetUser || ""}；核心流程：${profile?.coreFlow || ""}`,
    needOverview ? "需要输出 overview（封面介绍）。" : `封面介绍已确定，不需要输出 overview：${existingOverview || ""}`,
    `功能说明每屏至少 ${floor} 个字符。`,
    "",
    ...blocks,
    "",
    `输出 JSON：{${needOverview ? '"overview":"",' : ""}"screens":[{"id":"screen-01","title":"","text":""}]}，screens 只包含上面列出的屏，顺序一致。`,
  ].join("\n");
}

export function contentCheck(result, { screens, needOverview, floor }) {
  const problems = [];
  const ids = screens.map((screen) => screen.id);
  const got = (result.screens || []).map((screen) => screen.id);
  if (JSON.stringify(got) !== JSON.stringify(ids)) problems.push(`screens 必须正好是 ${ids.join(",")}，顺序一致`);
  if (needOverview) {
    const overview = String(result.overview || "");
    if (textLength(overview) < 120) problems.push("overview 太短，至少 150 个字符");
    if (hasFigureReference(overview)) problems.push("overview 里不能出现「图N」");
  }
  for (const screen of result.screens || []) {
    const length = textLength(screen.text);
    if (length < floor) problems.push(`${screen.id} 的 text 只有 ${length} 个字符，至少需要 ${floor} 个，请补充该界面专属的操作与状态细节`);
    if (hasFigureReference(screen.text)) problems.push(`${screen.id} 的 text 出现了「图N」字样`);
    if (mentionsFictional(screen.text)) problems.push(`${screen.id} 的 text 不能说软件是虚构或示例`);
  }
  return problems;
}

// ---------------- S6 设计说明（可选） ----------------

export const DESIGN_SCHEMA = {
  type: "object",
  required: ["sections"],
  properties: {
    sections: {
      type: "array",
      minItems: 3,
      items: { type: "object", required: ["title", "text"], properties: { title: { type: "string" }, text: { type: "string", minLength: 120 } } },
    },
  },
};

export const DESIGN_SYSTEM = `你为中文软件用户手册撰写「软件设计说明」章节，内容要和给出的规划一致、领域专属，不臆造厂商或实现细节。
按顺序输出五节：
1. 软件基本处理流程：入口、校验、核心操作、持久化、反馈、退出或恢复。
2. 程序系统组织结构：表现层、应用/服务层、领域层、数据访问层、集成职责。
3. 功能模块划分：把功能规划划分为内聚模块，说明职责和交互。
4. 接口设计：只写领域或用户要求支持的内部/外部接口，说明用途、输入、输出、错误。
5. 数据结构设计：核心实体、标识、关系、状态字段、时间戳、保留策略。
每节 250–600 字，可用换行分段；不要出现「图N」字样，不要说软件是虚构的。`;

export function designUserPrompt({ softwareName, profile, features, screens }) {
  return [
    `软件名：${softwareName}`,
    `领域：${profile?.domain}；目标用户：${profile?.targetUser}；核心流程：${profile?.coreFlow}`,
    `功能：${features.map((feature) => feature.name).join("、")}`,
    `界面：${screens.map((screen) => `${screen.title}（${screen.textContract?.action || ""}）`).join("；")}`,
    '输出 JSON：{"sections":[{"title":"软件基本处理流程","text":""}]}',
  ].join("\n");
}

export function designCheck(result) {
  const problems = [];
  for (const section of result.sections || []) {
    if (hasFigureReference(`${section.title}${section.text}`)) problems.push(`「${section.title}」里出现了「图N」字样`);
  }
  return problems;
}
