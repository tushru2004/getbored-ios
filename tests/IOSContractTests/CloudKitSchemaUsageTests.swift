import Foundation
import XCTest

final class CloudKitSchemaUsageTests: XCTestCase {
    func testCloudKitCodeUsesSharedSchemaConstants() throws {
        let paths = [
            "Sources/iOS/App/ContentView.swift",
            "Sources/iOS/iOSFilterControlProvider/FilterControlProvider.swift",
        ]

        let forbiddenPatterns = [
            #"CKRecord\.ID\(recordName:\s*""#,
            #"CKRecord\(recordType:\s*""#,
            #"(?:record|regRecord)\["(urls|mode|exceptions|allowedApps|devicesJSON|activityLogJSON|parent_child_map_v1|updatedAt|filterListsJSON)"\]"#,
            #"iCloud\.com\.getbored\.sync"#,
            #"cloudContainerID\s*=\s*"iCloud\.com\.getbored\.sync""#,
        ]

        for path in paths {
            let source = try readRepoFile(path)
            for pattern in forbiddenPatterns {
                XCTAssertNil(
                    source.range(of: pattern, options: .regularExpression),
                    "\(path) should use GetBoredIdentifiers.CloudKit constants instead of raw CloudKit schema literal: \(pattern)"
                )
            }
        }
    }

    private func readRepoFile(_ relativePath: String) throws -> String {
        let fileURL = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
