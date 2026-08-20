import Foundation

/// NAS 管理响应的内部宽容解码器；不承载网络调用或写操作状态。
enum DsmDynamicJSON: Decodable, Sendable {
    case object([String: DsmDynamicJSON])
    case array([DsmDynamicJSON])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: DsmDynamicJSON].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([DsmDynamicJSON].self))
        }
    }

    var object: [String: DsmDynamicJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var array: [DsmDynamicJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> DsmDynamicJSON? {
        object?[key]
    }

    func string(_ keys: [String]) -> String? {
        guard let object else { return scalarString }
        for key in keys {
            if let value = object[key]?.scalarString, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    var scalarString: String? {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value.rounded() == value ? String(Int64(value)) : String(value)
        case .boolean(let value):
            value ? "true" : "false"
        default:
            nil
        }
    }

    func number(_ keys: [String]) -> Double? {
        guard let object else { return scalarNumber }
        for key in keys {
            if let value = object[key]?.scalarNumber {
                return value
            }
        }
        return nil
    }

    var scalarNumber: Double? {
        switch self {
        case .number(let value):
            value
        case .string(let value):
            Double(value)
        case .boolean(let value):
            value ? 1 : 0
        default:
            nil
        }
    }

    func integer(_ keys: [String]) -> Int64? {
        number(keys).map(Int64.init)
    }

    func boolean(_ keys: [String]) -> Bool? {
        guard let object else { return scalarBoolean }
        for key in keys {
            if let value = object[key]?.scalarBoolean {
                return value
            }
        }
        return nil
    }

    var scalarBoolean: Bool? {
        switch self {
        case .boolean(let value):
            value
        case .number(let value):
            value != 0
        case .string(let value):
            ["true", "yes", "1", "enabled"].contains(value.lowercased())
        default:
            nil
        }
    }

    func objects(_ key: String) -> [[String: DsmDynamicJSON]] {
        self[key]?.array?.compactMap(\.object) ?? []
    }

    func strings(_ keys: [String]) -> [String] {
        guard let object else {
            if let value = scalarString {
                return value.split(separator: " ").map(String.init)
            }
            return array?.compactMap(\.scalarString) ?? []
        }
        for key in keys {
            guard let value = object[key] else { continue }
            if let values = value.array?.compactMap(\.scalarString), !values.isEmpty {
                return values
            }
            if let scalar = value.scalarString, !scalar.isEmpty {
                return scalar.split(separator: " ").map(String.init)
            }
        }
        return []
    }
}

struct PackageControlMetadata: Sendable {
    let dsmApps: [String]
}

struct DiskTestHistorySnapshot: Sendable {
    let lastQuickTest: String?
    let lastExtendedTest: String?
    let latestResult: String?
    let isAvailable: Bool

    static let unavailable = DiskTestHistorySnapshot(
        lastQuickTest: nil,
        lastExtendedTest: nil,
        latestResult: nil,
        isAvailable: false
    )
}
