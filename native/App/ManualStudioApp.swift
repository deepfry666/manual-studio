import AppKit
import StudioCore
import SwiftUI

@main
struct ManualStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // 只开一个窗口：两个窗口同时写同一份数据会出错
        Window("软件指南生成器", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1120, minHeight: 720)
                .task {
                    delegate.model = model
                    await model.start()
                }
        }
        .defaultSize(width: 1440, height: 920)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建项目") { model.go(.new) }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { model.go(.settings) }
                    .keyboardShortcut(",")
            }
            CommandMenu("前往") {
                Button("新建项目") { model.go(.new) }.keyboardShortcut("1")
                Button("历史项目") { model.go(.projects) }.keyboardShortcut("2")
                Button("模型与线路") { model.go(.models) }.keyboardShortcut("3")
                Button("设置") { model.go(.settings) }.keyboardShortcut("4")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    /// 关窗：没有任务就退出；有任务在跑就留在后台继续跑，点程序坞图标重新打开窗口，跑完自动退出。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard let model, model.hasBackgroundWork else { return true }
        model.notify("窗口已关闭，任务在后台继续运行；点程序坞里的图标可以重新打开，全部跑完后自动退出。")
        return false
    }

    /// 主动退出（⌘Q）时还有项目在运行，先确认。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model?.core?.pipeline.runningProjects() ?? []
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "还有 \(running.count) 个项目在运行"
        alert.informativeText = "只想关掉窗口的话，点窗口左上角的关闭按钮，任务会在后台继续跑。\n\n现在退出：批量队列里的项目下次打开会自动接着跑；已经提交的异步生图任务下次打开会继续查询，不会重复提交；单独运行的项目要再点一次「继续运行」，已完成的步骤不会重做。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
