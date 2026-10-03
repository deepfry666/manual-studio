import os from "node:os";
import path from "node:path";
import fsp from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** 给看图模型用的缩小版（宽 720 的 JPEG），省流量也省钱。Electron 里会换成 nativeImage 实现。 */
export async function imageToVisionDataUrl(file) {
  const dir = await fsp.mkdtemp(path.join(os.tmpdir(), "manual-studio-vision-"));
  try {
    const output = path.join(dir, "vision.jpg");
    await execFileAsync("/usr/bin/sips", ["--resampleWidth", "720", "-s", "format", "jpeg", "-s", "formatOptions", "80", file, "--out", output], { timeout: 30_000 });
    return `data:image/jpeg;base64,${(await fsp.readFile(output)).toString("base64")}`;
  } catch {
    return `data:image/png;base64,${(await fsp.readFile(file)).toString("base64")}`;
  } finally {
    await fsp.rm(dir, { recursive: true, force: true });
  }
}
