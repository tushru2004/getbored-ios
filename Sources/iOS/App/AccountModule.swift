import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import React

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
                resolve(["signedIn": true, "userId": me.userId])
            case .failure:
                // Keychain presence already answered "signedIn" above; a
                // failed enrichment call just means "userId" is omitted.
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

/// GET /api/me response body, narrowed to the one field `currentAccount`
/// uses. `JSONDecoder` ignores undeclared response fields (contactEmail,
/// identityEmail, plan), so this stays decoupled from fields this module
/// never reads.
private struct MeResponse: Decodable {
    let userId: String
}
