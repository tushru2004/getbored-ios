import Foundation
import React
import GetBoredCore

@objc(AppGroupDefaults)
final class AppGroupDefaultsModule: NSObject {
    private let appGroupIdentifier = GetBoredIdentifiers.AppGroup.ios
    private let flowLogKey = "safari_app_proxy_spike_flows"
    private let flowLogLimit = 50
    private let previewLimit = 240

    @objc static func requiresMainQueueSetup() -> Bool { false }

    /// Call flow:
    ///
    ///   snapshot()
    ///       │
    ///       ├── Load app group defaults
    ///       │   └── Filter out FLOW_WRITE_FAILED entries from flowLog
    ///       │
    ///       └── Map each key through typeName() and preview()
    ///           └── resolve({groupIdentifier, flowLogKey, flowLog, keys[]})
    @objc func snapshot(_ resolve: @escaping RCTPromiseResolveBlock,
                        rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else {
            reject("defaults_unavailable", "App group defaults are unavailable", nil)
            return
        }

        let dictionary = defaults.dictionaryRepresentation()
        let rawFlowLog = defaults.stringArray(forKey: flowLogKey) ?? []
        let flowLog = rawFlowLog.filter { !$0.contains("FLOW_WRITE_FAILED") }
        if flowLog.count != rawFlowLog.count {
            defaults.set(flowLog, forKey: flowLogKey)
        }
        let keys = dictionary.keys.sorted().map { key -> [String: Any] in
            let value = dictionary[key]
            return [
                "key": key,
                "type": typeName(for: value),
                "preview": preview(for: value),
            ]
        }

        resolve([
            "groupIdentifier": appGroupIdentifier,
            "flowLogKey": flowLogKey,
            "flowLogLimit": flowLogLimit,
            "flowLogCount": flowLog.count,
            "flowLog": flowLog,
            "keys": keys,
        ])
    }

    private func typeName(for value: Any?) -> String {
        switch value {
        case is String: return "String"
        case is [String]: return "String[]"
        case is Data: return "Data"
        case is Date: return "Date"
        case is NSNumber: return "Number"
        case is [String: Any]: return "Dictionary"
        case is [Any]: return "Array"
        case nil: return "nil"
        default: return String(describing: type(of: value as Any))
        }
    }

    private func preview(for value: Any?) -> String {
        let raw: String
        switch value {
        case let value as String:
            raw = value
        case let value as [String]:
            raw = value.prefix(8).joined(separator: ", ")
        case let value as Data:
            raw = "\(value.count) bytes"
        case let value as Date:
            raw = ISO8601DateFormatter().string(from: value)
        case let value as NSNumber:
            raw = value.stringValue
        case let value as [String: Any]:
            raw = "\(value.count) keys"
        case let value as [Any]:
            raw = "\(value.count) items"
        case nil:
            raw = ""
        default:
            raw = String(describing: value as Any)
        }
        if raw.count <= previewLimit { return raw }
        return String(raw.prefix(previewLimit)) + "..."
    }
}
