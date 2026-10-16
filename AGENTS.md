# 项目执行约束

## 版本与本地交付

- 用户要求：以后每次向用户交付软件更新，都同步递增可见版本号和构建号，不能用同一版本号交付不同功能的更新。
- 原生版修改 `native/ManualStudio.xcodeproj/project.pbxproj` 中 Debug / Release 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。普通修复默认递增补丁版本；同一次更新的开发重编译不反复增加版本。
- 本地交付检查打包产物、安装版 Info.plist 和实际界面显示的版本号一致；替换安装版前确认无运行/排队任务，保留旧版及核对持久数据。
- 本地构建和安装不代表对外发布授权。未经用户授权不推送、建 GitHub Release 或上传产物。
