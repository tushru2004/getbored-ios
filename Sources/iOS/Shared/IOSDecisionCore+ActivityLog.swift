import GetBoredCore

extension IOSDecisionCore {
    // MARK: - Activity Log Helpers

    public static func activityLogStripTeamID(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let prefixes = [
            "com.", "org.", "net.", "de.", "io.", "me.", "app.", "co.", "uk.", "fr.", "jp.", "au.",
            "at.",
        ]
        for prefix in prefixes {
            if let index = identifier.range(of: prefix)?.lowerBound {
                return String(identifier[index...])
            }
        }
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].count >= 8,
            parts[0].allSatisfy({ $0.isUppercase || $0.isNumber })
        else { return identifier }
        return parts.dropFirst().joined(separator: ".")
    }

    public static func activityLogMergeAndTrim(
        existing: [GetBoredCore.ActivityLogEntry], newEntries: [GetBoredCore.ActivityLogEntry],
        maxTotal: Int = 500, maxPerApp: Int = 50
    ) -> [GetBoredCore.ActivityLogEntry] {
        let all = newEntries + existing
        guard all.count > maxTotal else { return all }
        var counts: [String: Int] = [:]
        let capped = all.filter { entry in
            let key = entry.sourceApp?.lowercased() ?? "__nil__"
            let count = counts[key, default: 0]
            guard count < maxPerApp else { return false }
            counts[key] = count + 1
            return true
        }
        return Array(capped.prefix(max(0, maxTotal)))
    }
}
