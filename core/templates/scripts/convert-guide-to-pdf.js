#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const os = require("os");
const { ensureLibreOfficeReady, launchLibreOffice } = require("../lib/libreoffice");

function usage() {
  console.error("Usage: node convert-guide-to-pdf.js --project <dir> --software <name>");
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === "--project") args.project = argv[++i];
    else if (key === "--software") args.software = argv[++i];
    else if (key === "--help" || key === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${key}`);
  }
  return args;
}

function fileUri(filePath) {
  return `file:///${path.resolve(filePath).replace(/\\/g, "/").replace(/ /g, "%20")}`;
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv);
  } catch (err) {
    console.error(err.message);
    usage();
    process.exit(2);
  }
  if (args.help || !args.project || !args.software) {
    usage();
    process.exit(args.help ? 0 : 2);
  }

  const soffice = ensureLibreOfficeReady();
  if (!soffice) {
    console.error("LibreOffice not found or could not be started. Install LibreOffice or skip PDF export.");
    process.exit(3);
  }

  const project = path.resolve(args.project);
  const deliveryDir = path.join(project, args.software);
  fs.mkdirSync(deliveryDir, { recursive: true });
  const bundledGuideDocx = path.join(deliveryDir, `${args.software}指南.docx`);
  const rootGuideDocx = path.join(project, `${args.software}指南.docx`);
  const guideDocx = fs.existsSync(bundledGuideDocx) ? bundledGuideDocx : rootGuideDocx;
  const guidePdf = path.join(deliveryDir, `${args.software}指南.pdf`);
  if (!fs.existsSync(guideDocx)) {
    console.error(`Guide DOCX missing: ${bundledGuideDocx}`);
    process.exit(1);
  }

  const profile = path.join(os.tmpdir(), `software-manual-generator-lo-${process.pid}`);
  fs.rmSync(guidePdf, { force: true });
  const convertArgs = [
    "--headless",
    "--nologo",
    "--nodefault",
    "--nolockcheck",
    `-env:UserInstallation=${fileUri(profile)}`,
    "--convert-to",
    "pdf",
    "--outdir",
    deliveryDir,
    guideDocx,
  ];
  let result = cp.spawnSync(soffice, convertArgs, { encoding: "utf8" });
  if (result.status !== 0 || !fs.existsSync(guidePdf) || fs.statSync(guidePdf).size === 0) {
    launchLibreOffice();
    result = cp.spawnSync(soffice, convertArgs, { encoding: "utf8" });
  }

  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  if (result.status !== 0) process.exit(result.status || 1);
  if (!fs.existsSync(guidePdf) || fs.statSync(guidePdf).size === 0) {
    console.error(`PDF was not created: ${guidePdf}`);
    process.exit(1);
  }
  console.log(`PDF created: ${guidePdf}`);
}

main();
