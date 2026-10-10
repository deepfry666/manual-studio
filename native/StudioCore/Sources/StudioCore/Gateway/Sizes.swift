import Foundation

public struct PixelSize: Sendable, Hashable {
    public let width: Double
    public let height: Double
}

public struct SizeSpec: Sendable, Hashable {
    public let mode: String
    public let size: String
}

public func parsePixelSize(_ value: String?) -> PixelSize? {
    guard let match = Rx.match(#"^([0-9]+)\s*[x×*]\s*([0-9]+)$"#, (value ?? "").jsTrimmed, "i"),
          let width = Double(match[1] ?? ""), let height = Double(match[2] ?? ""), width > 0, height > 0 else { return nil }
    return PixelSize(width: width, height: height)
}

public func parseRatio(_ value: String?) -> PixelSize? {
    guard let match = Rx.match(#"^([0-9]+(?:\.[0-9]+)?)\s*:\s*([0-9]+(?:\.[0-9]+)?)$"#, (value ?? "").jsTrimmed),
          let width = Double(match[1] ?? ""), let height = Double(match[2] ?? ""), width > 0, height > 0 else { return nil }
    return PixelSize(width: width, height: height)
}

/// 在线路支持的比例里，按对数距离选最接近目标的一个（864x1824 → 1:2）。
public func nearestRatio(_ target: PixelSize, _ ratios: [String]) -> String? {
    let goal = log(target.width / target.height)
    var best: String?
    var bestDistance = Double.infinity
    for ratio in ratios {
        guard let parsed = parseRatio(ratio) else { continue }
        let distance = abs(log(parsed.width / parsed.height) - goal)
        if distance < bestDistance {
            best = ratio
            bestDistance = distance
        }
    }
    return best
}

private let asciiWordBefore = "(?<![A-Za-z0-9_])"
private let asciiWordAfter = "(?![A-Za-z0-9_])"

/// 从「pixel sizes are not supported; must be auto or one of 1:1, 16:9 …」这类报错里取出允许的比例。
public func parseAllowedRatios(_ message: String) -> [String] {
    guard Rx.test("ratio|比例|pixel|像素|size|尺寸", message, "i") else { return [] }
    let found = Rx.matches(asciiWordBefore + "[0-9]{1,2}:[0-9]{1,2}" + asciiWordAfter, message).compactMap { $0[0] }
    return uniqued(found)
}

public func looksLikeUnsupportedPixelSize(_ message: String) -> Bool {
    Rx.test(#"pixel sizes? (?:are|is) not supported|not support(?:ed)? pixel|不支持像素|size must be one of|invalid (?:image )?size|must be (?:auto or )?one of|invalid value: '[0-9]+x[0-9]+'|supported (?:sizes|values) (?:are|is)"#, message, "i")
}

/// 根据线路配置决定实际发送的尺寸：像素尺寸（864x1824）或比例（1:2）。
public func resolveRequestSize(_ provider: ImageProvider, _ targetSize: String) -> SizeSpec {
    let target = parsePixelSize(targetSize) ?? PixelSize(width: 864, height: 1824)
    if provider.sizeMode == "ratio" {
        let ratios = provider.ratios.isEmpty ? ["9:16"] : provider.ratios
        return SizeSpec(mode: "ratio", size: nearestRatio(target, ratios) ?? ratios[0])
    }
    let pixel = parsePixelSize(provider.pixelSize) ?? target
    return SizeSpec(mode: "pixel", size: "\(JSON.formatNumber(pixel.width))x\(JSON.formatNumber(pixel.height))")
}

/// 从报错里取允许的像素尺寸，例如 OpenAI 官方的 '1024x1536'。
public func parseAllowedPixelSizes(_ message: String) -> [String] {
    uniqued(Rx.matches(asciiWordBefore + "[0-9]{3,4}x[0-9]{3,4}" + asciiWordAfter, message).compactMap { $0[0] })
}

public struct SizeFallback: Sendable {
    public let spec: SizeSpec
    public let sizeMode: String
    public let pixelSize: String?
    public let ratios: [String]?

    public func apply(to provider: inout ImageProvider) {
        provider.sizeMode = sizeMode
        if let pixelSize { provider.pixelSize = pixelSize }
        if let ratios { provider.ratios = ratios }
    }
}

/// 线路报尺寸不支持时，算出该改用的尺寸：
/// - 报错里列了像素尺寸 → 选宽高比最接近的那个；
/// - 报错里列了比例 → 选最接近的比例；
/// - 只说不支持像素、没列选项 → 用线路配置里的比例表；
/// - 都没有 → 返回 nil，不改配置，当普通失败处理。
public func sizeFallback(_ error: ProviderError, _ provider: ImageProvider, _ targetSize: String, _ currentSize: String?) -> SizeFallback? {
    let target = parsePixelSize(targetSize) ?? PixelSize(width: 864, height: 1824)
    let pixels = parseAllowedPixelSizes(error.message).filter { $0 != currentSize }
    if !pixels.isEmpty {
        let goal = log(target.width / target.height)
        let best = pixels.enumerated().min { a, b in
            let pa = parsePixelSize(a.element)!
            let pb = parsePixelSize(b.element)!
            let da = abs(log(pa.width / pa.height) - goal)
            let db = abs(log(pb.width / pb.height) - goal)
            return da == db ? a.offset < b.offset : da < db
        }!.element
        return SizeFallback(spec: SizeSpec(mode: "pixel", size: best), sizeMode: "pixel", pixelSize: best, ratios: nil)
    }
    if error.allowedRatios.count >= 2 {
        return SizeFallback(spec: SizeSpec(mode: "ratio", size: nearestRatio(target, error.allowedRatios) ?? error.allowedRatios[0]), sizeMode: "ratio", pixelSize: nil, ratios: error.allowedRatios)
    }
    if Rx.test("pixel sizes? (?:are|is) not supported|不支持像素", error.message, "i"), !provider.ratios.isEmpty {
        return SizeFallback(spec: SizeSpec(mode: "ratio", size: nearestRatio(target, provider.ratios) ?? provider.ratios[0]), sizeMode: "ratio", pixelSize: nil, ratios: nil)
    }
    return nil
}
