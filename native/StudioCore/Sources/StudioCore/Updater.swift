import Foundation

/// 在线更新：从 GitHub Releases 查最新版本，下载 zip、校验、解出 App。替换和重启由界面层做（要退出自己）。
public enum Updater {
    public static let repo = "deepfry666/manual-studio"
    public static let latestURL = "https://api.github.com/repos/\(repo)/releases/latest"
    /// 发版脚本上传的附件名（GitHub 会去掉中文，所以是英文名）
    public static let assetPattern = #"^ManualStudio-[0-9]+\.[0-9]+\.[0-9]+\.zip$"#

    public struct Release: Sendable, Equatable {
        public let version: String
        public let title: String
        public let notes: String
        public let pageURL: String
        public let assetURL: String
        public let assetSize: Int
        /// GitHub 给的附件 SHA-256（没有时为 nil，只校验解出来的 App）
        public let sha256: String?
    }

    /// 版本号比较：1.10.0 > 1.9.2；缺的段按 0 算。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            Rx.replace("^[vV]", in: value.jsTrimmed, with: "").split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 解析 releases/latest 的返回；草稿、预发布、没有安装包的都不算。
    public static func parseRelease(_ json: JSON) -> Release? {
        guard !json["draft"].isTruthy, !json["prerelease"].isTruthy, let tag = json["tag_name"]?.string, Rx.test(#"^v?[0-9]+(\.[0-9]+)*$"#, tag) else { return nil }
        guard let asset = json["assets"].items.first(where: { Rx.test(assetPattern, $0["name"].text) }), let url = asset["browser_download_url"]?.string else { return nil }
        let digest = asset["digest"]?.string.flatMap { Rx.match("^sha256:([0-9a-f]{64})$", $0)?[1] }
        return Release(
            version: Rx.replace("^v", in: tag, with: ""),
            title: json["name"]?.string ?? tag,
            notes: json["body"]?.string ?? "",
            pageURL: json["html_url"]?.string ?? "https://github.com/\(repo)/releases",
            assetURL: url,
            assetSize: asset["size"]?.int ?? 0,
            sha256: digest
        )
    }

    /// 查最新版本；比当前新就返回，否则 nil。
    public static func check(currentVersion: String, http: HTTPClient = URLSessionHTTPClient()) async throws -> Release? {
        let response = try await http.send(HTTPRequest(url: latestURL, headers: ["Accept": "application/vnd.github+json", "User-Agent": "ManualStudio/\(currentVersion)"], timeout: 20))
        if response.status == 404 { return nil } // 还没有发过版
        guard response.status == 200 else { throw StudioError("检查更新失败（HTTP \(response.status)）") }
        guard let json = try? JSON.parse(response.body), let release = parseRelease(json) else { throw StudioError("检查更新失败：发布信息看不懂") }
        return isNewer(release.version, than: currentVersion) ? release : nil
    }

    /// 校验下载的 zip 并解出 App：哈希一致、包标识一致、版本号就是要装的版本。返回解出来的 .app 路径。
    public static func extract(zip: String, release: Release, bundleId: String, into dir: String) throws -> String {
        if let expected = release.sha256 {
            let actual = sha256Hex(try FS.read(zip))
            guard actual == expected else { throw StudioError("下载的安装包校验不通过，请重试") }
        }
        try FS.mkdirp(dir)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip, dir]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw StudioError("解压安装包失败") }
        guard let name = (FS.list(dir) ?? []).first(where: { $0.hasSuffix(".app") }) else { throw StudioError("安装包里没有 App") }
        let app = Path.join(dir, name)
        let info = NSDictionary(contentsOfFile: Path.join(app, "Contents", "Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleId else { throw StudioError("安装包不是这个软件") }
        guard info?["CFBundleShortVersionString"] as? String == release.version else { throw StudioError("安装包版本和发布信息不一致") }
        return app
    }

    /// 替换脚本：等当前进程退出 → 旧 App 挪开 → 新 App 放进去 → 打开新 App；失败时放回旧的。
    /// 等当前进程退出后重新打开 App（不替换）。
    public static func relaunchScript(pid: Int32, target: String, relaunchEnv: [String: String] = [:]) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let envArgs = relaunchEnv.sorted { $0.key < $1.key }.map { "--env \(quote("\($0.key)=\($0.value)")) " }.joined()
        return "#!/bin/sh\nwhile kill -0 \(pid) 2>/dev/null; do sleep 0.3; done\nopen \(envArgs)\(quote(target))\n"
    }

    /// relaunchEnv：重新打开时带上的环境变量（开发自检时把软件数据目录指到临时位置，正常使用为空）。
    public static func installScript(pid: Int32, newApp: String, target: String, relaunchEnv: [String: String] = [:]) -> String {
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let envArgs = relaunchEnv.sorted { $0.key < $1.key }.map { "--env \(quote("\($0.key)=\($0.value)")) " }.joined()
        let backup = target + ".old-update"
        return """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(quote(backup))
        if mv \(quote(target)) \(quote(backup)) && mv \(quote(newApp)) \(quote(target)); then
          rm -rf \(quote(backup))
          xattr -dr com.apple.quarantine \(quote(target)) 2>/dev/null
        else
          [ -d \(quote(backup)) ] && [ ! -d \(quote(target)) ] && mv \(quote(backup)) \(quote(target))
        fi
        open \(envArgs)\(quote(target))

        """
    }
}
