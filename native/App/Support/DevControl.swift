import AppKit
import StudioCore
import SwiftUI

/// 开发自检：设置 MS_DEV_CONTROL=<文件> 时，App 每 0.4 秒读一次这个文件，按里面的指令切换页面，
/// 配合截图脚本逐页检查界面（和 Electron 版的 MS_AUTOMATION 一样，只在开发时用）。
/// 指令一行一个：section=projects、modelsTab=llm、settingsTab=pdf、open=<项目路径>、projectTab=screens、
/// feedback=open|close、newMode=batch、migrate=import|skip、appearance=dark|light、size=1440x920、select=<路径>|none、back、hold=1|0、close
@MainActor
final class DevControl {
    static let shared = DevControl()
    private var lastText = ""
    private var timer: Timer?

    func start(_ model: AppModel) {
        guard let file = ProcessInfo.processInfo.environment["MS_DEV_CONTROL"], timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(file, model) }
        }
    }

    private func poll(_ file: String, _ model: AppModel) {
        guard let text = FS.readTextIfExists(file), text != lastText else { return }
        lastText = text
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.jsTrimmed, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1].jsTrimmed : ""
            apply(key, value, model)
        }
    }

    private func apply(_ key: String, _ value: String, _ model: AppModel) {
        switch key {
        case "section": if let item = SidebarItem(rawValue: value) { model.go(item) }
        case "modelsTab": model.modelsTab = value
        case "settingsTab": model.settingsTab = value
        case "open": model.openProject(value)
        case "back": model.projectPath = []
        case "projectTab": model.devProjectTab = ProjectTab(name: value)
        case "feedback": model.devFeedbackOpen = value == "open"
        case "newMode": model.devNewMode = value
        case "select": model.devSelection = value == "none" ? [] : Set(value.split(separator: "|").map(String.init))
        case "migrate":
            if model.phase == .askMigration { Task { await model.finishMigrationChoice(importData: value == "import") } }
        case "appearance":
            NSApp.appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
        case "size":
            let numbers = value.split(separator: "x").compactMap { Double($0) }
            if numbers.count == 2, let window = NSApp.windows.first(where: { $0.isVisible }) {
                var frame = window.frame
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                window.setFrame(frame, display: true, animate: false)
            }
        case "hold":
            model.devHoldBackground = value == "1"
            if !model.devHoldBackground { model.quitIfIdleInBackground() }
        case "timeFilter": model.devTimeFilter = value + "#" + String(Date().timeIntervalSince1970)
        case "minimize":
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.miniaturize(nil)
        case "close":
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.performClose(nil)
        case "activate":
            NSApp.windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        default: break
        }
    }
}
