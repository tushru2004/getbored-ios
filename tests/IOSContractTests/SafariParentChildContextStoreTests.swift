import Foundation
import XCTest
@testable import GetBoredIOSCore

final class SafariParentChildContextStoreTests: XCTestCase {
    func testSafariParentChildContextStoreAppGroupAndKeyContracts() {
        XCTAssertEqual(SafariParentChildContextStore.appGroupIdentifier, "group.com.getbored.ios")

        XCTAssertEqual(
            SafariParentChildContextStore.activeContextDataKey,
            "safari_parent_child_active_context_v1"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.flowObservationDataKey,
            "safari_parent_child_flow_observation_v1"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.parentChildMapKey,
            "parent_child_map_v1"
        )
    }

    func testSafariParentChildContextStoreLegacyKeyContracts() {
        XCTAssertEqual(
            SafariParentChildContextStore.legacyLastMessageKey,
            "safari_extension_spike_last_message"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyLastMessageDateKey,
            "safari_extension_spike_last_message_at"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyActiveContextKey,
            "safari_extension_spike_active_page_context"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyActiveContextDateKey,
            "safari_extension_spike_active_page_context_at"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyActiveContextClearedDateKey,
            "safari_extension_spike_active_page_context_cleared_at"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyParentChildRegistryKey,
            "safari_extension_spike_parent_child_registry"
        )
        XCTAssertEqual(
            SafariParentChildContextStore.legacyFlowLogKey,
            "safari_app_proxy_spike_flows"
        )
    }

    func testSafariParentChildMapSchemaDecodesCurrentContractShape() throws {
        let json = """
        {
          "schemaVersion": 1,
          "version": "fixture-v1",
          "publishedAt": "2026-05-10T00:00:00Z",
          "rules": [
            {
              "p": "www.docker.com",
              "c": ["bam.nr-data.net", "js-agent.newrelic.com"]
            }
          ],
          "wildcards": [
            {
              "p": "www.cnbc.com",
              "c": "*.cnbcfm.com"
            }
          ]
        }
        """

        let map = try JSONDecoder().decode(
            SafariParentChildContextStore.ParentChildMap.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(map.schemaVersion, 1)
        XCTAssertEqual(map.version, "fixture-v1")
        XCTAssertEqual(map.publishedAt, "2026-05-10T00:00:00Z")
        XCTAssertEqual(map.rules, [
            SafariParentChildContextStore.ParentChildMap.Rule(
                p: "www.docker.com",
                c: ["bam.nr-data.net", "js-agent.newrelic.com"]
            ),
        ])
        XCTAssertEqual(map.wildcards, [
            SafariParentChildContextStore.ParentChildMap.Wildcard(
                p: "www.cnbc.com",
                c: "*.cnbcfm.com"
            ),
        ])
    }
}
