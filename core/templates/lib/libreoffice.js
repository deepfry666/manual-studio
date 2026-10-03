"use strict";

const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const MAC_APP = "/Applications/LibreOffice.app";
const MAC_SOFFICE = "/Applications/LibreOffice.app/Contents/MacOS/soffice";

function candidatePaths() {
  const candidates = [
    "C:\\Program Files\\LibreOffice\\program\\soffice.com",
    "C:\\Program Files (x86)\\LibreOffice\\program\\soffice.com",
    MAC_SOFFICE,
  ];
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(path.delimiter).filter(Boolean)) {
    candidates.push(path.join(dir, process.platform === "win32" ? "soffice.com" : "soffice"));
  }
  return candidates;
}

function findSoffice() {
  for (const candidate of candidatePaths()) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

function sleep(ms) {
  if (ms <= 0) return;
  const end = Date.now() + ms;
  while (Date.now() < end) {
    // short blocking wait; scripts are CLI build tools, not servers.
  }
}

function probeSoffice(soffice, options = {}) {
  if (!soffice) return false;
  const spawnSync = options.spawnSync || cp.spawnSync;
  const timeout = Number.isFinite(options.timeoutMs) ? options.timeoutMs : 5000;
  try {
    const res = spawnSync(
      soffice,
      ["--headless", "--nologo", "--nodefault", "--version"],
      {
        encoding: "utf8",
        timeout,
        windowsHide: true,
      }
    );
    return !res.error && res.status === 0;
  } catch {
    return false;
  }
}

function launchLibreOffice(options = {}) {
  const spawnSync = options.spawnSync || cp.spawnSync;
  const wait = options.sleep || sleep;
  if (process.platform === "darwin" && fs.existsSync(MAC_APP)) {
    const res = spawnSync("open", ["-gj", "-a", "LibreOffice"], { encoding: "utf8" });
    if (res.status === 0) wait(1500);
    return res.status === 0;
  }
  const soffice = findSoffice();
  if (!soffice) return false;
  return probeSoffice(soffice, {
    spawnSync,
    timeoutMs: options.probeTimeoutMs,
  });
}

function ensureLibreOfficeReady(options = {}) {
  const find = options.findSoffice || findSoffice;
  const probe =
    options.probeSoffice ||
    ((soffice) =>
      probeSoffice(soffice, {
        spawnSync: options.spawnSync,
        timeoutMs: options.probeTimeoutMs,
      }));
  const launch =
    options.launchLibreOffice ||
    (() =>
      launchLibreOffice({
        spawnSync: options.spawnSync,
        sleep: options.sleep,
        probeTimeoutMs: options.probeTimeoutMs,
      }));

  let soffice = find();
  if (soffice && probe(soffice)) return soffice;

  // 已安装但首次探测失败时也要尝试启动/唤醒，再重新发现并探测；仍失败必须冻结为 no-PDF。
  launch();
  soffice = find();
  if (!soffice || !probe(soffice)) return null;
  return soffice;
}

function hasLibreOffice(options = {}) {
  return Boolean(ensureLibreOfficeReady(options));
}

module.exports = {
  ensureLibreOfficeReady,
  findSoffice,
  hasLibreOffice,
  launchLibreOffice,
  probeSoffice,
};
