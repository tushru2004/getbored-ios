import Foundation
import NetworkExtension
import CloudKit
import React

@objc(FilterStatus)
final class FilterStatusModule: NSObject {
    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func current(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        NEFilterManager.shared().loadFromPreferences { filterError in
            let filterEnabled: Bool? = filterError == nil ? NEFilterManager.shared().isEnabled : nil
            let filterErrorMsg = filterError?.localizedDescription

            CKContainer.default().accountStatus { status, ckError in
                let icloudAvailable: Bool? = ckError == nil ? (status == .available) : nil
                let icloudErrorMsg = ckError?.localizedDescription

                let vm = KMPDecisionCoreAdapter.filterStatusViewModel(
                    filterEnabled: filterEnabled,
                    filterErrorMessage: filterErrorMsg,
                    icloudAvailable: icloudAvailable,
                    icloudErrorMessage: icloudErrorMsg
                )
                resolve(vm.toDictionary())
            }
        }
    }
}
