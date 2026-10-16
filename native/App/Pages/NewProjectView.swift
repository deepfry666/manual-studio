import StudioCore
import SwiftUI

struct NewProjectView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = "single"

    var body: some View {
        PageScroll(maxWidth: 1100) {
            if mode == "single" {
                SingleProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform)
                    .id(model.settingsRevision)
            } else {
                BatchProjectForm(defaultScreens: model.settings.pipeline.defaultScreenCount, defaultPlatform: model.settings.pipeline.platform)
                    .id(model.settingsRevision)
            }
        }
        .navigationTitle("新建项目")
        .onChange(of: model.devNewMode) { _, next in if let next { mode = next } }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $mode) {
                    Text("单个项目").tag("single")
                    Text("批量新建").tag("batch")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

struct CodeSourceRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsRow(label: "代码来源", info: "在「设置 → 代码来源」里统一设置，所有项目共用。没有代码来源时交付包只有说明书 3 个文件。") {
            PathText(path: model.settings.codeSource.path, empty: "未设置（只出说明书）")
            Button("更改") { model.go(.settings, tab: "code") }.buttonStyle(.borderless)
        }
    }
}

/// 内容日期（截图里的「今天」）和最早日期（历史记录最早到哪天）。
struct ContentDateRows: View {
    @Binding var contentDate: String
    @Binding var earliestDate: String

    var body: some View {
        SettingsRow(label: "内容日期", hint: "截图里的「今天」，默认新建当天") {
            TextField(localDateKey(), text: $contentDate).textFieldStyle(.roundedBorder).frame(width: 150)
        }
        SettingsRow(label: "最早日期", hint: "选填；不填时历史记录只在内容日期前 \(DEFAULT_HISTORY_DAYS) 天内", info: "可填企业成立日期或开发完成日期。截图和正文里的流水、订单、动态等历史记录不会早于这一天；预约、截止等未来安排不受限。") {
            TextField("YYYY-MM-DD", text: $earliestDate).textFieldStyle(.roundedBorder).frame(width: 150)
        }
    }
}

struct ScreenCountRow: View {
    var hint: String? = nil
    @Binding var autoCount: Bool
    @Binding var screenCount: Int

    var body: some View {
        SettingsRow(label: "截图数", hint: hint) {
            Picker("", selection: $autoCount) {
                Text("固定").tag(false)
                Text("按功能决定").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if !autoCount {
                NumberField(value: screenCount, range: 2...15, suffix: "屏", width: 44) { screenCount = $0 }
            }
        }
    }
}

struct SingleProjectForm: View {
    let defaultScreens: Int
    let defaultPlatform: String
    @Environment(AppModel.self) private var model
    @State private var name = ""
    // 默认固定屏数（设置里的「默认截图数」，默认 7），也可以改成让大模型按功能决定
    @State private var autoCount = false
    @State private var screenCount = 7
    @State private var emphasis = ""
    @State private var notes = ""
    @State private var platform = ""
    @State private var wantDesign = false
    @State private var contentDate = localDateKey()
    @State private var earliestDate = ""
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let version = detectVersion(name)
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SettingsGroup(title: "基本信息") {
                    SettingsRow(label: "软件名", hint: name.jsTrimmed.isEmpty ? "含版本号，按原样填写" : version.map { "识别到版本号 \($0)" } ?? "没有版本号", info: "只用于文件名、文档标题和页眉，截图里不会出现软件名和版本号。") {
                        TextField("例如：云伴日程 V1.0", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                            .focused($nameFocused)
                            .onSubmit { submit(runNow: true) }
                    }
                    ScreenCountRow(autoCount: $autoCount, screenCount: $screenCount)
                    SettingsRow(label: "重点功能") {
                        TextField("可选，例如：违章查询、在线缴费", text: $emphasis).textFieldStyle(.roundedBorder).frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                    }
                    SettingsRow(label: "补充说明") {
                        TextField("可选，目标用户、风格偏好等", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4).frame(minWidth: 160, idealWidth: 320, maxWidth: 320)
                    }
                }
                SettingsGroup(title: "生成选项") {
                    SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                        Picker("", selection: $platform) {
                            ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(width: 240, alignment: .trailing)
                    }
                    ContentDateRows(contentDate: $contentDate, earliestDate: $earliestDate)
                    SettingsRow(label: "设计说明章节") {
                        Toggle("", isOn: $wantDesign).toggleStyle(.switch).labelsHidden()
                    }
                    CodeSourceRow()
                }
            }
            HStack {
                Spacer()
                Button("只创建") { submit(runNow: false) }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                Button("创建并开始") { submit(runNow: true) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(busy)
        }
        .onAppear {
            screenCount = defaultScreens
            platform = PLATFORMS.contains { $0.value == defaultPlatform } ? defaultPlatform : PLATFORMS[0].value
            contentDate = localDateKey()
            nameFocused = true
        }
    }

    func submit(runNow: Bool) {
        guard !name.jsTrimmed.isEmpty else {
            model.toast(.warning, "请填写软件名")
            return
        }
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let dir = try await core.createProject(.obj([
                    "softwareName": .string(name.jsTrimmed), "screenCount": autoCount ? .null : .number(Double(screenCount)),
                    "emphasis": .string(emphasis), "notes": .string(notes), "platform": .string(platform), "wantDesign": .bool(wantDesign),
                    "contentDate": .string(contentDate.jsTrimmed), "earliestDate": .string(earliestDate.jsTrimmed),
                ]))
                if runNow { core.run(dir) }
                await model.reloadProjects()
                name = ""
                emphasis = ""
                notes = ""
                model.openProject(dir)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}

struct BatchProjectForm: View {
    let defaultScreens: Int
    let defaultPlatform: String
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var autoCount = false
    @State private var screenCount = 7
    @State private var platform = ""
    @State private var wantDesign = false
    @State private var contentDate = localDateKey()
    @State private var earliestDate = ""
    @State private var startNow = true
    @State private var busy = false

    var count: Int {
        Rx.split(#"\r?\n"#, text).filter { line in
            let trimmed = line.jsTrimmed
            return !trimmed.isEmpty && !Rx.test("^(软件名|名称|name)[,，\\t]", trimmed, "i")
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                SettingsGroup(title: "软件名（每行一个，已填 \(count) 个）", footer: "也可以在名字后面用逗号带上：截图数,重点功能,补充说明", trailing: AnyView(
                    Button("从文件读取…") {
                        if let file = Panels.chooseFiles("选择 CSV 或文本文件", extensions: ["csv", "txt", "tsv"], multiple: false).first {
                            text = FS.readTextIfExists(file) ?? ""
                        }
                    }
                    .buttonStyle(.borderless)
                )) {
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("云伴日程 V1.0\n快记账本 V1.0,7,预算提醒\n掌上违章助手 V1.0").foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                        }
                        TextEditor(text: $text).font(.body).scrollContentBackground(.hidden).frame(minHeight: 260)
                    }
                    .padding(8)
                }
                SettingsGroup(title: "生成选项") {
                    ScreenCountRow(hint: "没在列表里写截图数的项目", autoCount: $autoCount, screenCount: $screenCount)
                    SettingsRow(label: "截图样式", hint: "仅决定界面样式，文档省略运行平台") {
                        Picker("", selection: $platform) {
                            ForEach(PLATFORMS, id: \.value) { Text($0.label).tag($0.value) }
                        }
                        .labelsHidden()
                        .frame(width: 240, alignment: .trailing)
                    }
                    ContentDateRows(contentDate: $contentDate, earliestDate: $earliestDate)
                    SettingsRow(label: "设计说明章节") { Toggle("", isOn: $wantDesign).toggleStyle(.switch).labelsHidden() }
                    CodeSourceRow()
                    SettingsRow(label: "创建后直接开始", hint: "不停下确认规划") {
                        Toggle("", isOn: $startNow).toggleStyle(.switch).labelsHidden()
                    }
                    // 默认就是设置里的值；在这里改会同时改设置，正在跑的批量也立刻按新值调整
                    SettingsRow(label: "同时处理项目", hint: "不限：全部同时开跑") {
                        ConcurrencyPicker(value: model.settings.pipeline.batchConcurrency, presets: PROJECT_CONCURRENCY_PRESETS, unit: "个") { model.saveSettings(["pipeline": ["batchConcurrency": .number(Double($0))]]) }
                    }
                    SettingsRow(label: "生图并发上限", hint: "所有项目合计；不限时只受每条线路自己的上限约束") {
                        ConcurrencyPicker(value: model.settings.image.globalConcurrency, presets: IMAGE_CONCURRENCY_PRESETS, unit: "张") { model.saveSettings(["image": ["globalConcurrency": .number(Double($0))]]) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("创建 \(count > 0 ? "\(count) " : "")个项目") { submit() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(busy || count == 0)
            }
        }
        .onAppear {
            screenCount = defaultScreens
            platform = PLATFORMS.contains { $0.value == defaultPlatform } ? defaultPlatform : PLATFORMS[0].value
            contentDate = localDateKey()
        }
    }

    func submit() {
        guard let core = model.core else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await core.createProjectsFromList(text, screenCount: autoCount ? nil : screenCount, platform: platform, wantDesign: wantDesign, contentDate: contentDate.jsTrimmed, earliestDate: earliestDate.jsTrimmed)
                if startNow, !result.created.isEmpty { await core.batch.enqueue(result.created) }
                text = ""
                await model.reloadProjects()
                if result.errors.isEmpty {
                    model.toast(.success, "已创建 \(result.created.count) 个项目")
                } else {
                    model.alert = AlertItem(title: "创建了 \(result.created.count) 个，\(result.errors.count) 个没有创建", message: result.errors.joined(separator: "\n"))
                }
                model.go(.projects)
            } catch {
                model.toast(.error, messageOf(error))
            }
        }
    }
}
