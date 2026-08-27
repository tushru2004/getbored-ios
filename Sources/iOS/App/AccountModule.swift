import Foundation
import GetBoredCore
import React
import os.log

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

    /// Starts the shared password-authentication pipeline for an existing account.
    ///
    /// Call flow:
    ///
    ///   JS calls signIn(username, password)
    ///           │
    ///           ▼
    ///   authenticate("/auth/password/login", ...)
    ///           │
    ///           ├── encodes credentials without logging or persisting the password
    ///           ├── POSTs the unauthenticated request
    ///           └── success → stores only the returned session token in Keychain
    @objc func signIn(
        _ username: String,
        password: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        authenticate(
            path: "/auth/password/login",
            username: username,
            password: password,
            resolve: resolve,
            reject: reject
        )
    }

    /// Starts the same password-authentication pipeline for a new account.
    /// The shared pipeline deliberately owns error mapping so sign-in and
    /// sign-up cannot present different outcomes for the same server response.
    ///
    /// Call flow:
    ///
    ///   JS calls signUp(username, password)
    ///           │
    ///           ▼
    ///   authenticate("/auth/password/signup", ...)
    ///           │
    ///           └── follows the same encode → request → Keychain-write path as signIn
    @objc func signUp(
        _ username: String,
        password: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        authenticate(
            path: "/auth/password/signup",
            username: username,
            password: password,
            resolve: resolve,
            reject: reject
        )
    }

    /// Converts the password response into local session state and the bridge
    /// contract used by both sign-in and sign-up.
    ///
    /// Call flow:
    ///
    ///   signIn/signUp
    ///           │
    ///           ▼
    ///   authenticate(path, username, password)
    ///           │
    ///           ├── JSON encoding fails → reject(SERVER) before starting a Task
    ///           └── Task
    ///                   ├── API success → KeychainStore.write(sessionToken) → resolve(userId)
    ///                   ├── known HTTP status → bridge-specific reject code
    ///                   └── other failure → rejectRequest(...) normalizes APIError
    private func authenticate(
        path: String,
        username: String,
        password: String,
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        logger.info("begin authenticate path=\(path, privacy: .public)")
        guard
            let body = try? JSONEncoder().encode(
                PasswordAuthRequest(username: username, password: password)
            )
        else {
            reject("SERVER", "Failed to encode the sign-in request", nil)
            return
        }

        Task {
            do {
                let response = try await APIClient.shared.request(
                    PasswordAuthResponse.self,
                    method: .post,
                    path: path,
                    jsonBody: body,
                    authenticated: false
                )
                KeychainStore.write(response.sessionToken, for: .sessionToken)
                logger.info(
                    "end authenticate: session stored userId=\(response.userId, privacy: .public)")
                resolve(["userId": response.userId])
            } catch APIError.signedOut {
                reject("INVALID_CREDENTIALS", "Invalid username or password.", nil)
            } catch APIError.server(let status) where status == 409 {
                reject("USERNAME_UNAVAILABLE", "That username is unavailable.", nil)
            } catch APIError.server(let status) where status == 400 {
                reject(
                    "INVALID_INPUT",
                    "Use a 3-64 character username and a password of at least 8 characters.",
                    nil
                )
            } catch APIError.server(let status) where status == 429 {
                reject("RATE_LIMITED", "Too many attempts. Try again later.", nil)
            } catch {
                Self.rejectRequest(reject, dueTo: APIError.normalized(error))
            }
        }
    }

    /// Revokes the server session when possible, then always clears the local
    /// token. Local sign-out must complete while offline, so revocation is
    /// explicitly best-effort.
    ///
    /// Call flow:
    ///
    ///   JS calls signOut()
    ///           │
    ///           ▼
    ///   POST /auth/logout
    ///           │
    ///           ├── success → continue
    ///           └── failure → log only; continue
    ///                   │
    ///                   ▼
    ///               KeychainStore.delete(.sessionToken) → resolve(nil)
    @objc func signOut(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        logger.info("begin signOut")
        Task {
            do {
                _ = try await APIClient.shared.send(
                    .post,
                    path: "/auth/logout",
                    authenticated: true
                )
            } catch {
                logger.warning(
                    "signOut: best-effort revoke failed: \(String(describing: error), privacy: .public)"
                )
            }
            KeychainStore.delete(.sessionToken)
            logger.info("end signOut: local session cleared")
            resolve(nil)
        }
    }

    /// Deletes the account remotely, then clears all local account and policy
    /// state on the main actor so the filter cannot retain a deleted account's
    /// rules.
    ///
    /// Call flow:
    ///
    ///   JS calls deleteAccount()
    ///           │
    ///           ▼
    ///   DELETE /api/account
    ///           │
    ///           ├── failure → rejectRequest(...), preserving local state
    ///           └── success → clear Keychain token + device ID
    ///                           │
    ///                           ▼
    ///                       MainActor.applyFilterListSnapshot(empty) → resolve(nil)
    @objc func deleteAccount(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        logger.info("begin deleteAccount")
        Task {
            do {
                _ = try await APIClient.shared.send(
                    .delete,
                    path: "/api/account",
                    authenticated: true
                )
                KeychainStore.delete(.sessionToken)
                KeychainStore.delete(.serverDeviceID)
                await MainActor.run {
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
            } catch {
                Self.rejectRequest(reject, dueTo: APIError.normalized(error))
            }
        }
    }

    /// Redeems an authenticated activation code. The code is sent once in the
    /// request body and is not retained locally after the server responds.
    ///
    /// Call flow:
    ///
    ///   JS calls redeemActivationCode(code)
    ///           │
    ///           ├── encoding failure → reject(SERVER)
    ///           └── POST /api/activation/redeem
    ///                   ├── success → resolve(nil)
    ///                   ├── 400/429 → specific JS rejection
    ///                   └── other error → rejectRequest(...)
    @objc func redeemActivationCode(
        _ code: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        guard let body = try? JSONEncoder().encode(ActivationCodeRequest(code: code)) else {
            reject("SERVER", "Failed to encode the activation request", nil)
            return
        }
        Task {
            do {
                _ = try await APIClient.shared.send(
                    .post,
                    path: "/api/activation/redeem",
                    jsonBody: body,
                    authenticated: true
                )
                resolve(nil)
            } catch APIError.server(let status) where status == 400 {
                reject("INVALID_CODE", "That activation code is invalid or unavailable.", nil)
            } catch APIError.server(let status) where status == 429 {
                reject("RATE_LIMITED", "Too many attempts. Try again later.", nil)
            } catch {
                Self.rejectRequest(reject, dueTo: APIError.normalized(error))
            }
        }
    }

    /// Verifies the locally stored session against the server before reporting
    /// that the UI may treat the account as signed in.
    ///
    /// Call flow:
    ///
    ///   JS calls currentAccount()
    ///           │
    ///           ├── no local token → resolve(signedIn: false)  ← no network call
    ///           └── token present → GET /api/me
    ///                   ├── success → resolve account payload
    ///                   ├── 401 → delete stale token → resolve(signedIn: false)
    ///                   └── other error → rejectRequest(...)  ← do not trust token alone
    @objc func currentAccount(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        guard KeychainStore.read(.sessionToken) != nil else {
            resolve(["signedIn": false])
            return
        }

        Task {
            do {
                let me = try await APIClient.shared.request(
                    MeResponse.self,
                    method: .get,
                    path: "/api/me",
                    authenticated: true
                )
                var payload: [String: Any] = [
                    "signedIn": true,
                    "userId": me.userId,
                    "plan": me.plan,
                    "accountKind": me.accountKind,
                ]
                if let username = me.username { payload["username"] = username }
                if let email = me.contactEmail ?? me.identityEmail { payload["email"] = email }
                resolve(payload)
            } catch APIError.signedOut {
                KeychainStore.delete(.sessionToken)
                resolve(["signedIn": false])
            } catch {
                logger.warning(
                    "currentAccount: account state unavailable: \(String(describing: error), privacy: .public)"
                )
                // Fail closed. A stored token alone does not prove that the
                // account has an active plan or is the server-owned review
                // demo account, so the UI must not advance past its gates.
                Self.rejectRequest(reject, dueTo: APIError.normalized(error))
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
