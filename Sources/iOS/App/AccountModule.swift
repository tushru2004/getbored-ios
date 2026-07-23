import Foundation
import AuthenticationServices
import CryptoKit
import os.log
import UIKit
import React
import GetBoredCore

private let logger = Logger(
    subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
    category: "AccountModule"
)

/// Native Sign in with Apple bridge, exposed to JS as `NativeModules.Account`
/// (see the `RCT_EXTERN_MODULE(Account, ...)` declaration in AccountModule.m).
///
/// Backs the REST API migration's account flows:
///   - signIn                — native Sign in with Apple sheet (diagram below)
///   - signInWithWebAccount  — "use a different Apple Account" web flow
///   - signOut               — best-effort server revoke, always clears the local token
///   - deleteAccount         — permanent account deletion (App Review 5.1.1(v))
///   - redeemActivationCode  — redeem a one-time entitlement code
///   - currentAccount        — cheap "am I signed in" check, optionally enriched from /api/me
///
/// Sign-in state is the presence of a Keychain-stored session token
/// (`KeychainStore.Item.sessionToken`): signIn/signInWithWebAccount write it,
/// signOut/deleteAccount clear it, and currentAccount reads it (and clears
/// it too when the server rejects it outright — see currentAccount below).
/// There is no separate local "account" model to keep in sync.
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

    @objc static func requiresMainQueueSetup() -> Bool {
        logger.info("begin requiresMainQueueSetup")
        logger.info("end requiresMainQueueSetup: true")
        return true
    }

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
        logger.info("begin clearPendingState")
        pendingResolve = nil
        pendingReject = nil
        pendingRawNonce = nil
        pendingController = nil
        logger.info("end clearPendingState")
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
        logger.info("begin signIn")
        DispatchQueue.main.async {
            self.beginSignIn(resolve: resolve, reject: reject)
        }
        logger.info("end signIn: queued on main")
    }

    private func beginSignIn(resolve: @escaping RCTPromiseResolveBlock,
                             reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin beginSignIn")
        guard pendingResolve == nil else {
            logger.warning("end beginSignIn: request already in progress")
            reject("SERVER", "A Sign in with Apple request is already in progress", nil)
            return
        }

        guard let rawNonce = Self.generateRawNonce() else {
            logger.error("end beginSignIn: secure nonce generation failed")
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
        logger.info("end beginSignIn: authorization request presented")
    }

    /// Maps a failed `/auth/apple` call to the RN rejection codes this
    /// module documents to JS. `.decoding` has no dedicated JS-facing code —
    /// it falls under the same "SERVER" catch-all as `.server`.
    private static func rejectSignIn(_ reject: RCTPromiseRejectBlock, dueTo apiError: APIError) {
        logger.info("begin rejectSignIn")
        switch apiError {
        case .network(let underlying):
            logger.warning("end rejectSignIn: NETWORK: \(underlying as NSError, privacy: .public)")
            reject("NETWORK", underlying.localizedDescription, underlying)
        case .signedOut:
            logger.warning("end rejectSignIn: SIGNED_OUT")
            reject("SIGNED_OUT", "Sign in with Apple was rejected: not authenticated", apiError)
        case .subscriptionRequired:
            logger.warning("end rejectSignIn: SUBSCRIPTION_REQUIRED")
            reject("SUBSCRIPTION_REQUIRED", "Sign in with Apple was rejected: subscription required", apiError)
        case .server(let status):
            logger.error("end rejectSignIn: SERVER status=\(status, privacy: .public)")
            reject("SERVER", "Server returned status \(status)", apiError)
        case .decoding(let underlying):
            logger.error("end rejectSignIn: SERVER decode failure: \(underlying as NSError, privacy: .public)")
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
        logger.info("begin signInWithWebAccount")
        DispatchQueue.main.async {
            self.beginWebSignIn(resolve: resolve, reject: reject)
        }
        logger.info("end signInWithWebAccount: queued on main")
    }

    private func beginWebSignIn(resolve: @escaping RCTPromiseResolveBlock,
                                reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin beginWebSignIn")
        guard pendingWebSession == nil else {
            logger.warning("end beginWebSignIn: request already in progress")
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
            logger.error("end beginWebSignIn: session presentation failed")
            reject("SERVER", "Unable to present the sign-in window", nil)
            return
        }
        logger.info("end beginWebSignIn: web session presented")
    }

    private static func finishWebSignIn(callbackURL: URL?,
                                        error: Error?,
                                        resolve: RCTPromiseResolveBlock,
                                        reject: RCTPromiseRejectBlock) {
        logger.info("begin finishWebSignIn")
        if let error {
            let sessionError = error as? ASWebAuthenticationSessionError
            if sessionError?.code == .canceledLogin {
                logger.warning("end finishWebSignIn: user cancelled")
                reject("CANCELLED", "The user canceled Sign in with Apple", error)
                return
            }
            logger.error("end finishWebSignIn: web session failed: \(error as NSError, privacy: .public)")
            reject("SERVER", error.localizedDescription, error)
            return
        }

        guard let callbackURL,
              let fragment = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.fragment
        else {
            logger.error("end finishWebSignIn: callback or fragment missing")
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
                logger.warning("end finishWebSignIn: server flow cancelled")
                reject("CANCELLED", "The user canceled Sign in with Apple", nil)
            } else {
                logger.error("end finishWebSignIn: server flow error=\(flowError, privacy: .public)")
                reject("SERVER", "Sign in failed on the server", nil)
            }
            return
        }

        guard let sessionToken = values["sessionToken"], let userId = values["userId"] else {
            logger.error("end finishWebSignIn: incomplete callback result")
            reject("SERVER", "Sign in returned an incomplete result", nil)
            return
        }

        KeychainStore.write(sessionToken, for: .sessionToken)
        logger.info("end finishWebSignIn: session stored for userId=\(userId, privacy: .public)")
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
        logger.info("begin signOut")
        APIClient.shared.send(.post, path: "/auth/logout", authenticated: true) { result in
            switch result {
            case .success:
                logger.info("signOut: server session revoked")
            case .failure(let error):
                switch error {
                case .network(let underlying), .decoding(let underlying):
                    logger.warning("signOut: best-effort server revoke failed: \(underlying as NSError, privacy: .public)")
                case .server(let status):
                    logger.warning("signOut: best-effort server revoke failed with status=\(status, privacy: .public)")
                case .signedOut:
                    logger.warning("signOut: server already considers session signed out")
                case .subscriptionRequired:
                    logger.warning("signOut: server rejected revoke as subscriptionRequired")
                }
            }
            KeychainStore.delete(.sessionToken)
            logger.info("end signOut: local session cleared")
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
                    logger.info("end deleteAccount: account data and local policy cleared")
                    resolve(nil)
                }
            case .failure(let apiError):
                logger.error("end deleteAccount: request failed")
                Self.rejectSignIn(reject, dueTo: apiError)
            }
        }
    }

    // MARK: - redeemActivationCode

    /// Redeems a one-time activation code against the signed-in account.
    /// The backend owns validation and atomically flips the live entitlement;
    /// this bridge deliberately never stores the submitted code.
    ///
    /// Call flow:
    ///
    ///   JS calls redeemActivationCode(code)
    ///           │
    ///           ├── JSONEncoder().encode(ActivationCodeRequest) fails → reject("SERVER")
    ///           │
    ///           ▼
    ///   POST /api/activation/redeem (authenticated) via APIClient
    ///           │
    ///           ├── .success               → resolve(nil)
    ///           ├── .failure(.server(400)) → reject("INVALID_CODE")   ← bad / already-used code
    ///           ├── .failure(.server(429)) → reject("RATE_LIMITED")   ← too many attempts
    ///           └── .failure(other)        → rejectSignIn(...) maps to
    ///                                         NETWORK / SIGNED_OUT / SUBSCRIPTION_REQUIRED / SERVER
    @objc func redeemActivationCode(_ code: String,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin redeemActivationCode")
        guard let body = try? JSONEncoder().encode(ActivationCodeRequest(code: code)) else {
            logger.error("end redeemActivationCode: request encoding failed")
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
                logger.info("end redeemActivationCode: activation redeemed")
                resolve(nil)
            case .failure(.server(let status)) where status == 400:
                logger.warning("end redeemActivationCode: invalid or unavailable code")
                reject("INVALID_CODE", "That activation code is invalid or unavailable.", nil)
            case .failure(.server(let status)) where status == 429:
                logger.warning("end redeemActivationCode: rate limited")
                reject("RATE_LIMITED", "Too many attempts. Try again later.", nil)
            case .failure(let error):
                logger.error("end redeemActivationCode: request failed")
                Self.rejectSignIn(reject, dueTo: error)
            }
        }
    }

    // MARK: - currentAccount

    /// Reports sign-in state to JS. Keychain presence of a session token
    /// answers "signed in" — with one exception: a token the server rejects
    /// outright (401) is dead weight, and keeping it would strand the user
    /// in a permanent "signed in but nothing works" shell (expired 30-day
    /// session, token minted against a different environment). That token
    /// is deleted here and the user is reported signed out, exactly as if
    /// they had tapped Sign Out. Transient failures (offline, 5xx) must NOT
    /// sign the user out — a network blip is not a revoked session — so
    /// they keep the token and merely omit the enrichment fields.
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
    ///                   ├── .success → resolve(["signedIn": true, "userId", "plan",
    ///                   │                        + "email" when contactEmail ?? identityEmail present])
    ///                   ├── .failure(.signedOut)   ← server said 401: token expired/foreign
    ///                   │       └── KeychainStore.delete(.sessionToken)
    ///                   │           resolve(["signedIn": false])
    ///                   └── .failure(anything else) → resolve(["signedIn": true])
    ///                           ← offline/5xx: never reject; enrichment omitted
    @objc func currentAccount(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
        logger.info("begin currentAccount")
        guard KeychainStore.read(.sessionToken) != nil else {
            logger.info("end currentAccount: signed out locally")
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
                let hasEmail = me.contactEmail != nil || me.identityEmail != nil
                logger.info("end currentAccount: signed in userId=\(me.userId, privacy: .public) plan=\(me.plan, privacy: .public) emailPresent=\(hasEmail, privacy: .public)")
                resolve(payload)
            case .failure(.signedOut):
                // The server rejected the token itself (expired, revoked, or
                // minted for another environment). Holding onto it would show
                // a zombie "signed in" state forever; discard it like signOut
                // does and let the welcome screen offer a fresh sign-in.
                KeychainStore.delete(.sessionToken)
                logger.warning("end currentAccount: server rejected stored session; local session cleared")
                resolve(["signedIn": false])
            case .failure(let error):
                // Keychain presence already answered "signedIn" above; a
                // failed enrichment call just means userId/email are omitted.
                switch error {
                case .network(let underlying), .decoding(let underlying):
                    logger.warning("end currentAccount: enrichment unavailable: \(underlying as NSError, privacy: .public)")
                case .server(let status):
                    logger.warning("end currentAccount: enrichment server status=\(status, privacy: .public)")
                case .subscriptionRequired:
                    logger.warning("end currentAccount: enrichment subscriptionRequired")
                case .signedOut:
                    break
                }
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
        logger.info("begin generateRawNonce")
        var randomBytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &randomBytes)
        guard status == errSecSuccess else {
            logger.error("end generateRawNonce: SecRandomCopyBytes status=\(status, privacy: .public)")
            return nil
        }
        logger.info("end generateRawNonce: generated secure random bytes")
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
        logger.info("begin authorizationController.didCompleteWithAuthorization")
        guard let resolve = pendingResolve,
              let reject = pendingReject,
              let rawNonce = pendingRawNonce
        else {
            // No pending signIn() call tracked — this delegate is only ever
            // attached while one is in flight, so this should not happen.
            logger.error("end authorizationController.didCompleteWithAuthorization: pending state missing")
            return
        }
        clearPendingState()

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            logger.error("end authorizationController.didCompleteWithAuthorization: unexpected credential type")
            reject("SERVER", "Sign in with Apple returned an unexpected credential type", nil)
            return
        }

        guard let identityTokenData = credential.identityToken,
              let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            logger.error("end authorizationController.didCompleteWithAuthorization: identity token missing or invalid")
            reject("SERVER", "Sign in with Apple did not return an identity token", nil)
            return
        }

        let authorizationCode = credential.authorizationCode.flatMap {
            String(data: $0, encoding: .utf8)
        }
        logger.info("authorizationController.didCompleteWithAuthorization: authorizationCodePresent=\(authorizationCode != nil, privacy: .public)")

        let requestBody = AppleSignInRequestBody(
            identityToken: identityToken,
            nonce: rawNonce,
            authorizationCode: authorizationCode
        )

        guard let jsonBody = try? JSONEncoder().encode(requestBody) else {
            logger.error("end authorizationController.didCompleteWithAuthorization: request encoding failed")
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
                logger.info("end authorizationController.didCompleteWithAuthorization: session stored for userId=\(response.userId, privacy: .public)")
                resolve(["userId": response.userId])
            case .failure(let apiError):
                logger.error("end authorizationController.didCompleteWithAuthorization: backend sign-in failed")
                Self.rejectSignIn(reject, dueTo: apiError)
            }
        }
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        logger.info("begin authorizationController.didCompleteWithError")
        guard let reject = pendingReject else {
            logger.error("end authorizationController.didCompleteWithError: pending rejection missing")
            return
        }
        clearPendingState()

        if let authorizationError = error as? ASAuthorizationError, authorizationError.code == .canceled {
            logger.warning("end authorizationController.didCompleteWithError: user cancelled")
            reject("CANCELLED", "The user canceled Sign in with Apple", error)
            return
        }

        logger.error("end authorizationController.didCompleteWithError: \(error as NSError, privacy: .public)")
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
        logger.info("begin presentationAnchor.ASAuthorizationController")
        if let window = UIApplication.shared.delegate?.window ?? nil {
            logger.info("end presentationAnchor.ASAuthorizationController: app window")
            return window
        }
        // Should not happen in practice: signIn() can only run after the app
        // has finished launching and RCTAppDelegate has assigned its window.
        // A fresh UIWindow satisfies the non-optional return type without
        // crashing if it somehow does.
        logger.warning("end presentationAnchor.ASAuthorizationController: fallback window")
        return UIWindow()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension AccountModule: ASWebAuthenticationPresentationContextProviding {

    /// Same key-window anchor as the native sheet above (see that method's
    /// doc comment for the `UIWindow??` flattening).
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        logger.info("begin presentationAnchor.ASWebAuthenticationSession")
        if let window = UIApplication.shared.delegate?.window ?? nil {
            logger.info("end presentationAnchor.ASWebAuthenticationSession: app window")
            return window
        }
        logger.warning("end presentationAnchor.ASWebAuthenticationSession: fallback window")
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
        logger.info("begin AppleSignInRequestBody.encode")
        defer { logger.info("end AppleSignInRequestBody.encode") }
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
