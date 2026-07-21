import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import React
import GetBoredCore

/// Native Sign in with Apple bridge, exposed to JS as `NativeModules.Account`
/// (see the `RCT_EXTERN_MODULE(Account, ...)` declaration in AccountModule.m).
///
/// Backs the REST API migration's account flows: sign in, sign out, and a
/// cheap "am I signed in" check. All three methods key off the presence of a
/// Keychain-stored session token (`KeychainStore.Item.sessionToken`) —
/// there is no separate local "account" model to keep in sync.
///
/// Call flow for signIn (the only multi-step method):
///
///   JS calls signIn()
///           │
///           ▼
///   beginSignIn (hopped to main queue — SIWA UI must present from main)
///           │
///           ├── a sign-in is already pending → reject("SERVER", ...)
///           ├── generateRawNonce() fails      → reject("SERVER", ...)
///           │
///           └── stash (resolve, reject, rawNonce) on self, retain the
///               ASAuthorizationController on self (see pendingController),
///               then controller.performRequests()
///                       │
///                       ▼ (async — Apple presents its sheet, user acts)
///                       │
///           ┌───────────┴────────────────────────────┐
///           ▼                                         ▼
///   didCompleteWithAuthorization              didCompleteWithError
///           │                                         │
///           ├── decode identityToken/                 ├── .canceled → reject("CANCELLED", ...)
///           │   authorizationCode from credential      └── anything else → reject("SERVER", ...)
///           │
///           ▼
///   POST /auth/apple (authenticated: false) via APIClient
///           │
///           ├── .success → KeychainStore.write(sessionToken, for: .sessionToken)
///           │              → resolve(["userId": ...])
///           │
///           └── .failure(APIError) → rejectSignIn(...) maps to
///                   NETWORK / SIGNED_OUT / SUBSCRIPTION_REQUIRED / SERVER
@objc(Account)
final class AccountModule: NSObject {

    @objc static func requiresMainQueueSetup() -> Bool { true }

    // MARK: - In-flight sign-in state

    /// Non-nil only between `beginSignIn` starting and the delegate callback
    /// (`didCompleteWithAuthorization`/`didCompleteWithError`) firing. Guards
    /// against a second concurrent `signIn()` call and lets the delegate
    /// callbacks — which have no other way to reach this call's promise
    /// blocks — resolve or reject the right JS promise.
    private var pendingResolve: RCTPromiseResolveBlock?
    private var pendingReject: RCTPromiseRejectBlock?

    /// The raw (unhashed) nonce generated for the in-flight request. Needed
    /// again once the credential comes back, to send alongside the identity
    /// token so the backend can re-hash and verify it.
    private var pendingRawNonce: String?

    /// Strong reference to the in-flight `ASAuthorizationController`.
    /// `performRequests()` is asynchronous and returns immediately, so
    /// without this the controller could be deallocated before its delegate
    /// callback fires — a well-known SIWA pitfall. Cleared alongside the
    /// other pending state in `clearPendingState()`.
    private var pendingController: ASAuthorizationController?

    private func clearPendingState() {
        pendingResolve = nil
        pendingReject = nil
        pendingRawNonce = nil
        pendingController = nil
    }

    /// Strong reference to the in-flight web sign-in session ("Use a
    /// different Apple Account"). Same deallocation pitfall as
    /// `pendingController`: `start()` returns immediately and the session
    /// must outlive it until the completion handler fires.
    private var pendingWebSession: ASWebAuthenticationSession?

    // MARK: - signIn

    /// Entry point for the Sign in with Apple button. Hops to the main queue
    /// because `ASAuthorizationController` must be created and presented
    /// from there (`requiresMainQueueSetup` above already asks React Native
    /// to invoke this module's methods on main, but the hop is explicit here
    /// too so this method is correct even if that ever changes).
    @objc func signIn(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async {
            self.beginSignIn(resolve: resolve, reject: reject)
        }
    }

    private func beginSignIn(resolve: @escaping RCTPromiseResolveBlock,
                             reject: @escaping RCTPromiseRejectBlock) {
        guard pendingResolve == nil else {
            reject("SERVER", "A Sign in with Apple request is already in progress", nil)
            return
        }

        guard let rawNonce = Self.generateRawNonce() else {
            reject("SERVER", "Unable to generate a secure nonce for Sign in with Apple", nil)
            return
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        // Apple embeds this HASHED value in the identity token's `nonce`
        // claim. The RAW nonce is sent to the backend below (once the
        // credential comes back) so it can re-hash and compare.
        request.nonce = Self.sha256Hex(rawNonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        pendingResolve = resolve
        pendingReject = reject
        pendingRawNonce = rawNonce
        pendingController = controller

        controller.performRequests()
    }

    /// Maps a failed `/auth/apple` call to the RN rejection codes this
    /// module documents to JS. `.decoding` has no dedicated JS-facing code —
    /// it falls under the same "SERVER" catch-all as `.server`.
    private static func rejectSignIn(_ reject: RCTPromiseRejectBlock, dueTo apiError: APIError) {
        switch apiError {
        case .network(let underlying):
            reject("NETWORK", underlying.localizedDescription, underlying)
        case .signedOut:
            reject("SIGNED_OUT", "Sign in with Apple was rejected: not authenticated", apiError)
        case .subscriptionRequired:
            reject("SUBSCRIPTION_REQUIRED", "Sign in with Apple was rejected: subscription required", apiError)
        case .server(let status):
            reject("SERVER", "Server returned status \(status)", apiError)
        case .decoding(let underlying):
            reject("SERVER", "Failed to decode the server's response", underlying)
        }
    }

    // MARK: - signInWithWebAccount

    /// "Use a different Apple Account": Apple's WEB authorize flow inside an
    /// `ASWebAuthenticationSession`, because the native sheet above is locked
    /// to the device's iCloud account and offers no way to enter other
    /// credentials. The heavy lifting lives on the backend
    /// (`/auth/apple/web/start` → Apple → `/auth/apple/web/callback`); this
    /// method just hosts the browser sheet and catches the final redirect.
    ///
    /// Call flow:
    ///
    ///   JS calls signInWithWebAccount()
    ///           │
    ///           ▼ (main queue — the sheet presents from UI)
    ///   ASWebAuthenticationSession(url: <api>/auth/apple/web/start,
    ///                              callbackURLScheme: "getbored")
    ///           │   prefersEphemeralWebBrowserSession = true
    ///           │     └── no shared cookies: ALWAYS asks for credentials,
    ///           │         which is the entire point of this flow
    ///           ▼
    ///   backend 302 → appleid.apple.com (user signs in with any Apple ID)
    ///           → backend callback verifies + mints session
    ///           → 302 getbored://apple-auth#sessionToken=…&userId=…
    ///           │
    ///           ├── fragment has sessionToken → KeychainStore.write → resolve({userId})
    ///           ├── fragment has error=cancelled → reject(CANCELLED)
    ///           ├── fragment has error=…         → reject(SERVER)
    ///           └── session error .canceledLogin → reject(CANCELLED)
    @objc func signInWithWebAccount(_ resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async {
            self.beginWebSignIn(resolve: resolve, reject: reject)
        }
    }

    private func beginWebSignIn(resolve: @escaping RCTPromiseResolveBlock,
                                reject: @escaping RCTPromiseRejectBlock) {
        guard pendingWebSession == nil else {
            reject("SERVER", "A sign-in is already in progress", nil)
            return
        }

        let startURL = APIEnvironment.baseURL.appendingPathComponent("auth/apple/web/start")
        let session = ASWebAuthenticationSession(
            url: startURL,
            callbackURLScheme: "getbored"
        ) { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                self?.pendingWebSession = nil
                Self.finishWebSignIn(
                    callbackURL: callbackURL,
                    error: error,
                    resolve: resolve,
                    reject: reject
                )
            }
        }
        session.prefersEphemeralWebBrowserSession = true
        session.presentationContextProvider = self
        pendingWebSession = session

        if !session.start() {
            pendingWebSession = nil
            reject("SERVER", "Unable to present the sign-in window", nil)
        }
    }

    private static func finishWebSignIn(callbackURL: URL?,
                                        error: Error?,
                                        resolve: RCTPromiseResolveBlock,
                                        reject: RCTPromiseRejectBlock) {
        if let error {
            let sessionError = error as? ASWebAuthenticationSessionError
            if sessionError?.code == .canceledLogin {
                reject("CANCELLED", "The user canceled Sign in with Apple", error)
                return
            }
            reject("SERVER", error.localizedDescription, error)
            return
        }

        guard let callbackURL,
              let fragment = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.fragment
        else {
            reject("SERVER", "Sign in returned no result", nil)
            return
        }

        // Fragment is `key=value&key=value`; every value the backend sends
        // (JWT, UUID, error slug) is URL-safe, so no percent-decoding pass.
        var values: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                values[parts[0]] = parts[1]
            }
        }

        if let flowError = values["error"] {
            if flowError == "cancelled" {
                reject("CANCELLED", "The user canceled Sign in with Apple", nil)
            } else {
                reject("SERVER", "Sign in failed on the server", nil)
            }
            return
        }

        guard let sessionToken = values["sessionToken"], let userId = values["userId"] else {
            reject("SERVER", "Sign in returned an incomplete result", nil)
            return
        }

        KeychainStore.write(sessionToken, for: .sessionToken)
        resolve(["userId": userId])
    }

    // MARK: - signOut

    /// Revokes the session server-side (best-effort) and always clears the
    /// local session token, resolving regardless of the network outcome —
    /// signing out must never leave the user stuck mid-flow because a
    /// logout request happened to fail. The endpoint always returns 204 on
    /// success; even on failure this device can no longer present the
    /// deleted token, so the server-side row simply outlives it until it
    /// naturally expires.
    @objc func signOut(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        APIClient.shared.send(.post, path: "/auth/logout", authenticated: true) { _ in
            KeychainStore.delete(.sessionToken)
            resolve(nil)
        }
    }

    // MARK: - deleteAccount

    /// Permanently deletes the account (App Review guideline 5.1.1(v)).
    ///
    /// Server side, DELETE /api/account revokes the stored Apple refresh
    /// grants (TN3194), revokes every session, and cascades devices, lists,
    /// and identities away. The endpoint is exempt from the entitlement gate,
    /// so a lapsed subscriber can still delete their account.
    ///
    /// Locally, success clears every trace and stops filtering:
    ///
    ///   DELETE /api/account (authenticated)
    ///           │
    ///           ├── .success → KeychainStore.delete(.sessionToken)
    ///           │              KeychainStore.delete(.serverDeviceID)   ← server row is gone
    ///           │              DispatchQueue.main.async
    ///           │                  ├── applyFilterListSnapshot(empty)  ← filtering stops,
    ///           │                  │     same as the subscription-lapse path
    ///           │                  └── resolve(nil)
    ///           │
    ///           └── .failure → same SIGNED_OUT / SUBSCRIPTION_REQUIRED /
    ///                          NETWORK / SERVER mapping as signIn; nothing
    ///                          is cleared locally on failure, so the user
    ///                          can retry.
    @objc func deleteAccount(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
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
                    resolve(nil)
                }
            case .failure(let apiError):
                Self.rejectSignIn(reject, dueTo: apiError)
            }
        }
    }

    // MARK: - redeemActivationCode

    /// Redeems a one-time activation code against the signed-in account.
    /// The backend owns validation and atomically flips the live entitlement;
    /// this bridge deliberately never stores the submitted code.
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
                Self.rejectSignIn(reject, dueTo: error)
            }
        }
    }

    // MARK: - currentAccount

    /// Reports sign-in state to JS. Keychain presence of a session token is
    /// the source of truth: a missing token always means signed out, and a
    /// present token always means signed in, regardless of what `/api/me`
    /// does or doesn't return.
    ///
    /// Call flow:
    ///
    ///   currentAccount()
    ///           │
    ///           ├── KeychainStore.read(.sessionToken) == nil
    ///           │       └── resolve(["signedIn": false])   ← no network call
    ///           │
    ///           └── token present
    ///                   ▼
    ///           GET /api/me (authenticated: true)
    ///                   ├── .success → resolve(["signedIn": true, "userId": ...])
    ///                   └── .failure → resolve(["signedIn": true])   ← never reject
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
                var payload: [String: Any] = ["signedIn": true, "userId": me.userId]
                payload["plan"] = me.plan
                if let email = me.contactEmail ?? me.identityEmail {
                    payload["email"] = email
                }
                resolve(payload)
            case .failure:
                // Keychain presence already answered "signedIn" above; a
                // failed enrichment call just means userId/email are omitted.
                resolve(["signedIn": true])
            }
        }
    }

    // MARK: - Nonce generation

    /// Generates the raw (unhashed) Sign in with Apple nonce: 32
    /// cryptographically random bytes, base64url-encoded (RFC 4648 §5, no
    /// padding).
    ///
    /// Returns `nil` only if `SecRandomCopyBytes` itself fails — an
    /// exceedingly rare condition surfaced to JS as a plain "SERVER"
    /// rejection rather than a crash, since there is no safe fallback
    /// source of randomness to substitute for a cryptographic nonce.
    private static func generateRawNonce(byteCount: Int = 32) -> String? {
        var randomBytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &randomBytes)
        guard status == errSecSuccess else {
            return nil
        }
        return base64URLEncode(Data(randomBytes))
    }

    /// RFC 4648 §5 base64url encoding with padding stripped: `+`→`-`, `/`→`_`, no `=`.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex SHA-256 digest of `input`'s UTF-8 bytes. This is the
    /// exact transform Apple applies to what we hand it as
    /// `ASAuthorizationAppleIDRequest.nonce` before embedding it in the
    /// identity token's `nonce` claim, and the same transform the backend
    /// re-applies to the raw nonce this module sends alongside the token —
    /// its `sha256Hex` check — to confirm the two match. The web SPA hashes
    /// its own nonce the same way.
    private static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ASAuthorizationControllerDelegate

extension AccountModule: ASAuthorizationControllerDelegate {

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let resolve = pendingResolve,
              let reject = pendingReject,
              let rawNonce = pendingRawNonce
        else {
            // No pending signIn() call tracked — this delegate is only ever
            // attached while one is in flight, so this should not happen.
            return
        }
        clearPendingState()

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            reject("SERVER", "Sign in with Apple returned an unexpected credential type", nil)
            return
        }

        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            reject("SERVER", "Sign in with Apple did not return an identity token", nil)
            return
        }

        let authorizationCode = credential.authorizationCode.flatMap {
            String(data: $0, encoding: .utf8)
        }

        let requestBody = AppleSignInRequestBody(
            identityToken: identityToken,
            nonce: rawNonce,
            authorizationCode: authorizationCode
        )

        guard let jsonBody = try? JSONEncoder().encode(requestBody) else {
            reject("SERVER", "Failed to encode the Sign in with Apple request body", nil)
            return
        }

        // CRITICAL: no "redirectUri" field — that only applies to the web
        // SPA's redirect-based flow. Native codes have no redirect binding.
        APIClient.shared.sendDecoding(
            AppleSignInResponse.self,
            method: .post,
            path: "/auth/apple",
            jsonBody: jsonBody,
            authenticated: false
        ) { result in
            switch result {
            case .success(let response):
                KeychainStore.write(response.sessionToken, for: .sessionToken)
                resolve(["userId": response.userId])
            case .failure(let apiError):
                Self.rejectSignIn(reject, dueTo: apiError)
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        guard let reject = pendingReject else {
            return
        }
        clearPendingState()

        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
            reject("CANCELLED", "The user canceled Sign in with Apple", error)
            return
        }

        reject("SERVER", error.localizedDescription, error)
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding

extension AccountModule: ASAuthorizationControllerPresentationContextProviding {

    /// Returns the app's key window as the anchor the Sign in with Apple
    /// sheet presents from.
    ///
    /// This app has no `UIApplicationSceneManifest` (see Info.plist) — it is
    /// a classic, non-scene `RCTAppDelegate` app — so the window lives on
    /// `UIApplication.shared.delegate`, not on a `UIWindowScene`.
    ///
    /// `UIApplicationDelegate.window` is an `@objc optional` protocol
    /// property whose declared type is already `UIWindow?`, so accessing it
    /// through `delegate?.window` produces `UIWindow??` (one layer for "the
    /// requirement might not be implemented", one for the property's own
    /// optionality). `?? nil` flattens that back down to `UIWindow?` before
    /// the `if let` below.
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window = UIApplication.shared.delegate?.window ?? nil {
            return window
        }
        // Should not happen in practice: signIn() can only run after the app
        // has finished launching and RCTAppDelegate has assigned its window.
        // A fresh UIWindow satisfies the non-optional return type without
        // crashing if it somehow does.
        return UIWindow()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AccountModule: ASWebAuthenticationPresentationContextProviding {

    /// Same key-window anchor as the native sheet above (see that method's
    /// doc comment for the `UIWindow??` flattening).
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = UIApplication.shared.delegate?.window ?? nil {
            return window
        }
        return UIWindow()
    }
}

// MARK: - Wire models

/// POST /auth/apple request body. `authorizationCode` is encoded only when
/// present — native Sign in with Apple always yields an identity token, but
/// the authorization code is a secondary credential that can be absent;
/// omitting the JSON key entirely (rather than sending `null`) is why this
/// type has a hand-written `encode(to:)` instead of the synthesized one.
private struct AppleSignInRequestBody: Encodable {
    let identityToken: String
    let nonce: String
    let authorizationCode: String?

    private enum CodingKeys: String, CodingKey {
        case identityToken
        case nonce
        case authorizationCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identityToken, forKey: .identityToken)
        try container.encode(nonce, forKey: .nonce)
        try container.encodeIfPresent(authorizationCode, forKey: .authorizationCode)
    }
}

/// POST /auth/apple success response body.
private struct AppleSignInResponse: Decodable {
    let sessionToken: String
    let userId: String
}

/// GET /api/me response body, narrowed to the fields `currentAccount` uses.
/// `JSONDecoder` ignores undeclared response fields (plan), so this stays
/// decoupled from fields this module never reads. Both email fields are
/// nullable on the wire; `contactEmail` is the user-managed address and wins
/// over `identityEmail` (the Apple-provided one, possibly a private relay).
private struct MeResponse: Decodable {
    let userId: String
    let contactEmail: String?
    let identityEmail: String?
    let plan: String
}

private struct ActivationCodeRequest: Encodable {
    let code: String
}
