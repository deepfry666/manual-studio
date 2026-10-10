import Foundation

/// TXT 环境字段默认值与旧 skill 模板逐字一致。
public let DEFAULT_TXT_FIELDS: [String: String] = [
    "devHardware": "CPU类型：Intel英特尔酷睿i5-4590",
    "runHardware": "安卓机，8核处理器，ROM 64GB",
    "devOs": "Windows Server 2012以上",
    "devTools": "Visual Studio2010",
    "runPlatform": "Android操作系统5.0版以上",
    "runSupport": " Android Studio + Java jdk + Android SDK",
    "language": "JAVA",
]

public let TXT_FIELD_ORDER = ["devHardware", "runHardware", "devOs", "devTools", "runPlatform", "runSupport", "language"]

public let PIPELINE_STEPS = ["plan", "prompts", "images", "gate", "content", "design", "receipt", "build"]

public struct LlmStepInfo: Sendable, Codable, Hashable {
    public let label: String
    public let needsVision: Bool
}

/// gate 用看图模型一次完成两件事：品牌验收 + 抄录界面实际内容（供文案对账）。
public let LLM_STEP_ORDER = ["plan", "gate", "content", "design"]
public let LLM_STEPS: [String: LlmStepInfo] = [
    "plan": LlmStepInfo(label: "规划界面", needsVision: false),
    "gate": LlmStepInfo(label: "截图验收与内容抄录", needsVision: true),
    "content": LlmStepInfo(label: "撰写说明文字", needsVision: false),
    "design": LlmStepInfo(label: "设计说明（可选）", needsVision: false),
]

// MARK: - 宽松解码：字段缺失或类型不对时用默认值（相当于 Electron 版的 deepMerge + sanitizeSettings）

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// 数值字段：存成空值、非数字时换回默认值。
    func number(_ key: Key, _ fallback: Int) -> Int {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(value) }
        return fallback
    }

    func double(_ key: Key, _ fallback: Double) -> Double {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return value }
        return fallback
    }
}

public struct HedgeSettings: Codable, Sendable, Hashable {
    public var enabled = true
    public var percentile: Double = 85
    public var minSec: Double = 20
    public var maxSec: Double = 120
    public var maxPerBatch = 3
    public var allowCrossModel = false

    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, percentile, minSec, maxSec, maxPerBatch, allowCrossModel }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HedgeSettings()
        enabled = c.value(.enabled, d.enabled)
        percentile = c.double(.percentile, d.percentile)
        minSec = c.double(.minSec, d.minSec)
        maxSec = c.double(.maxSec, d.maxSec)
        maxPerBatch = c.number(.maxPerBatch, d.maxPerBatch)
        allowCrossModel = c.value(.allowCrossModel, d.allowCrossModel)
    }
}

public struct ImageSettings: Codable, Sendable, Hashable {
    public var targetSize = "864x1824"
    public var quality = "low"
    public var globalConcurrency = 10
    public var maxAttemptsPerScreen = 4
    public var gateRegenerateLimit = 3
    public var spillover = true
    public var hedge = HedgeSettings()

    public init() {}
    enum CodingKeys: String, CodingKey { case targetSize, quality, globalConcurrency, maxAttemptsPerScreen, gateRegenerateLimit, spillover, hedge }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageSettings()
        targetSize = c.value(.targetSize, d.targetSize)
        quality = c.value(.quality, d.quality)
        globalConcurrency = c.number(.globalConcurrency, d.globalConcurrency)
        maxAttemptsPerScreen = c.number(.maxAttemptsPerScreen, d.maxAttemptsPerScreen)
        gateRegenerateLimit = c.number(.gateRegenerateLimit, d.gateRegenerateLimit)
        spillover = c.value(.spillover, d.spillover)
        hedge = c.value(.hedge, d.hedge)
    }
}

/// 生图线路。mapping / extraBody 是自定义 JSON，原样保存。
public struct ImageProvider: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var enabled = true
    public var preset = "openai-sync"
    public var baseUrl = ""
    public var model = ""
    public var modelGroup = ""
    public var sizeMode = "pixel"
    public var pixelSize = "864x1824"
    public var ratios: [String] = []
    public var quality = "low"
    public var concurrency = 3
    public var hardTimeoutSec: Double = 240
    public var hedgeDefaultSec: Double = 60
    public var mapping: JSON? = nil
    public var extraBody: JSON? = nil

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case id, name, enabled, preset, baseUrl, model, modelGroup, sizeMode, pixelSize, ratios, quality, concurrency, hardTimeoutSec, hedgeDefaultSec, mapping, extraBody }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        name = c.value(.name, id)
        enabled = c.value(.enabled, true)
        preset = c.value(.preset, "openai-sync")
        let base = PROVIDER_PRESETS[preset] ?? PROVIDER_PRESETS["openai-sync"]!
        baseUrl = c.value(.baseUrl, "")
        model = c.value(.model, "")
        modelGroup = c.value(.modelGroup, "")
        sizeMode = c.value(.sizeMode, base.sizeMode)
        pixelSize = c.value(.pixelSize, base.pixelSize)
        ratios = c.value(.ratios, base.ratios)
        quality = c.value(.quality, "low")
        concurrency = c.number(.concurrency, base.concurrency)
        hardTimeoutSec = c.double(.hardTimeoutSec, base.hardTimeoutSec)
        hedgeDefaultSec = c.double(.hedgeDefaultSec, base.hedgeDefaultSec)
        mapping = c.value(.mapping, JSON?.none)
        if mapping == .null { mapping = nil }
        extraBody = c.value(.extraBody, JSON?.none)
        if extraBody == .null { extraBody = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(preset, forKey: .preset)
        try c.encode(baseUrl, forKey: .baseUrl)
        try c.encode(model, forKey: .model)
        try c.encode(modelGroup, forKey: .modelGroup)
        try c.encode(sizeMode, forKey: .sizeMode)
        try c.encode(pixelSize, forKey: .pixelSize)
        try c.encode(ratios, forKey: .ratios)
        try c.encode(quality, forKey: .quality)
        try c.encode(concurrency, forKey: .concurrency)
        try c.encode(hardTimeoutSec, forKey: .hardTimeoutSec)
        try c.encode(hedgeDefaultSec, forKey: .hedgeDefaultSec)
        try c.encode(mapping ?? .null, forKey: .mapping)
        if let extraBody { try c.encode(extraBody, forKey: .extraBody) }
    }
}

public struct LlmVendor: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var preset = "custom"
    public var baseUrl = ""
    public var jsonMode = true
    public var models: [String] = []

    public init(id: String, name: String, preset: String, baseUrl: String, jsonMode: Bool = true, models: [String] = []) {
        self.id = id
        self.name = name
        self.preset = preset
        self.baseUrl = baseUrl
        self.jsonMode = jsonMode
        self.models = models
    }

    enum CodingKeys: String, CodingKey { case id, name, preset, baseUrl, jsonMode, models }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        name = c.value(.name, id)
        preset = c.value(.preset, "custom")
        baseUrl = c.value(.baseUrl, "")
        jsonMode = c.value(.jsonMode, true)
        models = c.value(.models, [])
    }
}

public struct LlmAssignment: Codable, Sendable, Hashable {
    public var vendorId: String
    public var model: String
    public init(vendorId: String, model: String) {
        self.vendorId = vendorId
        self.model = model
    }
}

public struct LlmSettings: Codable, Sendable, Hashable {
    public var vendors: [LlmVendor] = []
    public var assignments: [String: LlmAssignment?] = ["plan": nil, "gate": nil, "content": nil, "design": nil]

    public init() {}
    enum CodingKeys: String, CodingKey { case vendors, assignments }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vendors = c.value(.vendors, [])
        var merged = LlmSettings().assignments
        for (key, value) in c.value(.assignments, [String: LlmAssignment?]()) { merged[key] = value }
        assignments = merged
    }

    public func assignment(_ step: String) -> LlmAssignment? { assignments[step] ?? nil }
}

public struct PipelineSettings: Codable, Sendable, Hashable {
    public var defaultScreenCount = 7
    public var platform = "iPhone 16 Pro Max / iOS 26"
    /// 规划完是否先停下让人确认；默认不停，直接做完
    public var reviewPlanSingle = false
    public var reviewPlanBatch = false
    public var batchConcurrency = 3
    public var featureTextFloor = 300

    public init() {}
    enum CodingKeys: String, CodingKey { case defaultScreenCount, platform, reviewPlanSingle, reviewPlanBatch, batchConcurrency, featureTextFloor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PipelineSettings()
        defaultScreenCount = c.number(.defaultScreenCount, d.defaultScreenCount)
        platform = c.value(.platform, d.platform)
        reviewPlanSingle = c.value(.reviewPlanSingle, d.reviewPlanSingle)
        reviewPlanBatch = c.value(.reviewPlanBatch, d.reviewPlanBatch)
        batchConcurrency = c.number(.batchConcurrency, d.batchConcurrency)
        featureTextFloor = c.number(.featureTextFloor, d.featureTextFloor)
    }
}

public struct CodeDefaults: Codable, Sendable, Hashable {
    public var extensions = [".java"]
    public var excludeDirs = ["node_modules", ".git", "build", "dist", "out", "target", ".gradle", ".idea", "Pods", "DerivedData"]

    public init() {}
    enum CodingKeys: String, CodingKey { case extensions, excludeDirs }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodeDefaults()
        extensions = c.value(.extensions, d.extensions)
        excludeDirs = c.value(.excludeDirs, d.excludeDirs)
    }
}

/// 代码来源只在这里设一次，所有项目共用；项目第一次生成交付包时记下当时用的来源，之后改这里不影响已完成的项目
public struct CodeSourceSetting: Codable, Sendable, Hashable {
    public var path = ""
    public var extensions = [".java"]

    public init(path: String = "", extensions: [String] = [".java"]) {
        self.path = path
        self.extensions = extensions
    }
    enum CodingKeys: String, CodingKey { case path, extensions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = c.value(.path, "")
        extensions = c.value(.extensions, [".java"])
    }

    public var json: JSON { .obj(["path": .string(path), "extensions": JSON(extensions)]) }
}

/// 原版字体没装时 PDF 用哪个系统字体代替
public struct PdfSettings: Codable, Sendable, Hashable {
    public var guide = DEFAULT_PDF_FONTS["guide"]!
    public var code = DEFAULT_PDF_FONTS["code"]!

    public init() {}
    enum CodingKeys: String, CodingKey { case guide, code }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guide = c.value(.guide, DEFAULT_PDF_FONTS["guide"]!)
        code = c.value(.code, DEFAULT_PDF_FONTS["code"]!)
    }

    public subscript(kind: String) -> String { kind == "guide" ? guide : code }
}

public struct ExportSettings: Codable, Sendable, Hashable {
    public var lastDir = ""
    public init() {}
    enum CodingKeys: String, CodingKey { case lastDir }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastDir = c.value(.lastDir, "")
    }
}

public struct Settings: Codable, Sendable, Hashable {
    public var schemaVersion = 1
    public var workspaceDir = Path.join(NSHomeDirectory(), "Desktop", "软件指南生成")
    public var image = ImageSettings()
    public var providers: [ImageProvider] = []
    public var llm = LlmSettings()
    public var pipeline = PipelineSettings()
    public var txtFields = DEFAULT_TXT_FIELDS
    public var codeDefaults = CodeDefaults()
    public var codeSource = CodeSourceSetting()
    public var pdf = PdfSettings()
    public var export = ExportSettings()

    public init() {}
    enum CodingKeys: String, CodingKey { case schemaVersion, workspaceDir, image, providers, llm, pipeline, txtFields, codeDefaults, codeSource, pdf, export }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        schemaVersion = c.number(.schemaVersion, 1)
        workspaceDir = c.value(.workspaceDir, d.workspaceDir)
        image = c.value(.image, d.image)
        providers = c.value(.providers, [])
        llm = c.value(.llm, d.llm)
        pipeline = c.value(.pipeline, d.pipeline)
        var fields = DEFAULT_TXT_FIELDS
        for (key, value) in c.value(.txtFields, [String: String]()) { fields[key] = value }
        txtFields = fields
        codeDefaults = c.value(.codeDefaults, d.codeDefaults)
        if c.contains(.codeSource) {
            codeSource = c.value(.codeSource, d.codeSource)
        } else {
            // 旧版本把代码文件类型放在 codeDefaults 里
            codeSource = CodeSourceSetting(path: "", extensions: codeDefaults.extensions)
        }
        pdf = c.value(.pdf, d.pdf)
        export = c.value(.export, d.export)
    }

    public static var defaults: Settings { Settings() }
}

/// 设置文件：settings.json。patch 可以是 JSON（深合并）或闭包（改类型化的副本）。
public actor SettingsStore {
    public nonisolated let file: String
    private var cache: Settings?

    public init(dataDir: String) {
        file = Path.join(dataDir, "settings.json")
    }

    private func load() throws -> Settings {
        if let cache { return cache }
        let stored = try FS.readJSON(file) ?? .emptyObject
        let loaded = (try? stored.decode(Settings.self)) ?? Settings()
        cache = loaded
        return loaded
    }

    public func get() throws -> Settings { try load() }

    @discardableResult
    public func update(_ mutate: (inout Settings) throws -> Void) throws -> Settings {
        var next = try load()
        try mutate(&next)
        // 编码再解码一遍：数值等字段按同样的规则校正
        let json = try JSON.encode(next)
        let sanitized = (try? json.decode(Settings.self)) ?? next
        try FS.writeJSONAtomic(file, try JSON.encode(sanitized))
        cache = sanitized
        return sanitized
    }

    /// 深合并一个 JSON 补丁（数组整体替换，对象逐层合并）。
    @discardableResult
    public func update(patch: JSON) throws -> Settings {
        let current = try JSON.encode(try load())
        let merged = deepMerge(current, patch)
        let next = try (try? merged.decode(Settings.self)) ?? load()
        try FS.writeJSONAtomic(file, try JSON.encode(next))
        cache = next
        return next
    }
}

public func deepMerge(_ base: JSON, _ patch: JSON) -> JSON {
    guard case .object(let baseObject) = base, case .object(let patchObject) = patch else { return patch }
    var result = baseObject
    for (key, value) in patchObject {
        if case .object = value, case .object? = baseObject[key] {
            result[key] = deepMerge(baseObject[key]!, value)
        } else {
            result[key] = value
        }
    }
    return .object(result)
}
