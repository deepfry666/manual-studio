import Foundation

/// 生图线路预设。内部全部转成「声明式映射」执行（思路来自四季画布的 provider registry）：
/// 请求体里的 "$model" "$prompt" "$size" "$quality" 会被替换成实际值。
public let APIMART_RATIOS = ["1:1", "3:2", "2:3", "4:3", "3:4", "5:4", "4:5", "16:9", "9:16", "2:1", "1:2", "3:1", "1:3", "21:9", "9:21"]
public let OPENAI_COMMON_RATIOS = ["1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "5:4", "4:5", "21:9"]

let OPENAI_SYNC_MAPPING: JSON = [
    "submit": [
        "method": "POST",
        "path": "/images/generations",
        "body": ["model": "$model", "prompt": "$prompt", "size": "$size", "quality": "$quality", "n": 1, "output_format": "png"],
    ],
    "response": ["images": "$.data[*]"],
]

let APIMART_ASYNC_MAPPING: JSON = [
    "submit": [
        "method": "POST",
        "path": "/images/generations",
        // 必须带 quality（默认 low）：不带的话 APIMart 按默认的高质量计费，单价约贵 17 倍。
        // 字段与旧 skill 实测便宜的请求保持一致：model / prompt / size / quality / n。
        "body": ["model": "$model", "prompt": "$prompt", "size": "$size", "quality": "$quality", "n": 1],
    ],
    "response": ["taskId": "$.data[0].task_id", "images": "$.data[*]"],
    "polling": [
        "method": "GET",
        "path": "/tasks/$taskId?language=zh",
        "statusPath": "$.data.status",
        "successValues": ["completed", "succeeded", "success"],
        "failureValues": ["failed", "error", "cancelled", "canceled"],
        "resultPath": "$.data.result.images[*]",
        "intervalMs": 3000,
    ],
]

public struct ProviderPreset: Sendable, Codable, Hashable {
    public let label: String
    public let `protocol`: String
    public let sizeMode: String
    public let pixelSize: String
    public let ratios: [String]
    public let concurrency: Int
    public let hardTimeoutSec: Double
    public let hedgeDefaultSec: Double
    public let mapping: JSON
}

public let PROVIDER_PRESET_ORDER = ["openai-sync", "apimart-async", "custom"]
public let PROVIDER_PRESETS: [String: ProviderPreset] = [
    "openai-sync": ProviderPreset(label: "OpenAI 兼容（同步出图，CPA 也选这个）", protocol: "sync", sizeMode: "pixel", pixelSize: "864x1824", ratios: OPENAI_COMMON_RATIOS, concurrency: 4, hardTimeoutSec: 150, hedgeDefaultSec: 45, mapping: OPENAI_SYNC_MAPPING),
    "apimart-async": ProviderPreset(label: "APIMart（异步任务）", protocol: "async", sizeMode: "ratio", pixelSize: "864x1824", ratios: APIMART_RATIOS, concurrency: 6, hardTimeoutSec: 240, hedgeDefaultSec: 60, mapping: APIMART_ASYNC_MAPPING),
    "custom": ProviderPreset(label: "自定义（声明式 JSON）", protocol: "auto", sizeMode: "pixel", pixelSize: "864x1824", ratios: OPENAI_COMMON_RATIOS, concurrency: 3, hardTimeoutSec: 240, hedgeDefaultSec: 90, mapping: OPENAI_SYNC_MAPPING),
]

public func providerMapping(_ provider: ImageProvider) -> JSON {
    if provider.preset == "custom", let mapping = provider.mapping, mapping.isObject { return mapping }
    return (PROVIDER_PRESETS[provider.preset] ?? PROVIDER_PRESETS["openai-sync"]!).mapping
}

public func isAsyncProvider(_ provider: ImageProvider) -> Bool {
    providerMapping(provider)["polling"]?.truthy == true
}

/// 新建线路时的默认字段。
public func newProviderFromPreset(_ preset: String, id: String, name: String? = nil) -> ImageProvider {
    let base = PROVIDER_PRESETS[preset] ?? PROVIDER_PRESETS["openai-sync"]!
    var provider = ImageProvider(id: id, name: name ?? base.label)
    provider.preset = preset
    provider.sizeMode = base.sizeMode
    provider.pixelSize = base.pixelSize
    provider.ratios = base.ratios
    provider.quality = "low"
    provider.concurrency = base.concurrency
    provider.hardTimeoutSec = base.hardTimeoutSec
    provider.hedgeDefaultSec = base.hedgeDefaultSec
    provider.mapping = preset == "custom" ? base.mapping : nil
    return provider
}

public func hostOf(_ baseUrl: String) -> String {
    guard let components = URLComponents(string: baseUrl), let host = components.host, components.scheme != nil else { return baseUrl }
    if let port = components.port { return "\(host):\(port)" }
    return host
}

public func modelGroupOf(_ provider: ImageProvider) -> String {
    let group = provider.modelGroup.isEmpty ? provider.model : provider.modelGroup
    return group.jsTrimmed.lowercased()
}
