# 软件指南生成器

macOS 桌面 App：输入软件名，自动规划界面、生成截图、撰写说明文字，交付 Word / PDF / TXT 和代码文档。

## 版本

| | 位置 | 状态 |
|---|---|---|
| **原生版（以此为准）** | [`native/`](native/) | SwiftUI，当前唯一维护和发版的版本，见 [native/README.md](native/README.md) |
| Electron 旧版 | `electron/`、`core/`、`web/` | 已定档在标签 `electron-v0.1.0-final`，**不再修改、不再发版**，只留作对照 |

- 新功能和修复只做在 `native/` 里。
- 发版用 `native/scripts/release.sh <版本号>`，产物在 GitHub Releases。
- Electron 旧版的代码保留在仓库里，原生版的提示词、Word 固定部件和对照测试数据由 `native/scripts/` 从这些代码生成（只读）。
- 两个版本共用项目文件夹 `~/Desktop/软件指南生成`，软件数据分开存放；原生版第一次打开可以导入 Electron 旧版的数据。
- 装在「应用程序」里时，Electron 旧版命名为「软件指南生成器（Electron 旧版）.app」。
