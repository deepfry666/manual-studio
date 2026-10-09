// 用 Electron 把 build/icon.svg 渲染成各尺寸 PNG，再用 iconutil 打成 icon.icns。
// 运行：npx electron build/render-icon.mjs
import { app, BrowserWindow } from "electron";
import fsp from "node:fs/promises";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const SIZES = [16, 32, 128, 256, 512];

app.whenReady().then(async () => {
  const svg = await fsp.readFile(path.join(here, "icon.svg"), "utf8");
  const win = new BrowserWindow({ width: 1024, height: 1024, show: false, transparent: true, frame: false, webPreferences: { offscreen: true } });
  await win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`)}`);
  await new Promise((resolve) => setTimeout(resolve, 600));
  const image = await win.webContents.capturePage({ x: 0, y: 0, width: 1024, height: 1024 });
  const iconset = path.join(here, "icon.iconset");
  await fsp.rm(iconset, { recursive: true, force: true });
  await fsp.mkdir(iconset, { recursive: true });
  const full = image.resize({ width: 1024, height: 1024, quality: "best" });
  await fsp.writeFile(path.join(here, "icon-1024.png"), full.toPNG());
  for (const size of SIZES) {
    await fsp.writeFile(path.join(iconset, `icon_${size}x${size}.png`), full.resize({ width: size, height: size, quality: "best" }).toPNG());
    await fsp.writeFile(path.join(iconset, `icon_${size}x${size}@2x.png`), full.resize({ width: size * 2, height: size * 2, quality: "best" }).toPNG());
  }
  execFileSync("iconutil", ["-c", "icns", iconset, "-o", path.join(here, "icon.icns")]);
  console.log("icon.icns written");
  app.quit();
});
