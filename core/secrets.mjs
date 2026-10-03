import path from "node:path";
import { readJson, writeJsonAtomic, createSerialQueue } from "./util/fsx.mjs";

/**
 * 密钥存储。cipher 由 Electron 主进程注入（safeStorage，依托系统钥匙串）；
 * 测试里用 createMemorySecrets。密钥永远不会写进项目目录或日志。
 */
export function createFileSecrets(dataDir, cipher) {
  if (!cipher || typeof cipher.encrypt !== "function" || typeof cipher.decrypt !== "function") {
    throw new Error("缺少密钥加密器");
  }
  const file = path.join(dataDir, "secrets.json");
  const serial = createSerialQueue();
  let cache = null;

  async function load() {
    if (!cache) cache = await readJson(file, {});
    return cache;
  }

  return {
    async get(id) {
      const entry = (await load())[id];
      if (!entry) return "";
      try {
        return cipher.decrypt(entry);
      } catch {
        return "";
      }
    },
    async has(id) {
      return Boolean((await load())[id]);
    },
    set(id, value) {
      return serial(async () => {
        const store = { ...(await load()) };
        if (value) store[id] = cipher.encrypt(String(value));
        else delete store[id];
        await writeJsonAtomic(file, store, { mode: 0o600 });
        cache = store;
      });
    },
    delete(id) {
      return this.set(id, "");
    },
    async values() {
      const store = await load();
      const result = [];
      for (const entry of Object.values(store)) {
        try {
          const value = cipher.decrypt(entry);
          if (value) result.push(value);
        } catch {
          // 无法解密的条目忽略
        }
      }
      return result;
    },
  };
}

export function createMemorySecrets(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    async get(id) {
      return store.get(id) || "";
    },
    async has(id) {
      return store.has(id);
    },
    async set(id, value) {
      if (value) store.set(id, String(value));
      else store.delete(id);
    },
    async delete(id) {
      store.delete(id);
    },
    async values() {
      return [...store.values()];
    },
  };
}

export const secretIds = {
  imageProvider: (id) => `image:${id}`,
  llmVendor: (id) => `llm:${id}`,
};

/** 把错误信息里的密钥替换掉，再写日志或显示。 */
export function redact(text, secrets = []) {
  let output = String(text ?? "");
  for (const secret of secrets) {
    if (secret && secret.length >= 6) output = output.split(secret).join("<已隐藏>");
  }
  return output
    .replace(/Bearer\s+[A-Za-z0-9._\-]{8,}/g, "Bearer <已隐藏>")
    .replace(/\bsk-[A-Za-z0-9_\-]{8,}/g, "sk-<已隐藏>");
}
