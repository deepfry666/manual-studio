import AppKit
import Observation
import StudioCore
import SwiftUI
import UserNotifications

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case new, projects, models, stats, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .new: "新建项目"
        case .projects: "历史项目"
        case .models: "模型与线路"
        case .stats: "统计"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .new: "plus.circle"
        case .projects: "square.grid.2x2"
        case .models: "cpu"
        case .stats: "chart.bar.xaxis"
        case .settings: "gearshape"
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case success, info, warning, error }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
}

struct PdfJob: Equatable {
    let index: Int
    let total: Int
    let current: String
}

/// 全局状态：核心服务、设置、项目列表、实时进度和事件。所有界面都从这里取数据。
@Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        case askMigration
        case ready
        case failed(String)
    }

    var phase: Phase = .starting
    var core: StudioCore?
    /// 开发自检：MS_DATA_DIR 换一个数据目录，MS_TEST_MEMORY_SECRETS 密钥只放内存（不碰钥匙串）
    let dataDir = ProcessInfo.processInfo.environment["MS_DATA_DIR"] ?? nativeDataDir()
    let memorySecrets = ProcessInfo.processInfo.environment["MS_TEST_MEMORY_SECRETS"] != nil
    let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"

    // 导航
    var section: SidebarItem? = .projects
    var projectPath: [String] = []
    var modelsTab = "providers"
    var settingsTab = "general"

    // 数据
    var settings = Settings()
    var providerKeys: [String: Bool] = [:]
    var vendorKeys: [String: Bool] = [:]
    var projects: [ProjectRow] = []
    var projectsLoaded = false
    var batchItems: [JSON] = []
    var batchPaused = false
    var pendingJobs: [JSON] = []
    var live: [String: JSON] = [:]
    var activity: [String: [String]] = [:]
    var revisions: [String: Int] = [:]
    var callsRevision = 0
    var settingsRevision = 0
    var pdfJob: PdfJob?
    var toasts: [Toast] = []
    var alert: AlertItem?
    var migrationSummary: JSON?

    // 开发自检（DevControl）
    var devProjectTab: ProjectTab?
    var devFeedbackOpen: Bool?
    var devNewMode: String?
    var devSelection: Set<String>?

    private var debounced: [String: Task<Void, Never>] = [:]
    private var batchNotified = false

    /// 还有没跑完的活：项目在运行、批量队列没跑完（暂停的不算）、正在重新导出 PDF。
    var hasBackgroundWork: Bool {
        devHoldBackground || !(core?.pipeline.runningProjects().isEmpty ?? true) || (batchActive && !batchPaused) || pdfJob != nil
    }
    /// 开发自检：假装有任务在跑（MS_DEV_CONTROL 的 hold=1）
    var devHoldBackground = false
    /// 开发自检：历史项目的时间筛选（today / week / date:2026-10-09 / picker）
    var devTimeFilter: String?

    /// 窗口已经关掉、活也干完了，就退出（关窗时有任务在跑才会留在后台）。
    func quitIfIdleInBackground() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !hasBackgroundWork, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
            NSApp.terminate(nil)
        }
    }

    var batchActive: Bool { batchItems.contains { ["queued", "running"].contains($0["status"]?.string ?? "") } }
    var unknownJobs: [JSON] { pendingJobs.filter { $0["state"]?.string == "needs-attention" } }

    // MARK: - 启动

    private var started = false

    func start() async {
        // 关窗后从程序坞重新打开时 RootView 会再触发一次，不能再建一个 core
        guard !started else { return }
        started = true
        DevControl.shared.start(self)
        if ElectronMigration.isFresh(dataDir) && ElectronMigration.available() {
            phase = .askMigration
            return
        }
        await launchCore()
    }

    /// 第一次打开时选择是否从 Electron 旧版导入。
    func finishMigrationChoice(importData: Bool) async {
        if importData {
            do {
                let secrets: SecretStore = memorySecrets ? MemorySecrets() : LocalSecrets.open(dataDir: dataDir)
                migrationSummary = try await ElectronMigration.migrate(to: dataDir, secrets: secrets, readSecrets: !memorySecrets)
            } catch {
                alert = AlertItem(title: "导入失败", message: messageOf(error))
            }
        } else {
            try? ElectronMigration.declineFirstRun(dataDir)
        }
        await launchCore()
    }

    func launchCore() async {
        phase = .starting
        do {
            let core = try await StudioCore(dataDir: dataDir, secrets: memorySecrets ? MemorySecrets() : nil, appVersion: appVersion, onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
            self.core = core
            await reloadSettings()
            await reloadProjects()
            reloadBatch()
            reloadPendingJobs()
            phase = .ready
            Task { await core.start() }
            requestNotificationPermission()
        } catch {
            phase = .failed(messageOf(error))
        }
    }

    /// 导入 Electron 旧版数据后重建核心（核心会缓存设置和记录）。
    func importFromElectron() async {
        guard let core else { return }
        if !core.pipeline.runningProjects().isEmpty {
            alert = AlertItem(title: "有项目正在运行", message: "先停止所有项目再导入。")
            return
        }
        do {
            migrationSummary = try await ElectronMigration.migrate(to: dataDir, secrets: core.secrets, readSecrets: !memorySecrets)
            self.core = nil
            await launchCore()
            let summary = migrationSummary ?? .emptyObject
            let failed = summary["secretsFailed"].items.count
            alert = AlertItem(
                title: "已从 Electron 旧版导入",
                message: "生图线路 \(summary["providers"]?.int ?? 0) 条、大模型厂商 \(summary["vendors"]?.int ?? 0) 个、项目 \(summary["projects"]?.int ?? 0) 个、密钥 \(summary["secrets"]?.int ?? 0) 个。\(failed > 0 ? "\n有 \(failed) 个密钥没能解开，请在「模型与线路」里重新填写。" : "")\nElectron 旧版的数据没有改动。"
            )
        } catch {
            alert = AlertItem(title: "导入失败", message: messageOf(error))
        }
    }

    // MARK: - 数据

    func reloadSettings() async {
        guard let core else { return }
        if let bundle = try? await core.getSettings() {
            settings = bundle.settings
            providerKeys = bundle.providerKeys
            vendorKeys = bundle.vendorKeys
            settingsRevision += 1
        }
    }

    func reloadProjects() async {
        guard let core else { return }
        if let rows = try? await core.listProjects() {
            projects = rows.map(ProjectRow.init(json:))
            projectsLoaded = true
        }
    }

    func reloadBatch() {
        guard let core else { return }
        let list = core.batch.list()
        batchItems = list.items
        batchPaused = list.paused
    }

    func reloadPendingJobs() {
        pendingJobs = core?.pendingJobs() ?? []
    }

    func bump(_ dir: String) {
        debounce("project:\(dir)", 250) { [weak self] in self?.revisions[dir, default: 0] += 1 }
    }

    func scheduleProjectsReload(_ ms: Int = 800) {
        debounce("projects", ms) { [weak self] in await self?.reloadProjects() }
    }

    func debounce(_ key: String, _ ms: Int, _ action: @escaping @MainActor () async -> Void) {
        debounced[key]?.cancel()
        debounced[key] = Task {
            try? await Task.sleep(for: .milliseconds(ms))
            if Task.isCancelled { return }
            await action()
        }
    }

    // MARK: - 事件

    func handle(_ event: JSON) {
        let type = event["type"]?.string ?? ""
        let dir = event["projectDir"]?.string
        switch type {
        case "progress":
            guard let dir else { return }
            if let progress = event["progress"], !progress.isNull {
                live[dir] = progress
            } else {
                live[dir] = nil
                bump(dir)
            }
            scheduleProjectsReload()
        case "project", "step", "screen":
            if let dir { bump(dir) }
            scheduleProjectsReload()
        case "log":
            if let dir { bump(dir) }
            if event["level"]?.string == "error", let message = event["message"]?.string {
                toast(.error, message)
            }
        case "run-finished":
            quitIfIdleInBackground()
            scheduleProjectsReload(300)
            if let dir { bump(dir) }
            if event["status"]?.string == "done" {
                let text = "「\(event["name"]?.jsString ?? "")」完成，本次用时 \(formatDuration(event["ms"]?.number ?? 0))"
                toast(.success, text)
                if !NSApp.isActive && !batchActive { notify(text) }
            }
        case "batch":
            quitIfIdleInBackground()
            batchItems = event["items"].items
            batchPaused = event["paused"].isTruthy
            scheduleProjectsReload(300)
            let unfinished = batchItems.filter { ["queued", "running"].contains($0["status"]?.string ?? "") }.count
            if !batchItems.isEmpty, unfinished == 0, !batchNotified, !NSApp.isActive {
                batchNotified = true
                notify("批量队列已全部跑完")
            }
            if unfinished > 0 { batchNotified = false }
        case "image":
            guard let dir else { return }
            let kind = event["kind"]?.string ?? ""
            if ["job-failed", "winner", "job-recovered"].contains(kind) { reloadPendingJobs() }
            if let line = activityLine(event) {
                var list = activity[dir] ?? []
                list.insert("\(clockTime(nowMs()))  \(line)", at: 0)
                activity[dir] = Array(list.prefix(60))
            }
            bump(dir)
        case "call":
            debounce("calls", 800) { [weak self] in self?.callsRevision += 1 }
        case "pdf-reexport":
            if let current = event["current"]?.string {
                pdfJob = PdfJob(index: event["index"]?.int ?? 0, total: event["total"]?.int ?? 0, current: current)
            } else {
                pdfJob = nil
            }
        default:
            break
        }
    }

    private func activityLine(_ event: JSON) -> String? {
        let screen = event["screenId"]?.jsString ?? ""
        let provider = event["providerName"]?.jsString ?? ""
        switch event["kind"]?.string ?? "" {
        case "attempt-start":
            let role = event["role"]?.string
            return "\(screen) 开始生成（\(provider)\(role == "hedge" ? "，补发" : role == "failover" ? "，切换线路" : role == "retry" ? "，重试" : "")）"
        case "hedge": return "\(screen) 超过补发线，补发到 \(provider)"
        case "winner": return "\(screen) 出图：\(provider)，\(Int(jsRound((event["durationMs"]?.number ?? 0) / 1000))) 秒"
        case "attempt-failed": return "\(screen) \(provider) 失败：\(event["message"]?.jsString ?? "")"
        case "alternate": return "\(screen) 收到一张备选图（\(provider)）"
        case "size-switched": return "\(screen) 线路不收像素尺寸，已改用 \(event["ratio"]?.jsString ?? "")"
        default: return nil
        }
    }

    // MARK: - 提示

    func toast(_ kind: Toast.Kind, _ text: String) {
        let item = Toast(kind: kind, text: text)
        withAnimation(.snappy) { toasts.append(item) }
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 6 : 3.5))
            withAnimation(.snappy) { toasts.removeAll { $0.id == item.id } }
        }
    }

    /// 执行一个操作，出错时弹出提示；成功返回 true。
    @discardableResult
    func perform(_ success: String? = nil, _ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            if let success { toast(.success, success) }
            return true
        } catch {
            toast(.error, messageOf(error))
            return false
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "软件指南生成器"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: - 导航

    func openProject(_ dir: String) {
        section = .projects
        projectPath = [dir]
    }

    func go(_ item: SidebarItem, tab: String? = nil) {
        section = item
        if item == .models, let tab { modelsTab = tab }
        if item == .settings, let tab { settingsTab = tab }
        if item == .projects { projectPath = [] }
    }

    // MARK: - 访达

    func open(_ path: String) {
        guard FS.exists(path) else {
            toast(.error, "文件不存在：\(path)")
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - 选择文件

enum Panels {
    static func chooseDirectory(_ title: String, at path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path, !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func choosePath(_ title: String, at path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let path, !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: Path.dirname(path)) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseFiles(_ title: String, extensions: [String], multiple: Bool = true) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls.map(\.path) : []
    }
}

import UniformTypeIdentifiers
