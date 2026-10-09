import http from "node:http";

function longText(title, seed) {
  const base = `进入「${title}」后，界面顶部显示当前页面标题和返回入口，中部区域按卡片排列本页的核心数据与操作控件。用户可以先查看列表中的状态标签，再点击主要按钮完成本页的关键操作；提交前系统会逐项校验必填内容，缺少信息时在对应输入框下方给出红色提示并保留已填写的内容。操作成功后页面顶部弹出浅色提示条，相关数值即时刷新，便于确认结果。若网络中断或服务暂时不可用，页面会显示重试按钮和最近一次同步时间，不会把空值当作零处理。完成本页操作后，可以通过底部导航切换到其他模块，或点击左上角返回上一页继续处理。`;
  return `${base}（第${seed}屏补充：本页还支持下拉刷新与长按快捷操作，常用设置会自动记住，下次打开时直接沿用上次的筛选条件和排序方式。）`;
}

/**
 * 模拟 OpenAI 兼容的 /chat/completions，按系统提示词判断是哪一步。
 * options.gateBrandOnce：这些屏第一次验收返回「发现品牌文字」。
 */
export async function startMockLlm(options = {}) {
  const calls = [];
  const gateSeen = new Map();
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => {
      const send = (status, payload) => {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(payload));
      };
      if (req.method === "GET" && req.url.endsWith("/models")) return send(200, { data: [{ id: "mock-text" }, { id: "mock-vision" }] });
      const request = JSON.parse(body || "{}");
      const system = request.messages?.[0]?.content || "";
      const userContent = request.messages?.[1]?.content;
      const user = typeof userContent === "string" ? userContent : userContent?.[0]?.text || "";
      let result;
      if (system.includes("规划手机 App 界面截图")) {
        calls.push({ step: "plan", model: request.model });
        const count = Number(user.match(/必须正好 (\d+) 屏/)?.[1] || 7);
        const titles = ["账号登录", "记账首页", "新增账单", "账单明细", "统计分析", "预算提醒", "我的设置", "分类管理", "导出账单", "同步备份"];
        result = {
          profile: { domain: "个人记账", targetUser: "需要管理日常收支的上班族", coreFlow: "登录—首页—记账—明细—统计—设置" },
          coverageReason: `${count} 屏覆盖记账核心流程`,
          features: titles.slice(0, count).map((name, index) => ({ name, screenId: `screen-${String(index + 1).padStart(2, "0")}`, tier: "core" })),
          uiContract: { visualStyle: "clean light finance app", palette: { primary: "#2563EB", background: "#F5F7FB", surface: "#FFFFFF", text: "#172033" }, typography: "system sans", radius: "12px", shadow: "subtle", density: "comfortable", navigation: { type: "bottom-tabs", labels: ["首页", "明细", "统计", "我的"], iconSemantics: ["home", "list", "chart", "person"] } },
          screens: titles.slice(0, count).map((title, index) => ({
            id: `screen-${String(index + 1).padStart(2, "0")}`,
            title,
            pageType: "page",
            activeTab: index === 0 ? null : "首页",
            mustShow: ["标题栏", "数据卡片", "主要按钮"],
            sampleData: ["本月支出 ¥3,280", "餐饮 ¥1,120"],
            textContract: { entry: "从首页进入", action: "录入并保存", feedback: "保存成功提示", exception: "必填项为空时提示", exit: "返回首页" },
            visualBrief: `A clean personal finance screen titled ${title} with a header, a summary card showing 本月支出 ¥3,280, a category list including 餐饮 ¥1,120 and 交通 ¥360, a primary blue button, and consistent spacing. The layout is calm and readable, with clear Chinese labels and no branding of any kind anywhere on the screen.`,
          })),
        };
      } else if (system.includes("截图验收员")) {
        const title = user.match(/计划是「(.+?)」/)?.[1] || "";
        const seen = gateSeen.get(title) || 0;
        gateSeen.set(title, seen + 1);
        calls.push({ step: "gate", model: request.model, title, hasImage: Array.isArray(userContent) && userContent.some((part) => part.type === "image_url") });
        const brand = ((options.gateBrandOnce || []).includes(title) && seen === 0) || (options.gateBrandAlways || []).includes(title);
        result = {
          singleScreen: true,
          portraitApp: true,
          brandFound: brand,
          brandEvidence: brand ? "顶部写着软件名" : "",
          screenTitle: title,
          visibleText: brand ? [title, options.brandText || "测试记账本"] : [title, "本月支出 ¥3,280", "餐饮 ¥1,120"],
          inventory: `界面标题为「${title}」，上方是本月支出 ¥3,280 的汇总卡片，下面列出餐饮 ¥1,120、交通 ¥360 等分类，底部有蓝色主按钮。`,
          warnings: [],
        };
      } else if (system.includes("多条修改意见整理成具体的修改动作")) {
        calls.push({ step: "feedback", model: request.model, user });
        // 简单规则模拟大模型：图N + 说明/文字 → 改说明；图N → 改图；封面 → 封面介绍；整体 → 所有图；其他 → 提问
        const items = [...user.matchAll(/意见(\d+)：(.+)/g)].map((match) => ({ index: Number(match[1]), text: match[2] }));
        const merged = new Map();
        const questions = [];
        for (const item of items) {
          const figure = item.text.match(/图(\d+)/);
          let action = null;
          if (/封面/.test(item.text)) action = { type: "overview", target: "overview" };
          else if (figure && /说明|文字|多写/.test(item.text)) action = { type: "text", target: `screen-${String(figure[1]).padStart(2, "0")}` };
          else if (figure) action = { type: "image", target: `screen-${String(figure[1]).padStart(2, "0")}` };
          else if (/整体|全部/.test(item.text)) action = { type: "image", target: "all" };
          if (!action) {
            questions.push({ question: `「${item.text}」具体想改哪一屏？`, items: [item.index] });
            continue;
          }
          const key = `${action.type}:${action.target}`;
          const previous = merged.get(key);
          merged.set(key, previous ? { ...previous, instruction: `${previous.instruction}；${item.text}`, items: [...previous.items, item.index] } : { ...action, instruction: item.text, items: [item.index] });
        }
        result = { summary: `共 ${merged.size} 处修改`, actions: [...merged.values()], questions };
      } else if (system.includes("改写一份手机 App 截图的生图提示词")) {
        calls.push({ step: "prompt-edit", model: request.model, user });
        const instruction = user.match(/修改要求：(.+)/)?.[1] || "";
        const original = user.split("原提示词：\n")[1]?.split("\n\n输出 JSON")[0] || "";
        result = { prompt: `${original.trim()}\nRevision applied: ${instruction}` };
      } else if (system.includes("用户手册撰写专家")) {
        calls.push({ step: "content", model: request.model, user });
        const blocks = [...user.matchAll(/【(screen-\d+)｜(.+?)】/g)];
        result = {
          ...(user.includes("需要输出 overview") ? { overview: "本软件面向需要管理日常收支的上班族，提供快速记账、账单明细、分类统计与预算提醒等功能。用户登录后可在首页查看本月收支概况，通过新增账单快速录入每一笔消费，并在统计页按分类和时间查看趋势，预算接近上限时会收到提醒，个人设置中可管理分类、导出账单与同步备份，帮助用户长期养成记账习惯。" } : {}),
          screens: blocks.map((match, index) => ({ id: match[1], title: match[2], text: longText(match[2], index + 1) })),
        };
      } else if (system.includes("软件设计说明")) {
        calls.push({ step: "design" });
        const section = (title) => ({ title, text: `${title}：本软件围绕记账、明细、统计与预算四个核心环节组织处理流程，前端负责输入校验与展示，服务层负责业务规则与数据汇总，数据层按用户、账单、分类和预算等实体保存记录，并为每条记录保留创建时间、更新时间和状态字段，保证数据可追溯、可恢复。`.repeat(2) });
        result = { sections: ["软件基本处理流程", "程序系统组织结构", "功能模块划分", "接口设计", "数据结构设计"].map(section) };
      } else {
        calls.push({ step: "other" });
        result = { ok: true };
      }
      send(200, { choices: [{ message: { role: "assistant", content: JSON.stringify(result) } }], usage: { prompt_tokens: 10, completion_tokens: 10 } });
    });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    baseUrl: `http://127.0.0.1:${server.address().port}/v1`,
    calls,
    close: () => new Promise((resolve) => {
      server.closeAllConnections?.();
      server.close(() => resolve());
    }),
  };
}
