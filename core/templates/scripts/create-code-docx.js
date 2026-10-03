#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const {
  AlignmentType,
  Document,
  Header,
  Packer,
  Paragraph,
  PageOrientation,
  TextRun,
} = require("docx");

const CODE_SUFFIX = "\u6307\u5357_\u4ee3\u7801-\uff08JAVA\uff09";
const CODE_FONT = "\u65b0\u5b8b\u4f53";
const CODE_SIZE = 18; // 9pt, Word half-point units.

function usage() {
  console.error("Usage: node create-code-docx.js --project <dir> --software <name> --body-file <code.txt>");
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === "--project") args.project = argv[++i];
    else if (key === "--software") args.software = argv[++i];
    else if (key === "--body-file") args.bodyFile = argv[++i];
    else if (key === "--help" || key === "-h") args.help = true;
    else throw new Error(`Unknown argument: ${key}`);
  }
  return args;
}

function normalizeBody(text) {
  return text.replace(/^\uFEFF/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

function createCodeParagraph(line) {
  return new Paragraph({
    alignment: AlignmentType.BOTH,
    spacing: {
      before: 0,
      after: 0,
      line: 240,
    },
    indent: {
      left: 0,
      right: 0,
      firstLine: 0,
    },
    children: [
      new TextRun({
        text: line.length > 0 ? line : " ",
        font: CODE_FONT,
        size: CODE_SIZE,
      }),
    ],
  });
}

function createDocument(software, body) {
  const lines = normalizeBody(body).split("\n");
  return new Document({
    styles: {
      default: {
        document: {
          run: {
            font: CODE_FONT,
            size: CODE_SIZE,
          },
          paragraph: {
            alignment: AlignmentType.BOTH,
            spacing: {
              before: 0,
              after: 0,
              line: 240,
            },
          },
        },
      },
    },
    sections: [
      {
        properties: {
          page: {
            size: {
              width: 11906,
              height: 16838,
              orientation: PageOrientation.PORTRAIT,
            },
            margin: {
              top: 1440,
              right: 1200,
              bottom: 1440,
              left: 1200,
              header: 720,
              footer: 720,
            },
          },
        },
        headers: {
          default: new Header({
            children: [
              new Paragraph({
                alignment: AlignmentType.LEFT,
                spacing: { before: 0, after: 0 },
                children: [
                  new TextRun({
                    text: software,
                    font: CODE_FONT,
                    size: 22,
                  }),
                ],
              }),
            ],
          }),
        },
        children: lines.map(createCodeParagraph),
      },
    ],
  });
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv);
  } catch (err) {
    console.error(err.message);
    usage();
    process.exit(2);
  }
  if (args.help || !args.project || !args.software || !args.bodyFile) {
    usage();
    process.exit(args.help ? 0 : 2);
  }

  try {
    // 软件指南生成器补丁：代码正文只来自项目指定的代码来源，不内置任何代码。
    const bodyFile = path.resolve(args.bodyFile);
    if (!fs.existsSync(bodyFile)) {
      throw new Error(`Code body file missing: ${bodyFile}`);
    }

    const project = path.resolve(args.project);
    const deliveryDir = path.join(project, args.software);
    fs.mkdirSync(deliveryDir, { recursive: true });
    const outputDocx = path.join(deliveryDir, `${args.software}${CODE_SUFFIX}.docx`);
    const body = fs.readFileSync(bodyFile, "utf8");
    const doc = createDocument(args.software, body);
    const buffer = await Packer.toBuffer(doc);
    fs.writeFileSync(outputDocx, buffer);
    console.log(`Code DOCX created: ${outputDocx}`);
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
}

main();
