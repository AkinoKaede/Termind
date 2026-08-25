import Foundation

/// Deliberately small JSON Schema validator for the strict schemas exposed by
/// Termind tools. Unsupported schema shapes fail closed instead of becoming
/// advisory metadata.
nonisolated enum AgentJSONSchemaValidator {
    static func validate(_ value: AgentJSONValue, against schema: AgentJSONValue) throws {
        try validate(value, schema: schema, path: "$")
    }

    private static func validate(
        _ value: AgentJSONValue, schema: AgentJSONValue, path: String
    ) throws {
        guard let rule = schema.objectValue else { throw AgentSchemaError.invalidSchema(path) }
        if let allowed = rule["enum"]?.arrayValue, !allowed.contains(value) {
            throw AgentSchemaError.violation("\(path) is not one of the allowed values.")
        }
        if let type = rule["type"]?.stringValue, !matches(value, type: type) {
            throw AgentSchemaError.violation("\(path) must be \(type).")
        }

        switch value {
        case .object(let object):
            let properties = rule["properties"]?.objectValue ?? [:]
            for key in rule["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            where object[key] == nil {
                throw AgentSchemaError.violation("\(path).\(key) is required.")
            }
            if rule["additionalProperties"]?.boolValue == false {
                let unknown = Set(object.keys).subtracting(properties.keys)
                if let key = unknown.sorted().first {
                    throw AgentSchemaError.violation("\(path).\(key) is not allowed.")
                }
            }
            for (key, child) in object {
                if let childSchema = properties[key] {
                    // OpenAI strict mode returns null for provider-neutral
                    // optional fields. Treat that representation as omission;
                    // required fields remain non-null and validate normally.
                    let required = rule["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if child == .null, !required.contains(key) { continue }
                    try validate(child, schema: childSchema, path: "\(path).\(key)")
                }
            }
        case .array(let array):
            if let maximum = rule["maxItems"]?.integerValue, array.count > maximum {
                throw AgentSchemaError.violation("\(path) has too many items.")
            }
            if let itemSchema = rule["items"] {
                for (index, item) in array.enumerated() {
                    try validate(item, schema: itemSchema, path: "\(path)[\(index)]")
                }
            }
        case .string(let string):
            if let minimum = rule["minLength"]?.integerValue, string.count < minimum {
                throw AgentSchemaError.violation("\(path) is too short.")
            }
            if let maximum = rule["maxLength"]?.integerValue, string.count > maximum {
                throw AgentSchemaError.violation("\(path) is too long.")
            }
        case .number(let number):
            if let minimum = rule["minimum"]?.numberValue, number < minimum {
                throw AgentSchemaError.violation("\(path) is below the minimum.")
            }
            if let maximum = rule["maximum"]?.numberValue, number > maximum {
                throw AgentSchemaError.violation("\(path) is above the maximum.")
            }
        case .bool, .null:
            break
        }
    }

    private static func matches(_ value: AgentJSONValue, type: String) -> Bool {
        switch (value, type) {
        case (.object, "object"), (.array, "array"), (.string, "string"),
            (.number, "number"), (.bool, "boolean"), (.null, "null"):
            true
        case (.number(let value), "integer"):
            value.rounded() == value
        default:
            false
        }
    }
}

nonisolated enum AgentSchemaError: LocalizedError, Sendable {
    case invalidSchema(String)
    case violation(String)

    var errorDescription: String? {
        switch self {
        case .invalidSchema(let path): "The tool schema is invalid at \(path)."
        case .violation(let message): message
        }
    }
}
