import Foundation
import os.log
import React
import GetBoredCore

private let logger = Logger(
    subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
    category: "AccountModule"
)

/// Native bridge for first-party GetBored username/password sessions.
/// Passwords are sent only in the TLS request body, are never logged, and are
/// never persisted on device. Only the resulting session token is
/// stored in Keychain.
@objc(Account)
final class AccountModule: NSObject {

    @objc static func requiresMainQueueSetup() -> Bool { false }

    @objc func signIn(_ username: String,
                      password: String,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        authenticate(
            path: "/auth/password/login",
            username: username,
            password: password,
            resolve: resolve,
            reject: reject
        )
    }

    @objc func signUp(_ username: String,
                      password: String,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        authenticate(
            path: "/auth/password/signup",
            username: username,
            password: password,
            resolve: resolve,
            reject: reject
        )
    }

    private func authenticate(path: String,
                              username: String,
                              password: String,
                              resolve: @escaping RCTPromiseResolveBlock,
                              reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin authenticate path=\(path, privacy: .public)")
        guard let body = try? JSONEncoder().encode(
            PasswordAuthRequest(username: username, password: password)
        ) else {
            reject("SERVER", "Failed to encode the sign-in request", nil)
            return
        }

        APIClient.shared.sendDecoding(
            PasswordAuthResponse.self,
            method: .post,
            path: path,
            jsonBody: body,
            authenticated: false
        ) { result in
            switch result {
            case .success(let response):
                KeychainStore.write(response.sessionToken, for: .sessionToken)
                logger.info("end authenticate: session stored userId=\(response.userId, privacy: .public)")
                resolve(["userId": response.userId])
            case .failure(.signedOut):
                reject("INVALID_CREDENTIALS", "Invalid username or password.", nil)
            case .failure(.server(let status)) where status == 409:
                reject("USERNAME_UNAVAILABLE", "That username is unavailable.", nil)
            case .failure(.server(let status)) where status == 400:
                reject(
                    "INVALID_INPUT",
                    "Use a 3-64 character username and a password of at least 8 characters.",
                    nil
                )
            case .failure(.server(let status)) where status == 429:
                reject("RATE_LIMITED", "Too many attempts. Try again later.", nil)
            case .failure(let error):
                Self.rejectRequest(reject, dueTo: error)
            }
        }
    }

    @objc func signOut(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin signOut")
        APIClient.shared.send(.post, path: "/auth/logout", authenticated: true) { result in
            if case .failure(let error) = result {
                logger.warning("signOut: best-effort revoke failed: \(String(describing: error), privacy: .public)")
            }
            KeychainStore.delete(.sessionToken)
            logger.info("end signOut: local session cleared")
            resolve(nil)
        }
    }

    @objc func deleteAccount(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin deleteAccount")
        APIClient.shared.send(.delete, path: "/api/account", authenticated: true) { result in
            switch result {
            case .success:
                KeychainStore.delete(.sessionToken)
                KeychainStore.delete(.serverDeviceID)
                DispatchQueue.main.async {
                    IOSRuleStore.shared.applyFilterListSnapshot(
                        mode: .blockSpecific,
                        entries: [],
                        exceptions: [],
                        allowedApps: [],
                        blockedApps: []
                    )
                    logger.info("end deleteAccount: account and local policy cleared")
                    resolve(nil)
                }
            case .failure(let error):
                Self.rejectRequest(reject, dueTo: error)
            }
        }
    }

    @objc func redeemActivationCode(_ code: String,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard let body = try? JSONEncoder().encode(ActivationCodeRequest(code: code)) else {
            reject("SERVER", "Failed to encode the activation request", nil)
            return
        }
        APIClient.shared.send(
            .post,
            path: "/api/activation/redeem",
            jsonBody: body,
            authenticated: true
        ) { result in
            switch result {
            case .success:
                resolve(nil)
            case .failure(.server(let status)) where status == 400:
                reject("INVALID_CODE", "That activation code is invalid or unavailable.", nil)
            case .failure(.server(let status)) where status == 429:
                reject("RATE_LIMITED", "Too many attempts. Try again later.", nil)
            case .failure(let error):
                Self.rejectRequest(reject, dueTo: error)
            }
        }
    }

    @objc func currentAccount(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
        guard KeychainStore.read(.sessionToken) != nil else {
            resolve(["signedIn": false])
            return
        }

        APIClient.shared.sendDecoding(
            MeResponse.self,
            method: .get,
            path: "/api/me",
            authenticated: true
        ) { result in
            switch result {
            case .success(let me):
                var payload: [String: Any] = [
                    "signedIn": true,
                    "userId": me.userId,
                    "plan": me.plan,
                    "accountKind": me.accountKind,
                ]
                if let username = me.username { payload["username"] = username }
                if let email = me.contactEmail ?? me.identityEmail { payload["email"] = email }
                resolve(payload)
            case .failure(.signedOut):
                KeychainStore.delete(.sessionToken)
                resolve(["signedIn": false])
            case .failure(let error):
                logger.warning("currentAccount: account state unavailable: \(String(describing: error), privacy: .public)")
                // Fail closed. A stored token alone does not prove that the
                // account has an active plan or is the server-owned review
                // demo account, so the UI must not advance past its gates.
                Self.rejectRequest(reject, dueTo: error)
            }
        }
    }

    private static func rejectRequest(_ reject: RCTPromiseRejectBlock, dueTo error: APIError) {
        switch error {
        case .network(let underlying):
            reject("NETWORK", underlying.localizedDescription, underlying)
        case .signedOut:
            reject("SIGNED_OUT", "The session is no longer valid.", error)
        case .subscriptionRequired:
            reject("SUBSCRIPTION_REQUIRED", "An active subscription is required.", error)
        case .server(let status):
            reject("SERVER", "Server returned status \(status)", error)
        case .decoding(let underlying):
            reject("SERVER", "Failed to decode the server response", underlying)
        }
    }
}

private struct PasswordAuthRequest: Encodable {
    let username: String
    let password: String
}

private struct PasswordAuthResponse: Decodable {
    let sessionToken: String
    let userId: String
}

private struct MeResponse: Decodable {
    let userId: String
    let contactEmail: String?
    let identityEmail: String?
    let username: String?
    let plan: String
    let accountKind: String
}

private struct ActivationCodeRequest: Encodable {
    let code: String
}
