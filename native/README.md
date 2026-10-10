# 软件指南生成器

SwiftUI 写的 macOS 原生 App，是现在唯一维护和发版的版本。功能和 Electron 旧版一致；Electron 旧版定档在 git 标签 `electron-v0.1.0-final`，不再修改、不再发版。

## 打包和运行

需要 Xcode 27（macOS 27 SDK），App 最低支持 macOS 26。

```bash
scripts/build-app.sh            # 生成 dist/软件指南生成器.app
scripts/build-app.sh --test     # 先跑全部测试再打包
scripts/build-app.sh --zip      # 另外打一个 zip
```

产物是 arm64 + x86_64 通用包，ad-hoc 签名，只适合自己的 Mac 用；拷到别的 Mac 第一次打开要在「系统设置 → 隐私与安全性」里放行。装到「应用程序」时，Electron 旧版改名为「软件指南生成器（Electron 旧版）.app」，两个可以同时存在。

开发时用 Xcode 打开 `ManualStudio.xcodeproj` 直接运行，或者：

```bash
xcodebuild -project ManualStudio.xcodeproj -scheme ManualStudio -configuration Debug -derivedDataPath build/DerivedData build
```

PDF 仍然靠 LibreOffice 转换，没装时「设置 → 通用」里会提示。

## 数据

| | Electron 旧版 | 当前版本 |
|---|---|---|
| 项目文件夹 | `~/Desktop/软件指南生成` | 同一个，格式完全相同 |
| 软件数据（设置、线路、调用记录、项目列表） | `~/Library/Application Support/软件指南生成器` | `~/Library/Application Support/软件指南生成器（原生版）` |
| 密钥 | Electron safeStorage | 钥匙串里的密钥加密，单独保存 |

- 软件数据目录和钥匙串项的名字里仍带「（原生版）」，这是内部名字，为了不和 Electron 旧版混在一起，不要改。
- 第一次打开会问要不要导入 Electron 旧版的数据（设置、线路和密钥、调用记录、项目列表）。之后也可以在「设置 → 导入历史项目 → 从 Electron 旧版导入」再导一次，只合并新增的内容。
- 导入只读 Electron 的数据目录，不会改动它。导入密钥时 macOS 会弹窗询问是否允许读取「软件指南生成器 Safe Storage」，点允许即可。
- 两个版本共用项目文件夹，同一个项目不要两边同时运行。

## 发版

只发原生版。改完代码、提交之后：

```bash
scripts/release.sh 1.1.0             # 更新说明按提交记录自动生成
scripts/release.sh 1.1.0 notes.md    # 或者自己写更新说明
```

脚本会改版本号、跑测试、打包、提交并打标签 `v1.1.0`、推送到 GitHub，再建 Release 并上传 `软件指南生成器-1.1.0.zip`。需要先 `gh auth login` 登录 GitHub。下载 zip 解压后，把 App 拖进「应用程序」替换旧的即可，数据不受影响。

## 结构

```
native/
├── App/                    SwiftUI 界面（ManualStudio target）
│   ├── Pages/              新建项目、历史项目、项目详情各标签、模型与线路、设置
│   └── Support/            AppModel（状态和事件）、通用组件、开发自检
├── StudioCore/             Swift Package，全部业务逻辑，不依赖界面
│   ├── Sources/StudioCore/
│   │   ├── Util/           和 JS 字节一致的 JSON、文本、文件、zip
│   │   ├── Gateway/        生图网关：并发、补发、切换、重试、熔断、异步任务续查
│   │   ├── LLM/            OpenAI 兼容客户端、JSON Schema 校验和修复
│   │   ├── Pipeline/       规划 → 提示词 → 生图 → 验收 → 文案 → 设计说明 → 审查回执 → 交付包
│   │   ├── Build/          Word（复刻 docx 库输出）、TXT、LibreOffice 转 PDF 和字体核对
│   │   └── Migration.swift 从 Electron 旧版导入
│   └── Tests/              73 个测试
└── scripts/
    ├── build-app.sh                 打 Release 包
    ├── release.sh                   发版到 GitHub Releases
    ├── generate-from-electron.mjs   从 Electron 代码生成提示词和 docx 固定部件
    └── make-fixtures.mjs            从 Electron 代码生成对照用的测试数据
```

## 和 Electron 旧版的一致性

- 提示词、JSON Schema 报错文字、Word 的 XML、TXT 模板都由 `scripts/` 从定档的 Electron 代码生成，测试逐字节对照（`CompatibilityTests`）。
- 每一步的输入哈希和 Electron 旧版算法相同，所以 Electron 旧版做到一半的项目可以在原生版接着跑，不会被当成改过而重做。`RealDataTests` 会只读地扫一遍本机 Electron 数据里的真实项目重新核对哈希。
- 网关、流水线、反馈修改、导入、导出、改名等用模拟的生图线路和大模型测试（`GatewayTests`、`PipelineTests`、`FeatureTests`、`EdgeTests`）。

```bash
cd StudioCore && swift test
```

## 开发自检

设置环境变量 `MS_DEV_CONTROL=<文件>` 启动时，App 会读这个文件里的指令切换页面（见 `App/Support/DevControl.swift`），配合截图逐页检查界面。`MS_DATA_DIR` 可以把软件数据换到别的目录，`MS_TEST_MEMORY_SECRETS=1` 让密钥只存在内存里、不碰钥匙串。
