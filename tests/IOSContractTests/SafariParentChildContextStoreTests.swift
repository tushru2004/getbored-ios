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
}
