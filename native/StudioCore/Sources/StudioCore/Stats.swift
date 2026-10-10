import Foundation

/// 统计页的数据：按本机时区的自然日汇总生图、大模型调用和项目完成情况。
public enum UsageStats {
    /// 本机时区的日期键 yyyy-MM-dd
    public static func dayKey(_ ms: Double, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 算一张「生成的截图」：成功、不是测速
    static func isGeneratedImage(_ row: JSON) -> Bool { row["ok"].isTruthy && row["role"]?.string != "probe" }
    /// 算一次真实的生图请求：不含测速、被取消的
    static func isImageRequest(_ row: JSON) -> Bool { row["role"]?.string != "probe" && row["kind"]?.string != "aborted" }

    /// sinceMs：只统计这个时间之后的（nil 为全部）；每日数据 daily 始终包含全部历史，用来画热力图。
    public static func compute(imageCalls: [JSON], llmCalls: [JSON], projects: [JSON], sinceMs: Double?, calendar: Calendar = .current) -> JSON {
        func inRange(_ ms: Double?) -> Bool { guard let ms else { return false }; return sinceMs.map { ms >= $0 } ?? true }

        var daily: [String: (images: Int, llm: Int, completed: Int, created: Int)] = [:]
        // 生图
        var imageRequests = 0, imagesOk = 0
        var imageSeconds: [Double] = []
        var byProvider: [String: (images: Int, requests: Int, seconds: [Double])] = [:]
        for row in imageCalls {
            guard let ms = parseISO(row["ts"]?.string) else { continue }
            if isGeneratedImage(row) { daily[dayKey(ms, calendar: calendar), default: (0, 0, 0, 0)].images += 1 }
            guard inRange(ms), isImageRequest(row) else { continue }
            let provider = row["providerName"]?.string ?? row["model"]?.string ?? row["providerId"]?.string ?? "未知线路"
            imageRequests += 1
            byProvider[provider, default: (0, 0, [])].requests += 1
            if isGeneratedImage(row) {
                imagesOk += 1
                byProvider[provider, default: (0, 0, [])].images += 1
                if let duration = row["durationMs"]?.number {
                    imageSeconds.append(duration / 1000)
                    byProvider[provider, default: (0, 0, [])].seconds.append(duration / 1000)
                }
            }
        }
        // 大模型
        var llmTotal = 0, llmOk = 0
        var llmSeconds: [Double] = []
        var byModel: [String: (calls: Int, ok: Int, seconds: [Double])] = [:]
        var byStep: [String: Int] = [:]
        for row in llmCalls {
            guard let ms = parseISO(row["ts"]?.string) else { continue }
            daily[dayKey(ms, calendar: calendar), default: (0, 0, 0, 0)].llm += 1
            guard inRange(ms) else { continue }
            let model = row["model"]?.string ?? "未知模型"
            llmTotal += 1
            byModel[model, default: (0, 0, [])].calls += 1
            byStep[row["step"]?.string ?? "其他", default: 0] += 1
            if row["ok"].isTruthy {
                llmOk += 1
                byModel[model, default: (0, 0, [])].ok += 1
                if let duration = row["durationMs"]?.number {
                    llmSeconds.append(duration / 1000)
                    byModel[model, default: (0, 0, [])].seconds.append(duration / 1000)
                }
            }
        }
        // 项目
        var created = 0, completed = 0
        var projectSeconds: [Double] = []
        for project in projects {
            // 导入的历史项目不算新建
            if project["origin"]?.string != "imported", let ms = parseISO(project["addedAt"]?.string) {
                daily[dayKey(ms, calendar: calendar), default: (0, 0, 0, 0)].created += 1
                if inRange(ms) { created += 1 }
            }
            if let ms = parseISO(project["timing"]?["completedAt"]?.string) {
                daily[dayKey(ms, calendar: calendar), default: (0, 0, 0, 0)].completed += 1
                if inRange(ms) {
                    completed += 1
                    if let duration = project["timing"]?["completedMs"]?.number, duration > 0 { projectSeconds.append(duration / 1000) }
                }
            }
        }

        func average(_ values: [Double]) -> JSON { values.isEmpty ? .null : .number(values.reduce(0, +) / Double(values.count)) }
        return .obj([
            "projects": .obj(["created": .number(Double(created)), "completed": .number(Double(completed)), "avgSec": average(projectSeconds)]),
            "images": .obj([
                "generated": .number(Double(imagesOk)), "requests": .number(Double(imageRequests)),
                "successRate": imageRequests > 0 ? .number(Double(imagesOk) / Double(imageRequests)) : .null,
                "avgSec": average(imageSeconds), "p50": JSON.maybe(percentile(imageSeconds, 50)),
            ]),
            "llm": .obj([
                "calls": .number(Double(llmTotal)), "ok": .number(Double(llmOk)),
                "successRate": llmTotal > 0 ? .number(Double(llmOk) / Double(llmTotal)) : .null, "avgSec": average(llmSeconds),
            ]),
            "byProvider": .array(byProvider.sorted { $0.value.images > $1.value.images }.map { name, value in
                .obj(["name": .string(name), "images": .number(Double(value.images)), "requests": .number(Double(value.requests)), "avgSec": average(value.seconds)])
            }),
            "byModel": .array(byModel.sorted { $0.value.calls > $1.value.calls }.map { name, value in
                .obj(["model": .string(name), "calls": .number(Double(value.calls)), "ok": .number(Double(value.ok)), "avgSec": average(value.seconds)])
            }),
            "byStep": .object(JSONObject(byStep.sorted { $0.value > $1.value }.map { ($0.key, .number(Double($0.value))) })),
            "daily": .object(JSONObject(daily.sorted { $0.key < $1.key }.map { key, value in
                (key, .obj(["images": .number(Double(value.images)), "llm": .number(Double(value.llm)), "completed": .number(Double(value.completed)), "created": .number(Double(value.created))]))
            })),
        ])
    }
}
