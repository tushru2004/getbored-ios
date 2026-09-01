import Foundation
import GetBoredCore
import os.log

/**
 * Every request/response outcome below is written here before returning to
 * the caller — DiagnosticsModule ships this subsystem's OSLogStore entries
 * to the backend, so a request failure not logged here is invisible to
 * remote diagnostics.
 */
private let logger = Logger(
        subsystem: GetBoredIdentifiers.Logging.iOSFilterApp,
        category: "APIClient"
)

/**
 * The diagnostics-upload endpoint itself is logged at `.debug` only (never
 * `.info`/`.warning`) — logging its own traffic at a level DiagnosticsModule
 * captures would make every snapshot include the previous snapshot's upload,
 * compounding indefinitely.
 */
private let diagnosticsUploadPath = "/api/client-events"

/**
 * Selects the REST API backend base URL for the current build configuration.
 *
 * There is no runtime toggle — the backend is baked in at compile time.
 * DEBUG builds (e.g. `make build-device`, simulator builds) talk to the
 * staging backend; RELEASE builds (App Store / TestFlight) talk to production.
 */
enum APIEnvironment {
        #if DEBUG
            static let baseURL = URL(string: "https://dashboard.staging.getbored.online")!
        #else
            static let baseURL = URL(string: "https://dashboard.getbored.online")!
        #endif
}

/**
 * Errors surfaced by `APIClient` to callers.
 *
 * Every case maps to something a caller can act on directly — sign the user
 * out, show a paywall, show a generic error — rather than exposing raw
 * `URLSession`/HTTP detail that every call site would otherwise have to
 * re-interpret.
 */
enum APIError: Error {
        /**
         * No session token was stored locally, or the server rejected the
         * stored token with 401. Either way, the caller should treat the user
         * as signed out.
         */
        case signedOut

        /// The server responded 402 Payment Required: the account's plan does
        /// not currently entitle it to this endpoint.
        case subscriptionRequired

        /// Any other non-2xx HTTP status. Carries the raw status code for
        /// logging/diagnostics; callers usually show a generic error.
        case server(status: Int)

        /// The request never reached the server (offline, timeout, DNS, TLS, …).
        case network(underlying: Error)

        /// The response body was 2xx but did not decode into the expected type.
        case decoding(underlying: Error)

        /// Async `throws` is not typed before Swift 6, so bridge call sites use
        /// this to preserve an `APIError` or safely wrap an unexpected error.
        static func normalized(_ error: Error) -> APIError {
            error as? APIError ?? .network(underlying: error)
        }
}

/**
 * Thin REST client wrapping `URLSession` for the GetBored backend API.
 *
 * Two async entry points:
 *   - `send`: returns the raw HTTP status + body when the caller expects no
 *     JSON body or needs the status code directly.
 *   - `request`: calls `send` and decodes the JSON response into a
 *     `Decodable` model.
 *
 * Usage:
 *
 *   let response = try await APIClient.shared.send(.get, path: "/api/me")
 *
 *   let me = try await APIClient.shared.request(
 *       MeResponse.self,
 *       method: .get,
 *       path: "/api/me"
 *   )
 */
final class APIClient {

        static let shared = APIClient()

        /// HTTP methods this client supports. Deliberately a closed set — every
        /// endpoint this app calls uses one of these four.
        enum Method: String {
            case get = "GET"
            case post = "POST"
            case put = "PUT"
            case delete = "DELETE"
        }

        /**
         * Per-request timeout. Short enough that a hung request doesn't leave
         * callers (and any UI spinner bound to their completion) waiting
         * indefinitely; long enough to tolerate a slow mobile connection.
         */
        private static let requestTimeout: TimeInterval = 15

        private let session: URLSession

        private init() {
            logger.info("begin init")
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            session = URLSession(configuration: configuration)
            logger.info("end init: URLSession configured")
        }

        // MARK: - send

        /**
         * Sends a request and returns the raw HTTP status + body, throwing an
         * `APIError` on failure.
         *
         * Call flow:
         *
         *   prepare request
         *       ├── authentication required, token missing → signedOut (no network call)
         *       └── unauthenticated or token present → send
         *               ├── invalid URL or transport failure → network
         *               ├── 2xx → return status + data
         *               ├── 401 → signedOut
         *               ├── 402 → subscriptionRequired
         *               └── other status → server(status)
         */
        func send(
            _ method: Method,
            path: String,
            query: [URLQueryItem]? = nil,
            jsonBody: Data? = nil,
            authenticated: Bool = true
        ) async throws -> (status: Int, data: Data) {
            Self.logStart(method: method, path: path)

            var bearerToken: String?
            if authenticated {
                guard let token = KeychainStore.read(.sessionToken) else {
                    // No stored session token — treat exactly like a 401 without
                    // spending a network round trip to find that out.
                    let error = APIError.signedOut
                    Self.logFailure(method: method, path: path, error: error)
                    throw error
                }
                bearerToken = token
            }

            guard
                let request = buildRequest(
                    method: method,
                    path: path,
                    query: query,
                    jsonBody: jsonBody,
                    bearerToken: bearerToken
                )
            else {
                let error = APIError.network(underlying: URLError(.badURL))
                Self.logFailure(method: method, path: path, error: error)
                throw error
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                let apiError = APIError.network(underlying: error)
                Self.logFailure(method: method, path: path, error: apiError)
                throw apiError
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                let error = APIError.network(underlying: URLError(.badServerResponse))
                Self.logFailure(method: method, path: path, error: error)
                throw error
            }

            switch httpResponse.statusCode {
            case 200..<300:
                Self.logSuccess(method: method, path: path, status: httpResponse.statusCode)
                return (status: httpResponse.statusCode, data: data)
            case 401:
                let error = APIError.signedOut
                Self.logFailure(method: method, path: path, error: error)
                throw error
            case 402:
                let error = APIError.subscriptionRequired
                Self.logFailure(method: method, path: path, error: error)
                throw error
            default:
                let error = APIError.server(status: httpResponse.statusCode)
                Self.logFailure(method: method, path: path, error: error)
                throw error
            }
        }

        // MARK: - Request/response logging

        /// `true` only for the diagnostics-upload endpoint — see `diagnosticsUploadPath`.
        private static func isDiagnosticsUpload(_ path: String) -> Bool {
            path == diagnosticsUploadPath
        }

        private static func logStart(method: Method, path: String) {
            if isDiagnosticsUpload(path) {
                logger.debug(
                    "begin send: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
                return
            }
            logger.info("begin send: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
        }

        private static func logSuccess(method: Method, path: String, status: Int) {
            if isDiagnosticsUpload(path) {
                logger.debug(
                    "end send: status=\(status, privacy: .public) \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                )
                return
            }
            logger.info(
                "end send: status=\(status, privacy: .public) \(method.rawValue, privacy: .public) \(path, privacy: .public)"
            )
        }

        private static func logFailure(method: Method, path: String, error: APIError) {
            if isDiagnosticsUpload(path) {
                switch error {
                case .signedOut:
                    logger.debug(
                        "end send: signedOut for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                case .subscriptionRequired:
                    logger.debug(
                        "end send: subscriptionRequired for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                case .server(let status):
                    logger.debug(
                        "end send: server status=\(status, privacy: .public) for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                case .network(let underlying):
                    logger.debug(
                        "end send: network failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                    )
                case .decoding(let underlying):
                    logger.debug(
                        "end send: decoding failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                    )
                }
                return
            }

            let logLine: () -> Void
            switch error {
            case .signedOut:
                logLine = {
                    logger.warning(
                        "end send: signedOut for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                }
            case .subscriptionRequired:
                logLine = {
                    logger.warning(
                        "end send: subscriptionRequired for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                }
            case .server(let status):
                logLine = {
                    logger.warning(
                        "end send: server status=\(status, privacy: .public) for \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                    )
                }
            case .network(let underlying):
                logLine = {
                    logger.warning(
                        "end send: network failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                    )
                }
            case .decoding(let underlying):
                logLine = {
                    logger.error(
                        "end send: decoding failure for \(method.rawValue, privacy: .public) \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                    )
                }
            }
            logLine()
        }

        // MARK: - Decoded requests

        /**
         * Calls `send`, then decodes a successful JSON response into `T`.
         *
         * Call flow:
         *
         *   send request
         *       ├── APIError → rethrow it
         *       ├── unexpected error → network
         *       └── success → decode body
         *               ├── valid JSON → return value
         *               └── invalid JSON → decoding(error)
         */
        func request<T: Decodable>(
            _ type: T.Type,
            method: Method,
            path: String,
            query: [URLQueryItem]? = nil,
            jsonBody: Data? = nil,
            authenticated: Bool = true
        ) async throws -> T {
            logger.info("begin request: \(method.rawValue, privacy: .public) \(path, privacy: .public)")
            let response: (status: Int, data: Data)
            do {
                response = try await send(
                    method,
                    path: path,
                    query: query,
                    jsonBody: jsonBody,
                    authenticated: authenticated
                )
            } catch let error as APIError {
                Self.logDecodingFailure(path: path, error: error)
                throw error
            } catch {
                let apiError = APIError.network(underlying: error)
                Self.logDecodingFailure(path: path, error: apiError)
                throw apiError
            }

            do {
                let decoded = try JSONDecoder().decode(T.self, from: response.data)
                logger.info("end request: decoded response for \(path, privacy: .public)")
                return decoded
            } catch {
                let apiError = APIError.decoding(underlying: error)
                Self.logDecodingFailure(path: path, error: apiError)
                throw apiError
            }
        }

        private static func logDecodingFailure(path: String, error: APIError) {
            switch error {
            case .signedOut:
                logger.warning("end request: signedOut for \(path, privacy: .public)")
            case .subscriptionRequired:
                logger.warning("end request: subscriptionRequired for \(path, privacy: .public)")
            case .server(let status):
                logger.warning(
                    "end request: server status=\(status, privacy: .public) for \(path, privacy: .public)"
                )
            case .network(let underlying):
                logger.warning(
                    "end request: network failure for \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                )
            case .decoding(let underlying):
                logger.error(
                    "end request: decoding failure for \(path, privacy: .public): \(underlying as NSError, privacy: .public)"
                )
            }
        }

        // MARK: - Request building

        /**
         * Assembles the `URLRequest` for a call: resolves `path` + `query`
         * against `APIEnvironment.baseURL`, sets the HTTP method, and attaches
         * headers for the JSON body / bearer token when present.
         *
         * Builds the URL by string concatenation (base + leading-slash-normalized
         * path) rather than `URL.appendingPathComponent`, so the result never
         * depends on Foundation's path-merging edge cases — every caller in this
         * app passes an absolute path like "/api/me" or "/auth/apple".
         *
         * Returns `nil` only if URL construction itself fails (e.g. a malformed
         * `path`) — `send` maps that to `.network(URLError(.badURL))`.
         *
         * NOTE: intentionally never sets an "X-Session-Delivery" header — that
         * header is the web SPA's opt-in to receive the session token as an
         * HttpOnly cookie instead of in the JSON response body. Native always
         * wants the token in the body so it can store it in the Keychain itself.
         */
        private func buildRequest(
            method: Method,
            path: String,
            query: [URLQueryItem]?,
            jsonBody: Data?,
            bearerToken: String?
        ) -> URLRequest? {
            let isDiagnosticsUpload = Self.isDiagnosticsUpload(path)
            if isDiagnosticsUpload {
                logger.debug(
                    "begin buildRequest: \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                )
            } else {
                logger.info(
                    "begin buildRequest: \(method.rawValue, privacy: .public) \(path, privacy: .public)"
                )
            }

            let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

            guard
                var components = URLComponents(
                    string: APIEnvironment.baseURL.absoluteString + normalizedPath)
            else {
                if isDiagnosticsUpload {
                    logger.debug(
                        "end buildRequest: invalid URL components for \(path, privacy: .public)")
                } else {
                    logger.error(
                        "end buildRequest: invalid URL components for \(path, privacy: .public)")
                }
                return nil
            }
            components.queryItems = query

            guard let url = components.url else {
                if isDiagnosticsUpload {
                    logger.debug("end buildRequest: invalid URL for \(path, privacy: .public)")
                } else {
                    logger.error("end buildRequest: invalid URL for \(path, privacy: .public)")
                }
                return nil
            }

            var request = URLRequest(url: url)
            request.httpMethod = method.rawValue
            request.httpBody = jsonBody

            if jsonBody != nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            if let bearerToken {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }

            if isDiagnosticsUpload {
                logger.debug("end buildRequest: request ready for \(path, privacy: .public)")
            } else {
                logger.info("end buildRequest: request ready for \(path, privacy: .public)")
            }
            return request
        }
}
