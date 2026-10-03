import http from "node:http";
import { makePng } from "./png.mjs";

/**
 * 本地模拟中转站。behavior(callIndex, body) 决定每次提交怎么回：
 *   { delayMs, status, error, headers, mode: "sync" | "async", readyAfterMs, failTask, blank, width, height }
 */
export async function startMockRelay(behavior = () => ({})) {
  const requests = [];
  const tasks = new Map();
  let submitCount = 0;
  let taskSeq = 0;
  const started = Date.now();
  let port = 0;

  function handle(req, res, body) {
    const url = new URL(req.url, "http://127.0.0.1");
    const send = (status, payload, headers = {}) => {
      if (res.writableEnded || res.destroyed) return;
      res.writeHead(status, { "content-type": "application/json", ...headers });
      res.end(JSON.stringify(payload));
    };

    if (req.method === "GET" && url.pathname.endsWith("/models")) {
      send(200, { data: [{ id: "gpt-image-2.5" }, { id: "gpt-image-2" }] });
      return;
    }
    if (req.method === "GET" && url.pathname.startsWith("/img/")) {
      const task = tasks.get(url.pathname.slice(5).replace(/\.png$/, ""));
      res.writeHead(200, { "content-type": "image/png" });
      res.end(makePng(216, 456, { seed: task?.seed || 3 }));
      return;
    }
    if (req.method === "GET" && url.pathname.includes("/tasks/")) {
      const id = url.pathname.split("/tasks/")[1];
      const task = tasks.get(id);
      requests.push({ kind: "poll", taskId: id, at: Date.now() - started });
      if (!task) {
        send(404, { error: { message: "task not found" } });
        return;
      }
      if (Date.now() < task.readyAt) {
        send(200, { data: { status: "processing" } });
        return;
      }
      if (task.failTask) {
        send(200, { data: { status: "failed", error: "upstream failed" } });
        return;
      }
      send(200, { data: { status: "completed", result: { images: [{ url: [`http://127.0.0.1:${port}/img/${id}.png`] }] } } });
      return;
    }
    if (req.method === "POST" && url.pathname.endsWith("/images/generations")) {
      const parsed = JSON.parse(body || "{}");
      const index = submitCount++;
      const plan = behavior(index, parsed) || {};
      const record = { kind: "submit", index, prompt: parsed.prompt, size: parsed.size, model: parsed.model, arrivedAt: Date.now() - started, aborted: false };
      requests.push(record);
      res.on("close", () => {
        if (!res.writableEnded) record.aborted = true;
      });
      setTimeout(() => {
        record.finishedAt = Date.now() - started;
        if (plan.status && plan.status >= 400) {
          send(plan.status, { error: { message: plan.error || "error" } }, plan.headers || {});
          return;
        }
        if (plan.mode === "async") {
          const id = `task_${++taskSeq}`;
          tasks.set(id, { readyAt: Date.now() + (plan.readyAfterMs ?? 200), failTask: plan.failTask, seed: index + 1 });
          send(200, { code: 200, data: [{ status: "submitted", task_id: id }] });
          return;
        }
        const png = makePng(plan.width || 216, plan.height || 456, { seed: index + 1, blank: plan.blank });
        send(200, { data: [{ b64_json: png.toString("base64") }] });
      }, plan.delayMs ?? 50);
      return;
    }
    send(404, { error: { message: "not found" } });
  }

  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => (body += chunk));
    req.on("end", () => handle(req, res, body));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = server.address().port;
  return {
    baseUrl: `http://127.0.0.1:${port}/v1`,
    requests,
    submits: () => requests.filter((request) => request.kind === "submit"),
    tasks,
    close: () =>
      new Promise((resolve) => {
        server.closeAllConnections?.();
        server.close(() => resolve());
      }),
  };
}
