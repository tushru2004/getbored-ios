import Foundation
import XCTest

final class SharedIdentifierUsageTests: XCTestCase {
    func testSwiftCallSitesUseSharedIdentifierConstants() throws {
        let paths = [
            "Sources/iOS/App/ContentView.swift",
            "Sources/iOS/App/LocationBlockingManager.swift",
            "Sources/iOS/App/WhitelistManager.swift",
            "Sources/iOS/iOSFilterControlProvider/FilterControlProvider.swift",
            "Sources/iOS/iOSFilterDataProvider/FilterDataProvider.swift",
            "Sources/iOS/SafariAppProxyProvider/SafariAppProxyProvider.swift",
            "Sources/iOS/SafariChildRegistrationExtension/SafariWebExtensionHandler.swift",
            "Sources/iOS/Shared/IOSRuleStore.swift",
            "Sources/iOS/Shared/SafariParentChildContextStore.swift",
        ]

        let forbiddenPatterns = [
            #"Logger\(subsystem:\s*"com\.getbored\."#,
            #"OSLog\(subsystem:\s*"com\.getbored\."#,
            #"UserDefaults\(suiteName:\s*"group\.com\.getbored\."#,
            #"containerURL\(forSecurityApplicationGroupIdentifier:\s*"group\.com\.getbored\."#,
            #""PayloadIdentifier":\s*"com\.getbored\.advance\."#,
            #"CFNotificationName\("com\.getbored\.filter\."#,
            #"appendingPathComponent\(\s*"Library/Group Containers/group\.com\.getbored\."#,
            #"parentChildMapKey\s*=\s*"parent_child_map_v1""#,
            #"DispatchQueue\(label:\s*"com\.getbored\."#,
        ]

        for path in paths {
            let source = try readRepoFile(path)
            for pattern in forbiddenPatterns {
                XCTAssertNil(
                    source.range(of: pattern, options: .regularExpression),
                    "\(path) should use GetBoredIdentifiers instead of raw shared identifier pattern: \(pattern)"
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
