import Foundation

public struct ProcessResult: Sendable {
    public let code: Int32?
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
}

/// 运行外部程序（异步，不卡界面），超时就强制结束。
public func runProcess(_ executable: String, _ arguments: [String], timeoutSec: Double = 600, environment: [String: String]? = nil) async throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let output = Locked((out: Data(), err: Data()))
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        output.withLock { $0.out.append(chunk) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        output.withLock { $0.err.append(chunk) }
    }
    let timedOut = Locked(false)
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            process.terminationHandler = { finished in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let restOut = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? nil
                let restErr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? nil
                let collected = output.withLock { state -> (Data, Data) in
                    if let restOut { state.out.append(restOut) }
                    if let restErr { state.err.append(restErr) }
                    return (state.out, state.err)
                }
                let killed = timedOut.current
                continuation.resume(returning: ProcessResult(
                    code: killed || finished.terminationReason == .uncaughtSignal ? nil : finished.terminationStatus,
                    stdout: String(decoding: collected.0, as: UTF8.self),
                    stderr: String(decoding: collected.1, as: UTF8.self),
                    timedOut: killed
                ))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec) {
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    kill(pid, SIGKILL)
                }
            }
        }
    } onCancel: {
        if process.isRunning { process.terminate() }
    }
}

// MARK: - LibreOffice

func sofficeCandidates() -> [String] {
    if let override = ProcessInfo.processInfo.environment["MS_SOFFICE"], !override.isEmpty { return [override] }
    var candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice", Path.join(NSHomeDirectory(), "Applications/LibreOffice.app/Contents/MacOS/soffice")]
    let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
    // App 从访达打开时 PATH 很短，把常见的安装位置也找一遍
    let dirs = pathEnv.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", Path.join(NSHomeDirectory(), ".local/bin")]
    for dir in dirs where !dir.isEmpty { candidates.append(Path.join(dir, "soffice")) }
    return uniqued(candidates)
}

private let sofficeCache = Locked<String??>(nil)

/// 找到并确认 LibreOffice 可用；找不到返回 nil（构建走无 PDF 模式）。
public func findLibreOffice() async -> String? {
    if let cached = sofficeCache.current { return cached }
    guard let candidate = sofficeCandidates().first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        sofficeCache.withLock { $0 = .some(nil) }
        return nil
    }
    let probe = try? await runProcess(candidate, ["--headless", "--nologo", "--nodefault", "--version"], timeoutSec: 30)
    let found: String? = probe?.code == 0 ? candidate : nil
    sofficeCache.withLock { $0 = .some(found) }
    return found
}

public func resetLibreOfficeCache() { sofficeCache.withLock { $0 = nil } }

/// LibreOffice 同时开多个容易出错，这里排队一个个转。
private let pdfQueue = SerialQueue()

/// DOCX → PDF。fontPairs：这次转换用的字体替换表（写进临时配置目录，不影响平时使用的 LibreOffice）。
public func convertToPdf(_ docxPath: String, outDir: String, fontPairs: [FontPair] = []) async throws -> String {
    try await pdfQueue.run {
        guard let soffice = await findLibreOffice() else { throw StudioError("没有找到 LibreOffice") }
        let pdfPath = Path.join(outDir, "\(Path.basename(docxPath, Path.extname(docxPath))).pdf")
        FS.remove(pdfPath)
        let profile = try FS.makeTempDirectory(prefix: "manual-studio-lo-")
        defer { FS.remove(profile) }
        try FS.mkdirp(Path.join(profile, "user"))
        try FS.write(Path.join(profile, "user", "registrymodifications.xcu"), fontRegistryXml(fontPairs))
        let profileUri = "file:///" + Rx.replace("^/+", in: profile, with: "").replacingOccurrences(of: " ", with: "%20")
        let arguments = ["--headless", "--nologo", "--nodefault", "--nolockcheck", "-env:UserInstallation=\(profileUri)", "--convert-to", "pdf", "--outdir", outDir, docxPath]
        for attempt in 0..<2 {
            let result = try await runProcess(soffice, arguments, timeoutSec: 5 * 60)
            if result.code == 0, (FS.size(pdfPath) ?? 0) > 0 { return pdfPath }
            if attempt == 1 { throw StudioError("PDF 转换失败：\((result.stderr.isEmpty ? result.stdout : result.stderr).jsSlice(-400))") }
        }
        return pdfPath
    }
}

public struct PdfFontResult: Sendable, Hashable {
    public let pdfPath: String
    public let ok: Bool
    public let fonts: [String]
    public let unexpected: [String]
    public let expectedFound: Bool
    public let intended: String
    public let mode: String

    public var summary: JSON {
        .obj(["ok": .bool(ok), "intended": .string(intended), "mode": .string(mode), "fonts": JSON(fonts)])
    }
}

/// 转 PDF 并核对字体：按替换方案依次尝试（中文系统和英文系统里字体名不一样），
/// 第一个核对通过的就用；都不通过时保留最好的一次（用上了预期字体、多出来的字体最少），并说明用了什么字体。
public func convertToPdfChecked(_ docxPath: String, outDir: String, kind: String, fontPlan: [String: FontPlanEntry]?) async throws -> PdfFontResult {
    let attempts = substitutionAttempts(kind, fontPlan?[kind])
    var best: (result: PdfFontResult, copy: String?)?
    let keepDir = attempts.count > 1 ? try FS.makeTempDirectory(prefix: "manual-studio-pdf-") : nil
    defer { if let keepDir { FS.remove(keepDir) } }
    for (index, attempt) in attempts.enumerated() {
        let pdfPath = try await convertToPdf(docxPath, outDir: outDir, fontPairs: attempt.pairs)
        let verdict = judgePdfFonts(try pdfFontNames(pdfPath), attempt)
        let result = PdfFontResult(pdfPath: pdfPath, ok: verdict.ok, fonts: verdict.fonts, unexpected: verdict.unexpected, expectedFound: verdict.expectedFound, intended: attempt.name, mode: fontPlan?[kind]?.mode ?? "original")
        if verdict.ok {
            rememberWorkingName(attempt.key, attempt.name)
            return result
        }
        let better = best.map { current in
            (result.expectedFound && !current.result.expectedFound) || (result.expectedFound == current.result.expectedFound && result.unexpected.count < current.result.unexpected.count)
        } ?? true
        if better {
            // 后面的方案会覆盖同名 PDF，先留一份
            var copy: String?
            if let keepDir, index < attempts.count - 1 {
                copy = Path.join(keepDir, "\(index).pdf")
                try FS.copy(pdfPath, copy!)
            }
            best = (result, copy)
        }
    }
    let chosen = best!
    if let copy = chosen.copy {
        FS.remove(chosen.result.pdfPath)
        try FS.copy(copy, chosen.result.pdfPath)
    }
    return chosen.result
}

/// 粗略统计 PDF 页数（LibreOffice 生成的 PDF 页对象不压缩，可以直接数）。
public func countPdfPages(_ pdfPath: String) -> Int? {
    guard let data = try? FS.read(pdfPath), let text = String(data: data, encoding: .isoLatin1) else { return nil }
    let count = Rx.count(#"/Type\s*/Page(?![sA-Za-z0-9_])"#, text)
    return count > 0 ? count : nil
}
