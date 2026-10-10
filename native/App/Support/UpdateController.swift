import AppKit
import StudioCore
import SwiftUI

/// 在线更新：启动时（每 6 小时最多一次）和菜单「检查更新…」去 GitHub Releases 查新版本，
/// 有新版弹窗；确认后下载、校验、退出并替换 App，再自动打开新版本。数据都在软件数据目录里，不受影响。
@MainActor
@Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case available
        case downloading
        case failed(String)
    }

    var phase: Phase = .idle
    var release: Updater.Release?
    /// 弹窗是否显示
    var presented = false

    private let defaults = UserDefaults.standard
    private let autoCheckKey = "update.autoCheck"
    private let lastCheckKey = "update.lastCheck"
    private let skippedKey = "update.skippedVersion"

    var autoCheck: Bool = UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true {
        didSet { defaults.set(autoCheck, forKey: autoCheckKey) }
    }

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }

    /// 启动后自动检查：关掉了自动检查、6 小时内查过、或用户跳过了这个版本，就不打扰。
    func checkOnLaunch() {
        guard autoCheck, ProcessInfo.processInfo.environment["MS_DEV_CONTROL"] == nil || ProcessInfo.processInfo.environment["MS_UPDATE_TEST"] != nil else { return }
        let last = defaults.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        Task { await check(manual: false) }
    }

    /// manual：菜单里手动检查，没有新版也要告诉用户。
    func check(manual: Bool) async {
        guard phase != .checking, phase != .downloading else { return }
        phase = .checking
        do {
            let found = try await Updater.check(currentVersion: currentVersion)
            defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            release = found
            if let found, manual || defaults.string(forKey: skippedKey) != found.version {
                phase = .available
                presented = true
            } else {
                phase = .idle
                if manual { presentInfo("已经是最新版本", "当前版本 \(currentVersion)。") }
            }
        } catch {
            phase = .idle
            if manual { presentInfo("检查更新失败", messageOf(error)) }
        }
    }

    func skip() {
        if let release { defaults.set(release.version, forKey: skippedKey) }
        presented = false
        phase = .idle
    }

    func later() {
        presented = false
        phase = .idle
    }

    /// 下载 → 校验 → 写替换脚本 → 退出。替换脚本等本进程退出后换掉 App 并打开新版本。
    func install(model: AppModel) async {
        guard let release else { return }
        if model.hasBackgroundWork {
            phase = .failed("还有任务在运行，等跑完再更新（或先停止任务）。")
            return
        }
        let target = Bundle.main.bundlePath
        let parent = (target as NSString).deletingLastPathComponent
        phase = .downloading
        do {
            let work = try FS.makeTempDirectory(prefix: "manual-studio-update-")
            let zip = Path.join(work, "update.zip")
            let (downloaded, response) = try await URLSession.shared.download(from: URL(string: release.assetURL)!)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError("下载安装包失败") }
            try FS.move(downloaded.path, zip)
            let newApp = try Updater.extract(zip: zip, release: release, bundleId: Bundle.main.bundleIdentifier ?? "", into: Path.join(work, "app"))
            guard FileManager.default.isWritableFile(atPath: parent) else {
                // 装在没有写权限的位置：把新版本放到「下载」里，让用户自己拖
                let downloads = Path.join(NSHomeDirectory(), "Downloads", Path.basename(target))
                FS.remove(downloads)
                try FS.copy(newApp, downloads)
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: downloads)])
                phase = .failed("没有权限替换 \(parent) 里的 App。新版本已放到「下载」文件夹，请手动拖进去替换。")
                return
            }
            let script = Path.join(work, "install.sh")
            let env = ProcessInfo.processInfo.environment.filter { ["MS_DATA_DIR", "MS_TEST_MEMORY_SECRETS", "MS_UPDATE_TEST"].contains($0.key) }
            try FS.write(script, Updater.installScript(pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp, target: target, relaunchEnv: env))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script]
            try process.run()
            // 窗口上挂着弹窗时 macOS 会拒绝退出，先关弹窗再退出
            presented = false
            try? await Task.sleep(nanoseconds: 600_000_000)
            NSApp.terminate(nil)
            // 还没退：有任务刚开始跑、用户在退出确认里点了取消，就放弃这次更新；否则（比如还有别的弹窗挡着）直接结束
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if model.hasBackgroundWork {
                process.terminate()
                phase = .failed("有任务在运行，这次没有更新。等任务跑完后再点「检查更新」。")
                presented = true
            } else {
                exit(0)
            }
        } catch {
            phase = .failed(messageOf(error))
        }
    }

    private func presentInfo(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// 有新版本时的弹窗：更新说明 + 立即更新 / 以后再说 / 跳过这个版本。
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    let updater: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image("Logo").resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("有新版本：\(updater.release?.version ?? "")").font(.title2.weight(.semibold))
                    Text("当前版本 \(updater.currentVersion)\(updater.release.map { $0.assetSize > 0 ? "，安装包 \(String(format: "%.1f", Double($0.assetSize) / 1_048_576)) MB" : "" } ?? "")")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(notes).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 220)
            .padding(12)
            .cardBackground()
            if case .failed(let message) = updater.phase {
                Text(message).foregroundStyle(.red).font(.callout)
            }
            Text("更新时软件会自动退出、替换并重新打开；项目和设置都不受影响。").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("跳过这个版本") { updater.skip() }
                Spacer()
                Button("以后再说") { updater.later() }.keyboardShortcut(.cancelAction)
                Button {
                    Task { await updater.install(model: model) }
                } label: {
                    if updater.phase == .downloading {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在下载…") }
                    } else {
                        Text("立即更新")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(updater.phase == .downloading)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    var notes: AttributedString {
        let text = updater.release?.notes ?? ""
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
