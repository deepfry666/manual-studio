import Foundation

/// 默认的总文件夹名：软著导出-20261009-1930
public func defaultGroupName(_ date: Date = Date()) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    func pad(_ value: Int?) -> String { String(value ?? 0).padStart(2) }
    return "软著导出-\(c.year!)\(pad(c.month))\(pad(c.day))-\(pad(c.hour))\(pad(c.minute))"
}

/// 交付包里要导出的文件：说明书 docx/pdf/txt，代码文档 docx/pdf（有代码来源时才有）。
func deliveryFiles(_ bundleDir: String) -> [String] {
    (FS.list(bundleDir) ?? []).filter { name in
        !name.hasPrefix(".") && FS.isFile(Path.join(bundleDir, name)) && Rx.test("\\.(docx|pdf|txt)$", name, "i")
    }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
}

/// 实际导出到哪里：多选时在导出位置下面建一个总文件夹（重名就加 -2、-3），单选时直接放在导出位置。
public func resolveExportRoot(_ targetDir: String, _ groupName: String) throws -> (root: String, groupFolder: String?) {
    guard !targetDir.isEmpty, Path.isAbsolute(targetDir) else { throw StudioError("请选择导出位置") }
    let name = groupName.jsTrimmed
    if name.isEmpty { return (targetDir, nil) }
    try assertSafeSoftwareName(name)
    var candidate = name
    var index = 2
    while FS.exists(Path.join(targetDir, candidate)) {
        candidate = "\(name)-\(index)"
        index += 1
    }
    return (Path.join(targetDir, candidate), candidate)
}

/// 导出前先看一遍：每个项目能不能导、导出哪些文件、目标位置有没有同名文件夹。
/// 文件夹名就是项目名（软件名）。
public func planExport(dirs: [String], targetDir baseDir: String, projectStore: ProjectStore, groupName: String = "") throws -> JSON {
    let (targetDir, groupFolder) = try resolveExportRoot(baseDir, groupName)
    var items: [JSON] = []
    var names = Set<String>()
    for dir in dirs {
        let state = try? projectStore.read(dir)
        let name = state?["request"]?["softwareName"].truthyValue?.jsString ?? Path.basename(dir)
        var item: JSON = .obj(["dir": .string(dir), "name": .string(name), "folder": .string(Path.join(targetDir, name)), "files": [], "ok": false, "reason": .null, "conflict": false, "warnings": []])
        defer { items.append(item) }
        guard let state else {
            item["reason"] = "项目状态不存在"
            continue
        }
        do {
            try assertSafeSoftwareName(name)
        } catch {
            item["reason"] = .string(messageOf(error))
            continue
        }
        if names.contains(name) {
            item["reason"] = "这次导出里已经有同名项目"
            continue
        }
        let bundleDir = projectPaths(dir).bundle(name)
        let files = deliveryFiles(bundleDir)
        item["files"] = JSON(files)
        if !files.contains(where: { $0.hasSuffix("指南.docx") }) {
            item["reason"] = "还没有交付包"
            continue
        }
        if Path.resolve(Path.join(targetDir, name)) == Path.resolve(bundleDir) {
            item["reason"] = "导出位置就是这个项目的交付文件夹"
            continue
        }
        names.insert(name)
        item["ok"] = true
        item["conflict"] = .bool(FS.exists(Path.join(targetDir, name)))
        var warnings: [String] = []
        if state["status"]?.string != "done", state["origin"]?.string != "imported" { warnings.append("项目还有步骤没完成，导出的是上一次生成的交付包") }
        if state["lastBuild"]?["pdfFonts"].fields.values.contains(where: { $0.isObject && $0["ok"] == .bool(false) }) ?? false { warnings.append("PDF 字体不对，建议先「重新导出 PDF」") }
        if !files.contains(where: { $0.hasSuffix(".pdf") }) { warnings.append("没有 PDF") }
        item["warnings"] = JSON(warnings)
    }
    return .obj(["targetDir": .string(targetDir), "groupFolder": JSON.orNull(groupFolder), "items": .array(items)])
}

/// 导出：每个项目一个文件夹（名字就是项目名），里面是交付的 5 个或 3 个文件。只复制，不动原项目。
/// groupName 不为空时（多选导出），这些项目文件夹都放进导出位置下的同一个总文件夹。
/// 目标位置已有同名文件夹时按 conflict 处理：skip 跳过；overwrite 把旧文件夹移到废纸篓（没有废纸篓时改名留底）后再导出。
public func exportBundles(dirs: [String], targetDir baseDir: String, projectStore: ProjectStore, conflict: String = "skip", groupName: String = "", trashItem: ((String) throws -> Void)? = nil) throws -> JSON {
    let plan = try planExport(dirs: dirs, targetDir: baseDir, projectStore: projectStore, groupName: groupName)
    let targetDir = plan["targetDir"]?.string ?? baseDir
    try FS.mkdirp(targetDir)
    var exported: [JSON] = []
    var skipped: [JSON] = []
    for item in plan["items"].items {
        let name = item["name"]?.jsString ?? ""
        guard item["ok"].isTruthy else {
            skipped.append(.obj(["name": .string(name), "reason": item["reason"] ?? .null]))
            continue
        }
        let folder = item["folder"]?.jsString ?? ""
        if item["conflict"].isTruthy {
            if conflict != "overwrite" {
                skipped.append(.obj(["name": .string(name), "reason": "目标位置已有同名文件夹"]))
                continue
            }
            if let trashItem {
                try trashItem(folder)
            } else {
                try FS.move(folder, "\(folder)-旧-\(timestampSlug())")
            }
        }
        let bundleDir = projectPaths(item["dir"]?.jsString ?? "").bundle(name)
        let staging = "\(folder).导出中-\(ProcessInfo.processInfo.processIdentifier)"
        FS.remove(staging)
        do {
            try FS.mkdirp(staging)
            for file in item["files"].items.map(\.jsString) { try FileManager.default.copyItem(atPath: Path.join(bundleDir, file), toPath: Path.join(staging, file)) }
            try FS.move(staging, folder)
        } catch {
            FS.remove(staging)
            skipped.append(.obj(["name": .string(name), "reason": .string(messageOf(error))]))
            continue
        }
        exported.append(.obj(["name": .string(name), "folder": .string(folder), "files": item["files"] ?? [], "warnings": item["warnings"] ?? []]))
    }
    // 总文件夹里一个都没导出时，不留下空文件夹
    if plan["groupFolder"]?.string != nil, exported.isEmpty { rmdir(targetDir) }
    return .obj(["targetDir": .string(targetDir), "groupFolder": plan["groupFolder"] ?? .null, "exported": .array(exported), "skipped": .array(skipped)])
}
