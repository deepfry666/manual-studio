import Foundation

/// JSON Schema 校验（只实现流水线用到的关键字：type、required、properties、items、minItems、
/// minLength、maxLength、pattern、enum），报错文字和 ajv 一致，会原样发回给大模型让它修正。
public enum SchemaValidator {
    public static func validate(_ value: JSON, _ schema: JSON) -> [String] {
        var errors: [String] = []
        check(value, schema, path: "", errors: &errors)
        return errors
    }

    /// 和 Electron 版的 describeAjvErrors 一样：最多 12 条，用「；」连接。
    public static func describe(_ errors: [String]) -> String {
        errors.prefix(12).joined(separator: "；")
    }

    private static func typeName(_ value: JSON) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let number): return number.rounded() == number && number.isFinite ? "integer" : "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func matches(_ value: JSON, type: String) -> Bool {
        let actual = typeName(value)
        if type == "number" { return actual == "number" || actual == "integer" }
        return actual == type
    }

    private static func pointerEscape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func check(_ value: JSON, _ schema: JSON, path: String, errors: inout [String]) {
        let place = path.isEmpty ? "(根)" : path
        if let type = schema["type"] {
            let types = type.array?.compactMap(\.string) ?? [type.string].compactMap { $0 }
            if !types.isEmpty, !types.contains(where: { matches(value, type: $0) }) {
                errors.append("\(place) must be \(types.joined(separator: ","))")
                return
            }
        }
        if let options = schema["enum"]?.array, !options.contains(value) {
            errors.append("\(place) must be equal to one of the allowed values")
        }
        switch value {
        case .string(let text):
            if let minimum = schema["minLength"]?.number, Double(text.unicodeScalars.count) < minimum {
                errors.append("\(place) must NOT have fewer than \(Int(minimum)) characters")
            }
            if let maximum = schema["maxLength"]?.number, Double(text.unicodeScalars.count) > maximum {
                errors.append("\(place) must NOT have more than \(Int(maximum)) characters")
            }
            if let pattern = schema["pattern"]?.string, !Rx.test(pattern, text) {
                errors.append("\(place) must match pattern \"\(pattern)\"")
            }
        case .array(let items):
            if let minimum = schema["minItems"]?.number, Double(items.count) < minimum {
                errors.append("\(place) must NOT have fewer than \(Int(minimum)) items")
            }
            if let itemSchema = schema["items"], itemSchema.isObject {
                for (index, item) in items.enumerated() { check(item, itemSchema, path: "\(path)/\(index)", errors: &errors) }
            }
        case .object(let object):
            for required in schema["required"]?.stringArray ?? [] where object[required] == nil {
                errors.append("\(place) must have required property '\(required)'")
            }
            for (key, propertySchema) in schema["properties"]?.object ?? JSONObject() {
                if let child = object[key] { check(child, propertySchema, path: "\(path)/\(pointerEscape(key))", errors: &errors) }
            }
        default:
            break
        }
    }
}
