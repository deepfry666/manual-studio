import Foundation
import Testing
@testable import StudioCore

/// 不跑流程，直接造一个「已有交付包」的项目（导出测试用）。
func fakeBuiltProject(_ ctx: CoreContext, _ name: String, _ files: [String]) async throws -> String {
    let dir = try await ctx.create(name, screenCount: 2)
    let bundle = Path.join(dir, name)
    for file in files { try FS.write(Path.join(bundle, file), "\(name):\(file)") }
    try FS.write(Path.join(bundle, ".DS_Store"), "x")
    let at = isoNow()
    try await ctx.core.projectStore.update(dir) { state in
        state["status"] = "done"
        state["lastBuild"] = .obj(["at": .string(at), "files": JSON(files)])
    }
    return dir
}

@Suite("功能", .serialized)
struct FeatureTests {
    @Test("修改意见：先攒清单，整理后统一修改，只重生涉及的截图，文字要求传给大模型，留记录", .timeLimit(.minutes(2)))
    func feedback() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 40) })
        let pipeline = ctx.core.pipeline
        let dir = try await ctx.create("意见测试 V1.0", screenCount: 3)
        #expect(await ctx.run(dir).status == "done")
        let submitsBefore = ctx.relay.submits.count
        #expect(submitsBefore == 3)

        // 攒清单：同一屏两条、一条改说明、一条改封面、一条说不清
        try await pipeline.addFeedback(dir, "图2 底部按钮改成蓝色")
        try await pipeline.addFeedback(dir, "图2 再加一个筛选按钮")
        try await pipeline.addFeedback(dir, "图3 说明多写异常处理")
        try await pipeline.addFeedback(dir, "封面介绍提一下数据导出")
        let vague = try await pipeline.addFeedback(dir, "这个不太好看")
        let removable = try await pipeline.addFeedback(dir, "写错了，删掉这条")
        try await pipeline.removeFeedback(dir, removable["id"]!.string!)

        // 整理
        let plan = try await pipeline.analyzeFeedback(dir)
        var byKey: [String: JSON] = [:]
        for action in plan["actions"].items { byKey[action["key"]!.string!] = action }
        #expect(byKey.keys.sorted() == ["image:screen-02", "overview:overview", "text:screen-03"])
        #expect(byKey["image:screen-02"]?["items"]?.array?.count == 2, "同一屏两条意见合并成一个动作")
        #expect(Rx.test("蓝色.*筛选", byKey["image:screen-02"]?["instruction"]?.string ?? ""))
        #expect(byKey["image:screen-02"]?["targetLabel"]?.string == "图2「记账首页」")
        #expect(plan["questions"].items.count == 1)
        #expect(plan["questions"]?[0]?["items"] == JSON([vague["id"]!.string!]))
        let feedbackCall = ctx.llm.steps("feedback").first!
        #expect(feedbackCall.user.contains("图2（screen-02）「记账首页」"))
        #expect(!feedbackCall.user.contains("写错了"))

        // 统一修改（用户在确认框里改了一下措辞）
        let chosen = plan["actions"].items.map { action in
            action["key"]?.string == "text:screen-03" ? action.merging(["instruction": "多写异常处理和网络中断时的提示"]) : action
        }
        let applied = try await pipeline.applyFeedback(dir, actions: chosen)
        #expect(applied["images"]?.int == 1)
        #expect(applied["texts"]?.int == 2)
        #expect(await ctx.run(dir).status == "done")

        // 只重生了图2
        #expect(ctx.relay.submits.count == submitsBefore + 1)
        let prompt2 = try FS.readText(Path.join(dir, "prompts", "screen-02.md"))
        #expect(Rx.test("Revision applied: .*蓝色", prompt2))
        #expect(Rx.test("Do NOT render the software name[^\\n]*$", prompt2.jsTrimmedEnd), "品牌禁令仍在末尾")
        #expect(!(try FS.readText(Path.join(dir, "prompts", "screen-01.md"))).contains("Revision applied"))

        // 文字要求传给了写说明的大模型，并带上当前正文
        let revision = ctx.llm.steps("content").last!.user
        #expect(revision.contains("用户修改要求（必须照做）：多写异常处理和网络中断时的提示"))
        #expect(revision.contains("当前正文（在此基础上按要求修改"))
        #expect(revision.contains("封面介绍修改要求（必须照做）：封面介绍提一下数据导出"))
        #expect(revision.contains("【screen-02｜"), "图2 换了图，说明按新图重写")

        // 清单状态和溯源记录
        let project = try await ctx.project(dir)
        var statuses: [String: String] = [:]
        for item in project["state"]?["feedback"].items ?? [] { statuses[item["text"]!.string!] = item["status"]!.string! }
        #expect(statuses == ["图2 底部按钮改成蓝色": "done", "图2 再加一个筛选按钮": "done", "图3 说明多写异常处理": "done", "封面介绍提一下数据导出": "done", "这个不太好看": "pending"])
        #expect(project["state"]?["feedbackPlan"] == .null)
        let record = try readJSONFile(Path.join(dir, "generation-record.json"))
        #expect(record["feedback"].items.count == 1)
        #expect(record["feedback"]?[0]?["items"].items.count == 4)
        #expect(record["feedback"]?[0]?["actions"].items.contains { $0["type"]?.string == "image" && $0["target"]?.string == "screen-02" } == true)
        #expect(record["history"].items.contains { $0["event"]?.string == "run" && $0["reason"]?.string == "修改意见" })
        #expect(record["screens"]?["screen-02"]?["source"]?.string == "generated")

        // 没勾选任何修改时不动
        await #expect(throws: StudioError.self) { try await pipeline.applyFeedback(dir, actions: []) }
    }

    @Test("修改意见：要求整体改风格时展开成每一屏；项目没有规划时不能整理")
    func feedbackAll() async throws {
        let ctx = try await CoreContext(relayBehavior: { _, _ in RelayPlan(delayMs: 40) })
        let empty = try await ctx.create("未开始项目", screenCount: 2)
        try await ctx.core.pipeline.addFeedback(empty, "整体颜色淡一点")
        do {
            _ = try await ctx.core.pipeline.analyzeFeedback(empty)
            Issue.record("应该报错")
        } catch {
            #expect(messageOf(error).contains("还没有界面规划"))
        }
        let dir = try await ctx.create("整体测试 V1.0", screenCount: 3)
        #expect(await ctx.run(dir, RunOptions(until: "gate")).status == "idle")
        try await ctx.core.pipeline.addFeedback(dir, "整体颜色淡一点")
        let plan = try await ctx.core.pipeline.analyzeFeedback(dir)
        #expect(plan["actions"].items.map { $0["key"]!.string! } == ["image:screen-01", "image:screen-02", "image:screen-03"])
        #expect(plan["actions"].items.allSatisfy { $0["instruction"]?.string == "整体颜色淡一点" })
    }

    @Test("批量导出：每个项目一个文件夹（名字是项目名），同名文件夹先提醒，覆盖时旧的进废纸篓")
    func export() async throws {
        let ctx = try await CoreContext()
        let full = ["甲软件 V1.0指南.docx", "甲软件 V1.0指南.pdf", "甲软件 V1.0指南.txt", "甲软件 V1.0指南_代码-（JAVA）.docx", "甲软件 V1.0指南_代码-（JAVA）.pdf"]
        let a = try await fakeBuiltProject(ctx, "甲软件 V1.0", full)
        let b = try await fakeBuiltProject(ctx, "乙软件 V1.0", ["乙软件 V1.0指南.docx", "乙软件 V1.0指南.pdf", "乙软件 V1.0指南.txt"])
        let notBuilt = try await ctx.create("丙软件", screenCount: 2)
        let target = Path.join(ctx.root, "导出")

        let first = try await ctx.core.exportBundles([a, b, notBuilt], targetDir: target)
        #expect(first["exported"].items.map { $0["name"]!.string! }.sorted() == ["乙软件 V1.0", "甲软件 V1.0"])
        #expect(first["skipped"]!.serialized() == #"[{"name":"丙软件","reason":"还没有交付包"}]"#)
        #expect((FS.list(Path.join(target, "甲软件 V1.0")) ?? []).sorted() == full.sorted())
        #expect((FS.list(Path.join(target, "乙软件 V1.0")) ?? []).count == 3)
        #expect(!FS.exists(Path.join(target, "甲软件 V1.0", ".DS_Store")))
        #expect(FS.exists(Path.join(a, "甲软件 V1.0", "甲软件 V1.0指南.docx")), "原项目不动")
        #expect(try await ctx.core.getSettings().settings.export.lastDir == target)

        // 再导一次：先看计划，提示有同名文件夹
        let plan = try ctx.core.planExport([a, b], targetDir: target)
        #expect(plan["items"].items.map { $0["conflict"]!.bool! } == [true, true])
        try FS.write(Path.join(target, "乙软件 V1.0", "我的备注.txt"), "keep me")
        let skipped = try await ctx.core.exportBundles([a, b], targetDir: target, conflict: "skip")
        #expect(skipped["exported"].items.isEmpty)
        #expect(skipped["skipped"].items.allSatisfy { $0["reason"]?.string == "目标位置已有同名文件夹" })
        #expect(try FS.readText(Path.join(target, "乙软件 V1.0", "我的备注.txt")) == "keep me")

        let overwritten = try await ctx.core.exportBundles([b], targetDir: target, conflict: "overwrite")
        #expect(overwritten["exported"].items.count == 1)
        #expect(ctx.trashed.current == [Path.join(target, "乙软件 V1.0")])
        #expect(!FS.exists(Path.join(target, "乙软件 V1.0", "我的备注.txt")))
        #expect((FS.list(Path.join(target, "乙软件 V1.0")) ?? []).count == 3)
    }

    @Test("多选导出放进同一个总文件夹，总文件夹重名自动加 -2；规划确认默认关闭")
    func exportGroup() async throws {
        let ctx = try await CoreContext()
        let fresh = try await StudioCore(dataDir: Path.join(ctx.root, "fresh2"), secrets: MemorySecrets(), http: ctx.network)
        #expect(try await fresh.getSettings().settings.pipeline.reviewPlanSingle == false)
        let a = try await fakeBuiltProject(ctx, "项目A V1.0", ["项目A V1.0指南.docx", "项目A V1.0指南.txt"])
        let b = try await fakeBuiltProject(ctx, "项目B V1.0", ["项目B V1.0指南.docx", "项目B V1.0指南.txt"])
        let desktop = Path.join(ctx.root, "桌面")
        try FS.mkdirp(desktop)

        let plan = try ctx.core.planExport([a, b], targetDir: desktop, groupName: "软著导出-测试")
        #expect(plan["targetDir"]?.string == Path.join(desktop, "软著导出-测试"))
        let first = try await ctx.core.exportBundles([a, b], targetDir: desktop, groupName: "软著导出-测试")
        #expect(FS.list(desktop) == ["软著导出-测试"], "桌面上只多了一个总文件夹")
        #expect((FS.list(Path.join(desktop, "软著导出-测试")) ?? []).sorted() == ["项目A V1.0", "项目B V1.0"])
        #expect(first["targetDir"]?.string == Path.join(desktop, "软著导出-测试"))

        let second = try await ctx.core.exportBundles([a, b], targetDir: desktop, groupName: "软著导出-测试")
        #expect(second["groupFolder"]?.string == "软著导出-测试-2")
        #expect(second["exported"].items.count == 2)
        // 导出位置记的是桌面，不是总文件夹
        #expect(try await ctx.core.getSettings().settings.export.lastDir == desktop)

        // 单选：直接放在导出位置
        _ = try await ctx.core.exportBundles([a], targetDir: desktop)
        #expect(FS.exists(Path.join(desktop, "项目A V1.0", "项目A V1.0指南.docx")))
        #expect(throws: StudioError.self) { try ctx.core.planExport([a, b], targetDir: desktop, groupName: "a/b") }
    }

    @Test("在线更新：版本比较、解析发布信息、校验安装包、替换脚本")
    func updater() throws {
        #expect(Updater.isNewer("1.10.0", than: "1.9.2"))
        #expect(Updater.isNewer("v1.1.0", than: "1.0.0"))
        #expect(!Updater.isNewer("1.1.0", than: "1.1.0"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
        #expect(!Updater.isNewer("1.0.9", than: "1.1.0"))
        let digest = String(repeating: "a", count: 64)
        let json: JSON = .obj(["tag_name": "v1.2.0", "name": "软件指南生成器 1.2.0", "body": "说明", "html_url": "https://github.com/x/y/releases/tag/v1.2.0", "draft": false, "prerelease": false,
                               "assets": [.obj(["name": "-1.2.0.zip", "browser_download_url": "https://example.com/bad.zip"]),
                                          .obj(["name": "ManualStudio-1.2.0.zip", "browser_download_url": "https://example.com/ok.zip", "size": 6290174, "digest": .string("sha256:\(digest)")])]])
        let release = try #require(Updater.parseRelease(json))
        #expect(release.version == "1.2.0" && release.assetURL == "https://example.com/ok.zip" && release.sha256 == digest && release.assetSize == 6290174)
        #expect(Updater.parseRelease(json.merging(["prerelease": true])) == nil, "预发布不算")
        #expect(Updater.parseRelease(json.merging(["assets": []])) == nil, "没有安装包不算")

        // 安装包：哈希不对拒绝；包标识、版本号都要对上
        let root = try FS.makeTempDirectory(prefix: "update-")
        defer { FS.remove(root) }
        let app = Path.join(root, "src", "软件指南生成器.app")
        try FS.mkdirp(Path.join(app, "Contents"))
        (["CFBundleIdentifier": "local.manual-studio.native", "CFBundleShortVersionString": "1.2.0"] as NSDictionary).write(toFile: Path.join(app, "Contents", "Info.plist"), atomically: true)
        let zip = Path.join(root, "u.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", app, zip]
        try ditto.run(); ditto.waitUntilExit()
        #expect(throws: StudioError.self) { try Updater.extract(zip: zip, release: release, bundleId: "local.manual-studio.native", into: Path.join(root, "a")) }
        let good = Updater.Release(version: "1.2.0", title: "", notes: "", pageURL: "", assetURL: "", assetSize: 0, sha256: sha256Hex(try FS.read(zip)))
        let extracted = try Updater.extract(zip: zip, release: good, bundleId: "local.manual-studio.native", into: Path.join(root, "b"))
        #expect(Path.basename(extracted) == "软件指南生成器.app")
        #expect(throws: StudioError.self) { try Updater.extract(zip: zip, release: good, bundleId: "other.app", into: Path.join(root, "c")) }
        let wrongVersion = Updater.Release(version: "1.3.0", title: "", notes: "", pageURL: "", assetURL: "", assetSize: 0, sha256: nil)
        #expect(throws: StudioError.self) { try Updater.extract(zip: zip, release: wrongVersion, bundleId: "local.manual-studio.native", into: Path.join(root, "d")) }

        // 替换脚本：真实跑一遍（进程号用一个已经结束的），旧的被换掉，失败不会丢 App
        let target = Path.join(root, "装好的.app")
        try FS.mkdirp(Path.join(target, "Contents"))
        try FS.write(Path.join(target, "old.txt"), "old")
        let script = Updater.installScript(pid: 999_999, newApp: extracted, target: target).replacingOccurrences(of: "open '", with: ": '")
        try FS.write(Path.join(root, "install.sh"), script)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = [Path.join(root, "install.sh")]
        try sh.run(); sh.waitUntilExit()
        #expect(FS.exists(Path.join(target, "Contents", "Info.plist")))
        #expect(!FS.exists(Path.join(target, "old.txt")))
        #expect(!FS.exists(target + ".old-update"))
    }

    @Test("系统字样：软件名没指明系统时，规划、文案、设计说明里出现 iPhone/安卓 等就打回")
    func platformTerms() {
        #expect(!softwareNameNamesPlatform("云伴日程 V1.0"))
        #expect(softwareNameNamesPlatform("安卓清理大师 V1.0"))
        #expect(softwareNameNamesPlatform("iPad 手账 V1.0"))
        #expect(findPlatformTerms(["是面向 iPhone 用户的存储空间清理工具，支持 iOS 26 与安卓"]) == ["iPhone", "iOS", "安卓"])
        #expect(findPlatformTerms(["Studios 和 radios 不算；Bios 也不算"]).isEmpty, "英文单词里的片段不算")
        #expect(findPlatformTerms(["适配 iPhone 16 Pro Max 屏幕"]) == ["iPhone", "Pro Max"])
        #expect(platformProblems("云伴日程 V1.0", "功能说明", ["在手机上打开 App 即可"]).isEmpty)
        #expect(platformProblems("云伴日程 V1.0", "功能说明", ["面向 iPhone 用户"]).first?.contains("iPhone") == true)
        #expect(platformProblems("安卓清理大师 V1.0", "功能说明", ["面向安卓用户"]).isEmpty, "软件名指明了系统就允许")
        #expect(platformNeutralRule("云伴日程 V1.0").contains("不要出现 iPhone"))
        #expect(platformNeutralRule("安卓清理大师 V1.0").isEmpty)
        let plan: JSON = .obj(["profile": .obj(["domain": "存储清理", "targetUser": "iPhone 用户", "coreFlow": "扫描—清理"]), "screens": [.obj(["title": "首页", "visualBrief": "iOS 风格大标题", "mustShow": ["空间占用"], "sampleData": [], "textContract": .obj(["entry": "打开 App"])])]])
        #expect(findPlatformTerms(planVisibleTexts(plan)) == ["iPhone"], "画面描述里写界面风格不算")
    }

    @Test("PDF 字体：替换表、核对、原版已安装时不替换、记住能用的字体名")
    func fonts() {
        let xml = fontRegistryXml([FontPair(from: "新宋体", to: "华文宋体")])
        #expect(xml.contains(#"<prop oor:name="Replacement" oor:op="fuse"><value>true</value>"#))
        #expect(xml.contains(#"ReplaceFont" oor:op="fuse"><value>新宋体</value>"#))
        #expect(xml.contains(#"SubstituteFont" oor:op="fuse"><value>华文宋体</value>"#))
        #expect(!fontRegistryXml([]).contains("Replacement"))

        let stsong = FontAttempt(pairs: [], expect: SUBSTITUTES["stsong"]!.expect, alsoAllowed: nil, name: "", key: nil)
        #expect(judgePdfFonts(["STSong"], stsong).ok)
        #expect(judgePdfFonts(["ArialUnicodeMS"], stsong) == FontVerdict(ok: false, fonts: ["ArialUnicodeMS"], unexpected: ["ArialUnicodeMS"], expectedFound: false))
        #expect(!judgePdfFonts(["STSong", "YuppyTC-Regular"], stsong).ok, "混进别的中文字体也算不对")
        let courier = FontAttempt(pairs: [], expect: SUBSTITUTES["courier"]!.expect, alsoAllowed: SUBSTITUTES["courier"]!.alsoAllowed, name: "", key: nil)
        #expect(judgePdfFonts(["CourierNewPSMT", "PingFangSC-Regular"], courier).ok)
        // 替代字体缺的个别符号由系统符号字体补字，不算不对；乱抓的中文字体仍然算不对；原版模式不放行
        let pingfang = substitutionAttempts("guide", FontPlanEntry(kind: "guide", mode: "substitute", substitute: "pingfang", label: ""))[0]
        #expect(judgePdfFonts(["LucidaGrande", "PingFangSC-Regular", "PingFangSC-Semibold"], pingfang).ok)
        #expect(!judgePdfFonts(["LucidaGrande", "PingFangSC-Regular", "WeibeiSC-Bold"], pingfang).ok)
        #expect(!judgePdfFonts(["LucidaGrande", "LiberationSerif"], pingfang).ok)
        #expect(!judgePdfFonts(["STSong", "LucidaGrande"], stsong).ok)
        #expect(judgePdfFonts(["HiraginoSans-W3", "PingFangSC-Regular", "PingFangSC-Semibold"], pingfang).ok, "冬青黑体补个别符号")
        #expect(!judgePdfFonts(["HiraMinProN-W3", "PingFangSC-Regular"], pingfang).ok, "明朝体不在补字名单里")
        #expect(!judgePdfFonts(["HiraginoSans-W3", "LucidaGrande"], pingfang).ok, "正文没用上苹方")

        let missing = resolveFontPlan(PdfSettings(), families: ["PingFang SC", "STSong"])
        #expect(missing["guide"]?.mode == "substitute")
        #expect(missing["code"]?.label == "华文宋体")
        let installed = resolveFontPlan(PdfSettings(), families: ["Microsoft YaHei", "NSimSun"])
        #expect(installed["guide"]?.mode == "original")
        #expect(installed["code"]?.label == "新宋体")
        #expect(substitutionAttempts("code", installed["code"])[0].pairs.isEmpty)
        var bogusSettings = PdfSettings()
        bogusSettings.guide = "courier"
        #expect(resolveFontPlan(bogusSettings, families: [])["guide"]?.substitute == "pingfang", "不在可选范围的设置回到默认")
        let attempts = substitutionAttempts("guide", missing["guide"])
        #expect(attempts.map(\.name) == ["苹方-简", "PingFang SC"])
        #expect(attempts[0].pairs.map(\.from) == ["Microsoft YaHei", "微软雅黑"])
        rememberWorkingName("pingfang", "PingFang SC")
        #expect(substitutionAttempts("guide", missing["guide"])[0].name == "PingFang SC")
        rememberWorkingName("pingfang", "苹方-简")
    }

    @Test("小工具：版本号识别、用时格式、代码来源锁定规则")
    func helpers() throws {
        #expect(detectVersion("云伴日程 V1.0") == "V1.0")
        #expect(detectVersion("掌上游戏辅助器免费 V1.0.0") == "V1.0.0")
        #expect(detectVersion("警车驾驶狂飙1.0") == "1.0")
        #expect(detectVersion("3D世界贪吃蛇") == nil)
        #expect(detectVersion("123违章助手速答") == nil)
        #expect(formatDuration(42_000) == "42秒")
        #expect(formatDuration(250_000) == "4分10秒")
        #expect(formatDuration(3_720_000) == "1小时2分")
        var settings = Settings()
        settings.codeSource = CodeSourceSetting(path: "/code/new", extensions: [".kt"])
        let fresh: JSON = ["request": ["codeSource": nil], "origin": "created"]
        let freshResult = codeSourceFor(fresh, settings)
        #expect(freshResult.source == JSON.obj(["path": "/code/new", "extensions": [".kt"]]))
        #expect(!freshResult.locked)
        let built: JSON = ["request": ["codeSource": ["path": "/code/old", "extensions": [".java"]], "codeSourceLocked": true], "origin": "created"]
        #expect(codeSourceFor(built, settings).source?["path"]?.string == "/code/old")
        let legacyBuilt: JSON = ["request": ["codeSource": nil], "origin": "created", "lastBuild": ["at": "x"]]
        #expect(codeSourceFor(legacyBuilt, settings).source == nil, "以前建好的项目视为已锁定")
        let imported: JSON = ["request": ["codeSource": nil], "origin": "imported"]
        #expect(codeSourceFor(imported, settings).locked)
    }
}
