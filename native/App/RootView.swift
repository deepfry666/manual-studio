import StudioCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .starting:
                ProgressView("正在启动…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .askMigration:
                MigrationWelcomeView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("启动失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await model.launchCore() } }
                }
            case .ready:
                MainSplitView()
            }
        }
        .overlay(alignment: .top) { ToastOverlay(toasts: model.toasts) }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }), presenting: model.alert) { item in
            if let actionTitle = item.actionTitle, let action = item.action {
                Button(actionTitle) { action() }
                Button("关闭", role: .cancel) {}
            } else {
                Button("好") {}
            }
        } message: { item in
            Text(item.message)
        }
    }
}

struct MainSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 280)
        } detail: {
            Group {
                switch model.section ?? .projects {
                case .new:
                    NavigationStack { NewProjectView() }
                case .projects:
                    NavigationStack(path: $model.projectPath) {
                        ProjectsView()
                            .navigationDestination(for: String.self) { dir in
                                ProjectDetailView(dir: dir)
                            }
                    }
                case .models:
                    NavigationStack { ModelsView() }
                case .settings:
                    NavigationStack { SettingsView() }
                }
            }
            .overlay(alignment: .bottom) { PendingJobsNotice() }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.section) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(item == .projects ? runningCount : 0)
                        .tag(item)
                }
            } header: {
                HStack(spacing: 10) {
                    Image("Logo")
                        .resizable()
                        .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("软件指南生成器").font(.headline).foregroundStyle(.primary)
                        Text("截图 · 文案 · 交付包").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("v\(model.appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .onChange(of: model.section) { _, next in
            if next == .projects { model.projectPath = [] }
        }
    }

    var runningCount: Int { model.projects.filter { $0.status == "running" }.count }
}

/// 提交途中退出、不确定是否已扣费的生图任务。
struct PendingJobsNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.unknownJobs
        if !jobs.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("有 \(jobs.count) 个生图任务在提交途中软件退出了，不确定中转站是否已经扣费").fontWeight(.semibold)
                    Text("这些屏会在下次运行时重新生成。如果你在中转站后台确认已出图，可以忽略。").font(.callout).foregroundStyle(.secondary)
                }
                Button("知道了") {
                    Task {
                        for job in jobs { await model.core?.dismissJob(job["jobId"]?.string ?? "") }
                        model.reloadPendingJobs()
                    }
                }
                .buttonStyle(.glass)
            }
            .padding(16)
            .frame(maxWidth: 640)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .padding(20)
        }
    }
}

/// 第一次打开：可以把 Electron 旧版的设置、线路、密钥和项目一次导入。
struct MigrationWelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var busy = false

    var body: some View {
        VStack(spacing: 22) {
            Image("Logo").resizable().frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("欢迎使用软件指南生成器").font(.largeTitle.weight(.semibold))
                Text("发现了 Electron 旧版的数据，可以一次导入，接着用。").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label("设置、生图线路、大模型和各步骤用的模型", systemImage: "gearshape.2")
                Label("密钥（需要在系统弹窗里点「允许」读取 Electron 旧版的钥匙串项）", systemImage: "key")
                Label("项目列表和每个项目的进度、用时、修改意见", systemImage: "square.grid.2x2")
                Label("调用记录（补发线按历史耗时计算）", systemImage: "chart.bar")
            }
            .padding(18)
            .frame(width: 520, alignment: .leading)
            .cardBackground()
            Text("项目文件夹新旧两版共用，不复制、不改动；Electron 旧版的数据只读取，不修改。")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("不导入，全新开始") {
                    busy = true
                    Task { await model.finishMigrationChoice(importData: false) }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Button {
                    busy = true
                    Task { await model.finishMigrationChoice(importData: true) }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("导入 Electron 旧版的数据") }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .disabled(busy)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
