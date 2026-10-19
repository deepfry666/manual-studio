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
        case "codebatch": model.devCodeBatch = value + "#" + String(Date().timeIntervalSince1970)
        case "namelist": model.devNameListText = value.replacingOccurrences(of: "|", with: "\n")
        case "query": model.listQuery = value
        case "status": model.listStatus = value
        case "stress": startStress(Int(value) ?? 0, model)
        case "probe": value == "stop" ? stopProbe() : startProbe(value)
        case "activate":
            NSApp.windows.filter(\.isMiniaturized).forEach { $0.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible }?.makeKeyAndOrderFront(nil)
        default: break
        }
    }

    // MARK: 卡顿测量（只在开发自检时用）
    // stress=<每秒几条>：模拟批量运行，不断发进度、项目、截图事件（不调用 AI、不改文件）；stress=0 停。
    // probe=<结果文件>：每 16 毫秒问一次界面线程，记下它晚了多久才回应；probe=stop 写出统计。

    private var stressTimer: Timer?
    private var stressCount = 0

    private func startStress(_ perSecond: Int, _ model: AppModel) {
        stressTimer?.invalidate()
        stressTimer = nil
        guard perSecond > 0 else { return }
        stressTimer = Timer.scheduledTimer(withTimeInterval: 1 / Double(perSecond), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stressCount += 1
                let dirs = model.projects.prefix(12).map(\.dir) + model.projectPath
                guard let dir = dirs.randomElement() else { return }
                let progress: JSON = .obj(["step": "images", "started": .number(nowMs() - 60_000), "stepStarted": .number(nowMs() - 20_000),
                                           "screens": .obj(["finished": .number(Double(self.stressCount % 7)), "total": 7]), "detail": .string("模拟进度 \(self.stressCount)")])
                model.handle(.obj(["type": "progress", "projectDir": .string(dir), "progress": progress]))
                if self.stressCount % 3 == 0 { model.handle(.obj(["type": "image", "projectDir": .string(dir), "kind": "attempt"])) }
                if self.stressCount % 5 == 0 { model.handle(.obj(["type": "project", "projectDir": .string(dir)])) }
            }
        }
    }

    private let probeState = Locked<(file: String, lags: [Double], timer: DispatchSourceTimer?)>(("", [], nil))

    private func startProbe(_ file: String) {
        stopProbe()
        let timer = Self.makeProbeTimer(probeState)
        probeState.withLock { $0 = (file, [], timer) }
        timer.resume()
    }

    /// 计时器在后台线程跑，不能带界面线程的隔离（否则运行时检查会直接崩）
    private nonisolated static func makeProbeTimer(_ state: Locked<(file: String, lags: [Double], timer: DispatchSourceTimer?)>) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { @Sendable in
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async { @Sendable in
                let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000
                state.withLock { $0.lags.append(lag) }
            }
        }
        return timer
    }

    private func stopProbe() {
        let (file, lags, timer) = probeState.withLock { current -> (String, [Double], DispatchSourceTimer?) in
            let snapshot = current
            current = ("", [], nil)
            return snapshot
        }
        timer?.cancel()
        guard !file.isEmpty, !lags.isEmpty else { return }
        let sorted = lags.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let report: JSON = .obj([
            "samples": .number(Double(lags.count)), "avgMs": .number((lags.reduce(0, +) / Double(lags.count) * 10).rounded() / 10),
            "p95Ms": .number(pct(0.95).rounded()), "maxMs": .number(sorted.last!.rounded()),
            "over100ms": .number(Double(lags.filter { $0 > 100 }.count)), "over250ms": .number(Double(lags.filter { $0 > 250 }.count)),
            "over1000ms": .number(Double(lags.filter { $0 > 1000 }.count)),
        ])
        try? FS.writeJSONAtomic(file, report)
    }
}
